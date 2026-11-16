#if os(macOS)
    import Darwin
    import Foundation

    /// Low-frequency local management, independent of the pointer/input path.
    public final class LocalAutomationServer: @unchecked Sendable {
        public typealias Handler =
            @Sendable (
                LocalAutomationRequest, ContinuousClock.Instant
            ) async -> LocalAutomationResponse

        private let url: URL
        private let handler: Handler
        private let queue = DispatchQueue(
            label: "com.joeyteng.sofaremote.automation", qos: .utility)
        private var source: DispatchSourceRead?
        private var boundIdentity: stat?
        private var peers: [UUID: LocalAutomationPeer] = [:]

        public init(url: URL = LocalAutomationClient.socketURL, handler: @escaping Handler) {
            self.url = url; self.handler = handler
        }

        deinit {
            source?.cancel()
            for peer in peers.values { peer.cancel() }
            removeOwnedEndpoint()
        }

        public func start() throws {
            try queue.sync {
                guard source == nil else { throw LocalAutomationFailure.alreadyRunning }
                try LocalAutomationSocket.directory(url, create: true)
                let descriptor = try LocalAutomationSocket.make()
                do {
                    try removeStaleEndpoint()
                    guard
                        try LocalAutomationSocket.withAddress(
                            url, { Darwin.bind(descriptor, $0, $1) }) == 0
                    else { throw LocalAutomationFailure.unavailable }
                    guard chmod(url.path, 0o600) == 0 else {
                        throw LocalAutomationFailure.unsafeEndpoint
                    }
                    boundIdentity = try LocalAutomationSocket.identity(url)
                    guard listen(descriptor, 8) == 0 else {
                        throw LocalAutomationFailure.unavailable
                    }
                    let source = DispatchSource.makeReadSource(
                        fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.acceptPending(descriptor) }
                    source.setCancelHandler { close(descriptor) }
                    self.source = source
                    source.resume()
                } catch {
                    close(descriptor)
                    removeOwnedEndpoint()
                    throw error
                }
            }
        }

        public func stop() {
            queue.sync {
                source?.cancel(); source = nil
                for peer in peers.values { peer.cancel() }
                peers.removeAll()
                removeOwnedEndpoint()
            }
        }

        private func acceptPending(_ descriptor: Int32) {
            for _ in 0..<8 {
                let accepted = accept(descriptor, nil, nil)
                guard accepted >= 0 else { return }
                do {
                    guard peers.count < 8,
                        fcntl(accepted, F_SETFD, FD_CLOEXEC) == 0,
                        fcntl(accepted, F_SETFL, O_NONBLOCK) == 0
                    else { throw LocalAutomationFailure.unavailable }
                    var enabled: Int32 = 1
                    guard
                        setsockopt(
                            accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                            socklen_t(MemoryLayout<Int32>.size)) == 0
                    else { throw LocalAutomationFailure.unavailable }
                    try LocalAutomationSocket.requirePeer(accepted)
                    let id = UUID()
                    let peer = LocalAutomationPeer(descriptor: accepted)
                    peers[id] = peer
                    let handler = self.handler
                    peer.start(handler: handler) { [weak self] in
                        self?.queue.async { [weak self] in self?.peers.removeValue(forKey: id) }
                    }
                } catch { close(accepted) }
            }
        }

        private func removeStaleEndpoint() throws {
            var existing = stat()
            guard lstat(url.path, &existing) == 0 else {
                guard errno == ENOENT else { throw LocalAutomationFailure.unsafeEndpoint }
                return
            }
            let before = try LocalAutomationSocket.identity(url)
            let test = try LocalAutomationSocket.make()
            defer { close(test) }
            let result = try LocalAutomationSocket.withAddress(url) { Darwin.connect(test, $0, $1) }
            let connectionError = errno
            guard result != 0, connectionError == ECONNREFUSED else {
                throw LocalAutomationFailure.alreadyRunning
            }
            let after = try LocalAutomationSocket.identity(url)
            guard LocalAutomationSocket.sameObject(before, after), unlink(url.path) == 0 else {
                throw LocalAutomationFailure.unsafeEndpoint
            }
        }

        private func removeOwnedEndpoint() {
            guard let boundIdentity else { return }
            defer { self.boundIdentity = nil }
            guard let current = try? LocalAutomationSocket.identity(url),
                LocalAutomationSocket.sameObject(boundIdentity, current)
            else { return }
            _ = unlink(url.path)
        }
    }

    private final class LocalAutomationPeer: @unchecked Sendable {
        private let descriptor: Int32
        private let lock = NSLock()
        private var finished = false
        private var cancelled = false

        init(descriptor: Int32) { self.descriptor = descriptor }

        func cancel() {
            lock.withLock {
                guard !finished else { return }
                cancelled = true
                // Wake a bounded read without closing/reusing another worker's FD.
                _ = shutdown(descriptor, SHUT_RDWR)
            }
        }

        func start(
            handler: @escaping LocalAutomationServer.Handler,
            completion: @escaping @Sendable () -> Void
        ) {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.cancel()
            }
            Task.detached(priority: .utility) { [self] in
                defer {
                    lock.withLock {
                        finished = true; close(descriptor)
                    }
                    completion()
                }
                let response: LocalAutomationResponse
                do {
                    let frame = try LocalAutomationSocket.readFrame(
                        descriptor, limit: 16384, deadline: deadline)
                    let request = try LocalAutomationRequest.decode(frame)
                    guard request.isValid else { throw LocalAutomationFailure.invalidFrame }
                    guard !lock.withLock({ cancelled }), ContinuousClock.now < deadline else {
                        return
                    }
                    response = await handler(request, deadline)
                } catch {
                    response = LocalAutomationResponse(
                        .invalidRequest, message: "Invalid or incomplete local automation request.")
                }
                guard !lock.withLock({ cancelled }) else { return }
                if let bytes = try? JSONEncoder().encode(response) {
                    try? LocalAutomationSocket.writeFrame(bytes, to: descriptor, deadline: deadline)
                }
            }
        }
    }
#endif
