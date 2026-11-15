import Foundation

public struct LANDNSConfiguration: Codable, Equatable, Sendable {
    public let zoneID: String
    public let recordID: String
    public let hostname: String

    public init(zoneID: String, recordID: String, hostname: String) throws {
        self.zoneID = zoneID
        self.recordID = recordID
        self.hostname = hostname
        try validate()
    }

    public func validate() throws {
        let validID: (String) -> Bool = { value in
            value.utf8.count == 32
                && value.utf8.allSatisfy {
                    (48...57).contains($0) || (97...102).contains($0)
                }
        }
        guard validID(zoneID), validID(recordID), WebEndpoint.isHostname(hostname) else {
            throw LANDNSError.invalidConfiguration
        }
    }
}

public enum LANDNSError: Error, Equatable {
    case invalidConfiguration
    case invalidAddress
    case updateInProgress
    case rejected(Int)
    case invalidResponse
    case recordMismatch
}

/// A single in-flight publisher. Its API token never enters persisted configuration.
public actor LANDNSPublisher {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let configuration: LANDNSConfiguration
    private let token: String
    private let transport: Transport
    private var updating = false

    public init(configuration: LANDNSConfiguration, token: String, transport: Transport? = nil)
        throws
    {
        try configuration.validate()
        guard !token.isEmpty, token.utf8.count <= 4096,
            token.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw LANDNSError.invalidConfiguration }
        self.configuration = configuration
        self.token = token
        if let transport {
            self.transport = transport
        } else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 10
            settings.timeoutIntervalForResource = 15
            settings.httpShouldSetCookies = false
            settings.httpCookieStorage = nil
            settings.urlCredentialStorage = nil
            let session = URLSession(
                configuration: settings, delegate: DNSRedirectBlocker(), delegateQueue: nil)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw LANDNSError.invalidResponse
                }
                return (data, response)
            }
        }
    }

    /// Returns false when the verified record already has the desired address.
    /// Writes are never retried here: a caller can re-read after a network failure.
    public func publish(address: String) async throws -> Bool {
        guard WebEndpoint.isPrivateIPv4(address) else { throw LANDNSError.invalidAddress }
        guard !updating else { throw LANDNSError.updateInProgress }
        updating = true
        defer { updating = false }
        let current = try await request(method: "GET")
        try validate(current)
        if current.content == address { return false }
        try Task.checkCancellation()
        let updated = try await request(method: "PATCH", address: address)
        try validate(updated)
        guard updated.content == address else { throw LANDNSError.recordMismatch }
        let readBack = try await request(method: "GET")
        try validate(readBack)
        guard readBack.content == address else { throw LANDNSError.recordMismatch }
        return true
    }

    private func validate(_ record: Record) throws {
        guard record.id == configuration.recordID, record.name == configuration.hostname,
            record.type == "A", record.proxied == false
        else { throw LANDNSError.recordMismatch }
    }

    private func request(method: String, address: String? = nil) async throws -> Record {
        let path = "zones/\(configuration.zoneID)/dns_records/\(configuration.recordID)"
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/\(path)") else {
            throw LANDNSError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let address {
            request.httpBody = try JSONEncoder().encode(Update(content: address, proxied: false))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw LANDNSError.rejected(response.statusCode) }
        guard data.count <= 65_536,
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.success, let result = envelope.result
        else { throw LANDNSError.invalidResponse }
        return result
    }

    private struct Envelope: Decodable { let success: Bool; let result: Record? }
    private struct Update: Encodable { let content: String; let proxied: Bool }
    private struct Record: Decodable {
        let id: String
        let name: String
        let type: String
        let content: String
        let proxied: Bool
    }
}

private final class DNSRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
