import Foundation

/// Message transport shared by the network and Bluetooth control paths.
@MainActor
public protocol RemotePeer: AnyObject {
    var isPreauthenticated: Bool { get }
    var onReady: (() -> Void)? { get set }
    var onMessage: ((WireMessage) -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    func send(_ message: WireMessage)
    func close()
}

public extension RemotePeer {
    var isPreauthenticated: Bool { false }
}
