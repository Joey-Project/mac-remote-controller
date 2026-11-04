import Darwin
import Foundation

public enum UnlockPluginFiles {
    public static let names = [
        "Contents/Info.plist", "Contents/MacOS/SofaRemoteUnlock",
        "Contents/_CodeSignature/CodeResources"
    ]
    private static var tree: [String: Set<String>] {
        [
            "": ["Contents"], "Contents": ["Info.plist", "MacOS", "_CodeSignature"],
            "Contents/MacOS": ["SofaRemoteUnlock"], "Contents/_CodeSignature": ["CodeResources"]
        ]
    }

    public static func snapshot(_ bundle: URL, owner: uid_t) throws -> [String: Data] {
        for (name, expected) in tree {
            let directory = bundle.appendingPathComponent(name)
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == owner, info.st_mode & 0o022 == 0
            else { throw UnlockFailure.unsafeFile }
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard Set(entries) == expected else { throw UnlockFailure.conflict }
        }
        return try Dictionary(
            uniqueKeysWithValues: names.map { name in
                (
                    name,
                    try UnlockFiles.read(
                        bundle.appendingPathComponent(name), owner: owner, maximum: 8 * 1024 * 1024)
                )
            })
    }

    public static func stage(_ contents: [String: Data], at bundle: URL) throws {
        guard Set(contents.keys) == Set(names), !FileManager.default.fileExists(atPath: bundle.path)
        else {
            throw UnlockFailure.conflict
        }
        try FileManager.default.createDirectory(
            at: bundle, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        for name in ["Contents", "Contents/MacOS", "Contents/_CodeSignature"] {
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent(name), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755])
        }
        for name in names {
            guard let data = contents[name] else { throw UnlockFailure.signature }
            try UnlockFiles.write(
                data, to: bundle.appendingPathComponent(name),
                mode: name.contains("/MacOS/") ? 0o755 : 0o644)
        }
    }

    public static func remove(_ bundle: URL, expected: [String: String]) throws {
        let actual = try snapshot(bundle, owner: 0).mapValues(UnlockFiles.hash)
        guard actual == expected else { throw UnlockFailure.conflict }
        for name in names {
            try FileManager.default.removeItem(at: bundle.appendingPathComponent(name))
        }
        for name in ["Contents/MacOS", "Contents/_CodeSignature", "Contents", ""] {
            guard rmdir(bundle.appendingPathComponent(name).path) == 0 else {
                throw UnlockFailure.unsafeFile
            }
        }
    }
}
