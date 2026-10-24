import Foundation

public struct RemoteCommand: Codable, Sendable, Equatable {
    public var name: CommandName
    public var x: Double?
    public var y: Double?
    public var value: Double?
    public var text: String?
    public var key: RemoteKey?
    public var button: PointerButton?
    public var shortcut: SystemShortcut?
    public var mediaRequest: MediaRequest?
    public var tapTimestamp: TimeInterval?

    public init(
        name: CommandName,
        x: Double? = nil,
        y: Double? = nil,
        value: Double? = nil,
        text: String? = nil,
        key: RemoteKey? = nil,
        button: PointerButton? = nil,
        shortcut: SystemShortcut? = nil,
        mediaRequest: MediaRequest? = nil,
        tapTimestamp: TimeInterval? = nil
    ) {
        self.name = name
        self.x = x
        self.y = y
        self.value = value
        self.text = text
        self.key = key
        self.button = button
        self.shortcut = shortcut
        self.mediaRequest = mediaRequest
        self.tapTimestamp = tapTimestamp
    }

    public func validate() throws {
        switch name {
        case .pointerMove, .pointerScroll:
            try requireCoordinates(limit: name == .pointerMove ? 500 : 100)
            try requireOnly(["x", "y"])
        case .pointerClick, .pointerButtonDown, .pointerButtonUp:
            try validatePointerButton()
        case .keyboardText:
            guard let text, !text.isEmpty, text.utf8.count <= WireLimits.maximumTextBytes else {
                throw WireProtocolError.invalidCommand(
                    "keyboard.text requires 1...4096 UTF-8 bytes")
            }
            try requireOnly(["text"])
        case .systemShortcut, .keyboardKey:
            try validateKeyOrShortcut()
        case .systemVolumeSet:
            guard let value, value.isFinite, (0...1).contains(value) else {
                throw WireProtocolError.invalidCommand(
                    "system.volume.set value must be finite and within 0...1")
            }
            try requireOnly(["value"])
        case .mediaControl:
            try validateMediaControl()
        }
    }

    private func validatePointerButton() throws {
        guard button != nil else {
            throw WireProtocolError.invalidCommand("\(name.rawValue) requires button")
        }
        if name == .pointerClick {
            if let tapTimestamp,
                !tapTimestamp.isFinite
                    || !(0...WireLimits.maximumTapTimestampSeconds).contains(tapTimestamp)
            {
                throw WireProtocolError.invalidCommand(
                    "pointer.click tapTimestamp must be finite and within the supported range")
            }
            try requireOnly(["button", "tapTimestamp"])
        } else {
            try requireOnly(["button"])
        }
    }

    private func validateKeyOrShortcut() throws {
        switch name {
        case .systemShortcut:
            guard shortcut != nil else {
                throw WireProtocolError.invalidCommand(
                    "system.shortcut requires an allowlisted action")
            }
            try requireOnly(["shortcut"])
        case .keyboardKey:
            guard key != nil else {
                throw WireProtocolError.invalidCommand("keyboard.key requires an allowlisted key")
            }
            try requireOnly(["key"])
        default:
            throw WireProtocolError.invalidCommand("unsupported key action")
        }
    }

    private func validateMediaControl() throws {
        guard let mediaRequest else {
            throw WireProtocolError.invalidCommand("media.control requires a media request")
        }
        try requireOnly(["mediaRequest"])
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
        if shortcut != nil, !allowed.contains("shortcut") {
            throw WireProtocolError.invalidCommand("unexpected shortcut for \(name.rawValue)")
        }
        if mediaRequest != nil, !allowed.contains("mediaRequest") {
            throw WireProtocolError.invalidCommand("unexpected media request for \(name.rawValue)")
        }
        if tapTimestamp != nil, !allowed.contains("tapTimestamp") {
            throw WireProtocolError.invalidCommand("unexpected tapTimestamp for \(name.rawValue)")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MediaDynamicCodingKey.self)
        let name = try container.decode(
            CommandName.self, forKey: MediaDynamicCodingKey("name"))
        let keys = Set(container.allKeys.map(\.stringValue))
        let allowed: Set<String> = [
            "name", "x", "y", "value", "text", "key", "button", "shortcut", "mediaRequest",
            "tapTimestamp"
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
        shortcut = try container.decodeIfPresent(
            SystemShortcut.self, forKey: MediaDynamicCodingKey("shortcut"))
        mediaRequest = try container.decodeIfPresent(
            MediaRequest.self, forKey: MediaDynamicCodingKey("mediaRequest"))
        tapTimestamp = try container.decodeIfPresent(
            TimeInterval.self, forKey: MediaDynamicCodingKey("tapTimestamp"))
    }
}
