import Foundation

/// Stable semantic identifiers shared by the Mac UI and local automation.
public enum CompanionControl: String, CaseIterable, Codable, Sendable {
    case accessibilityRequest = "accessibility.request"
    case mediaEnabled = "media.enabled"
    case mediaSetupIINA = "media.setupIINA"
    case mediaSetupChrome = "media.setupChrome"
    case mediaManualExpanded = "media.manualExpanded"
    case mediaCopyToken = "media.copyToken"
    case unlockManage = "unlock.manage"
    case unlockUninstall = "unlock.uninstall"
    case unlockEnabled = "unlock.enabled"
    case deviceUnlock = "device.unlock"
    case deviceRemove = "device.remove"
    case recoveryChooseSetup = "recovery.chooseSetup"
    case recoveryReinstall = "recovery.reinstall"
    case webEnabled = "web.enabled"
    case webOpen = "web.open"
    case webCopyURL = "web.copyURL"
    case webOpenFolder = "web.openFolder"
    case webReload = "web.reload"
    case qrOpen = "pairing.qr.open"
    case qrClose = "pairing.qr.close"
    case qrCopy = "pairing.qr.copy"
    case numericCancel = "pairing.numeric.cancel"
    case numericCode = "pairing.mac.code"
    case webPairingCancel = "pairing.web.cancel"
    case webPairingCode = "pairing.web.code"
    case appQuit = "app.quit"
}

public struct LocalControlDescriptor: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case button, toggle, disclosure, value }
    public let id: CompanionControl
    public let label: String
    public let kind: Kind
    public var visible: Bool
    public var enabled: Bool
    public var value: String?
    public var deviceID: String?
    public var requiresSystemInteraction: Bool

    public init(
        _ id: CompanionControl, _ label: String, kind: Kind = .button,
        visible: Bool = true, enabled: Bool = true, value: String? = nil,
        deviceID: String? = nil, requiresSystemInteraction: Bool = false
    ) {
        self.id = id; self.label = label; self.kind = kind
        self.visible = visible; self.enabled = enabled; self.value = value
        self.deviceID = deviceID; self.requiresSystemInteraction = requiresSystemInteraction
    }
}

public struct LocalAutomationRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case status, list, get, invoke }
    public let version: Int
    public let operation: Operation
    public let control: CompanionControl?
    public let value: String?
    public let deviceID: String?
    public let path: String?

    public init(
        _ operation: Operation, control: CompanionControl? = nil, value: String? = nil,
        deviceID: String? = nil, path: String? = nil, version: Int = 1
    ) {
        self.version = version; self.operation = operation; self.control = control
        self.value = value; self.deviceID = deviceID; self.path = path
    }

    public var isValid: Bool {
        guard version == 1, value.map({ $0.utf8.count <= 32 }) ?? true,
            deviceID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
            path.map({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true
        else { return false }
        switch operation {
        case .status, .list:
            return control == nil && value == nil && deviceID == nil && path == nil
        case .get:
            return control != nil && value == nil && path == nil
        case .invoke:
            return control != nil
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        let allowed: Set<String> = ["version", "operation", "control", "value", "deviceID", "path"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct LocalAutomationResponse: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case success = "ok"
        case accepted, unavailable, invalidRequest, failed
    }
    public let version: Int
    public let outcome: Outcome
    public let message: String?
    public let controls: [LocalControlDescriptor]?
    public let values: [String: String]?

    public init(
        _ outcome: Outcome, message: String? = nil,
        controls: [LocalControlDescriptor]? = nil, values: [String: String]? = nil
    ) {
        version = 1; self.outcome = outcome; self.message = message
        self.controls = controls; self.values = values
    }
}
