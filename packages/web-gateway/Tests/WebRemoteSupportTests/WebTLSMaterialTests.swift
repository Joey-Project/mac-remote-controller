import Foundation
import Testing
@testable import WebRemoteSupport

@Test func tlsFilePolicyAllowsCertbotSymlinksAndBenignMetadataChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("private-key")
    let contents = Data("ephemeral test file".utf8)
    try contents.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let live = root.appendingPathComponent("live-key")
    try FileManager.default.createSymbolicLink(at: live, withDestinationURL: file)
    #expect(try WebTLSMaterial.read(live.path, limit: 128, privateFile: true) == contents)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
    #expect(try WebTLSMaterial.read(live.path, limit: 128, privateFile: true) == contents)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) {
        try WebTLSMaterial.read(live.path, limit: 128, privateFile: true)
    }
}

@Test func tlsFilesRemainBoundedAndDistinguishMissingFromUnreadableTypes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("oversized")
    try Data(repeating: 1, count: 129).write(to: file)
    #expect(throws: (any Error).self) {
        try WebTLSMaterial.read(file.path, limit: 128, privateFile: false)
    }
    #expect(throws: (any Error).self) {
        try WebTLSMaterial.read(root.path, limit: 128, privateFile: false)
    }
    do {
        _ = try WebTLSMaterial.read(
            root.appendingPathComponent("missing").path, limit: 128,
            privateFile: false)
        Issue.record("A missing certificate was accepted")
    } catch WebTLSFileError.notFound {
        // Missing material is distinct from an insecure or unreadable existing file.
    }
}
