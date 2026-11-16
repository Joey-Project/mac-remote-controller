import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

private typealias HTTPChannel = NIOAsyncChannel<
    HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>
>
private typealias SocketChannel = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>

private enum WebUpgrade: Sendable {
    case http(HTTPChannel)
    case socket(SocketChannel, [(String, String)])
}

/// One dedicated I/O thread; native Network.framework input stays untouched.
@MainActor
public final class WebGateway {
    public var onConnection: ((WebSocketRemotePeer) -> Void)?
    public var onFailure: (() -> Void)?
    private let endpoint: WebEndpoint
    private let application: WebHTTPApplication
    private let connections = WebConnections()
    private var group: MultiThreadedEventLoopGroup?
    private var server: Channel?
    private var stopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var acceptTask: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var material: WebTLSMaterial?
    private var starting = false
    private var generation: UInt64 = 0

    public var boundPort: Int? { server?.localAddress?.port }
    public var certificateFingerprint: String? { material?.certificateFingerprint }

    public init(endpoint: WebEndpoint, application: WebHTTPApplication) throws {
        try endpoint.validate()
        self.endpoint = endpoint
        self.application = application
    }

    public func start() async throws {
        try await bind(host: endpoint.bindAddress, port: endpoint.port, permitLoopback: false)
    }

    @_spi(Testing) public func startOnLoopbackForTesting(port: Int = 0) async throws {
        try await bind(host: "127.0.0.1", port: port, permitLoopback: true)
    }

    public func prepare() async throws {
        guard material == nil else { return }
        let endpoint = endpoint
        material = try await Task.detached(priority: .utility) { try WebTLSMaterial.load(endpoint) }
            .value
        try Task.checkCancellation()
    }

    public func stop() {
        generation &+= 1
        starting = false
        acceptTask?.cancel()
        acceptTask = nil
        for task in tasks.values { task.cancel() }
        connections.closeAll()
        if let server {
            stopping = true
            // Register before shutdown: a stopped event loop cannot deliver a new callback.
            server.closeFuture.whenComplete { [weak self] _ in
                Task { @MainActor in self?.serverClosed() }
            }
            server.close(promise: nil)
        }
        server = nil
        application.pairing.cancel()
        group?.shutdownGracefully { _ in }
        group = nil
    }

    public func stopAndWait() async {
        stop()
        guard stopping else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func serverClosed() {
        stopping = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func bind(host: String, port: Int, permitLoopback: Bool) async throws {
        guard server == nil, group == nil else { return }
        guard !starting, !stopping else { throw WebGatewayError.startInProgress }
        starting = true
        let attempt = generation
        defer { if attempt == generation { starting = false } }
        try await prepare()
        guard attempt == generation, !Task.isCancelled else { throw CancellationError() }
        guard let material else { return }
        let context = material.context
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let application = application
        let connections = connections
        do {
            let listener: NIOAsyncChannel<EventLoopFuture<WebUpgrade>, Never> =
                try await ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
                .childChannelOption(
                    .writeBufferWaterMark,
                    value: ChannelOptions.Types.WriteBufferWaterMark(low: 16_384, high: 32_768)
                )
                .bind(host: host, port: port) { channel in
                    Self.installPipeline(
                        channel: channel, context: context,
                        application: application, connections: connections,
                        permitLoopback: permitLoopback)
                }
            guard attempt == generation, !Task.isCancelled else {
                listener.channel.close(promise: nil)
                throw CancellationError()
            }
            server = listener.channel
            startAccepting(listener, attempt: attempt)
        } catch {
            if attempt == generation { stop() }
            throw error
        }
    }

    private func startAccepting(
        _ listener: NIOAsyncChannel<EventLoopFuture<WebUpgrade>, Never>, attempt: UInt64
    ) {
        acceptTask = Task { [weak self] in
            do {
                try await listener.executeThenClose { inbound in
                    for try await result in inbound {
                        guard let self, !Task.isCancelled else { break }
                        let id = UUID()
                        self.tasks[id] = Task { [weak self] in
                            guard let self else { return }
                            defer { self.tasks.removeValue(forKey: id) }
                            do { try await self.handle(try await result.get()) } catch {}
                        }
                    }
                }
            } catch {
                if !Task.isCancelled, self?.generation == attempt { self?.onFailure?() }
            }
        }
    }

}

extension WebGateway {
    private func handle(_ upgrade: WebUpgrade) async throws {
        switch upgrade {
        case .http(let channel): try await handleHTTP(channel)
        case .socket(let channel, let headers): try await handleSocket(channel, headers: headers)
        }
    }

    private func handleHTTP(_ channel: HTTPChannel) async throws {
        try await channel.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            var body = Data()
            for try await part in inbound {
                switch part {
                case .head(let received):
                    guard head == nil,
                        received.headers.reduce(
                            0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 8192,
                        received.headers["transfer-encoding"].isEmpty
                    else { return }
                    head = received
                case .body(let buffer):
                    guard head != nil, body.count + buffer.readableBytes <= 4096 else { return }
                    body.append(contentsOf: buffer.readableBytesView)
                case .end:
                    guard let head else { return }
                    let reply = application.handle(
                        method: head.method.rawValue, uri: head.uri,
                        headers: head.headers.map { ($0.name, $0.value) }, body: body)
                    try await respond(reply, headOnly: head.method == .HEAD, through: outbound)
                    return
                }
            }
        }
    }

    private func respond(
        _ reply: WebReply, headOnly: Bool,
        through outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var headers = HTTPHeaders([
            ("Content-Type", reply.contentType), ("Content-Length", String(reply.body.count)),
            ("Connection", "close"), ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
            ("Cross-Origin-Resource-Policy", "same-origin"),
            (
                "Content-Security-Policy",
                [
                    "default-src 'none'", "script-src 'self'", "style-src 'self'",
                    "connect-src 'self'", "base-uri 'none'", "form-action 'self'",
                    "frame-ancestors 'none'"
                ].joined(separator: "; ")
            )
        ])
        for (name, value) in reply.headers { headers.add(name: name, value: value) }
        try await outbound.write(
            .head(
                HTTPResponseHead(
                    version: .http1_1, status: HTTPResponseStatus(statusCode: reply.status),
                    headers: headers)))
        if !headOnly { try await outbound.write(.body(ByteBuffer(bytes: reply.body))) }
        try await outbound.write(.end(nil))
    }

    private func handleSocket(_ channel: SocketChannel, headers: [(String, String)]) async throws {
        guard let authenticated = application.authenticated(headers: headers) else {
            channel.channel.close(promise: nil); return
        }
        let (stream, output) = AsyncStream<WebSocketFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(32))
        let peer = WebSocketRemotePeer(
            credential: authenticated.credential, name: authenticated.name,
            channel: channel.channel, output: output)
        defer { peer.close() }
        onConnection?(peer)
        peer.start()
        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await frame in inbound {
                        if Task.isCancelled || !channel.channel.isActive { return }
                        switch frame.opcode {
                        case .text: await peer.receive(Data(frame.unmaskedData.readableBytesView))
                        case .ping:
                            try await outbound.write(
                                WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                        case .pong: break
                        case .connectionClose:
                            try await outbound.write(
                                WebSocketFrame(
                                    fin: true, opcode: .connectionClose, data: ByteBuffer()))
                            return
                        default: return
                        }
                    }
                }
                group.addTask {
                    for await frame in stream {
                        try Task.checkCancellation()
                        try await outbound.write(frame)
                    }
                }
                _ = try await group.next()
                group.cancelAll()
                peer.close()
            }
        }
    }
}

