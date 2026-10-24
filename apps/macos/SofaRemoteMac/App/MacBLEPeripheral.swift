@preconcurrency import CoreBluetooth
import AppleCore
import Foundation

@MainActor
final class MacBLEPeripheral: NSObject, RemotePeer {
    var onReady: (() -> Void)?
    var onMessage: ((WireMessage) -> Void)?
    var onClose: ((String) -> Void)?
    var onAuthenticated: ((MacBLEPeripheral, String, String) -> Void)?
    var onStatus: ((String) -> Void)?
    var isPreauthenticated: Bool { crypto != nil }

    private let serviceName: String
    private let pairedTokens: () -> [(id: String, token: String)]
    private var manager: CBPeripheralManager!
    private var service: CBMutableService?
    private var input: CBMutableCharacteristic?
    private var output: CBMutableCharacteristic?
    private var serviceIsPublished = false
    private var isAdvertising = false
    private var central: CBCentral?
    private var decoder = BLEFrameDecoder()
    private var handshake: BLEHandshake.Server?
    private var awaitingFinish = false
    private var crypto: BLECryptoSession?
    private var isSubscribed = false
    private var closed = false
    private var closing = false
    private var notificationQueue: [Data] = []
    private var queuedBytes = 0
    private var handshakeDeadline: Timer?
    private var frameDeadline: Timer?
    private var closeDeadline: Timer?
    private var sessionID = UUID()

    init(serviceName: String, pairedTokens: @escaping () -> [(id: String, token: String)]) {
        self.serviceName = serviceName
        self.pairedTokens = pairedTokens
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func send(_ message: WireMessage) {
        guard !closed, !closing, var crypto else { return }
        do {
            let frame = try BLEFrameCodec.encode(crypto.seal(message))
            self.crypto = crypto
            enqueueFragments(frame, maximum: central?.maximumUpdateValueLength ?? 20)
        } catch { finish("Bluetooth could not encode the message.") }
    }

    func close() {
        guard !closed, !closing else { return }
        guard var crypto, let connectionID = activeConnectionID else {
            finish("Disconnected")
            return
        }
        do {
            let frame = try BLEFrameCodec.encode(
                crypto.seal(WireMessage(type: .disconnect, connectionID: connectionID)))
            self.crypto = crypto
            closing = true
            let closingSessionID = sessionID
            let expireClose: (Timer) -> Void = { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sessionID == closingSessionID else { return }
                    self.finish("Disconnected")
                }
            }
            closeDeadline = Timer.scheduledTimer(
                withTimeInterval: 2, repeats: false, block: expireClose)
            enqueueFragments(frame, maximum: central?.maximumUpdateValueLength ?? 20)
        } catch { finish("Disconnected") }
    }

    private var activeConnectionID: String?

    func setConnectionID(_ value: String) { activeConnectionID = value }

}

