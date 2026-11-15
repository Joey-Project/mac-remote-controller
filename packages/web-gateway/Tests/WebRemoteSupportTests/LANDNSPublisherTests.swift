import AppleCore
import Foundation
import Testing
@testable import WebRemoteSupport

private actor DNSFixture {
    var address = "192.168.1.10"
    var name = "remote.example.com"
    var type = "A"
    var proxied = false
    var status = 200
    var methods: [String] = []
    var patches: [[String: String]] = []

    func alter(name: String? = nil, type: String? = nil, proxied: Bool? = nil, status: Int? = nil) {
        if let name { self.name = name }
        if let type { self.type = type }
        if let proxied { self.proxied = proxied }
        if let status { self.status = status }
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let method = try #require(request.httpMethod)
        methods.append(method)
        if method == "PATCH", let body = request.httpBody {
            let change = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(change.keys) == ["content", "proxied"])
            #expect(change["proxied"] as? Bool == false)
            address = try #require(change["content"] as? String)
        }
        let result: [String: Any] = [
            "id": String(repeating: "2", count: 32), "name": name,
            "type": type, "content": address, "proxied": proxied
        ]
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (
            try JSONSerialization.data(withJSONObject: ["success": status == 200, "result": result]
            ),
            response
        )
    }
}

private func publisher(_ fixture: DNSFixture) throws -> LANDNSPublisher {
    let configuration = try LANDNSConfiguration(
        zoneID: String(repeating: "1", count: 32), recordID: String(repeating: "2", count: 32),
        hostname: "remote.example.com")
    return try LANDNSPublisher(configuration: configuration, token: PairingSecurity.randomToken()) {
        try await fixture.send($0)
    }
}

@Test func unchangedVerifiedRecordDoesNotWrite() async throws {
    let fixture = DNSFixture()
    #expect(try await !publisher(fixture).publish(address: "192.168.1.10"))
    #expect(await fixture.methods == ["GET"])
}

@Test func changedAddressIsPatchedThenReadBack() async throws {
    let fixture = DNSFixture()
    #expect(try await publisher(fixture).publish(address: "192.168.1.20"))
    #expect(await fixture.methods == ["GET", "PATCH", "GET"])
    #expect(await fixture.address == "192.168.1.20")
}

@Test func mismatchedOrProxiedRecordsAreNeverChanged() async throws {
    for variant in 0...2 {
        let fixture = DNSFixture()
        if variant == 0 { await fixture.alter(name: "another.example.com") }
        if variant == 1 { await fixture.alter(type: "CNAME") }
        if variant == 2 { await fixture.alter(proxied: true) }
        await #expect(throws: LANDNSError.recordMismatch) {
            try await publisher(fixture).publish(address: "192.168.1.20")
        }
        #expect(await fixture.methods == ["GET"])
    }
}

@Test func publicAndInvalidAddressesNeverReachTheAPI() async throws {
    let fixture = DNSFixture()
    for address in ["8.8.8.8", "0.0.0.0", "127.0.0.1", "192.168.001.10", "invalid"] {
        await #expect(throws: LANDNSError.invalidAddress) {
            try await publisher(fixture).publish(address: address)
        }
    }
    #expect(await fixture.methods.isEmpty)
}

@Test func authorizationFailureIsNotAutomaticallyRetried() async throws {
    let fixture = DNSFixture()
    await fixture.alter(status: 403)
    await #expect(throws: LANDNSError.rejected(403)) {
        try await publisher(fixture).publish(address: "192.168.1.20")
    }
    #expect(await fixture.methods == ["GET"])
}
