import CryptoKit
import Darwin
import Foundation

public enum UnlockFiles {
    public static func read(_ url: URL, owner: uid_t, mode: mode_t? = nil, maximum: Int = 262_144)
        throws -> Data
    {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw UnlockFailure.unsafeFile }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == owner, before.st_nlink == 1, before.st_mode & 0o022 == 0,
            mode == nil || before.st_mode & 0o7777 == mode,
            before.st_size >= 0, before.st_size <= maximum
        else { throw UnlockFailure.unsafeFile }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_uid == after.st_uid, before.st_mode == after.st_mode,
            before.st_size == after.st_size, bytes.count == before.st_size
        else { throw UnlockFailure.unsafeFile }
        return bytes
    }

    public static func ensureDirectory(_ url: URL, owner: uid_t, mode: mode_t) throws {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            guard errno == ENOENT, mkdir(url.path, mode) == 0 else {
                throw UnlockFailure.unsafeFile
            }
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw UnlockFailure.unsafeFile }
            defer { close(descriptor) }
            var created = stat()
            guard fstat(descriptor, &created) == 0, created.st_uid == owner,
                fchmod(descriptor, mode) == 0
            else { throw UnlockFailure.unsafeFile }
            guard lstat(url.path, &value) == 0 else { throw UnlockFailure.unsafeFile }
            guard value.st_dev == created.st_dev, value.st_ino == created.st_ino else {
                throw UnlockFailure.unsafeFile
            }
        }
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == owner,
            value.st_mode & 0o7777 == mode
        else { throw UnlockFailure.unsafeFile }
    }

    public static func write(_ bytes: Data, to url: URL, mode: mode_t = 0o600) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".write-\(UUID().uuidString)")
        let descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw UnlockFailure.unsafeFile }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: bytes)
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0,
            rename(temporary.path, url.path) == 0
        else {
            throw UnlockFailure.unsafeFile
        }
    }

    public static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func withStateLock<T>(_ operation: () throws -> T) throws -> T {
        try ensureDirectory(UnlockPaths.directory, owner: 0, mode: 0o700)
        var expected = stat()
        guard lstat(UnlockPaths.directory.path, &expected) == 0 else {
            throw UnlockFailure.unsafeFile
        }
        let descriptor = open(
            UnlockPaths.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UnlockFailure.unsafeFile }
        defer { close(descriptor) }
        var opened = stat()
        // Bind the lock to the admitted directory and its access policy. Child
        // creation changes timestamps and is deliberately not a failure signal.
        guard fstat(descriptor, &opened) == 0, opened.st_dev == expected.st_dev,
            opened.st_ino == expected.st_ino, opened.st_mode & S_IFMT == S_IFDIR,
            opened.st_uid == 0, opened.st_mode & 0o7777 == 0o700
        else { throw UnlockFailure.unsafeFile }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw UnlockFailure.busy }
        return try operation()
    }
}
