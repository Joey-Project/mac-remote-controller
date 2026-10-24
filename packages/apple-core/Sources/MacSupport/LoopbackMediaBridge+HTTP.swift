import AppleCore
import CoreFoundation
import Foundation
import Network

extension LoopbackMediaBridge {
    func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard allowRequest(request, on: connection) else { return }
        do {
            try route(request, on: connection)
        } catch {
            send(status: 400, body: ["error": "invalid_request"], on: connection)
        }
    }

    private func allowRequest(_ request: HTTPRequest, on connection: NWConnection) -> Bool {
        let now = ContinuousClock.now
        if now - rateWindow >= .seconds(1) {
            rateWindow = now
            requestCount = 0
        }
        requestCount += 1
        guard requestCount <= 1_024 else {
            send(status: 429, body: ["error": "rate_limited"], on: connection)
            return false
        }
        guard request.host == "127.0.0.1:\(configuration.port)", request.origin == nil,
            request.authorization.map(constantTimeMatches) == true
        else {
            send(status: 401, body: ["error": "unauthorized"], on: connection)
            return false
        }
        return true
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) throws {
        switch (request.method, request.path) {
        case ("POST", "/v1/chrome") where request.query.isEmpty:
            guard request.contentType == "application/json" else { throw HTTPError.badRequest }
            try handleChrome(request.body)
            send(status: 204, body: Data(), on: connection)
        case ("GET", "/v1/chrome/next") where request.query.isEmpty:
            let command = takeNext(for: .youtube) ?? takeNext(for: .bilibili)
            send(status: 200, body: try commandResponse(command), on: connection)
        case ("POST", "/v1/iina/update") where request.query.isEmpty:
            try updateTarget(from: iinaJSONBody(request), expectedKind: .iina)
            send(status: 204, body: Data(), on: connection)
        case ("POST", "/v1/iina/unregister") where request.query.isEmpty:
            try unregisterIINA(iinaJSONBody(request), on: connection)
        case ("GET", "/v1/iina/next"):
            try pollIINA(request.query, on: connection)
        case ("POST", "/v1/iina/result") where request.query.isEmpty:
            try handleResult(iinaJSONBody(request), expectedTargetPrefix: "iina:")
            send(status: 204, body: Data(), on: connection)
        default:
            send(status: 404, body: ["error": "not_found"], on: connection)
        }
    }

    func iinaJSONBody(_ request: HTTPRequest) throws -> Data {
        try IINAFormPayload.decode(request)
    }

    private func unregisterIINA(_ body: Data, on connection: NWConnection) throws {
        let object = try strictObject(body, keys: ["targetId"])
        let targetID = try string(object["targetId"], max: WireLimits.maximumMediaTargetIDBytes)
        guard targetID.hasPrefix("iina:") else { throw HTTPError.badRequest }
        removeTarget(targetID)
        send(status: 204, body: Data(), on: connection)
    }

    private func pollIINA(_ query: [String: String], on connection: NWConnection) throws {
        guard Set(query.keys) == ["targetId"], let targetID = query["targetId"],
            targetID.hasPrefix("iina:")
        else { throw HTTPError.badRequest }
        send(
            status: 200,
            body: try commandResponse(takeNext(targetID: targetID)),
            on: connection)
    }

    func handleChrome(_ body: Data) throws {
        let object = try strictObject(
            body, allowed: ["type", "targetId", "target", "requestId", "ok", "error"])
        let type = try string(object["type"], max: 64)
        let targetID = try string(object["targetId"], max: WireLimits.maximumMediaTargetIDBytes)
        guard targetID.hasPrefix("chrome:") else { throw HTTPError.badRequest }
        switch type {
        case "media.targetUpdate":
            guard Set(object.keys) == ["type", "targetId", "target"] else {
                throw HTTPError.badRequest
            }
            guard let target = object["target"] as? [String: Any] else {
                throw HTTPError.badRequest
            }
            var targetBody = target
            targetBody["id"] = targetID
            try updateTarget(from: try json(targetBody), expectedKind: nil)
        case "media.targetUnavailable":
            guard Set(object.keys) == ["type", "targetId"] else { throw HTTPError.badRequest }
            removeTarget(targetID)
        case "media.commandResult":
            guard Set(object.keys).isSubset(of: ["type", "targetId", "requestId", "ok", "error"]),
                object["type"] as? String == type
            else { throw HTTPError.badRequest }
            try handleResult(body, expectedTargetPrefix: "chrome:")
        default:
            throw HTTPError.badRequest
        }
    }

    func updateTarget(from body: Data, expectedKind: MediaTargetKind?) throws {
        let object = try strictObject(
            body, keys: ["id", "name", "kind", "capabilities", "playerVolume"])
        let id = try string(object["id"], max: WireLimits.maximumMediaTargetIDBytes)
        let name = try string(object["name"], max: WireLimits.maximumMediaTargetNameBytes)
        guard let kindString = object["kind"] as? String,
            let kind = MediaTargetKind(rawValue: kindString),
            expectedKind == nil || expectedKind == kind,
            let capabilities = object["capabilities"] as? [String: Any]
        else { throw HTTPError.badRequest }
        guard
            Set(capabilities.keys) == [
                "playPause", "seek", "next", "previous", "playerVolumeMaximum"
            ]
        else {
            throw HTTPError.badRequest
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = capabilities[key] as? Bool else { throw HTTPError.badRequest }
            return value
        }
        guard let rawMaximum = capabilities["playerVolumeMaximum"] else {
            throw HTTPError.badRequest
        }
        let maximum: Double?
        if rawMaximum is NSNull {
            maximum = nil
        } else {
            guard let value = jsonNumber(rawMaximum), value > 0 else { throw HTTPError.badRequest }
            maximum = value
        }
        guard let rawVolume = object["playerVolume"] else { throw HTTPError.badRequest }
        let playerVolume: Double?
        if rawVolume is NSNull {
            playerVolume = nil
        } else {
            guard let value = jsonNumber(rawVolume), value >= 0 else { throw HTTPError.badRequest }
            playerVolume = value
        }
        let target = MediaTarget(
            id: id, name: name, kind: kind,
            capabilities: MediaCapabilities(
                playPause: try flag("playPause"), seek: try flag("seek"), next: try flag("next"),
                previous: try flag("previous"), playerVolumeMaximum: maximum),
            playerVolume: playerVolume)
        if try router.update(target) { onTargetsChanged?(sortedTargets) }
    }

    func handleResult(_ body: Data, expectedTargetPrefix: String) throws {
        let object = try strictObject(
            body, allowed: ["type", "targetId", "requestId", "ok", "error"])
        let targetID = try string(object["targetId"], max: WireLimits.maximumMediaTargetIDBytes)
        guard targetID.hasPrefix(expectedTargetPrefix) else { throw HTTPError.badRequest }
        let requestID = try string(object["requestId"], max: 256)
        guard let succeeded = object["ok"] as? Bool else { throw HTTPError.badRequest }
        let error: String?
        if let rawError = object["error"] {
            guard let value = rawError as? String, value.utf8.count <= 1_024 else {
                throw HTTPError.badRequest
            }
            error = value
        } else {
            error = nil
        }
        guard
            router.completeResult(
                requestID: requestID, targetID: targetID,
                errorMessage: succeeded ? nil : (error ?? "The media player rejected the command."))
                != nil
        else {
            throw HTTPError.badRequest
        }
    }

    var sortedTargets: [MediaTarget] { router.targets.values.sorted { $0.id < $1.id } }

    func takeNext(for kind: MediaTargetKind) -> RoutedMediaCommand? {
        router.takeNext(for: kind)
    }

    func takeNext(targetID: String) -> RoutedMediaCommand? {
        router.takeNext(targetID: targetID)
    }

    func removeTarget(_ id: String) {
        if router.remove(targetID: id) { onTargetsChanged?(sortedTargets) }
    }

    func strictObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        let object = try strictObject(data, allowed: keys)
        guard Set(object.keys) == keys else { throw HTTPError.badRequest }
        return object
    }

    func strictObject(_ data: Data, allowed: Set<String>) throws -> [String: Any] {
        guard data.count <= 65_536,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw HTTPError.badRequest }
        return object
    }

    func string(_ value: Any?, max: Int) throws -> String {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= max else {
            throw HTTPError.badRequest
        }
        return value
    }

    func jsonNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    func commandResponse(_ command: RoutedMediaCommand?) throws -> Data {
        let value: Any
        if let command {
            let encodedCommand = try JSONEncoder().encode(command)
            value = try JSONSerialization.jsonObject(with: encodedCommand)
        } else {
            value = NSNull()
        }
        return try json(["command": value])
    }

    func send(status: Int, body: Any, on connection: NWConnection) {
        let data = (try? json(body)) ?? Data()
        send(status: status, body: data, on: connection)
    }

    func send(status: Int, body: Data, on connection: NWConnection) {
        let reason =
            status == 204
            ? "No Content"
            : status == 200
                ? "OK"
                : status == 401
                    ? "Unauthorized"
                    : status == 429
                        ? "Too Many Requests"
                        : status == 503
                            ? "Service Unavailable" : status == 404 ? "Not Found" : "Bad Request"
        let headerText =
            "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\n\r\n"
        let headers = Data(headerText.utf8)
        var response = headers
        response.append(body)
        connection.send(
            content: response,
            completion: .contentProcessed { [weak self, weak connection] _ in
                MainActor.assumeIsolated {
                    if let connection { self?.finishConnection(connection) }
                }
            })
    }

    func constantTimeMatches(_ value: String) -> Bool {
        let expected = Data("Bearer \(configuration.token)".utf8)
        let actual = Data(value.utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum IINAFormPayload {
    static let contentType = "application/x-www-form-urlencoded"
    private static let maximumBodyBytes = 65_536

    static func decode(_ request: HTTPRequest) throws -> Data {
        guard request.contentType?.lowercased() == contentType else {
            throw HTTPError.badRequest
        }
        let body = request.body
        guard body.count <= maximumBodyBytes,
            let form = String(data: body, encoding: .utf8), !form.isEmpty,
            !form.contains("&"),
            let separator = form.firstIndex(of: "=")
        else { throw HTTPError.badRequest }

        let encodedKey = String(form[..<separator])
        let encodedPayload = String(form[form.index(after: separator)...])
        guard decodeComponent(encodedKey) == "payload",
            let payload = decodeComponent(encodedPayload), !payload.isEmpty,
            payload.utf8.count <= maximumBodyBytes
        else { throw HTTPError.badRequest }
        return Data(payload.utf8)
    }

    private static func decodeComponent(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
