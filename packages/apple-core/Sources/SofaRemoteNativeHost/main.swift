import Foundation
import MacSupport

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private let maximumMessageBytes = 65_536
private let extensionID = "bjplbbniljmmhclleegdfdonjmjlpnid"

@main
private struct SofaRemoteNativeHost {
    static func main() async {
        do {
            let configuration = try loadConfiguration()
            let output = NativeHostOutput()
            let polling = Task {
                await pollBridge(configuration: configuration, output: output)
            }
            while let data = try readFrame(), let message = try parse(message: data) {
                guard allowedExtensionMessage(message) else { continue }
                _ = try await postToBridge(configuration: configuration, body: message)
                if message["type"] as? String == "media.targetUpdate" {
                    try output.write(["type": "media.ready"])
                }
            }
            polling.cancel()
        } catch {
            // Native messaging stderr is reserved for diagnostics. Do not include configuration data.
            FileHandle.standardError.write(Data("Sofa Remote native host stopped.\n".utf8))
        }
    }

    private static func loadConfiguration() throws -> MediaBridgeConfiguration {
        let url = MediaBridgeConfiguration.configurationURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw HostError.configurationPermissions
        }
        let configuration = try JSONDecoder().decode(
            MediaBridgeConfiguration.self, from: Data(contentsOf: url))
        guard configuration.port > 0, configuration.token.utf8.count >= 32 else {
            throw HostError.invalidConfiguration
        }
        return configuration
    }

    private static func readFrame() throws -> Data? {
        guard let header = readExactly(4) else { return nil }
        let length = header.enumerated().reduce(UInt32(0)) { value, item in
            value | (UInt32(item.element) << (UInt32(item.offset) * 8))
        }
        guard length > 0, length <= maximumMessageBytes else { throw HostError.invalidFrame }
        guard let body = readExactly(Int(length)) else { throw HostError.invalidFrame }
        return body
    }

    private static func readExactly(_ count: Int) -> Data? {
        var result = Data()
        while result.count < count {
            let next = FileHandle.standardInput.readData(ofLength: count - result.count)
            if next.isEmpty { return result.isEmpty ? nil : nil }
            result.append(next)
        }
        return result
    }

    private static func parse(message data: Data) throws -> [String: Any]? {
        guard data.count <= maximumMessageBytes,
            let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HostError.invalidFrame }
        return message
    }

    private static func allowedExtensionMessage(_ message: [String: Any]) -> Bool {
        guard let type = message["type"] as? String,
            let targetID = message["targetId"] as? String,
            targetID.range(of: #"^chrome:[1-9][0-9]{0,9}$"#, options: .regularExpression) != nil
        else { return false }
        switch type {
        case "media.targetUnavailable":
            return Set(message.keys) == ["type", "targetId"]
        case "media.targetUpdate":
            return Set(message.keys) == ["type", "targetId", "target"]
                && (message["target"] as? [String: Any]) != nil
        case "media.commandResult":
            guard Set(message.keys).isSubset(of: ["type", "targetId", "requestId", "ok", "error"]),
                let requestID = message["requestId"] as? String,
                !requestID.isEmpty, requestID.utf8.count <= 128,
                message["ok"] is Bool
            else { return false }
            if let error = message["error"] as? String, error.utf8.count > 1_024 { return false }
            return true
        default:
            return false
        }
    }

    private static func postToBridge(
        configuration: MediaBridgeConfiguration,
        body: [String: Any]
    ) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(configuration.port)/v1/chrome") else {
            throw HostError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
        else {
            throw HostError.bridgeUnavailable
        }
        return data
    }

    private static func pollBridge(
        configuration: MediaBridgeConfiguration,
        output: NativeHostOutput
    ) async {
        while !Task.isCancelled {
            do {
                guard
                    let url = URL(
                        string: "http://127.0.0.1:\(configuration.port)/v1/chrome/next")
                else { throw HostError.invalidConfiguration }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(
                    "Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 2
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let command = object["command"] as? [String: Any],
                    validBridgeCommand(command)
                else {
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                var message = command
                message["type"] = "media.command"
                try output.write(message)
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func validBridgeCommand(_ value: [String: Any]) -> Bool {
        guard Set(value.keys).isSubset(of: ["requestId", "targetId", "action", "value"]),
            let requestID = value["requestId"] as? String,
            !requestID.isEmpty, requestID.utf8.count <= 256,
            let targetID = value["targetId"] as? String,
            targetID.range(of: #"^chrome:[1-9][0-9]{0,9}$"#, options: .regularExpression) != nil,
            let action = value["action"] as? String
        else { return false }
        switch action {
        case "playPause", "next", "previous":
            return value["value"] == nil
                && Set(value.keys) == ["requestId", "targetId", "action"]
        case "seek":
            guard let number = value["value"] as? Double else { return false }
            return number.isFinite && number != 0 && abs(number) <= 3_600
                && Set(value.keys) == ["requestId", "targetId", "action", "value"]
        case "setVolume":
            guard let number = value["value"] as? Double else { return false }
            return number.isFinite && number >= 0 && number <= 1
                && Set(value.keys) == ["requestId", "targetId", "action", "value"]
        default: return false
        }
    }
}

private final class NativeHostOutput: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard body.count <= maximumMessageBytes else { throw HostError.invalidFrame }
        let length = UInt32(body.count)
        var frame = Data([
            UInt8(length & 0xff), UInt8((length >> 8) & 0xff),
            UInt8((length >> 16) & 0xff), UInt8((length >> 24) & 0xff)
        ])
        frame.append(body)
        lock.lock()
        FileHandle.standardOutput.write(frame)
        lock.unlock()
    }
}

private enum HostError: Error {
    case invalidFrame
    case invalidConfiguration
    case configurationPermissions
    case bridgeUnavailable
}
