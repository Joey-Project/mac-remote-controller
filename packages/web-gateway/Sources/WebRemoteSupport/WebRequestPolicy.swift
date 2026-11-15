import Foundation

public enum WebRoute: Equatable, Sendable {
    case asset(String)
    case status
    case pairingStart
    case pairingConfirm
    case disconnect
    case socket
}

/// Shared by HTTP and WebSocket admission; no forwarded host/origin is trusted.
public struct WebRequestPolicy: Sendable {
    private let authority: String
    private let origin: String

    public init(endpoint: WebEndpoint) throws {
        try endpoint.validate()
        authority = endpoint.authority
        origin = endpoint.origin
    }

    public func route(method: String, uri: String, headers: [(String, String)]) -> WebRoute? {
        guard unique("host", in: headers) == authority else { return nil }
        let origins = values("origin", in: headers)
        guard origins.isEmpty || origins == [origin] else { return nil }
        let sites = values("sec-fetch-site", in: headers)
        guard sites.count <= 1 else { return nil }

        if method == "GET" || method == "HEAD" {
            return readRoute(method: method, uri: uri, origins: origins, sites: sites)
        }
        return writeRoute(
            method: method, uri: uri, headers: headers, origins: origins, sites: sites)
    }

    private func readRoute(
        method: String, uri: String, origins: [String], sites: [String]
    ) -> WebRoute? {
        if ["/", "/app.js", "/app.css"].contains(uri) { return .asset(uri) }
        if method == "GET", uri == "/api/status" { return .status }
        if method == "GET", uri == "/remote", origins == [origin],
            sites.isEmpty || sites == ["same-origin"]
        {
            return .socket
        }
        return nil
    }

    private func writeRoute(
        method: String, uri: String, headers: [(String, String)], origins: [String], sites: [String]
    ) -> WebRoute? {
        guard method == "POST", origins == [origin],
            sites.isEmpty || sites == ["same-origin"],
            let contentType = unique("content-type", in: headers),
            contentType.lowercased().split(separator: ";").first == "application/json"
        else { return nil }
        switch uri {
        case "/api/pairing/start": return .pairingStart
        case "/api/pairing/confirm": return .pairingConfirm
        case "/api/disconnect": return .disconnect
        default: return nil
        }
    }

    /// Reject duplicate cookies instead of choosing a credential ambiguously.
    public func cookie(_ name: String, headers: [(String, String)]) -> String? {
        let fields = values("cookie", in: headers)
        guard fields.count == 1, let field = fields.first, field.utf8.count <= 8192 else {
            return nil
        }
        let matches = field.split(separator: ";").compactMap { item -> String? in
            let pieces = item.trimmingCharacters(in: .whitespaces).split(
                separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0] == name else { return nil }
            return String(pieces[1])
        }
        guard matches.count == 1, let value = matches.first,
            value.utf8.count <= 128, Data(base64Encoded: value)?.count == 32
        else { return nil }
        return value
    }

    private func unique(_ name: String, in headers: [(String, String)]) -> String? {
        let fields = values(name, in: headers)
        return fields.count == 1 ? fields.first : nil
    }

    private func values(_ name: String, in headers: [(String, String)]) -> [String] {
        headers.compactMap { $0.0.lowercased() == name ? $0.1 : nil }
    }
}
