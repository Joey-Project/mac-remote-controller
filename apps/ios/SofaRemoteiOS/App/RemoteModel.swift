import AppleCore
import Foundation
import Network
import Observation
import UIKit

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let isPaired: Bool
}

enum RemoteMode: String {
    case touchpad = "Touchpad", keyboard = "Keyboard"
}

enum RemoteTransportKind: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi"
    case bluetooth = "Bluetooth LE"
    var id: String { rawValue }
}

struct BenchmarkPendingProbe {
    let id: String
    let sequence: UInt64
    let sentNanoseconds: UInt64
}

@MainActor
@Observable
final class RemoteModel {
    var discoveredMacs: [DiscoveredMac] = []
    var connectionSummary = "Choose your Mac"
    var isConnected = false
    var remoteState: RemoteState?
    var errorMessage: String?
    var selectedTransport: RemoteTransportKind = .wifi
    var benchmarkRunning = false
    var benchmarkProgress = 0
    var benchmarkResultText: String?
    var benchmarkGroupProgress = ""
    var benchmarkReports: [String: [RTTBenchmarkReport]] = [:]
    var playerVolumeDisplayStates: [String: PlayerVolumeDisplayState] = [:]

    #if DEBUG
        var liveSuccessfulResults = 0
        var liveFailedResults = 0
        var isLiveMediaTesting: Bool {
            ProcessInfo.processInfo.arguments.contains("--live-media-test")
        }
    #endif

    #if DEBUG && targetEnvironment(simulator)
        @ObservationIgnored private let uiTestFixture = UITestFixture()
        private var uiTestLogRevision = 0

        var isUITesting: Bool { uiTestFixture.isActive }
        var uiTestCommandLogJSON: String {
            _ = uiTestLogRevision
            return uiTestFixture.commandLogJSON
        }
    #endif

    private var browser: NWBrowser?
    private var resolver: BonjourResolver?
    var attemptID: UUID?
    var peer: RemotePeer?
    var pairedMacs: [PairedMac] = []
    var candidate: PairedMac?
    var benchmarkTargetID: String?
    var connectionID: String?
    var sequence: UInt64 = 0
    var pending: [String: (metadata: PendingCommandMetadata, sent: ContinuousClock.Instant)] = [:]
    var queuedPlayerVolumeRequests: [QueuedPlayerVolumeRequest] = []
    var pendingPlayerVolumeRequests: [String: QueuedPlayerVolumeRequest] = [:]
    @ObservationIgnored var commandScheduler = InputCommandScheduler(capacity: 8)
    @ObservationIgnored var localPointerDragCoordinator = LocalPointerDragCoordinator()
    var rejectedLocalDragID: UUID?
    private var deadline: Timer?
    @ObservationIgnored var coalescingTimer: Timer?
    var benchmark: RTTBenchmarkAccumulator?
    var benchmarkRequest: BenchmarkPendingProbe?
    var benchmarkRequestTracker = RTTBenchmarkRequestTracker()
    var benchmarkTimeout: Timer?

    var pairedMacChoices: [DiscoveredMac] {
        pairedMacs.map { DiscoveredMac(id: $0.serviceName, name: $0.name, isPaired: true) }
            .sorted { $0.name < $1.name }
    }

    var supportsRoundTripProbe: Bool {
        remoteState?.capabilities?.contains(WireCapabilities.roundTripProbe) == true
    }

    init() {
        #if DEBUG && targetEnvironment(simulator)
            if let fixtureState = uiTestFixture.initialState {
                connectionSummary = "Connected to UI Test Mac"
                isConnected = true
                remoteState = fixtureState
                return
            }
        #endif
        do {
            pairedMacs = try SecureStore.load([PairedMac].self, account: "paired-macs") ?? []
        } catch { errorMessage = error.localizedDescription }
    }

