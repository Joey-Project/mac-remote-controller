import AppleCore
import Darwin
import Foundation
@_spi(Testing) import WebRemoteSupport

/// A bounded transport fixture. It never imports AppKit or posts desktop events.
@main
@MainActor
enum FixtureMain {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw FixtureError.configuration }
            let configuration = try JSONDecoder().decode(
                FixtureConfiguration.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let fixture = Fixture(configuration: configuration)
            try await fixture.start()
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(
                signal: SIGTERM, queue: .global(qos: .utility))
            termination.setEventHandler { @Sendable in
                Task { @MainActor in
                    fixture.stop(); exit(0)
                }
            }
            termination.resume()
            let deadline = ContinuousClock.now.advanced(by: .seconds(1800))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(1))
                fixture.tick()
            }
            fixture.stop()
            termination.cancel()
        } catch {
            print("Web fixture failed; no desktop events were emitted.")
            exit(1)
        }
    }
}

private enum FixtureError: Error { case configuration }
private struct FixtureConfiguration: Decodable {
    let endpoint: WebEndpoint
    let assetsDirectory: String
    let evidenceFile: String
    var loopbackOnly: Bool?
    var restartOnce: Bool?
    var unlockAllowed: Bool?
}

@MainActor
private final class Fixture {
    private let configuration: FixtureConfiguration
    private var credentials: [String: String] = [:]
    private var clients: [UUID: Client] = [:]
    private var events: [[String: String]] = []
    private var gateway: WebGateway?
    private var prompt: WebPairingPrompt?
    private var releasedOnClose = 0
    private var deniedSessionCommands = 0
    private var ready = false
    private lazy var pairing = WebPairingCoordinator(
        isUnlocked: { true }, canPair: { self.credentials.count < 8 },
        authorize: { name in
            let credential = try PairingSecurity.randomToken()
            self.credentials[credential] = name
            return credential
        })
    private var state = RemoteState(
        accessibilityGranted: true, systemVolume: 0,
        deviceName: "Web integration fixture — no desktop control",
        supportsGestures: true,
        capabilities: [
            WireCapabilities.remoteLock, WireCapabilities.remoteUnlock,
            WireCapabilities.displayPower, WireCapabilities.simulatedGestures
        ],
        mediaTargets: [
            MediaTarget(
                id: "iina:fixture", name: "Fixture IINA", kind: .iina,
                capabilities: MediaCapabilities(
                    playPause: true, seek: true, next: true, previous: true,
                    playerVolumeMaximum: 4), playerVolume: 0.6),
            MediaTarget(
                id: "chrome:fixture", name: "Fixture browser", kind: .youtube,
                capabilities: MediaCapabilities(
                    playPause: true, seek: true, next: false, previous: false))
        ], sessionLocked: false, unlockAvailable: false, displayAsleep: false)

    private final class Client {
        let peer: WebSocketRemotePeer
        var credential: String?
        var session: ServerSession?
        var held = HeldInputState()
        init(peer: WebSocketRemotePeer) { self.peer = peer }
    }

    init(configuration: FixtureConfiguration) {
        self.configuration = configuration
        state.unlockAvailable = configuration.unlockAllowed == true
    }

    func start() async throws {
        var assets: [String: WebAsset] = [:]
        let root = URL(fileURLWithPath: configuration.assetsDirectory)
        for (path, filename, type) in [
            ("/", "index.html", "text/html; charset=utf-8"),
            ("/app.js", "app.js", "text/javascript; charset=utf-8"),
            ("/app.css", "app.css", "text/css; charset=utf-8")
        ] {
            assets[path] = WebAsset(
                data: try Data(contentsOf: root.appendingPathComponent(filename)), contentType: type
            )
        }
        pairing.onChange = { [weak self] prompt in
            self?.prompt = prompt; self?.writeEvidence()
        }
        let application = try WebHTTPApplication(
            endpoint: configuration.endpoint, assets: assets, pairing: pairing,
            deviceName: { self.state.deviceName }, resolveCredential: { self.credentials[$0] },
            forgetCredential: { credential in
                self.credentials.removeValue(forKey: credential)
                let revoked = self.clients.values.filter { $0.credential == credential }
                for client in revoked { client.peer.close() }
                self.writeEvidence()
            })
        let gateway = try WebGateway(endpoint: configuration.endpoint, application: application)
        gateway.onConnection = { [weak self] peer in self?.connect(peer) }
        self.gateway = gateway
        if configuration.loopbackOnly == true {
            try await gateway.startOnLoopbackForTesting(port: configuration.endpoint.port)
            if configuration.restartOnce == true {
                gateway.stop()
                await gateway.stopAndWait()
                try await gateway.startOnLoopbackForTesting(port: configuration.endpoint.port)
            }
        } else {
            try await gateway.start()
        }
        ready = true
        writeEvidence()
        print("READY — transport fixture only; desktop control is disabled.")
    }

    func stop() { ready = false; gateway?.stop(); gateway = nil; writeEvidence() }
    func tick() { pairing.refresh() }

    private func connect(_ peer: WebSocketRemotePeer) {
        let id = UUID()
        let client = Client(peer: peer)
        clients[id] = client
        peer.onMessage = { [weak self, weak client] message in
            guard let self, let client else { return }
            self.receive(message, client: client)
        }
        peer.onClose = { [weak self] _ in
            guard let self, let closed = self.clients.removeValue(forKey: id) else { return }
            self.releasedOnClose += closed.held.buttons.count
            self.writeEvidence()
        }
    }

