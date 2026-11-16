import AppKit
import AppleCore
import Foundation
import Network
import Observation
import WebRemoteSupport

@MainActor
@Observable
final class WebRemoteController {
    private(set) var hasConfiguration = false
    private(set) var enabled = false
    private(set) var busy = false
    private(set) var status = "Web remote is off"
    private(set) var dnsStatus = ""
    private(set) var address: URL?
    var errorMessage: String?
    @ObservationIgnored var isUnlocked: () -> Bool = { false }
    @ObservationIgnored var canPair: () -> Bool = { false }
    @ObservationIgnored var authorize: (String) throws -> String = { _ in
        throw WebConfigurationError.unavailable
    }
    @ObservationIgnored var resolveCredential: (String) -> String? = { _ in nil }
    @ObservationIgnored var forgetCredential: (String) throws -> Void = { _ in }
    @ObservationIgnored var deviceName: () -> String = { "Mac" }
    @ObservationIgnored var onPeer: ((WebSocketRemotePeer) -> Void)?
    @ObservationIgnored private var gateway: WebGateway?
    @ObservationIgnored private var configuration: WebRuntimeConfiguration?
    @ObservationIgnored private var publisher: LANDNSPublisher?
    @ObservationIgnored private var pairing: WebPairingCoordinator?
    @ObservationIgnored private let pairingWindow = WebPairingWindowController()
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var dnsTask: Task<Void, Never>?
    @ObservationIgnored private var certificateTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var retirement: Task<Void, Never>?
    private var generation = 0
    private var listenerGeneration = 0
    private var activeAddress: String?
    private var lastPublishedAddress: String?
    private var lastCertificateCheck: TimeInterval = 0
    private var nextDNSRetry: TimeInterval = 0
    private var dnsFailures = 0
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SofaRemote/Web", isDirectory: true)

    var pairingPrompt: WebPairingPrompt? { pairing?.prompt }
    func refreshPairing() { pairing?.refresh() }
    func cancelPairing() { pairing?.cancel() }

    func openInBrowser() {
        if let address { NSWorkspace.shared.open(address) }
    }

    func copyURL() {
        if let address { CompanionClipboard.copy(address.absoluteString) }
    }

    func reload() {
        stop()
        do {
            let configuration = try WebRuntimeConfiguration.load(in: root)
            self.configuration = configuration
            hasConfiguration = true
            enabled = configuration.enabled
            errorMessage = nil
            guard enabled else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor in self?.networkChanged() }
            }
            monitor.start(
                queue: DispatchQueue(label: "com.joeyteng.sofaremote.web-network", qos: .utility))
            self.monitor = monitor
            restartListener(force: true)
        } catch WebConfigurationError.notConfigured {
            hasConfiguration = false
            status = "Web remote is not configured"
        } catch {
            hasConfiguration = false
            status = "Web configuration unavailable"
            errorMessage = "Check the private Web setup folder and its configuration."
        }
    }

    func setEnabled(_ value: Bool) {
        do {
            var configuration = try WebRuntimeConfiguration.load(in: root)
            configuration.enabled = value
            try configuration.store(in: root)
            reload()
        } catch {
            if !value { stop() }
            errorMessage = "The Web preference could not be saved. Check the setup folder."
        }
    }

    func stop() {
        generation += 1
        listenerGeneration += 1
        listenerTask?.cancel(); listenerTask = nil
        dnsTask?.cancel(); dnsTask = nil
        certificateTask?.cancel(); certificateTask = nil
        debounce?.cancel(); debounce = nil
        monitor?.cancel(); monitor = nil
        let previous = gateway
        let pendingRetirement = retirement
        previous?.stop()
        retirement = Task {
            await pendingRetirement?.value
            await previous?.stopAndWait()
        }
        gateway = nil
        publisher = nil; pairing = nil
        pairingWindow.show(nil, onCancel: {})
        enabled = false; busy = false; address = nil; activeAddress = nil
        lastPublishedAddress = nil; nextDNSRetry = 0; dnsFailures = 0
        status = "Web remote is off"; dnsStatus = ""
    }

    func tick() {
        pairing?.refresh()
        guard enabled, let configuration else { return }
        let now = NumericPairingClock.now()
        if lastPublishedAddress != activeAddress, now >= nextDNSRetry { publishAddress() }
        guard now - lastCertificateCheck >= 60, certificateTask == nil else { return }
        lastCertificateCheck = now
        let revision = generation
        certificateTask = Task { [weak self] in
            defer { if self?.generation == revision { self?.certificateTask = nil } }
            do {
                let fingerprint = try await Task.detached(priority: .utility) {
                    try WebRuntimeConfiguration.certificateFingerprint(configuration.endpoint)
                }.value
                guard let self, self.generation == revision, !Task.isCancelled else { return }
                if self.gateway?.boundPort == nil
                    || self.gateway?.certificateFingerprint != fingerprint
                {
                    self.restartListener(force: true)
                }
            } catch {
                guard let self, self.generation == revision, !Task.isCancelled else { return }
                self.errorMessage =
                    "The HTTPS certificate could not be checked. Existing connections remain active."
            }
        }
    }

    func openFolder() {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(root)
        } catch { errorMessage = "The Web setup folder could not be opened." }
    }

    private func networkChanged() {
        guard enabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.restartListener(force: false) }
        }
    }

    private func restartListener(force: Bool) {
        guard enabled, let configuration else { return }
        listenerTask?.cancel()
        listenerGeneration += 1
        let revision = listenerGeneration
        busy = true
        listenerTask = Task { [weak self] in
            defer {
                if self?.listenerGeneration == revision {
                    self?.busy = false; self?.listenerTask = nil
                }
            }
            do {
                let endpoint = try await Task.detached(priority: .utility) {
                    try configuration.currentEndpoint()
                }.value
                guard let self, self.listenerGeneration == revision, !Task.isCancelled else {
                    return
                }
                if !force, self.activeAddress == endpoint.bindAddress, self.gateway != nil {
                    self.publishAddress(); return
                }
                let assets = try await Task.detached(priority: .utility) { try Self.loadAssets() }
                    .value
                let (next, coordinator) = try self.makeListener(endpoint: endpoint, assets: assets)
                try await self.activate(
                    next, pairing: coordinator, endpoint: endpoint, revision: revision)
            } catch is CancellationError {
                // A newer configuration owns the listener.
            } catch {
                guard let self, self.listenerGeneration == revision else { return }
                self.status =
                    self.gateway?.boundPort == nil
                    ? "Web connection unavailable" : "Web active; reload failed"
                self.errorMessage =
                    "Check the HTTPS certificate, private LAN interface, and Web setup."
            }
        }
    }
}

