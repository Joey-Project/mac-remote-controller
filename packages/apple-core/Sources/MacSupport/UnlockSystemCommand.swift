import Darwin
import Foundation

public struct UnlockCommandResult: Sendable {
    public let status: Int32
    public let output: Data
}

/// Used locally for fixed installer commands, never exported over XPC or the network.
public enum UnlockSystemCommand {
    public static func run(
        _ executable: String, arguments: [String], seconds: TimeInterval,
        maximumBytes: Int = 524_288, environment: [String: String]? = nil
    ) throws -> UnlockCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment =
            environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        try process.run()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= maximumBytes else { throw UnlockFailure.unavailable }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw UnlockFailure.unavailable
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw UnlockFailure.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw UnlockFailure.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return UnlockCommandResult(status: process.terminationStatus, output: output)
    }

    public static func bootstrap() throws {
        let result = try run(
            "/bin/launchctl", arguments: ["bootstrap", "system", UnlockPaths.daemon.path],
            seconds: 15)
        guard result.status == 0 else { throw UnlockFailure.unavailable }
    }

    public static func bootout() throws {
        let result = try run(
            "/bin/launchctl", arguments: ["bootout", "system/" + UnlockPaths.service], seconds: 15)
        if result.status != 0 {
            let check = try run(
                "/bin/launchctl", arguments: ["print", "system/" + UnlockPaths.service], seconds: 5)
            let text = String(bytes: check.output, encoding: .utf8) ?? ""
            guard check.status != 0,
                text.contains("Could not find service \"\(UnlockPaths.service)\"")
            else {
                throw UnlockFailure.unavailable
            }
        }
    }
}
