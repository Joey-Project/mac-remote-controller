import Foundation
import Testing
@testable import WebRemoteSupport

@Test func runtimeConfigurationDistinguishesMissingAndInsecureStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: WebConfigurationError.notConfigured) {
        try WebRuntimeConfiguration.load(in: root)
    }
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    #expect(throws: WebConfigurationError.unavailable) {
        try WebRuntimeConfiguration.load(in: root)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    #expect(throws: WebConfigurationError.notConfigured) {
        try WebRuntimeConfiguration.load(in: root)
    }
}

@Test func runtimeConfigurationRoundTripsWithoutEmbeddingCredentials() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = try WebEndpoint(
        hostname: "remote.example.com", port: 47_625, bindAddress: "192.168.1.10",
        certificateChain: "/cert.pem", privateKey: "/key.pem")
    let configuration = WebRuntimeConfiguration(
        schemaVersion: 1, enabled: false, endpoint: endpoint, dns: nil, interfaceName: nil)
    try configuration.store(in: root)
    let restored = try WebRuntimeConfiguration.load(in: root)
    #expect(restored.endpoint == endpoint)
    #expect(!restored.enabled)
    let data = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields["token"] == nil)
    #expect(fields["credentials"] == nil)
}

@Test func runtimeConfigurationRefusesUnsupportedVersionsAndRelativeKeyPaths() throws {
    let endpoint = try WebEndpoint(
        hostname: "remote.example.com", port: 47_625, bindAddress: "192.168.1.10",
        certificateChain: "/cert.pem", privateKey: "/key.pem")
    let configuration = WebRuntimeConfiguration(
        schemaVersion: 2, enabled: false, endpoint: endpoint, dns: nil, interfaceName: nil)
    #expect(throws: WebConfigurationError.invalid) { try configuration.validate() }
    #expect(throws: WebEndpointError.invalidConfiguration) {
        try WebEndpoint(
            hostname: "remote.example.com", port: 47_625, bindAddress: "192.168.1.10",
            certificateChain: "cert.pem", privateKey: "key.pem")
    }
}
