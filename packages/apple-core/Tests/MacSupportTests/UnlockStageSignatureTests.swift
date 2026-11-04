import Foundation
import XCTest
@testable import MacSupport

final class UnlockStageSignatureTests: XCTestCase {
    func testUniversalBundleWithDistinctNestedIdentityPassesActualValidationCommands() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(try validate(fixture).status, 0)
    }

    func testWrongMainHashAndResignedNestedReplacementAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrong =
            "identifier \"\(UnlockPaths.appIdentifier)\" and cdhash H\"\(String(repeating: "0", count: 40))\""
        XCTAssertNotEqual(try validate(fixture, requirement: wrong).status, 0)
        let replacement = fixture.root.appendingPathComponent("replacement")
        try compile(returning: 7, to: replacement)
        try sign(replacement, identifier: UnlockPaths.helperIdentifier)
        try UnlockFiles.write(Data(contentsOf: replacement), to: fixture.helper, mode: 0o755)
        _ = try UnlockSigning.requirement(
            of: fixture.helper, identifier: UnlockPaths.helperIdentifier)
        XCTAssertNotEqual(try validate(fixture).status, 0)
    }

    func testAncestorLinkIsRejectedButMetadataOnlyChangePreservesValidation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 42)],
            ofItemAtPath: fixture.helper.path)
        XCTAssertEqual(try validate(fixture).status, 0)
        let helpers = fixture.helper.deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("outside-helpers")
        try FileManager.default.moveItem(at: helpers, to: outside)
        try FileManager.default.createSymbolicLink(at: helpers, withDestinationURL: outside)
        XCTAssertNotEqual(try validate(fixture).status, 0)
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let helper: URL
        let requirement: String
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SofaStage-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Sofa Remote's.app")
        let contents = app.appendingPathComponent("Contents")
        for name in ["MacOS", "Helpers", "Resources"] {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent(name),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let main = contents.appendingPathComponent("MacOS/Fixture")
        try compile(returning: 0, to: main)
        let helper = contents.appendingPathComponent("Helpers/Helper")
        try FileManager.default.copyItem(at: main, to: helper)
        try sign(helper, identifier: UnlockPaths.helperIdentifier)
        let info = [
            "CFBundleIdentifier": UnlockPaths.appIdentifier, "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Fixture", "CFBundleVersion": "1"
        ]
        try UnlockFiles.write(
            UnlockPolicy.data(info), to: contents.appendingPathComponent("Info.plist"))
        try UnlockFiles.write(
            Data("fixture".utf8), to: contents.appendingPathComponent("Resources/Fixture.txt"))
        try sign(app, identifier: UnlockPaths.appIdentifier, runtime: true)
        return try Fixture(
            root: root, app: app, helper: helper,
            requirement: UnlockSigning.requirement(of: app, identifier: UnlockPaths.appIdentifier))
    }

    private func compile(returning value: Int, to output: URL) throws {
        let source = output.deletingLastPathComponent().appendingPathComponent(
            "fixture-\(UUID().uuidString).c")
        try UnlockFiles.write(Data("int main(void) { return \(value); }\n".utf8), to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try UnlockSystemCommand.run(
            "/usr/bin/xcrun",
            arguments: [
                "clang", "-arch", "arm64",
                "-arch", "x86_64", "-mmacosx-version-min=14.0", source.path, "-o", output.path
            ],
            seconds: 30, environment: environment)
        guard result.status == 0 else { throw UnlockFailure.unavailable }
    }

    private func sign(_ url: URL, identifier: String, runtime: Bool = false) throws {
        var arguments = ["--force", "--sign", "-", "--timestamp=none", "--identifier", identifier]
        if runtime { arguments += ["--options", "runtime"] }
        let result = try UnlockSystemCommand.run(
            "/usr/bin/codesign", arguments: arguments + [url.path],
            seconds: 10, environment: environment)
        guard result.status == 0 else { throw UnlockFailure.signature }
    }

    private func validate(_ fixture: Fixture, requirement: String? = nil) throws
        -> UnlockCommandResult
    {
        let script = try UnlockSetupCommand.validationScript(
            app: fixture.app,
            clientRequirement: requirement ?? fixture.requirement)
        return try UnlockSystemCommand.run(
            "/bin/sh", arguments: ["-c", "set -eu\n" + script],
            seconds: 20, environment: environment)
    }

    private var environment: [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            result["DEVELOPER_DIR"] = developer
        }
        return result
    }
}
