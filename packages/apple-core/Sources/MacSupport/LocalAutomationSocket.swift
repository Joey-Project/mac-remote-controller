#if os(macOS)
    import Darwin
    import Foundation

    public enum LocalAutomationFailure: String, Error, LocalizedError {
        case unsafeEndpoint, alreadyRunning, unavailable, invalidFrame, timedOut

        public var errorDescription: String? {
            switch self {
            case .unsafeEndpoint: "The local automation endpoint is not owner-private."
            case .alreadyRunning: "Another companion owns the local automation endpoint."
            case .unavailable: "Local automation is unavailable. Start the Mac companion."
            case .invalidFrame: "The local automation message is invalid or too large."
            case .timedOut: "The local automation request timed out; it was not retried."
            }
        }
    }

    enum LocalAutomationSocket {
        static var defaultURL: URL {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/SofaRemote/Automation/control.sock")
        }

        static func directory(_ url: URL, create: Bool) throws {
            let parent = url.deletingLastPathComponent()
            if create, !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            var info = stat()
            guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700
            else { throw LocalAutomationFailure.unsafeEndpoint }
        }

        static func identity(_ url: URL) throws -> stat {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600
            else { throw LocalAutomationFailure.unsafeEndpoint }
            return info
        }

        static func sameObject(_ first: stat, _ second: stat) -> Bool {
            // Object identity and access policy matter; timestamps do not.
            first.st_dev == second.st_dev && first.st_ino == second.st_ino
                && first.st_uid == second.st_uid && first.st_mode == second.st_mode
        }

        static func withAddress<T>(
            _ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
        ) throws -> T {
            var address = sockaddr_un()
            let bytes = Array(url.path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw LocalAutomationFailure.unsafeEndpoint
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
            }
            return try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }

        static func make() throws -> Int32 {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw LocalAutomationFailure.unavailable }
            var enabled: Int32 = 1
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                setsockopt(
                    descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                    socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                close(descriptor)
                throw LocalAutomationFailure.unavailable
            }
            return descriptor
        }

        static func requirePeer(_ descriptor: Int32) throws {
            var user = uid_t.max
            var group = gid_t.max
            guard getpeereid(descriptor, &user, &group) == 0, user == geteuid() else {
                throw LocalAutomationFailure.unsafeEndpoint
            }
        }

        static func wait(
            _ descriptor: Int32, event: Int16, deadline: ContinuousClock.Instant
        ) throws {
            while ContinuousClock.now < deadline {
                var item = pollfd(fd: descriptor, events: event, revents: 0)
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let milliseconds = max(
                    1,
                    min(
                        3000,
                        remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000))
                let result = poll(&item, 1, Int32(milliseconds))
                if result > 0, item.revents & event != 0 { return }
                if result < 0, errno == EINTR { continue }
                if result == 0 { break }
                throw LocalAutomationFailure.unavailable
            }
            throw LocalAutomationFailure.timedOut
        }

        static func readFrame(
            _ descriptor: Int32, limit: Int, deadline: ContinuousClock.Instant
        ) throws -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while data.count <= limit {
                try wait(descriptor, event: Int16(POLLIN), deadline: deadline)
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw LocalAutomationFailure.invalidFrame }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= limit else { throw LocalAutomationFailure.invalidFrame }
                if let newline = data.firstIndex(of: 10) {
                    guard newline == data.index(before: data.endIndex) else {
                        throw LocalAutomationFailure.invalidFrame
                    }
                    return data.prefix(upTo: newline)
                }
            }
            throw LocalAutomationFailure.invalidFrame
        }

        static func writeFrame(
            _ data: Data, to descriptor: Int32, deadline: ContinuousClock.Instant
        ) throws {
            guard data.count < 65536 else { throw LocalAutomationFailure.invalidFrame }
            let framed = data + Data([10])
            try framed.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else {
                    throw LocalAutomationFailure.invalidFrame
                }
                var offset = 0
                while offset < buffer.count {
                    try wait(descriptor, event: Int16(POLLOUT), deadline: deadline)
                    let count = Darwin.write(
                        descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    guard count > 0 else { throw LocalAutomationFailure.unavailable }
                    offset += count
                }
            }
        }

        static func connect(_ url: URL, deadline: ContinuousClock.Instant) throws -> Int32 {
            try directory(url, create: false)
            _ = try identity(url)
            let descriptor = try make()
            do {
                let result = try withAddress(url) { Darwin.connect(descriptor, $0, $1) }
                if result != 0 {
                    guard errno == EINPROGRESS else { throw LocalAutomationFailure.unavailable }
                    try wait(descriptor, event: Int16(POLLOUT), deadline: deadline)
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0,
                        error == 0
                    else { throw LocalAutomationFailure.unavailable }
                }
                try requirePeer(descriptor)
                return descriptor
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    public enum LocalAutomationClient {
        public static var socketURL: URL { LocalAutomationSocket.defaultURL }

        public static func send(
            _ request: LocalAutomationRequest, to url: URL = socketURL
        ) throws -> LocalAutomationResponse {
            guard request.isValid else { throw LocalAutomationFailure.invalidFrame }
            let encoded = try JSONEncoder().encode(request)
            guard encoded.count < 16384 else { throw LocalAutomationFailure.invalidFrame }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            let descriptor = try LocalAutomationSocket.connect(url, deadline: deadline)
            defer { close(descriptor) }
            try LocalAutomationSocket.writeFrame(
                encoded, to: descriptor, deadline: deadline)
            let data = try LocalAutomationSocket.readFrame(
                descriptor, limit: 65536, deadline: deadline)
            let response = try JSONDecoder().decode(LocalAutomationResponse.self, from: data)
            guard response.version == 1 else { throw LocalAutomationFailure.invalidFrame }
            return response
        }
    }
#endif