extension WebGateway {
    nonisolated private static func installPipeline(
        channel: Channel, context: NIOSSLContext,
        application: WebHTTPApplication, connections: WebConnections, permitLoopback: Bool
    ) -> EventLoopFuture<EventLoopFuture<WebUpgrade>> {
        channel.eventLoop.makeCompletedFuture {
            guard connections.admit(channel, permitLoopback: permitLoopback) else {
                channel.close(promise: nil)
                throw WebGatewayError.admissionRejected
            }
            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
            try channel.pipeline.syncOperations.addHandlers(
                IdleStateHandler(readTimeout: .seconds(30)), WebIdleCloser())
            let upgrade = NIOTypedHTTPServerUpgradeConfiguration(
                upgraders: [makeUpgrader(policy: application.policy, application: application)],
                notUpgradingCompletionHandler: { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(WebHTTPResponseAdapter())
                        return WebUpgrade.http(
                            try HTTPChannel(wrappingChannelSynchronously: channel))
                    }
                })
            return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                configuration: .init(upgradeConfiguration: upgrade))
        }
    }

    nonisolated private static func makeUpgrader(
        policy: WebRequestPolicy, application: WebHTTPApplication
    ) -> NIOTypedWebSocketServerUpgrader<WebUpgrade> {
        NIOTypedWebSocketServerUpgrader<WebUpgrade>(
            maxFrameSize: 65_536,
            shouldUpgrade: { channel, head in
                let headers = head.headers.map { ($0.name, $0.value) }
                guard
                    policy.route(method: head.method.rawValue, uri: head.uri, headers: headers)
                        == .socket
                else {
                    channel.close(promise: nil)
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                return channel.eventLoop.makeFutureWithTask { @MainActor in
                    guard application.authenticated(headers: headers) != nil else {
                        channel.close(promise: nil)
                        return nil
                    }
                    return HTTPHeaders()
                }
            },
            upgradePipelineHandler: { channel, head in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        WebFrameGuard(),
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1,
                            maxAccumulatedFrameCount: 16, maxAccumulatedFrameSize: 65_536))
                    return .socket(
                        try SocketChannel(wrappingChannelSynchronously: channel),
                        head.headers.map { ($0.name, $0.value) })
                }
            })
    }
}

private enum WebGatewayError: Error { case admissionRejected, startInProgress }

private final class WebConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var window: TimeInterval = 0
    private var count = 0

    func admit(_ channel: Channel, permitLoopback: Bool) -> Bool {
        guard let address = channel.remoteAddress?.ipAddress,
            WebEndpoint.isPrivateIPv4(address) || (permitLoopback && address == "127.0.0.1")
        else { return false }
        let id = ObjectIdentifier(channel)
        let admitted = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            if now - window >= 1 { window = now; count = 0 }
            guard channels.count < 16, count < 64 else { return false }
            count += 1
            channels[id] = channel
            return true
        }
        if admitted {
            channel.closeFuture.whenComplete { [weak self] _ in
                _ = self?.lock.withLock { self?.channels.removeValue(forKey: id) }
            }
        }
        return admitted
    }

    func closeAll() {
        let active = lock.withLock { Array(channels.values) }
        for channel in active { channel.close(promise: nil) }
    }
}

private final class WebFrameGuard: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = WebSocketFrame
    private var window: TimeInterval = 0
    private var count = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let now = ProcessInfo.processInfo.systemUptime
        if now - window >= 1 { window = now; count = 0 }
        count += 1
        guard count <= 240, frame.maskKey != nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
            context.close(promise: nil); return
        }
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class WebIdleCloser: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}
