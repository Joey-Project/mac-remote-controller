import Foundation

/// Constructed only after admitting the root-private incoming companion's signature.
struct UnlockUpdateIdentity {
    let uid: UInt32
    let requirement: String
    let certificateSHA256: String?
}

/// Persistent consent only; transactions, grants and runtime files never cross an update.
struct UnlockUpdateConsent {
    let wasEnabled: Bool
    let allowedDeviceIDs: [String]

    init?(
        previous: UnlockInstallationRecord, settings: UnlockSettings,
        incoming: UnlockUpdateIdentity
    ) {
        guard previous.phase == "installed", previous.clientUID == incoming.uid else { return nil }
        let continuous: Bool
        if let old = previous.clientCertificateSHA256 {
            continuous =
                UnlockInstallationRecord.validCertificateHash(old)
                && old == incoming.certificateSHA256
        } else {
            // A legacy/ad-hoc receipt can prove only an exact code identity.
            continuous = previous.clientRequirement == incoming.requirement
        }
        // A stored certificate pin cannot be weakened by a matching code hash.
        guard continuous else { return nil }
        wasEnabled = settings.enabled
        allowedDeviceIDs = settings.allowedDeviceIDs
    }

    var settingsForInstallation: UnlockSettings {
        var result = UnlockSettings()
        result.allowedDeviceIDs = allowedDeviceIDs
        // The admitted new helper restores the switch after clearing old authority.
        return result
    }
}

/// The caller holds the root state lock across clearing, persistence and enablement.
enum UnlockConsentStartup {
    static func prepare(
        record: UnlockInstallationRecord, clearAuthority: () throws -> Void,
        persist: (UnlockInstallationRecord) throws -> Void, enable: () throws -> Void
    ) throws {
        try clearAuthority()
        guard record.resumeEnabledAfterUpdate == true else { return }
        var consumed = record
        consumed.resumeEnabledAfterUpdate = false
        // Persist before touching policy so interruption cannot replay enablement.
        try persist(consumed)
        try enable()
    }
}