    func startDiscovery() {
        guard selectedTransport == .wifi else { return }
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_sofaremote._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.discoveredMacs = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    let saved = self.pairedMacs.first { $0.serviceName == name }
                    return DiscoveredMac(
                        id: name, name: saved?.name ?? "Mac · \(name.prefix(8))",
                        isPaired: saved != nil)
                }.sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }

                if case .failed = state {
                    browser.cancel()
                    self.browser = nil
                    self.errorMessage =
                        "Mac discovery failed. Allow Local Network access in Settings."
                }
                if case .waiting = state {
                    self.errorMessage = "Check Wi-Fi and Local Network permission in Settings."
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func connectSaved(to mac: DiscoveredMac) {
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
        guard let saved = pairedMacs.first(where: { $0.serviceName == mac.id }) else {
            errorMessage = "Open pairing on this Mac and scan its invitation."
            return
        }
        benchmarkTargetID = saved.serviceName
        connect(saved)
    }

    func selectTransport(_ transport: RemoteTransportKind) {
        guard selectedTransport != transport else { return }
        cancelBenchmark()
        disconnect()
        selectedTransport = transport
        if transport == .wifi { startDiscovery() } else { browser?.cancel(); browser = nil }
    }

    func pair(invitation: String) {
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
        guard selectedTransport == .wifi else {
            errorMessage = "Pair this Mac over Wi-Fi first, then select Bluetooth LE to reconnect."
            return
        }
        do {
            let invitation = try PairingInvitation.parse(
                invitation.trimmingCharacters(in: .whitespacesAndNewlines))
            connect(
                PairedMac(
                    serviceName: invitation.serviceName, name: "Mac",
                    certificateSHA256: invitation.certificateSHA256, token: invitation.token))
        } catch { errorMessage = error.localizedDescription }
    }

    func suspend() {
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
        disconnect()
        browser?.cancel()
        browser = nil
        discoveredMacs = []
    }

    private func connect(_ mac: PairedMac) {
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
        disconnect()
        errorMessage = nil
        connectionSummary = "Resolving Mac…"
        candidate = mac
        benchmarkTargetID = mac.serviceName
        let attempt = UUID()
        attemptID = attempt
        if selectedTransport == .bluetooth {
            startBluetoothConnection(to: mac, attempt: attempt)
            return
        }
        let resolver = BonjourResolver()
        self.resolver = resolver
        resolver.resolve(serviceName: mac.serviceName) { [weak self] result in
            guard let self, self.attemptID == attempt else { return }
            self.resolver = nil
            switch result {
            case .success(let url): self.startConnection(to: url, mac: mac, attempt: attempt)
            case .failure: self.handleClose("The Mac could not be found on this network.")
            }
        }
    }

    private func startConnection(to url: URL, mac: PairedMac, attempt: UUID) {
        connectionSummary = "Connecting securely…"
        let parameters = WebSocketPeer.parameters(pin: mac.certificateSHA256) { [weak self] in
            guard let self, self.attemptID == attempt else { return }
            self.peer?.close()
            self.errorMessage =
                "The Mac identity does not match. Open pairing on the Mac and scan a new invitation."
        }
        let peer = WebSocketPeer(
            connection: NWConnection(to: .url(url), using: parameters))
        self.peer = peer
        peer.onReady = { [weak self] in
            let name = DeviceName.bounded(UIDevice.current.name)
            self?.peer?.send(
                WireMessage(type: .authenticate, authToken: mac.token, deviceName: name))
        }
        peer.onMessage = { [weak self] message in self?.receive(message) }
        peer.onClose = { [weak self] reason in self?.handleClose(reason) }
        monitorConnection()
        peer.start()
    }

    func monitorConnection() {
        let started = ContinuousClock.now
        deadline = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ContinuousClock.now
                let timedOut =
                    self.isConnected
                    ? self.pending.values.contains { now - $0.sent > .seconds(3) }
                    : now - started > .seconds(12)
                if timedOut {
                    self.peer?.close()
                    if !self.isConnected, self.errorMessage == "Disconnected" {
                        self.errorMessage =
                            "The Mac did not finish connecting. Check its pairing window and network."
                    }
                }
            }
        }
    }

    func handleClose(_ reason: String) {
        let unknown = !pending.isEmpty
        if benchmarkRunning { cancelBenchmark() }
        benchmarkRequestTracker.reset()
        attemptID = nil
        isConnected = false
        remoteState = nil
        connectionID = nil
        pending.removeAll()
        queuedPlayerVolumeRequests.removeAll(keepingCapacity: true)
        pendingPlayerVolumeRequests.removeAll()
        playerVolumeDisplayStates.removeAll(keepingCapacity: true)
        commandScheduler.reset()
        resetLocalDragTracking()
        coalescingTimer?.invalidate()
        coalescingTimer = nil
        connectionSummary = "Disconnected"
        errorMessage =
            unknown
            ? "Connection lost. A pending control may have taken effect; it was not retried."
            : reason
        deadline?.invalidate()
        deadline = nil
        peer = nil
    }

}

extension RemoteModel {
    func disconnect() {
        #if DEBUG && targetEnvironment(simulator)
            if isUITesting {
                isConnected = false
                connectionID = nil
                remoteState = nil
                benchmarkRequestTracker.reset()
                resetLocalDragTracking()
                connectionSummary = "Disconnected"
                errorMessage = nil
                return
            }
        #endif
        let unknown = !pending.isEmpty
        resolver?.cancel()
        resolver = nil
        attemptID = nil
        deadline?.invalidate()
        deadline = nil
        coalescingTimer?.invalidate()
        coalescingTimer = nil
        peer?.onClose = nil
        peer?.close()
        peer = nil
        isConnected = false
        connectionID = nil
        remoteState = nil
        pending.removeAll()
        queuedPlayerVolumeRequests.removeAll(keepingCapacity: true)
        pendingPlayerVolumeRequests.removeAll()
        playerVolumeDisplayStates.removeAll(keepingCapacity: true)
        commandScheduler.reset()
        resetLocalDragTracking()
        connectionSummary = "Disconnected"
        errorMessage =
            unknown
            ? "Disconnected with a pending control. Its outcome is unknown; it was not retried."
            : nil
        if benchmarkRunning { cancelBenchmark() }
        benchmarkRequestTracker.reset()
    }

    @discardableResult
    func send(_ command: RemoteCommand) -> Bool {
        guard isConnected else { return false }
        #if DEBUG && targetEnvironment(simulator)
            if isUITesting {
                let accepted = uiTestFixture.send(
                    command, remoteState: &remoteState, errorMessage: &errorMessage)
                if accepted { uiTestLogRevision += 1 }
                return accepted
            }
        #endif
        guard connectionID != nil, peer != nil else { return false }
        do { try command.validate() } catch {
            errorMessage = "The control value is invalid."; return false
        }
        guard commandScheduler.enqueue(command) else {
            if command.name == .pointerButtonUp {
                let unknownOutcome = !pending.isEmpty
                disconnect()
                errorMessage =
                    unknownOutcome
                    ? "Disconnected to release the pointer safely. "
                        + "A pending control may have taken effect; it was not retried."
                    : "Disconnected to release the pointer safely. "
                        + "Reconnect to continue."
            } else if !InputCommandScheduler.isBestEffortPointerDelta(command) {
                errorMessage = "The Mac is busy. Wait for the pending controls to finish."
            }
            return false
        }
        if command.name == .pointerMove || command.name == .pointerScroll
            || command.name == .systemVolumeSet
        {
            scheduleCoalescedFlush()
        } else {
            coalescingTimer?.invalidate()
            coalescingTimer = nil
            flushQueuedCommands()
        }
        return true
    }

}
