import Foundation

/// Navigation only: entry points never carry credentials, device IDs or commands.
public enum RemoteEntryPoint: String, CaseIterable, Sendable {
    case touchpad
    case keyboard

    public var url: URL {
        guard let url = URL(string: "sofaremote://remote/\(rawValue)") else {
            preconditionFailure("Static remote entry URL must be valid.")
        }
        return url
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "sofaremote", components.host == "remote",
            components.user == nil, components.password == nil, components.port == nil,
            components.query == nil, components.fragment == nil,
            let destination = Self.allCases.first(where: {
                components.percentEncodedPath == "/\($0.rawValue)"
            })
        else { return nil }
        self = destination
    }
}