    private func receive(_ message: WireMessage, client: Client) {
        if message.type == .disconnect { client.peer.close(); return }
        if message.type == .authenticate {
            guard let credential = message.authToken, credentials[credential] != nil else {
                client.peer.close(); return
            }
            let session = ServerSession(connectionID: UUID().uuidString)
            client.credential = credential
            client.session = session
            client.peer.send(
                WireMessage(type: .welcome, connectionID: session.connectionID, state: state))
        } else if message.type == .ping {
            guard message.connectionID == client.session?.connectionID else {
                client.peer.close(); return
            }
            client.peer.send(
                WireMessage(
                    type: .pong, connectionID: message.connectionID, requestID: message.requestID,
                    sequence: message.sequence))
        } else if message.type == .command, var session = client.session {
            do {
                let accepted = try session.accept(message)
                client.session = session
                client.held.apply(accepted.command)
                client.held.refresh()
                if accepted.command.name == .sessionUnlock
                    || SessionControlPolicy.isControl(accepted.command.name)
                {
                    replySession(accepted, session: session, client: client)
                    return
                }
                if accepted.command.name == .mediaControl {
                    let failure = applyMedia(accepted.command.mediaRequest)
                    client.peer.send(session.makeResult(for: accepted, error: failure))
                    client.peer.send(
                        WireMessage(type: .state, connectionID: session.connectionID, state: state))
                    writeEvidence()
                    return
                }
                record(accepted.command)
                client.peer.send(session.makeResult(for: accepted))
                if accepted.command.name == .systemVolumeSet {
                    state.systemVolume = accepted.command.value
                    client.peer.send(
                        WireMessage(type: .state, connectionID: session.connectionID, state: state))
                }
                writeEvidence()
            } catch { client.peer.close() }
        }
    }

    private func replySession(_ accepted: AcceptedCommand, session: ServerSession, client: Client) {
        let failure = applySession(accepted.command.name)
        client.peer.send(session.makeResult(for: accepted, error: failure))
        client.peer.send(
            WireMessage(type: .state, connectionID: session.connectionID, state: state))
        writeEvidence()
    }

    /// Changes fixture memory only. Native Mac/helper actions are never called.
    private func applySession(_ action: CommandName) -> RemoteError? {
        guard SessionControlPolicy.allows(action, state: state) else {
            deniedSessionCommands += 1
            return RemoteError(
                code: "session_unavailable",
                message: "Fixture browser permission or session state does not allow this action.")
        }
        switch action {
        case .sessionLock: state.sessionLocked = true
        case .sessionUnlock: state.sessionLocked = false; state.displayAsleep = false
        case .displayOff: state.displayAsleep = true
        case .displayWake: state.displayAsleep = false
        case .sessionLockAndDisplayOff: state.sessionLocked = true; state.displayAsleep = true
        default:
            return RemoteError(code: "session_unavailable", message: "Unsupported fixture action.")
        }
        appendEvent(["name": action.rawValue])
        return nil
    }

    private func applyMedia(_ request: MediaRequest?) -> RemoteError? {
        guard let request,
            let index = state.mediaTargets?.firstIndex(where: { $0.id == request.targetID }),
            let target = state.mediaTargets?[index], target.capabilities.supports(request.action)
        else {
            return RemoteError(code: "media_unavailable", message: "Fixture source unavailable.")
        }
        if request.action == .setVolume {
            guard let value = request.value,
                let maximum = target.capabilities.playerVolumeMaximum, value <= maximum
            else {
                return RemoteError(
                    code: "media_unavailable", message: "Fixture volume out of range.")
            }
            state.mediaTargets?[index].playerVolume = value
        }
        var event = [
            "name": "media.control", "targetId": request.targetID, "action": request.action.rawValue
        ]
        if let value = request.value { event["value"] = String(value) }
        appendEvent(event)
        return nil
    }

    private func record(_ command: RemoteCommand) {
        var event = ["name": command.name.rawValue]
        if let text = command.text { event["textBytes"] = String(text.utf8.count) }
        if let key = command.key { event["key"] = key.rawValue }
        if let shortcut = command.shortcut { event["shortcut"] = shortcut.rawValue }
        if let value = command.value { event["value"] = String(value) }
        if let gesture = command.gesture {
            event["gestureID"] = gesture.id.uuidString.lowercased()
            event["kind"] = gesture.kind.rawValue
            event["phase"] = gesture.phase.rawValue
            event["value"] = String(gesture.value)
            event["timestamp"] = String(gesture.timestamp)
        }
        appendEvent(event)
    }

    private func appendEvent(_ event: [String: String]) {
        if events.count >= 128 { events.removeFirst() }
        events.append(event)
    }

    private func writeEvidence() {
        var value: [String: Any] = [
            "fixtureOnly": true, "ready": ready, "desktopEvents": 0, "pid": getpid(),
            "origin": configuration.endpoint.origin, "connections": clients.count,
            "pairedBrowsers": credentials.count, "events": events,
            "releasedButtonsOnClose": releasedOnClose,
            "deniedSessionCommands": deniedSessionCommands,
            "sessionLocked": state.sessionLocked ?? false,
            "displayAsleep": state.displayAsleep ?? false,
            "heldButtons": clients.values.reduce(0) { $0 + $1.held.buttons.count }
        ]
        if let prompt {
            value["pairingCode"] = prompt.code; value["pairingRequestId"] = prompt.id.uuidString
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let url = URL(fileURLWithPath: configuration.evidenceFile)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* No credential-bearing errors or text payloads are logged. */  }
    }
}
