import XCTest
@testable import MacSupport

final class MediaIntegrationInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var resources: URL!
    private var helper: URL!
    private let files = FileManager.default
    // Helper catalog joey-private-v3, bearer-a, active.
    private let fixtureToken = "codex_synth_v1_bearer_a"

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("SofaInstaller-\(UUID().uuidString)")
        home = root.appendingPathComponent("Home With Spaces")
        resources = root.appendingPathComponent("MediaAdapters")
        helper = root.appendingPathComponent("SofaRemoteNativeHost")
        for folder in [
            home!, resources.appendingPathComponent("SofaRemote.iinaplugin"),
            resources.appendingPathComponent("ChromeExtension")
        ] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for file in [
            "SofaRemote.iinaplugin/Info.json", "SofaRemote.iinaplugin/main.js",
            "SofaRemote.iinaplgz",
            "ChromeExtension/manifest.json", "ChromeExtension/content-script.js",
            "ChromeExtension/service-worker.js"
        ] {
            try Data("{}".utf8).write(to: resources.appendingPathComponent(file))
        }
        try Data("bundled helper".utf8).write(to: helper)
    }

    override func tearDownWithError() throws {
        try files.removeItem(at: root)
    }

    func testIINAConfigurationPreservesPreferencesAndOtherPluginsOnRepeat() throws {
        let preferenceFile = support.appendingPathComponent(
            "com.colliderli.iina/plugins/.preferences/\(MediaIntegrationInstaller.pluginID).plist")
        try files.createDirectory(
            at: preferenceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try PropertyListSerialization.data(
            fromPropertyList: ["custom": "keep"], format: .binary, options: 0)
        try existing.write(to: preferenceFile)
        let unrelated = support.appendingPathComponent("com.colliderli.iina/plugins/other.txt")
        try Data("untouched".utf8).write(to: unrelated)
        let config = MediaBridgeConfiguration(port: 47_623, token: fixtureToken)
        let installedPlugin = support.appendingPathComponent(
            "com.colliderli.iina/plugins/\(MediaIntegrationInstaller.pluginID).iinaplugin")
        try files.createDirectory(at: installedPlugin, withIntermediateDirectories: true)
        let installedEntry = installedPlugin.appendingPathComponent("main.js")
        try Data("installed version".utf8).write(to: installedEntry)
        let package = try installer.prepareIINA(configuration: config)
        XCTAssertEqual(package, try installer.prepareIINA(configuration: config))

        let preferences = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: preferenceFile), format: nil) as? [String: Any])
        XCTAssertEqual(preferences["custom"] as? String, "keep")
        XCTAssertEqual(preferences["bridge_port"] as? Int, 47_623)
        XCTAssertEqual(preferences["bridge_token"] as? String, fixtureToken)
        XCTAssertEqual(try permissions(preferenceFile), 0o600)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "untouched")
        XCTAssertEqual(
            try Data(contentsOf: installedEntry), Data("installed version".utf8))
        XCTAssertEqual(package.pathExtension, "iinaplgz")
        XCTAssertFalse(
            try String(contentsOf: package, encoding: .utf8).contains(fixtureToken))
    }

    func testFirstIINASetupPreparesPermissionFlowWithoutInstallingDisabledPlugin() throws {
        let package = try installer.prepareIINA(
            configuration: MediaBridgeConfiguration(port: 47_623, token: fixtureToken))
        XCTAssertTrue(files.fileExists(atPath: package.path))
        let plugin = support.appendingPathComponent(
            "com.colliderli.iina/plugins/\(MediaIntegrationInstaller.pluginID).iinaplugin")
        XCTAssertFalse(files.fileExists(atPath: plugin.path))
    }

    func testChromeInstallsStableHelperAndExactOriginWithoutChangingOtherHosts() throws {
        let hostRoot = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts")
        try files.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let unrelated = hostRoot.appendingPathComponent("other.json")
        try Data("other host".utf8).write(to: unrelated)
        let destination = try installer.installChrome()
        XCTAssertEqual(destination, try installer.installChrome())
        let manifestFile = hostRoot.appendingPathComponent(
            MediaIntegrationInstaller.nativeHostName + ".json")
        let data = try Data(contentsOf: manifestFile)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let executable = try XCTUnwrap(manifest["path"] as? String)
        XCTAssertEqual(
            manifest["allowed_origins"] as? [String],
            [
                "chrome-extension://\(MediaIntegrationInstaller.extensionID)/"
            ])
        XCTAssertEqual(manifest["name"] as? String, MediaIntegrationInstaller.nativeHostName)
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        XCTAssertTrue(executable.hasPrefix(support.path))
        XCTAssertEqual(try permissions(URL(fileURLWithPath: executable)), 0o755)
        XCTAssertEqual(try permissions(manifestFile), 0o600)
        XCTAssertFalse(try XCTUnwrap(String(bytes: data, encoding: .utf8)).contains(fixtureToken))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "other host")
    }

    func testInvalidIINAPreferencesAreNotOverwritten() throws {
        let preferenceFile = support.appendingPathComponent(
            "com.colliderli.iina/plugins/.preferences/\(MediaIntegrationInstaller.pluginID).plist")
        try files.createDirectory(
            at: preferenceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not a plist".utf8)
        try original.write(to: preferenceFile)
        XCTAssertThrowsError(
            try installer.prepareIINA(
                configuration:
                    MediaBridgeConfiguration(port: 47_623, token: fixtureToken)))
        XCTAssertEqual(try Data(contentsOf: preferenceFile), original)
    }

    func testLinkedDestinationsAreRejectedWithoutChangingTheirTargets() throws {
        let external = root.appendingPathComponent("outside")
        try files.createDirectory(at: external, withIntermediateDirectories: true)
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        try files.createSymbolicLink(
            at: support.appendingPathComponent("SofaRemote"), withDestinationURL: external)
        XCTAssertThrowsError(try installer.installChrome())
        XCTAssertEqual(try files.contentsOfDirectory(atPath: external.path), [])
    }

    private var support: URL { home.appendingPathComponent("Library/Application Support") }
    private var installer: MediaIntegrationInstaller {
        MediaIntegrationInstaller(home: home, resources: resources, helper: helper)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
            .intValue
    }
}
