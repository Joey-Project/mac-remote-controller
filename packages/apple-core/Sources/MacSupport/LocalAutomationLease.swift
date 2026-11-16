#if os(macOS)
    import Darwin
    import Foundation

    /// Cooperating app instances retain this lease through endpoint cleanup.
    /// The file is deliberately never unlinked, so every instance locks one inode.
    final class LocalAutomationLease {
        private let descriptor: Int32

        init(socketURL: URL) throws {
            let url = socketURL.appendingPathExtension("lock")
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LocalAutomationFailure.unsafeEndpoint }
            var info = stat()
            // This is a dedicated, unaliased, empty coordination file. These
            // structural/access-policy checks do not compare timestamps.
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
                info.st_nlink == 1, info.st_size == 0
            else {
                close(descriptor)
                throw LocalAutomationFailure.unsafeEndpoint
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let busy = errno == EWOULDBLOCK
                close(descriptor)
                throw busy ? LocalAutomationFailure.alreadyRunning : .unsafeEndpoint
            }
            self.descriptor = descriptor
        }

        deinit { close(descriptor) }
    }
#endif
