import Foundation
@testable import MacSupport
import XCTest

final class LoopbackMediaBridgeHTTPTests: XCTestCase {
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
}
