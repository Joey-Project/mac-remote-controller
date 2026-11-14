import Foundation
import XCTest
@testable import MacSupport

final class UnlockUpdateConsentTests: XCTestCase {
    private let certificate = String(repeating: "a", count: 64)
    private let oldRequirement =
        "identifier \"com.joeyteng.sofaremote.mac\" and cdhash H\"0123456789abcdef0123456789abcdef01234567\""
    private let newRequirement =
        "identifier \"com.joeyteng.sofaremote.mac\" and cdhash H\"abcdef0123456789abcdef0123456789abcdef01\""

    func testSameCertificateUpdateRetainsTwoAllowedDevicesAndEnabledIntent() throws {
        let settings = settings(enabled: true)
        let consent = try XCTUnwrap(
            UnlockUpdateConsent(
                previous: record(certificate: certificate), settings: settings,
                incoming: identity(certificate: certificate)))
        XCTAssertTrue(consent.wasEnabled)
        XCTAssertEqual(consent.allowedDeviceIDs, settings.allowedDeviceIDs)
        XCTAssertFalse(consent.settingsForInstallation.enabled)
        XCTAssertEqual(consent.settingsForInstallation.allowedDeviceIDs, settings.allowedDeviceIDs)
        let bytes = try PropertyListEncoder().encode(consent.settingsForInstallation)
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["enabled", "allowedDeviceIDs"])
    }

    func testDisabledAndRevokedConsentIsNotRestored() throws {
        var current = settings(enabled: false)
        current.allowedDeviceIDs.removeLast()
        let consent = try XCTUnwrap(
            UnlockUpdateConsent(
                previous: record(certificate: certificate), settings: current,
                incoming: identity(certificate: certificate)))
        XCTAssertFalse(consent.wasEnabled)
        XCTAssertEqual(consent.allowedDeviceIDs, current.allowedDeviceIDs)
        current.allowedDeviceIDs = []
        XCTAssertEqual(
            UnlockUpdateConsent(
                previous: record(certificate: certificate), settings: current,
                incoming: identity(certificate: certificate))?.allowedDeviceIDs, [])
    }

    func testDifferentUserOrCertificateCannotInheritConsent() {
        let previous = record(certificate: certificate)
        for incoming in [
            identity(uid: 502, certificate: certificate),
            identity(certificate: String(repeating: "b", count: 64)),
            identity(certificate: nil),
            identity(requirement: oldRequirement, certificate: String(repeating: "b", count: 64)),
            identity(requirement: oldRequirement, certificate: nil)
        ] {
            XCTAssertNil(
                UnlockUpdateConsent(
                    previous: previous, settings: settings(enabled: true), incoming: incoming))
        }
    }

    func testLegacyAndAdHocRecordsRequireTheExactSameBinaryAndUser() throws {
        let previous = record(certificate: nil)
        XCTAssertNil(
            UnlockUpdateConsent(
                previous: previous, settings: settings(enabled: true),
                incoming: identity(certificate: certificate)))
        XCTAssertNotNil(
            UnlockUpdateConsent(
                previous: previous, settings: settings(enabled: true),
                incoming: identity(requirement: oldRequirement, certificate: nil)))
        XCTAssertNil(
            UnlockUpdateConsent(
                previous: previous, settings: settings(enabled: true),
                incoming: identity(uid: 502, requirement: oldRequirement, certificate: nil)))
    }

    func testIncompleteInstallAndInvalidCertificateCannotTransferConsent() {
        var previous = record(certificate: certificate)
        for phase in ["prepared", "enabling"] {
            previous.phase = phase
            XCTAssertNil(
                UnlockUpdateConsent(
                    previous: previous, settings: settings(enabled: true),
                    incoming: identity(certificate: certificate)))
        }
        previous = record(certificate: "invalid")
        XCTAssertNil(
            UnlockUpdateConsent(
                previous: previous, settings: settings(enabled: true),
                incoming: identity(certificate: "invalid")))
    }

    func testLegacyReceiptDecodesWithoutTheNewIdentityOrResumeFields() throws {
        let bytes = try PropertyListEncoder().encode(record(certificate: nil))
        let decoded = try PropertyListDecoder().decode(UnlockInstallationRecord.self, from: bytes)
        XCTAssertNil(decoded.clientCertificateSHA256)
        XCTAssertNil(decoded.resumeEnabledAfterUpdate)
        var updated = decoded
        updated.clientCertificateSHA256 = certificate
        updated.resumeEnabledAfterUpdate = true
        let next = try PropertyListDecoder().decode(
            UnlockInstallationRecord.self, from: PropertyListEncoder().encode(updated))
        XCTAssertEqual(next.clientCertificateSHA256, certificate)
        XCTAssertEqual(next.resumeEnabledAfterUpdate, true)
    }

    func testCertificateFingerprintValidationRejectsMalformedValues() {
        XCTAssertTrue(UnlockInstallationRecord.validCertificateHash(certificate))
        for invalid in [
            "", String(repeating: "a", count: 63), String(repeating: "A", count: 64),
            String(repeating: "z", count: 64)
        ] {
            XCTAssertFalse(UnlockInstallationRecord.validCertificateHash(invalid))
        }
    }

    func testStartupClearsAuthorityThenPersistsConsumptionBeforeRestoringOnce() throws {
        var stored = record(certificate: certificate)
        stored.resumeEnabledAfterUpdate = true
        var events: [String] = []
        try UnlockConsentStartup.prepare(
            record: stored, clearAuthority: { events.append("clear") },
            persist: {
                stored = $0; events.append("persist")
            },
            enable: {
                XCTAssertEqual(stored.resumeEnabledAfterUpdate, false)
                events.append("enable")
            })
        XCTAssertEqual(events, ["clear", "persist", "enable"])
        events = []
        try UnlockConsentStartup.prepare(
            record: stored, clearAuthority: { events.append("clear") },
            persist: { _ in XCTFail("Must not persist another resume intent") },
            enable: { XCTFail("Must not replay enablement") })
        XCTAssertEqual(events, ["clear"])
    }

    func testFailureToClearOrPersistNeverRestoresAuthority() {
        var stored = record(certificate: certificate)
        stored.resumeEnabledAfterUpdate = true
        XCTAssertThrowsError(
            try UnlockConsentStartup.prepare(
                record: stored, clearAuthority: { throw InjectedFailure.failed },
                persist: { _ in XCTFail("Must not persist after clear failure") },
                enable: { XCTFail("Must not enable after clear failure") }))
        XCTAssertThrowsError(
            try UnlockConsentStartup.prepare(
                record: stored, clearAuthority: {}, persist: { _ in throw InjectedFailure.failed },
                enable: { XCTFail("Must not enable without durable consumption") }))
    }

    func testEnablementFailureLeavesResumeIntentConsumed() throws {
        var stored = record(certificate: certificate)
        stored.resumeEnabledAfterUpdate = true
        XCTAssertThrowsError(
            try UnlockConsentStartup.prepare(
                record: stored, clearAuthority: {}, persist: { stored = $0 },
                enable: { throw InjectedFailure.failed }))
        XCTAssertEqual(stored.resumeEnabledAfterUpdate, false)
        try UnlockConsentStartup.prepare(
            record: stored, clearAuthority: {},
            persist: { _ in XCTFail("Consumed intent must stay consumed") },
            enable: { XCTFail("Failed restore must not replay on restart") })
    }

    private enum InjectedFailure: Error { case failed }

    private func record(certificate: String?) -> UnlockInstallationRecord {
        var result = UnlockInstallationRecord(
            clientUID: 501, clientRequirement: oldRequirement,
            helperRequirement: "helper", helperHash: "hash", pluginHashes: [:],
            daemonHash: "daemon", originalPolicy: Data())
        result.phase = "installed"
        result.clientCertificateSHA256 = certificate
        return result
    }

    private func settings(enabled: Bool) -> UnlockSettings {
        var result = UnlockSettings()
        result.enabled = enabled
        result.allowedDeviceIDs = [UUID().uuidString, UUID().uuidString]
        return result
    }

    private func identity(
        uid: UInt32 = 501, requirement: String? = nil, certificate: String?
    ) -> UnlockUpdateIdentity {
        UnlockUpdateIdentity(
            uid: uid, requirement: requirement ?? newRequirement, certificateSHA256: certificate)
    }
}
