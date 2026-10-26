@preconcurrency import CoreBluetooth
import AppleCore
import Foundation

@MainActor
final class IOSBLEPeer: NSObject, RemotePeer {
    var onReady: (() -> Void)?
    var onMessage: ((WireMessage) -> Void)?
    var onClose: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var isPreauthenticated: Bool { crypto != nil }

    private let mac: PairedMac
    private let deviceName: String
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private var clientHandshake: BLEHandshake.Client?
    private var crypto: BLECryptoSession?
    private var decoder = BLEFrameDecoder()
    private var writeQueue: [Data] = []
    private var queuedBytes = 0
    private var writing = false
    private var finishFrameQueued = false
    private var closed = false
    private var frameDeadline: Timer?

    init(mac: PairedMac, deviceName: String) throws {
        self.mac = mac
        self.deviceName = deviceName
        clientHandshake = try BLEHandshake.Client(
            serviceName: mac.serviceName, deviceName: deviceName, token: mac.token)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        guard central.state == .poweredOn else { updateStatus(for: central.state); return }
        central.scanForPeripherals(
            withServices: [CBUUID(string: mac.serviceName)], options: nil)
        onStatus?("Searching for the paired Mac over Bluetooth")
    }

    func send(_ message: WireMessage) {
        guard !closed, var crypto else { return }
        do {
            let frame = try BLEFrameCodec.encode(crypto.seal(message))
            self.crypto = crypto
            enqueue(frame)
        } catch { finish("Bluetooth could not encode the message.") }
    }

    func close() {
        finish("Disconnected")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateStatus(for: central.state)
        if central.state != .poweredOn, peripheral != nil {
            finish("Bluetooth became unavailable")
            return
        }
        guard central.state == .poweredOn, !closed else { return }
        start()
    }

    private func updateStatus(for state: CBManagerState) {
        switch state {
        case .poweredOn: onStatus?("Bluetooth ready")
        case .poweredOff: onStatus?("Turn on Bluetooth in Settings")
        case .unauthorized: onStatus?("Bluetooth permission is denied in Settings")
        case .unsupported: onStatus?("This device does not support Bluetooth LE")
        case .resetting: onStatus?("Bluetooth is restarting")
        case .unknown: onStatus?("Waiting for Bluetooth")
        @unknown default: onStatus?("Bluetooth is unavailable")
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        // A matching GATT UUID is only a routing hint; the PSK handshake authenticates the Mac.
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([CBUUID(string: mac.serviceName)])
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        finish("Could not connect to the paired Mac over Bluetooth.")
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        finish("Bluetooth disconnected")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
            let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: mac.serviceName)
            })
        else { finish("The Mac Bluetooth service is unavailable."); return }
        peripheral.discoverCharacteristics(
            [
                CBUUID(string: BLETransportConstants.inputCharacteristicUUID),
                CBUUID(string: BLETransportConstants.outputCharacteristicUUID)
            ], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil,
            let input = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: BLETransportConstants.inputCharacteristicUUID)
            }),
            let output = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: BLETransportConstants.outputCharacteristicUUID)
            })
        else { finish("The Mac Bluetooth characteristics are unavailable."); return }
        self.input = input
        self.output = output
        peripheral.setNotifyValue(true, for: output)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.uuid == output?.uuid,
            let hello = try? clientHandshake?.hello(), let framed = try? BLEFrameCodec.encode(hello)
        else { finish("Could not start the Bluetooth authenticated session."); return }
        enqueue(framed)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.uuid == output?.uuid, let value = characteristic.value
        else {
            finish("Bluetooth receive failed."); return
        }
        do {
            let frames = try decoder.append(value)
            frameDeadline?.invalidate()
            frameDeadline =
                decoder.bufferedByteCount > 0
                ? Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish("Bluetooth frame timed out") }
                }
                : nil
            for frame in frames { try receiveFrame(frame) }
        } catch { finish("Bluetooth sent an invalid or oversized frame.") }
    }

    private func receiveFrame(_ frame: Data) throws {
        guard let type = frame.first else { throw BLETransportError.invalidFrame }
        if type == 0x01 {
            guard var clientHandshake else { throw BLETransportError.invalidHandshake }
            let finish = try clientHandshake.finish(after: frame)
            self.clientHandshake = nil
            crypto = finish.session
            finishFrameQueued = true
            enqueue(try BLEFrameCodec.encode(finish.message))
            return
        }
        guard type == 0x02, var crypto else { throw BLETransportError.invalidHandshake }
        let message = try crypto.open(frame)
        self.crypto = crypto
        if message.type == .disconnect { finish("The Mac disconnected Bluetooth."); return }
        onMessage?(message)
    }

    private func enqueue(_ frame: Data) {
        let maximum = peripheral?.maximumWriteValueLength(for: .withResponse) ?? 20
        guard frame.count + queuedBytes <= BLEFrameCodec.maximumQueuedBytes else {
            finish("Bluetooth output queue is full")
            return
        }
        var offset = 0
        while offset < frame.count {
            let end = min(frame.count, offset + max(1, maximum))
            let fragment = frame.subdata(in: offset..<end)
            writeQueue.append(fragment)
            queuedBytes += fragment.count
            offset = end
        }
        pumpWrites()
    }

    private func pumpWrites() {
        guard !writing, let peripheral, let input, let fragment = writeQueue.first else { return }
        writing = true
        peripheral.writeValue(fragment, for: input, type: .withResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == input?.uuid else { return }
        guard error == nil, let fragment = writeQueue.first else {
            finish("Bluetooth write failed."); return
        }
        writeQueue.removeFirst()
        queuedBytes -= fragment.count
        writing = false
        if writeQueue.isEmpty, finishFrameQueued {
            finishFrameQueued = false
            onReady?()
        }
        pumpWrites()
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        frameDeadline?.invalidate()
        frameDeadline = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        central.stopScan()
        peripheral?.delegate = nil
        peripheral = nil
        input = nil
        output = nil
        clientHandshake = nil
        crypto = nil
        decoder = BLEFrameDecoder()
        writeQueue.removeAll()
        queuedBytes = 0
        onClose?(reason)
        onReady = nil
        onMessage = nil
        onClose = nil
    }
}

extension IOSBLEPeer: @MainActor CBCentralManagerDelegate, @MainActor CBPeripheralDelegate {}
