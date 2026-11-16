import AppleCore
import Testing
@testable import WebRemoteSupport

private func policy() throws -> WebRequestPolicy {
    try WebRequestPolicy(
        endpoint: WebEndpoint(
            hostname: "remote.example.com", port: 47_625, bindAddress: "192.168.1.10",
            certificateChain: "/certificate.pem", privateKey: "/key.pem"))
}

@Test func pairingRequiresExactOriginHostAndJSON() throws {
    let policy = try policy()
    let headers = [
        ("Host", "remote.example.com:47625"),
        ("Origin", "https://remote.example.com:47625"),
        ("Content-Type", "application/json; charset=utf-8")
    ]
    #expect(
        policy.route(method: "POST", uri: "/api/pairing/start", headers: headers) == .pairingStart)
    for index in headers.indices {
        var altered = headers
        altered.remove(at: index)
        #expect(policy.route(method: "POST", uri: "/api/pairing/start", headers: altered) == nil)
    }
    let duplicate = headers + [("origin", "https://another.example.com")]
    #expect(policy.route(method: "POST", uri: "/api/pairing/start", headers: duplicate) == nil)
    #expect(
        policy.route(
            method: "POST", uri: "/api/pairing/start",
            headers: headers + [("Sec-Fetch-Site", "cross-site")]) == nil)
}

@Test func socketCannotUpgradeFromAnotherOriginOrQueryURL() throws {
    let policy = try policy()
    let headers = [
        ("Host", "remote.example.com:47625"),
        ("Origin", "https://remote.example.com:47625")
    ]
    #expect(policy.route(method: "GET", uri: "/remote", headers: headers) == .socket)
    #expect(policy.route(method: "GET", uri: "/remote", headers: [headers[0]]) == nil)
    #expect(policy.route(method: "GET", uri: "/remote?token=", headers: headers) == nil)
    #expect(policy.route(method: "OPTIONS", uri: "/remote", headers: headers) == nil)
}

@Test func browserNavigationHasAnExplicitAssetAllowlist() throws {
    let policy = try policy()
    let headers = [("Host", "remote.example.com:47625")]
    #expect(policy.route(method: "GET", uri: "/", headers: headers) == .asset("/"))
    for uri in [
        "/../private/key.pem", "/%2e%2e/key.pem", "https://another.example.com/", "/app.js?x=1"
    ] {
        #expect(policy.route(method: "GET", uri: uri, headers: headers) == nil)
    }
    #expect(policy.route(method: "GET", uri: "/", headers: headers + headers) == nil)
}

@Test func credentialCookiesPreserveBase64PaddingAndRejectAmbiguity() throws {
    let policy = try policy()
    let credential = try PairingSecurity.randomToken()
    let field = "other=ignored; __Host-sofaremote=\(credential)"
    #expect(policy.cookie("__Host-sofaremote", headers: [("Cookie", field)]) == credential)
    #expect(
        policy.cookie(
            "__Host-sofaremote", headers: [("Cookie", field + "; __Host-sofaremote=\(credential)")])
            == nil)
    #expect(
        policy.cookie("__Host-sofaremote", headers: [("Cookie", field), ("cookie", field)]) == nil)
    #expect(policy.cookie("__Host-sofaremote", headers: [("Cookie", "__Host-sofaremote=")]) == nil)
}
