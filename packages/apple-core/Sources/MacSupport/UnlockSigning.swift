import Foundation
import Security

public enum UnlockSigning {
    // The process code identity is immutable under the admitted runtime policy.
    // Cache its expensive validation; setup still verifies a fresh root-private
    // copy against this identity, and XPC validates peers on every connection.
    private static let runningRequirement: Result<String, UnlockFailure> = {
        do { return .success(try inspectRunningApp()) } catch { return .failure(.signature) }
    }()

    public static func designatedRequirement(of url: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
            let code,
            SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess,
            let requirement,
            SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess, let text
        else {
            throw UnlockFailure.signature
        }
        return text as String
    }
    public static func requirement(of url: URL, identifier: String) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
            let code,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
                == errSecSuccess
        else { throw UnlockFailure.signature }
        return try requirement(code, identifier: identifier)
    }

    public static func runningAppRequirement() throws -> String {
        try runningRequirement.get()
    }

    private static func inspectRunningApp() throws -> String {
        var running: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(), &running) == errSecSuccess, let running,
            SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
                == errSecSuccess,
            SecCodeCopyStaticCode(running, SecCSFlags(), &code) == errSecSuccess, let code
        else { throw UnlockFailure.signature }
        return try requirement(code, identifier: UnlockPaths.appIdentifier)
    }

    public static func verify(_ url: URL, requirement text: String) throws {
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard text.utf8.count <= 512,
            SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement)
                == errSecSuccess,
            let requirement,
            SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
            let code,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw UnlockFailure.signature }
    }

    private static func requirement(_ code: SecStaticCode, identifier: String) throws -> String {
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == identifier,
            let hash = values[kSecCodeInfoUnique as String] as? Data, hash.count == 20
        else { throw UnlockFailure.signature }
        if identifier == UnlockPaths.appIdentifier { try admitCompanion(values) }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and cdhash H\"\(hex)\""
    }

    static func admitCompanion(_ information: [String: Any]) throws {
        guard let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
            flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0
        else { throw UnlockFailure.signature }
        let entitlements =
            information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in [
            "com.apple.security.get-task-allow", "get-task-allow",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.disable-executable-page-protection",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-unsigned-executable-memory"
        ] {
            if let value = entitlements[key], value as? Bool != false {
                throw UnlockFailure.signature
            }
        }
    }
}
