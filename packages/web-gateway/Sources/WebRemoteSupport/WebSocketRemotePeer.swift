import AppleCore
import Foundation
import NIOCore
import NIOWebSocket

/// An HTTP-cookie-authenticated peer restricted to browser input and media control.
@MainActor
public final class WebSocketRemotePeer: RemotePeer {
    public var onReady: (() -> Void)?
    public var onMessage: ((WireMessage) -> Void)?
    public var onClose: ((String) -> Void)?
    public let deviceName: String
    private let credential: String
    private let channel: Channel
    private let output: AsyncStream<WebSocketFrame>.Continuation
    private var closed = false
    private var started = false

    init(
        credential: String, name: String, channel: Channel,
        output: AsyncStream<WebSocketFrame>.Continuation
    ) {
        self.credential = credential
        deviceName = name
        self.channel = channel
        self.output = output
    }

    /// Called after the companion has attached its existing session callbacks.
    public func start() {
        guard !started, !closed else { return }
        started = true
        onReady?()
        onMessage?(WireMessage(type: .authenticate, authToken: credential, deviceName: deviceName))
    }

    public func send(_ message: WireMessage) {
        guard !closed, channel.isActive else { return }
        do {
            var safe = message
            safe.authToken = nil
            let data = try WireCodec.encode(safe)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(bytes: data))
            if case .enqueued = output.yield(frame) { return }
        } catch {
            // Never include message contents or credential-bearing errors in logs.
        }
        close()
    }

    func receive(_ data: Data) {
        guard !closed, started, channel.isActive else { return }
        do {
            let message = try WireCodec.decode(data)
            switch message.type {
            case .command:
                guard let command = message.command, Self.allowed.contains(command.name) else {
                    close(); return
                }
            case .ping, .disconnect: break
            default: close(); return
            }
            onMessage?(message)
        } catch {
            close()
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        if channel.isActive {
            var data = ByteBuffer()
            data.writeInteger(UInt16(1008))
            if case .enqueued = output.yield(
                WebSocketFrame(fin: true, opcode: .connectionClose, data: data))
            {
                let channel = channel
                channel.eventLoop.scheduleTask(in: .seconds(1)) { channel.close(promise: nil) }
            } else {
                channel.close(promise: nil)
            }
        }
        output.finish()
        onClose?("Disconnected")
        onReady = nil
        onMessage = nil
        onClose = nil
    }

    private static let allowed: Set<CommandName> = [
        .pointerMove, .pointerClick, .pointerScroll, .pointerButtonDown, .pointerButtonUp,
        .keyboardKey, .keyboardText, .systemVolumeSet, .mediaControl
    ]
}
