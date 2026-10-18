public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connected(deviceName: String)

    public var summary: String {
        switch self {
        case .disconnected:
            "Not connected"
        case let .connected(deviceName):
            "Connected to \(deviceName)"
        }
    }
}
