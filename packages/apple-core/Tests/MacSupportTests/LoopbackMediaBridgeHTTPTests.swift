import Foundation
@testable import MacSupport
import XCTest

final class LoopbackMediaBridgeHTTPTests: XCTestCase {
    @MainActor
    func testUnauthorizedRequestsDoNotConsumeAuthenticatedQuota() {
        let configuration = MediaBridgeTestFixture.configuration(port: 47_623)
        let bridge = LoopbackMediaBridge(configuration: configuration)
        let now = ContinuousClock.now
        let validBearer = "Bearer \(configuration.token)"
        let invalidBearer = request(
            port: configuration.port, origin: nil, authorization: "invalid-bearer")
        let invalidOrigin = request(
            port: configuration.port, origin: "https://unauthorized.example",
            authorization: validBearer)
        let validRequest = request(
            port: configuration.port, origin: nil, authorization: validBearer)

        for index in 0..<(AuthenticatedRequestQuota.maximumRequestsPerWindow + 1) {
            let unauthorizedRequest = index.isMultiple(of: 2) ? invalidBearer : invalidOrigin
            XCTAssertEqual(bridge.admission(for: unauthorizedRequest, at: now), .unauthorized)
        }
        for _ in 0..<AuthenticatedRequestQuota.maximumRequestsPerWindow {
            XCTAssertEqual(bridge.admission(for: validRequest, at: now), .allowed)
        }
        XCTAssertEqual(bridge.admission(for: validRequest, at: now), .rateLimited)
        XCTAssertEqual(bridge.admission(for: invalidOrigin, at: now), .unauthorized)
        XCTAssertEqual(
            bridge.admission(for: validRequest, at: now.advanced(by: .seconds(1))), .allowed)
    }

    func testIINAFormWireDecodesOneJSONPayload() throws {
        let encodedBody =
            "payload=%7B%22targetId%22%3A%22iina%3Awindow-1%22%2C%22name%22%3A%22A%2BB+%26+C%22%7D"
        let wire = Data(
            ("POST /v1/iina/update HTTP/1.1\r\n"
                + "Host: 127.0.0.1:47623\r\n"
                + "Content-Type: application/x-www-form-urlencoded\r\n"
                + "Content-Length: \(encodedBody.utf8.count)\r\n\r\n"
                + encodedBody).utf8)

        let request = try XCTUnwrap(HTTPRequest.parse(wire))
        let json = try IINAFormPayload.decode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: String])
        XCTAssertEqual(object, ["targetId": "iina:window-1", "name": "A+B & C"])
    }

    func testIINAFormRejectsDuplicatePayloadAndExtraFields() {
        XCTAssertThrowsError(
            try IINAFormPayload.decode(request(body: "payload=%7B%7D&payload=%7B%7D")))
        XCTAssertThrowsError(try IINAFormPayload.decode(request(body: "payload=%7B%7D&other=x")))
    }

    func testIINAFormRejectsMalformedEncodingWrongContentTypeAndOversizeBodies() {
        XCTAssertThrowsError(try IINAFormPayload.decode(request(body: "payload=%7B%ZZ")))
        XCTAssertThrowsError(
            try IINAFormPayload.decode(request(contentType: "application/json", body: "{}")))
        XCTAssertThrowsError(
            try IINAFormPayload.decode(
                request(body: "payload=" + String(repeating: "a", count: 65_536))))
    }

    private func request(
        contentType: String = IINAFormPayload.contentType,
        body: String
    ) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: "/v1/iina/update", query: [:], host: "127.0.0.1:47623",
            origin: nil, authorization: nil, contentType: contentType,
            body: Data(body.utf8))
    }

    private func request(port: UInt16, origin: String?, authorization: String?) -> HTTPRequest {
        HTTPRequest(
            method: "GET", path: "/v1/chrome/next", query: [:], host: "127.0.0.1:\(port)",
            origin: origin, authorization: authorization, contentType: nil, body: Data())
    }
}
