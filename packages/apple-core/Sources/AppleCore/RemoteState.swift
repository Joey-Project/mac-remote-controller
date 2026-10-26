import Foundation

public struct RemoteState: Codable, Sendable, Equatable {
    public var accessibilityGranted: Bool
    /// Nil is treated as false by clients for compatibility with older companions.
    public var supportsGestures: Bool?
    public var systemVolume: Double?
    public var systemVolumeReason: String?
    public var deviceName: String
    public var capabilities: [String]?
    public var mediaTargets: [MediaTarget]?

    public init(
        accessibilityGranted: Bool, systemVolume: Double?, systemVolumeReason: String? = nil,
        deviceName: String, supportsGestures: Bool? = nil, capabilities: [String]? = nil,
        mediaTargets: [MediaTarget]? = nil
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.supportsGestures = supportsGestures
        self.systemVolume = systemVolume
        self.systemVolumeReason = systemVolumeReason
        self.deviceName = deviceName
        self.capabilities = capabilities
        self.mediaTargets = mediaTargets
    }

    public func validate() throws {
        if let systemVolume, !systemVolume.isFinite || !(0...1).contains(systemVolume) {
            throw WireProtocolError.invalidEnvelope("systemVolume must be finite and within 0...1")
        }
        guard !deviceName.isEmpty, deviceName.utf8.count <= WireLimits.maximumDeviceNameBytes else {
            throw WireProtocolError.invalidEnvelope("deviceName is empty or too long")
        }
        if let capabilities,
            capabilities.count > 16
                || capabilities.contains(where: { $0.isEmpty || $0.utf8.count > 64 })
        {
            throw WireProtocolError.invalidEnvelope("capabilities are empty or too large")
        }
        if let mediaTargets {
            guard mediaTargets.count <= WireLimits.maximumMediaTargets else {
                throw WireProtocolError.invalidEnvelope("too many media targets")
            }
            var targetIDs = Set<String>()
            for target in mediaTargets {
                try target.validate()
                guard targetIDs.insert(target.id).inserted else {
                    throw WireProtocolError.invalidEnvelope("duplicate media target ID")
                }
            }
        }
    }
}