extension WebRemoteController {
    private func makeListener(endpoint: WebEndpoint, assets: [String: WebAsset]) throws -> (
        WebGateway, WebPairingCoordinator
    ) {
        let coordinator = WebPairingCoordinator(
            isUnlocked: isUnlocked, canPair: canPair, authorize: authorize)
        coordinator.onChange = { [weak self, weak coordinator] prompt in
            guard let self, let coordinator, self.pairing === coordinator else { return }
            self.pairingWindow.show(prompt) { coordinator.cancel() }
        }
        let application = try WebHTTPApplication(
            endpoint: endpoint, assets: assets, pairing: coordinator,
            deviceName: deviceName, resolveCredential: resolveCredential,
            forgetCredential: forgetCredential)
        let next = try WebGateway(endpoint: endpoint, application: application)
        next.onConnection = onPeer
        next.onFailure = { [weak self, weak next] in
            guard let self, let next, self.gateway === next else { return }
            next.stop()
            self.gateway = nil
            self.pairing = nil
            self.activeAddress = nil
            self.address = nil
            self.status = "Web connection unavailable"
        }
        return (next, coordinator)
    }

    private func activate(
        _ next: WebGateway, pairing: WebPairingCoordinator, endpoint: WebEndpoint, revision: Int
    ) async throws {
        try await next.prepare()
        guard listenerGeneration == revision, !Task.isCancelled else { next.stop(); return }
        await retirement?.value
        guard listenerGeneration == revision, !Task.isCancelled else { next.stop(); return }
        await gateway?.stopAndWait()
        guard listenerGeneration == revision, !Task.isCancelled else { next.stop(); return }
        gateway = next
        self.pairing = pairing
        pairingWindow.show(nil, onCancel: {})
        try await next.start()
        guard listenerGeneration == revision, gateway === next, !Task.isCancelled else {
            next.stop(); return
        }
        activeAddress = endpoint.bindAddress
        address = URL(string: endpoint.origin)
        status = "Ready on the local network"
        lastCertificateCheck = NumericPairingClock.now()
        errorMessage = nil
        if configuration?.dns != nil { dnsStatus = "Checking local DNS…" }
        publishAddress()
    }

    private func publishAddress() {
        guard enabled, let address = activeAddress, lastPublishedAddress != address,
            let dns = configuration?.dns, dnsTask == nil, NumericPairingClock.now() >= nextDNSRetry
        else { return }
        let revision = generation
        let root = root
        dnsTask = Task { [weak self] in
            defer {
                if let self, self.generation == revision {
                    self.dnsTask = nil
                    if self.activeAddress != address { self.publishAddress() }
                }
            }
            do {
                guard let self else { return }
                if self.publisher == nil {
                    let token = try await Task.detached(priority: .utility) {
                        try WebRuntimeConfiguration.cloudflareToken(in: root)
                    }.value
                    guard self.generation == revision, !Task.isCancelled else { return }
                    self.publisher = try LANDNSPublisher(configuration: dns, token: token)
                }
                guard let publisher = self.publisher else { return }
                _ = try await publisher.publish(address: address)
                guard self.generation == revision, !Task.isCancelled else { return }
                self.lastPublishedAddress = address; self.dnsFailures = 0; self.nextDNSRetry = 0
                self.dnsStatus = "Local DNS up to date"
            } catch {
                guard let self, self.generation == revision, !Task.isCancelled else { return }
                self.dnsFailures += 1
                self.nextDNSRetry =
                    NumericPairingClock.now()
                    + min(900, 30 * pow(2, Double(min(self.dnsFailures - 1, 5))))
                self.dnsStatus = "DNS update pending; retrying automatically"
            }
        }
    }

    nonisolated private static func loadAssets() throws -> [String: WebAsset] {
        guard
            let root = Bundle.main.resourceURL?.appendingPathComponent(
                "WebRemote", isDirectory: true)
        else { throw WebConfigurationError.unavailable }
        var assets: [String: WebAsset] = [:]
        for (path, filename, type) in [
            ("/", "index.html", "text/html; charset=utf-8"),
            ("/app.js", "app.js", "text/javascript; charset=utf-8"),
            ("/app.css", "app.css", "text/css; charset=utf-8")
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(filename))
            guard data.count <= 524_288 else { throw WebConfigurationError.unavailable }
            assets[path] = WebAsset(data: data, contentType: type)
        }
        return assets
    }
}
