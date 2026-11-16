import Foundation

public struct WebAsset: Sendable {
    let data: Data
    let contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}

struct WebReply: Sendable {
    let status: Int
    let body: Data
    let contentType: String
    var headers: [(String, String)] = []
}

/// Called on the companion's main actor; pairing and revocation cannot race commands.
@MainActor
public final class WebHTTPApplication {
    static let credentialCookie = "__Host-sofaremote"
    static let pairingCookie = "__Host-sofaremote-pairing"
    let policy: WebRequestPolicy
    let pairing: WebPairingCoordinator
    private let assets: [String: WebAsset]
    private let deviceName: () -> String
    private let resolveCredential: (String) -> String?
    private let forgetCredential: (String) throws -> Void

    public init(
        endpoint: WebEndpoint, assets: [String: WebAsset], pairing: WebPairingCoordinator,
        deviceName: @escaping () -> String,
        resolveCredential: @escaping (String) -> String?,
        forgetCredential: @escaping (String) throws -> Void
    ) throws {
        policy = try WebRequestPolicy(endpoint: endpoint)
        self.assets = assets
        self.pairing = pairing
        self.deviceName = deviceName
        self.resolveCredential = resolveCredential
        self.forgetCredential = forgetCredential
    }

    func authenticated(headers: [(String, String)]) -> (credential: String, name: String)? {
        guard let credential = policy.cookie(Self.credentialCookie, headers: headers),
            let name = resolveCredential(credential)
        else { return nil }
        return (credential, name)
    }

    func handle(method: String, uri: String, headers: [(String, String)], body: Data) -> WebReply {
        guard body.count <= 4096,
            let route = policy.route(method: method, uri: uri, headers: headers)
        else { return failure("request_rejected", status: 403) }
        do {
            return try dispatch(route, body: body, headers: headers)
        } catch let error as WebPairingFailure {
            return pairingFailure(error)
        } catch is WebBodyError {
            return failure("invalid_request", status: 400)
        } catch {
            return failure("operation_failed", status: 503)
        }
    }

    private func dispatch(_ route: WebRoute, body: Data, headers: [(String, String)]) throws
        -> WebReply
    {
        switch route {
        case .asset(let path): return asset(path, body: body)
        case .status: return status(body: body, headers: headers)
        case .pairingStart: return try startPairing(body: body, headers: headers)
        case .pairingConfirm: return try confirm(body: body, headers: headers)
        case .forget: return try forget(body: body, headers: headers)
        case .socket: return failure("pairing_required", status: 401)
        }
    }

    private func asset(_ path: String, body: Data) -> WebReply {
        guard body.isEmpty, let asset = assets[path] else {
            return failure("client_unavailable", status: 503)
        }
        return WebReply(status: 200, body: asset.data, contentType: asset.contentType)
    }

    private func status(body: Data, headers: [(String, String)]) -> WebReply {
        guard body.isEmpty else { return failure("invalid_request", status: 400) }
        if authenticated(headers: headers) != nil {
            return json(["paired": true, "deviceName": deviceName()])
        }
        return json(["paired": false])
    }

    private func startPairing(body: Data, headers: [(String, String)]) throws -> WebReply {
        let fields = try strings(body, keys: ["name"])
        let start = try pairing.start(
            name: fields["name"] ?? "Web browser",
            ownerCookie: policy.cookie(Self.pairingCookie, headers: headers))
        var reply = json(["requestId": start.requestID.uuidString, "expiresIn": start.expiresIn])
        reply.headers.append(
            Self.cookie(Self.pairingCookie, value: start.ownerCookie, age: start.expiresIn))
        return reply
    }

    private func forget(body: Data, headers: [(String, String)]) throws -> WebReply {
        _ = try strings(body, keys: [])
        if let authenticated = authenticated(headers: headers) {
            try forgetCredential(authenticated.credential)
        }
        pairing.cancel(ownerCookie: policy.cookie(Self.pairingCookie, headers: headers))
        var reply = json(["paired": false])
        reply.headers.append(Self.cookie(Self.credentialCookie, value: "", age: 0))
        reply.headers.append(Self.cookie(Self.pairingCookie, value: "", age: 0))
        return reply
    }

    private func confirm(body: Data, headers: [(String, String)]) throws -> WebReply {
        let fields = try strings(body, keys: ["requestId", "code"])
        guard let value = fields["requestId"], let id = UUID(uuidString: value),
            let code = fields["code"]
        else {
            return failure("invalid_request", status: 400)
        }
        let credential = try pairing.confirm(
            id: id, ownerCookie: policy.cookie(Self.pairingCookie, headers: headers), code: code)
        guard Data(base64Encoded: credential)?.count == 32 else {
            return failure("pairing_unavailable", status: 503)
        }
        var reply = json(["paired": true])
        reply.headers.append(Self.cookie(Self.credentialCookie, value: credential, age: 31_536_000))
        reply.headers.append(Self.cookie(Self.pairingCookie, value: "", age: 0))
        return reply
    }

    private func strings(_ data: Data, keys: Set<String>) throws -> [String: String] {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
            let value = decoded as? [String: String],
            Set(value.keys) == keys
        else { throw WebBodyError.invalid }
        return value
    }

    private func pairingFailure(_ error: WebPairingFailure) -> WebReply {
        switch error {
        case .busy: failure("pairing_busy", status: 409)
        case .expired: failure("pairing_expired", status: 410)
        case .rateLimited: failure("pairing_rate_limited", status: 429)
        case .incorrectCode: failure("incorrect_code", status: 403)
        case .codeChanged: failure("pairing_code_changed", status: 429)
        case .unavailable, .randomFailure: failure("pairing_unavailable", status: 503)
        }
    }

    private func failure(_ code: String, status: Int) -> WebReply {
        json(["error": code], status: status)
    }

    private func json(_ value: [String: Any], status: Int = 200) -> WebReply {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return WebReply(status: status, body: data, contentType: "application/json; charset=utf-8")
    }

    private static func cookie(_ name: String, value: String, age: Int) -> (String, String) {
        (
            "Set-Cookie",
            "\(name)=\(value); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=\(age)"
        )
    }
}

private enum WebBodyError: Error { case invalid }
