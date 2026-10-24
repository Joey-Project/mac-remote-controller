import Foundation

public struct RemoteCommand: Codable, Sendable, Equatable {
    public var name: CommandName
    public var x: Double?
    public var y: Double?
    public var value: Double?
    public var text: String?
    public var key: RemoteKey?
    public var button: PointerButton?

    public init(
        name: CommandName,
        x: Double? = nil,
        y: Double? = nil,
        value: Double? = nil,
        text: String? = nil,
        key: RemoteKey? = nil,
        button: PointerButton? = nil
    ) {
        self.name = name
        self.x = x
        self.y = y
        self.value = value
        self.text = text
        self.key = key
        self.button = button
    }

    public func validate() throws {
        switch name {
        case .pointerMove:
            try requireCoordinates(limit: 500)
            try requireOnly(["x", "y"])
        case .pointerClick:
            guard button != nil else {
                throw WireProtocolError.invalidCommand("pointer.click requires button")
            }
            try requireOnly(["button"])
        case .pointerScroll:
            try requireCoordinates(limit: 100)
            try requireOnly(["x", "y"])
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
        case .systemVolumeSet:
            guard let value, value.isFinite, (0...1).contains(value) else {
                throw WireProtocolError.invalidCommand(
                    "system.volume.set value must be finite and within 0...1")
            }
            try requireOnly(["value"])
        }
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
    }
}
