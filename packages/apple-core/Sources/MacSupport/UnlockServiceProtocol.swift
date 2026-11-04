import Foundation

public enum UnlockPaths {
    public static let service = "com.joeyteng.sofaremote.unlock"
    public static let appIdentifier = "com.joeyteng.sofaremote.mac"
    public static let helperIdentifier = "com.joeyteng.sofaremote.unlock.helper"
    public static let installerIdentifier = "com.joeyteng.sofaremote.unlock.installer"
    public static let pluginIdentifier = "com.joeyteng.sofaremote.unlock.runtime-plugin"
    public static let right = "com.joeyteng.sofaremote.unlock.runtime"
    public static let screenRight = "system.login.screensaver"
    public static let directory = URL(
        fileURLWithPath: "/private/var/db/com.joeyteng.sofaremote.unlock-runtime")
    public static let plugin = URL(
        fileURLWithPath: "/Library/Security/SecurityAgentPlugins/SofaRemoteUnlock.bundle")
    public static let daemonPlist = service + ".plist"
    public static let helper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/" + service)
    public static let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/" + daemonPlist)
    public static let publicStatus = URL(
        fileURLWithPath: "/Library/Preferences/" + service + ".plist")
}

@objc public protocol UnlockServiceProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum UnlockOperation: String, Codable, Sendable {
    case status, install, enable, disable, uninstall, allowDevice, denyDevice, begin, wait, cancel
}

public struct UnlockRequest: Codable, Sendable {
    public var operation: UnlockOperation
    public var deviceID: String?
    public var transactionID: String?

    public init(
        _ operation: UnlockOperation, deviceID: String? = nil, transactionID: String? = nil
    ) {
        self.operation = operation
        self.deviceID = deviceID
        self.transactionID = transactionID
    }

    public func validate() throws {
        if let deviceID, UUID(uuidString: deviceID) == nil { throw UnlockFailure.invalidRequest }
        if let transactionID, UUID(uuidString: transactionID) == nil {
            throw UnlockFailure.invalidRequest
        }
        switch operation {
        case .allowDevice, .denyDevice, .begin:
            guard deviceID != nil, transactionID == nil else { throw UnlockFailure.invalidRequest }
        case .wait, .cancel:
            guard deviceID == nil, transactionID != nil else { throw UnlockFailure.invalidRequest }
        default:
            guard deviceID == nil, transactionID == nil else { throw UnlockFailure.invalidRequest }
        }
    }
}

public struct UnlockResponse: Codable, Sendable {
    public var installed = false
    public var enabled = false
    public var allowedDeviceIDs: [String] = []
    public var locked: Bool?
    public var transactionID: String?
    public var outcome = "ready"
    public var failure: String?

    public init(failure: String? = nil) { self.failure = failure }
}

public enum UnlockFailure: String, Error, LocalizedError, Sendable {
    case invalidRequest, unavailable, busy, signature, unsafeFile, conflict
    case notInstalled, notEnabled, deviceDenied, consoleUnavailable, wrongUser, notLocked
    case grantRefused, triggerUnavailable, cancelled, timedOut, unknownOutcome, setupIncomplete,
        setupUnconfirmed
    case accessibilityRequired, passwordControlUnavailable, passwordFieldNotEmpty
    case passwordControlNotWritable, passwordControlClearFailed

    public var errorDescription: String? {
        switch self {
        case .setupUnconfirmed:
            "Setup could not be confirmed. Check the helper status before retrying."
        case .signature: "The helper or companion signing identity could not be verified."
        case .conflict:
            "The system authentication configuration changed. Existing settings were preserved."
        case .setupIncomplete: "Unlock setup is incomplete. Keep its files for recovery."
        case .notInstalled: "Install the unlock helper in the Mac companion."
        case .notEnabled: "Enable remote unlock in the Mac companion."
        case .deviceDenied: "Allow this paired device to unlock the Mac in the companion."
        case .notLocked: "This Mac is already unlocked."
        case .triggerUnavailable: "The Mac could not activate its native unlock control."
        case .accessibilityRequired:
            "Allow Accessibility in the Mac companion before using remote unlock."
        case .passwordControlUnavailable:
            "The Mac's native password control is unavailable. Show its password entry screen and try again."
        case .passwordFieldNotEmpty:
            "Clear any partially entered password on the Mac, then try again."
        case .passwordControlNotWritable, .passwordControlClearFailed:
            "The Mac could not clear its native password control. Unlock normally and try again."
        case .cancelled: "The unlock request was cancelled."
        case .timedOut, .unknownOutcome: "Unlock was not confirmed. The request was not retried."
        case .busy: "Another unlock or setup operation is in progress."
        case .wrongUser, .consoleUnavailable: "A supported logged-in Mac session is unavailable."
        default: "The unlock helper could not complete this operation."
        }
    }
}
