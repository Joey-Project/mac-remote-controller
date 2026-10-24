import Foundation
import Network
import Security

/// All transport callbacks and command execution share the main actor's ordering.
@MainActor
public final class WebSocketPeer: RemotePeer {
    public var onReady: (() -> Void)?
    public var onMessage: ((WireMessage) -> Void)?
    public var onClose: ((String) -> Void)?
    private let connection: NWConnection
    private var closed = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public static func parameters(
        identity: SecIdentity? = nil, pin: String? = nil,
        onTrustFailure: (@MainActor @Sendable () -> Void)? = nil
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        if let identity, let protocolIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        }
        if let pin {
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, trust, complete in
                    let securityTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    let chain = SecTrustCopyCertificateChain(securityTrust) as? [SecCertificate]
                    let matches =
                        chain?.first.map {
                            PairingSecurity.matches(
                                PairingSecurity.fingerprint(SecCertificateCopyData($0) as Data), pin
                            )
                        } ?? false
                    complete(matches)
                    if !matches { MainActor.assumeIsolated { onTrustFailure?() } }
                }, .main)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 65_536
        if identity != nil {
            webSocket.setClientRequestHandler(.main) { _, _ in
                NWProtocolWebSocket.Response(
                    status: .accept, subprotocol: nil, additionalHeaders: [])
            }
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.includePeerToPeer = false
        return parameters
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.receive()
                case .failed:
                    self.finish("The secure connection failed. Check the Mac and pairing identity.")
                case .cancelled:
                    self.finish("Disconnected")
                case .waiting:
                    // Network.framework can recover from waiting; the owner enforces a deadline.
                    break
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    public func send(_ message: WireMessage) {
        guard !closed else { return }
        do {
            let data = try WireCodec.encode(message)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        MainActor.assumeIsolated {
                            self?.finish("The command could not be delivered.")
                        }
                    }
                })
        } catch {
            finish("The outgoing message is invalid.")
        }
    }

    public func close() {
        finish("Disconnected")
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil else { self.finish("The connection was interrupted."); return }
                let metadata =
                    context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.finish("The Mac closed the connection."); return
                }
                if metadata?.opcode == .ping || metadata?.opcode == .pong { self.receive(); return }
                guard complete, metadata?.opcode == .text, let data else {
                    self.finish("The remote sent an unsupported message.")
                    return
                }
                do {
                    self.onMessage?(try WireCodec.decode(data))
                    if !self.closed { self.receive() }
                } catch {
                    self.finish("The remote sent an invalid or incompatible message.")
                }
            }
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
        onReady = nil
        onMessage = nil
        onClose = nil
    }
}
