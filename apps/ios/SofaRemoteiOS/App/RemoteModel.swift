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

@MainActor
@Observable
final class RemoteModel {
    var discoveredMacs: [DiscoveredMac] = []
    var connectionSummary = "Choose your Mac"
    var isConnected = false
    var remoteState: RemoteState?
    var errorMessage: String?

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
    private var attemptID: UUID?
    private var peer: WebSocketPeer?
    private var pairedMacs: [PairedMac] = []
    private var candidate: PairedMac?
    private var connectionID: String?
    private var sequence: UInt64 = 0
    private var pending: [String: (sequence: UInt64, sent: Date)] = [:]
    private var queuedVolume: Double?
    private var deadline: Timer?

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
        connect(saved)
    }

    func pair(invitation: String) {
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
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
        let attempt = UUID()
        attemptID = attempt
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

    private func monitorConnection() {
        let started = Date()
        deadline = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let timedOut =
                    self.isConnected
                    ? self.pending.values.contains { Date().timeIntervalSince($0.sent) > 3 }
                    : Date().timeIntervalSince(started) > 12
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

    private func handleClose(_ reason: String) {
        let unknown = !pending.isEmpty
        attemptID = nil
        isConnected = false
        remoteState = nil
        connectionID = nil
        pending.removeAll()
        queuedVolume = nil
        connectionSummary = "Disconnected"
        errorMessage =
            unknown
            ? "Connection lost. A pending control may have taken effect; it was not retried."
            : reason
        deadline?.invalidate()
        deadline = nil
    }

    private func receive(_ message: WireMessage) {
        switch message.type {
        case .welcome:
            guard !isConnected, let id = message.connectionID, let state = message.state,
                let candidate
            else { peer?.close(); return }
            do {
                let saved = PairedMac(
                    serviceName: candidate.serviceName, name: state.deviceName,
                    certificateSHA256: candidate.certificateSHA256,
                    token: message.authToken ?? candidate.token)
                var updated = pairedMacs.filter { $0.serviceName != saved.serviceName }
                updated.append(saved)
                try SecureStore.save(updated, account: "paired-macs")
                pairedMacs = updated
                connectionID = id
                sequence = 0
                remoteState = state
                isConnected = true
                connectionSummary = "Connected to \(state.deviceName)"
                discoveredMacs = discoveredMacs.map {
                    $0.id == saved.serviceName
                        ? DiscoveredMac(id: $0.id, name: saved.name, isPaired: true) : $0
                }
            } catch { peer?.close(); errorMessage = error.localizedDescription }
        case .state:
            guard isConnected, message.connectionID == connectionID else { peer?.close(); return }
            remoteState = message.state
        case .result:
            guard message.connectionID == connectionID, let id = message.requestID,
                let request = pending[id], request.sequence == message.sequence
            else { peer?.close(); return }
            pending.removeValue(forKey: id)
            if let error = message.error { errorMessage = error.message }
            if let volume = queuedVolume {
                queuedVolume = nil
                send(RemoteCommand(name: .systemVolumeSet, value: volume))
            }
        default:
            peer?.close()
        }
    }
}

extension RemoteModel {
    func disconnect() {
        #if DEBUG && targetEnvironment(simulator)
            if isUITesting {
                isConnected = false
                connectionID = nil
                remoteState = nil
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
        peer?.onClose = nil
        peer?.close()
        peer = nil
        isConnected = false
        connectionID = nil
        remoteState = nil
        pending.removeAll()
        queuedVolume = nil
        connectionSummary = "Disconnected"
        errorMessage =
            unknown
            ? "Disconnected with a pending control. Its outcome is unknown; it was not retried."
            : nil
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
        guard let connectionID, let peer else { return false }
        do { try command.validate() } catch {
            errorMessage = "The control value is invalid."; return false
        }
        // Do not build an input backlog while the network is slow.
        guard pending.count < 8 else {
            if command.name == .systemVolumeSet {
                queuedVolume = command.value
                return true
            }
            if command.name != .pointerMove && command.name != .pointerScroll {
                errorMessage = "The Mac is busy. Wait for the pending controls to finish."
            }
            return false
        }
        sequence += 1
        let requestID = UUID().uuidString
        pending[requestID] = (sequence, Date())
        peer.send(
            WireMessage(
                type: .command, connectionID: connectionID, requestID: requestID,
                sequence: sequence, command: command))
        return true
    }
}
