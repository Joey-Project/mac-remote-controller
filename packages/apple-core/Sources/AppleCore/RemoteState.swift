import Foundation

public struct RemoteState: Codable, Sendable, Equatable {
    public var accessibilityGranted: Bool
    /// Nil is treated as false by clients for compatibility with older companions.
    public var supportsGestures: Bool?
    public var systemVolume: Double?
    public var systemVolumeReason: String?
    public var deviceName: String

    public init(
        accessibilityGranted: Bool, systemVolume: Double?, systemVolumeReason: String? = nil,
        deviceName: String, supportsGestures: Bool? = nil
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.supportsGestures = supportsGestures
        self.systemVolume = systemVolume
        self.systemVolumeReason = systemVolumeReason
        self.deviceName = deviceName
    }

    public func validate() throws {
        if let systemVolume, !systemVolume.isFinite || !(0...1).contains(systemVolume) {
            throw WireProtocolError.invalidEnvelope("systemVolume must be finite and within 0...1")
        }
        guard !deviceName.isEmpty, deviceName.utf8.count <= WireLimits.maximumDeviceNameBytes else {
            throw WireProtocolError.invalidEnvelope("deviceName is empty or too long")
        }
    }
}
