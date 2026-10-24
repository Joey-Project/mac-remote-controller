import Foundation

public enum CommandName: String, Codable, Sendable, Equatable {
    case pointerMove = "pointer.move"
    case pointerClick = "pointer.click"
    case pointerScroll = "pointer.scroll"
    case keyboardText = "keyboard.text"
    case keyboardKey = "keyboard.key"
    case systemVolumeSet = "system.volume.set"
    case mediaControl = "media.control"
}

public enum RemoteKey: String, Codable, Sendable, Equatable {
    case returnKey = "return"
    case escape
    case backspace
    case space
    case left
    case right
    case up
    case down
}

public enum PointerButton: String, Codable, Sendable, Equatable {
    case left
    case right
}

public struct RemoteCommand: Codable, Sendable, Equatable {
    public var name: CommandName
    public var x: Double?
    public var y: Double?
    public var value: Double?
    public var text: String?
    public var key: RemoteKey?
    public var button: PointerButton?
    public var mediaRequest: MediaRequest?

    public init(
        name: CommandName,
        x: Double? = nil,
        y: Double? = nil,
        value: Double? = nil,
        text: String? = nil,
        key: RemoteKey? = nil,
        button: PointerButton? = nil,
        mediaRequest: MediaRequest? = nil
    ) {
        self.name = name
        self.x = x
        self.y = y
        self.value = value
        self.text = text
        self.key = key
        self.button = button
        self.mediaRequest = mediaRequest
    }

    public func validate() throws {
        switch name {
        case .pointerMove:
            try validatePointer(limit: 500)
        case .pointerScroll:
            try validatePointer(limit: 100)
        case .pointerClick:
            try validateClick()
        case .keyboardText, .keyboardKey:
            try validateKeyboard()
        case .systemVolumeSet:
            try validateSystemVolume()
        case .mediaControl:
            try validateMediaControl()
        }
    }

    private func validatePointer(limit: Double) throws {
        try requireCoordinates(limit: limit)
        try requireOnly(["x", "y"])
    }

    private func validateClick() throws {
        guard button != nil else {
            throw WireProtocolError.invalidCommand("pointer.click requires button")
        }
        try requireOnly(["button"])
    }

    private func validateKeyboard() throws {
        switch name {
        case .keyboardText:
            guard let text, !text.isEmpty, text.utf8.count <= WireLimits.maximumTextBytes else {
                throw WireProtocolError.invalidCommand(
                    "keyboard.text requires 1...4096 UTF-8 bytes")
            }
            try requireOnly(["text"])
        case .keyboardKey:
            guard key != nil else {
                throw WireProtocolError.invalidCommand("keyboard.key requires an allowlisted key")
            }
            try requireOnly(["key"])
        default:
            throw WireProtocolError.invalidCommand("keyboard action is invalid")
        }
    }

    private func validateSystemVolume() throws {
        guard let value, value.isFinite, (0...1).contains(value) else {
            throw WireProtocolError.invalidCommand(
                "system.volume.set value must be finite and within 0...1")
        }
        try requireOnly(["value"])
    }

    private func validateMediaControl() throws {
        guard let mediaRequest else {
            throw WireProtocolError.invalidCommand("media.control requires a media request")
        }
        guard x == nil, y == nil, value == nil, text == nil, key == nil, button == nil else {
            throw WireProtocolError.invalidCommand(
                "media.control contains fields from another command")
        }
        try mediaRequest.validate()
    }

    private func requireCoordinates(limit: Double) throws {
        guard let x, let y, x.isFinite, y.isFinite, abs(x) <= limit, abs(y) <= limit else {
            throw WireProtocolError.invalidCommand(
                "\(name.rawValue) requires finite coordinates within ±\(Int(limit))")
        }
    }

    private func requireOnly(_ allowed: Set<String>) throws {
        if x != nil, !allowed.contains("x") {
            throw WireProtocolError.invalidCommand("unexpected x for \(name.rawValue)")
        }
        if y != nil, !allowed.contains("y") {
            throw WireProtocolError.invalidCommand("unexpected y for \(name.rawValue)")
        }
        if value != nil, !allowed.contains("value") {
            throw WireProtocolError.invalidCommand("unexpected value for \(name.rawValue)")
        }
        if text != nil, !allowed.contains("text") {
            throw WireProtocolError.invalidCommand("unexpected text for \(name.rawValue)")
        }
        if key != nil, !allowed.contains("key") {
            throw WireProtocolError.invalidCommand("unexpected key for \(name.rawValue)")
        }
        if button != nil, !allowed.contains("button") {
            throw WireProtocolError.invalidCommand("unexpected button for \(name.rawValue)")
        }
        if mediaRequest != nil, !allowed.contains("mediaRequest") {
            throw WireProtocolError.invalidCommand("unexpected media request for \(name.rawValue)")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MediaDynamicCodingKey.self)
        let nameKey = MediaDynamicCodingKey("name")
        let name = try container.decode(CommandName.self, forKey: nameKey)
        let keys = Set(container.allKeys.map(\.stringValue))
        let allowed: Set<String> = [
            "name", "x", "y", "value", "text", "key", "button", "mediaRequest"
        ]
        guard keys.isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "command contains an unexpected field"))
        }
        if name == .mediaControl, keys != ["name", "mediaRequest"] {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "media.control must contain only name and mediaRequest"))
        }
        self.name = name
        x = try container.decodeIfPresent(Double.self, forKey: MediaDynamicCodingKey("x"))
        y = try container.decodeIfPresent(Double.self, forKey: MediaDynamicCodingKey("y"))
        value = try container.decodeIfPresent(Double.self, forKey: MediaDynamicCodingKey("value"))
        text = try container.decodeIfPresent(String.self, forKey: MediaDynamicCodingKey("text"))
        key = try container.decodeIfPresent(RemoteKey.self, forKey: MediaDynamicCodingKey("key"))
        button = try container.decodeIfPresent(
            PointerButton.self, forKey: MediaDynamicCodingKey("button"))
        mediaRequest = try container.decodeIfPresent(
            MediaRequest.self, forKey: MediaDynamicCodingKey("mediaRequest"))
    }
}
