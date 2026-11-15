import AppleCore
import Foundation
import Testing
@testable import WebRemoteSupport

@MainActor
private final class HTTPFixture {
    var devices: [String: String] = [:]
    var codeNumber = 2000
    lazy var pairing = WebPairingCoordinator(
        isUnlocked: { true }, canPair: { self.devices.count < 8 },
        authorize: { name in
            let credential = try PairingSecurity.randomToken()
            self.devices[credential] = name
            return credential
        },
        makeCode: {
            self.codeNumber += 1; return String(self.codeNumber)
        })
    var application: WebHTTPApplication { get throws { try makeApplication() } }
    let headers = [
        ("Host", "remote.example.com:47625"),
        ("Origin", "https://remote.example.com:47625"),
        ("Content-Type", "application/json")
    ]

    func makeApplication() throws -> WebHTTPApplication {
        try WebHTTPApplication(
            endpoint: WebEndpoint(
                hostname: "remote.example.com", port: 47_625, bindAddress: "192.168.1.10",
                certificateChain: "/cert.pem", privateKey: "/key.pem"),
            assets: [
                "/": WebAsset(data: Data("<title>Remote</title>".utf8), contentType: "text/html")
            ],
            pairing: pairing, deviceName: { "Test Mac" },
            resolveCredential: { self.devices[$0] },
            forgetCredential: { self.devices.removeValue(forKey: $0) })
    }

    func post(_ uri: String, fields: [String: String], cookie: String? = nil) throws -> WebReply {
        var headers = headers
        if let cookie { headers.append(("Cookie", cookie)) }
        return try application.handle(
            method: "POST", uri: uri, headers: headers,
            body: try JSONSerialization.data(withJSONObject: fields))
    }

    func object(_ reply: WebReply) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
    }

    func cookies(_ reply: WebReply) -> String {
        reply.headers.filter { $0.0 == "Set-Cookie" }.map { String($0.1.prefix { $0 != ";" }) }
            .joined(separator: "; ")
    }
}

@Test @MainActor func httpPairingKeepsCredentialsOutOfJSONAndUsesSecureCookies() throws {
    let fixture = HTTPFixture()
    let start = try fixture.post("/api/pairing/start", fields: ["name": "Test browser"])
    #expect(start.status == 200)
    let object = try fixture.object(start)
    #expect(Set(object.keys) == ["requestId", "expiresIn"])
    let id = try #require(object["requestId"] as? String)
    let code = try #require(fixture.pairing.prompt?.code)
    let confirmed = try fixture.post(
        "/api/pairing/confirm", fields: ["requestId": id, "code": code],
        cookie: fixture.cookies(start))
    #expect(confirmed.status == 200)
    #expect(Set(try fixture.object(confirmed).keys) == ["paired"])
    #expect(fixture.devices.count == 1)
    #expect(
        confirmed.headers.allSatisfy {
            $0.1.contains("; Secure;") && $0.1.contains("; HttpOnly;")
                && $0.1.contains("; SameSite=Strict;")
        })
}

@Test @MainActor func forgedPairingRequestCannotShowAPINOrMintACredential() throws {
    let fixture = HTTPFixture()
    let application = try fixture.application
    let forged =
        fixture.headers.filter { $0.0 != "Origin" }
        + [("Origin", "https://another.example.com")]
    let reply = application.handle(
        method: "POST", uri: "/api/pairing/start", headers: forged,
        body: Data("{\"name\":\"Untrusted\"}".utf8))
    #expect(reply.status == 403)
    #expect(fixture.pairing.prompt == nil)
    #expect(fixture.devices.isEmpty)
}

@Test @MainActor func browserForgetRevokesTheExistingCredential() throws {
    let fixture = HTTPFixture()
    let credential = try PairingSecurity.randomToken()
    fixture.devices[credential] = "Browser"
    let cookie = "__Host-sofaremote=\(credential)"
    let before = try fixture.application.handle(
        method: "GET", uri: "/api/status", headers: fixture.headers + [("Cookie", cookie)],
        body: Data())
    #expect(try fixture.object(before)["paired"] as? Bool == true)
    let reply = try fixture.post("/api/pairing/forget", fields: [:], cookie: cookie)
    #expect(reply.status == 200)
    #expect(fixture.devices.isEmpty)
    let after = try fixture.application.handle(
        method: "GET", uri: "/api/status", headers: fixture.headers + [("Cookie", cookie)],
        body: Data())
    #expect(try fixture.object(after)["paired"] as? Bool == false)
}

@Test @MainActor func unexpectedJSONFieldsAreRejectedWithoutShowingAPIN() throws {
    let fixture = HTTPFixture()
    let reply = try fixture.post(
        "/api/pairing/start", fields: ["name": "Browser", "unexpected": "value"])
    #expect(reply.status == 400)
    #expect(fixture.pairing.prompt == nil)
}
