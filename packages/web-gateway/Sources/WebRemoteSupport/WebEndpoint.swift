import Foundation

/// Browser-trusted HTTPS has its own origin; it does not reuse native TLS pins.
public struct WebEndpoint: Codable, Equatable, Sendable {
    public let hostname: String
    public let port: Int
    public let bindAddress: String
    public let certificateChain: String
    public let privateKey: String

    public init(
        hostname: String, port: Int, bindAddress: String,
        certificateChain: String, privateKey: String
    ) throws {
        self.hostname = hostname
        self.port = port
        self.bindAddress = bindAddress
        self.certificateChain = certificateChain
        self.privateKey = privateKey
        try validate()
    }

    public var authority: String { "\(hostname):\(port)" }
    public var origin: String { "https://\(authority)" }

    public func validate() throws {
        guard Self.isHostname(hostname), (1024...65_535).contains(port),
            Self.isPrivateIPv4(bindAddress), certificateChain.hasPrefix("/"),
            privateKey.hasPrefix("/")
        else { throw WebEndpointError.invalidConfiguration }
    }

    public static func isHostname(_ hostname: String) -> Bool {
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...253).contains(hostname.utf8.count), hostname == hostname.lowercased(),
            labels.count >= 2, labels.last != "local", labels.last != "localhost",
            labels.last?.utf8.contains(where: { (97...122).contains($0) }) == true,
            labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy {
                        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    }
            })
        else { return false }
        return true
    }

    public static func isPrivateIPv4(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = components.compactMap { UInt8($0) }
        guard bytes.count == 4, components.count == 4,
            zip(components, bytes).allSatisfy({ String($0.0) == String($0.1) })
        else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }
}

public enum WebEndpointError: Error { case invalidConfiguration }
