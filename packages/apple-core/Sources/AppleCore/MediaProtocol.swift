import Foundation

public enum MediaTargetKind: String, Codable, Sendable, Equatable {
    case iina
    case youtube
    case bilibili
}

public enum MediaAction: String, Codable, Sendable, Equatable {
    case playPause
    case seek
    case next
    case previous
    case setVolume
}

public struct MediaCapabilities: Codable, Sendable, Equatable {
    public var playPause: Bool
    public var seek: Bool
    public var next: Bool
    public var previous: Bool
    public var playerVolumeMaximum: Double?

    public init(
        playPause: Bool, seek: Bool, next: Bool, previous: Bool,
        playerVolumeMaximum: Double? = nil
    ) {
        self.playPause = playPause
        self.seek = seek
        self.next = next
        self.previous = previous
        self.playerVolumeMaximum = playerVolumeMaximum
    }

    public func supports(_ action: MediaAction) -> Bool {
        switch action {
        case .playPause: playPause
        case .seek: seek
        case .next: next
        case .previous: previous
        case .setVolume: playerVolumeMaximum != nil
        }
    }

    public func validate() throws {
        if let playerVolumeMaximum,
            !playerVolumeMaximum.isFinite || playerVolumeMaximum <= 0
        {
            throw WireProtocolError.invalidEnvelope(
                "playerVolumeMaximum must be finite and greater than zero")
        }
    }
}

public struct MediaTarget: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: MediaTargetKind
    public var capabilities: MediaCapabilities
    public var playerVolume: Double?

    public init(
        id: String, name: String, kind: MediaTargetKind, capabilities: MediaCapabilities,
        playerVolume: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
        self.playerVolume = playerVolume
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= WireLimits.maximumMediaTargetIDBytes else {
            throw WireProtocolError.invalidEnvelope("media target ID is empty or too long")
        }
        guard !name.isEmpty, name.utf8.count <= WireLimits.maximumMediaTargetNameBytes else {
            throw WireProtocolError.invalidEnvelope("media target name is empty or too long")
        }
        try capabilities.validate()
        if let playerVolume {
            guard let maximum = capabilities.playerVolumeMaximum,
                playerVolume.isFinite, playerVolume >= 0, playerVolume <= maximum
            else {
                throw WireProtocolError.invalidEnvelope("playerVolume is outside its target range")
            }
        }
    }
}

public struct MediaRequest: Codable, Sendable, Equatable {
    public var targetID: String
    public var action: MediaAction
    public var value: Double?

    enum CodingKeys: String, CodingKey {
        case targetID = "targetId"
        case action
        case value
    }

    public init(targetID: String, action: MediaAction, value: Double? = nil) {
        self.targetID = targetID
        self.action = action
        self.value = value
    }

    public func validate() throws {
        guard !targetID.isEmpty, targetID.utf8.count <= WireLimits.maximumMediaTargetIDBytes else {
            throw WireProtocolError.invalidCommand("media target ID is empty or too long")
        }
        switch action {
        case .seek:
            guard let value, value.isFinite, value != 0, abs(value) <= 3_600 else {
                throw WireProtocolError.invalidCommand(
                    "media seek requires a finite nonzero value within ±3600 seconds")
            }
        case .setVolume:
            guard let value, value.isFinite, value >= 0 else {
                throw WireProtocolError.invalidCommand(
                    "media volume requires a finite nonnegative value")
            }
        case .playPause, .next, .previous:
            guard value == nil else {
                throw WireProtocolError.invalidCommand("media action does not accept a value")
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MediaDynamicCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys.isSubset(of: ["targetId", "action", "value"]),
            keys.contains("targetId"), keys.contains("action")
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "media request has missing or unexpected fields"))
        }
        targetID = try container.decode(String.self, forKey: MediaDynamicCodingKey("targetId"))
        action = try container.decode(MediaAction.self, forKey: MediaDynamicCodingKey("action"))
        value = try container.decodeIfPresent(Double.self, forKey: MediaDynamicCodingKey("value"))
    }
}

struct MediaDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