extension MacBLEPeripheral: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            publishService()
            onStatus?("Bluetooth ready")
        case .poweredOff:
            isAdvertising = false
            clearPublishedService()
            handleUnavailableState(
                status: "Bluetooth is off", reason: "Bluetooth became unavailable",
                shouldClose: hasActiveSession)
        case .unauthorized:
            isAdvertising = false
            handleUnavailableState(
                status: "Bluetooth permission is denied in System Settings",
                reason: "Bluetooth permission is unavailable", shouldClose: hasActiveSession)
        case .unsupported:
            isAdvertising = false
            handleUnavailableState(
                status: "This Mac does not support Bluetooth LE",
                reason: "Bluetooth LE is unsupported", shouldClose: hasActiveSession)
        case .resetting:
            isAdvertising = false
            handleUnavailableState(
                status: "Bluetooth is restarting", reason: "Bluetooth is restarting",
                shouldClose: hasActiveSession)
        case .unknown:
            isAdvertising = false
            onStatus?("Waiting for Bluetooth")
            if hasActiveSession { finish("Bluetooth state became unavailable") }
        @unknown default:
            isAdvertising = false
            onStatus?("Bluetooth is unavailable")
            if hasActiveSession { finish("Bluetooth state became unavailable") }
        }
    }

    private var hasActiveSession: Bool {
        central != nil || isSubscribed || handshake != nil || crypto != nil
    }

    private func handleUnavailableState(status: String, reason: String, shouldClose: Bool) {
        onStatus?(status)
        if shouldClose { finish(reason) }
    }

    private func publishService() {
        guard manager.state == .poweredOn else { return }
        if let service {
            if serviceIsPublished { startAdvertising(service) }
            return
        }
        // The pairing ID only narrows the scan candidate; BLEHandshake proves identity.
        let service = CBMutableService(type: CBUUID(string: serviceName), primary: true)
        let input = CBMutableCharacteristic(
            type: CBUUID(string: BLETransportConstants.inputCharacteristicUUID),
            properties: [.write], value: nil, permissions: [.writeable])
        let output = CBMutableCharacteristic(
            type: CBUUID(string: BLETransportConstants.outputCharacteristicUUID),
            properties: [.notify], value: nil, permissions: [.readable])
        self.service = service
        self.input = input
        self.output = output
        serviceIsPublished = false
        service.characteristics = [input, output]
        manager.add(service)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?
    ) {
        guard self.service === service else { return }
        guard error == nil else {
            clearPublishedService()
            onStatus?("Could not publish Bluetooth service")
            return
        }
        serviceIsPublished = true
        startAdvertising(service)
        onStatus?("Ready for paired Bluetooth devices")
    }

    private func startAdvertising(_ service: CBService) {
        guard manager.state == .poweredOn, serviceIsPublished, !isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [service.uuid]
        ])
        isAdvertising = true
    }

    private func clearPublishedService() {
        isAdvertising = false
        service = nil
        input = nil
        output = nil
        serviceIsPublished = false
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic === output else { return }
        if let existing = self.central, existing.identifier != central.identifier { return }
        self.central = central
        isSubscribed = true
        decoder = BLEFrameDecoder()
        handshake = BLEHandshake.Server(serviceName: serviceName, pairedTokens: pairedTokens())
        awaitingFinish = false
        crypto = nil
        activeConnectionID = nil
        closed = false
        let sessionID = UUID()
        self.sessionID = sessionID
        handshakeDeadline?.invalidate()
        handshakeDeadline = Timer.scheduledTimer(
            withTimeInterval: 12, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionID == sessionID else { return }
                self.finish("Bluetooth authentication timed out")
            }
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic === output,
            central.identifier == self.central?.identifier
        else { return }
        finish("Bluetooth disconnected")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
    ) {
        guard requests.count == 1 else {
            if let first = requests.first {
                peripheral.respond(to: first, withResult: .unlikelyError)
            }
            finish("Bluetooth sent an unsupported write batch")
            return
        }
        guard let first = requests.first,
            requests.allSatisfy({
                $0.characteristic === input
                    && $0.central.identifier == central?.identifier
            })
        else {
            if let first = requests.first {
                peripheral.respond(to: first, withResult: .requestNotSupported)
            }
            return
        }
        guard let value = first.value else {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
        }
        do {
            let frames = try decoder.append(value)
            frameDeadline?.invalidate()
            let sessionID = self.sessionID
            frameDeadline =
                decoder.bufferedByteCount > 0
                ? Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.sessionID == sessionID else { return }
                        self.finish("Bluetooth frame timed out")
                    }
                }
                : nil
            for frame in frames { try receiveFrame(frame) }
            peripheral.respond(to: first, withResult: .success)
        } catch {
            peripheral.respond(to: first, withResult: .insufficientResources)
            finish("Bluetooth input was invalid or too large")
        }
    }

    private func receiveFrame(_ frame: Data) throws {
        guard !closing else { return }
        if !awaitingFinish, var pendingHandshake = handshake, crypto == nil {
            let challenge = try pendingHandshake.challenge(to: frame)
            handshake = pendingHandshake
            awaitingFinish = true
            try enqueueHandshake(challenge)
            return
        }
        if awaitingFinish, var pendingHandshake = handshake, crypto == nil {
            let result = try pendingHandshake.finish(frame)
            handshake = nil
            awaitingFinish = false
            crypto = result.session
            handshakeDeadline?.invalidate()
            handshakeDeadline = nil
            onAuthenticated?(self, result.deviceID, result.deviceName)
            return
        }
        guard var crypto else { throw BLETransportError.invalidHandshake }
        let message = try crypto.open(frame)
        self.crypto = crypto
        if message.type == .disconnect { finish("Bluetooth client disconnected"); return }
        activeConnectionID = message.connectionID
        onMessage?(message)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pumpNotifications()
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        closing = false
        sessionID = UUID()
        handshakeDeadline?.invalidate()
        handshakeDeadline = nil
        frameDeadline?.invalidate()
        frameDeadline = nil
        closeDeadline?.invalidate()
        closeDeadline = nil
        notificationQueue.removeAll(keepingCapacity: false)
        queuedBytes = 0
        decoder = BLEFrameDecoder()
        awaitingFinish = false
        crypto = nil
        handshake = nil
        activeConnectionID = nil
        central = nil
        isSubscribed = false
        onClose?(reason)
        onReady = nil
        onMessage = nil
        onClose = nil
    }
}

private extension MacBLEPeripheral {
    func enqueueHandshake(_ payload: Data) throws {
        enqueueFragments(
            try BLEFrameCodec.encode(payload), maximum: central?.maximumUpdateValueLength ?? 20)
    }

    func enqueueFragments(_ frame: Data, maximum: Int) {
        guard frame.count + queuedBytes <= BLEFrameCodec.maximumQueuedBytes else {
            finish("Bluetooth output queue is full")
            return
        }
        var offset = 0
        while offset < frame.count {
            let end = min(frame.count, offset + max(1, maximum))
            let fragment = frame.subdata(in: offset..<end)
            notificationQueue.append(fragment)
            queuedBytes += fragment.count
            offset = end
        }
        pumpNotifications()
    }

    func pumpNotifications() {
        guard isSubscribed, let output else { return }
        while let fragment = notificationQueue.first {
            guard
                manager.updateValue(
                    fragment, for: output, onSubscribedCentrals: central.map { [$0] })
            else { return }
            notificationQueue.removeFirst()
            queuedBytes -= fragment.count
        }
        if closing, notificationQueue.isEmpty { finish("Disconnected") }
    }
}
