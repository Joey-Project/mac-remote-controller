import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt
import UnlockNative

@MainActor
enum SessionDisplayNative {
    private typealias LockFunction = @convention(c) () -> Void
    // Keep the handle alive for the lifetime of the function pointer.
    private static let loginFramework = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY | RTLD_LOCAL
    )
    private static let lockFunction: LockFunction? = {
        guard let loginFramework, let symbol = dlsym(loginFramework, "SACLockScreenImmediate")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    static var supportsLock: Bool { lockFunction != nil }

    static var operations: SessionDisplayController.Operations {
        .init(
            snapshot: snapshot,
            lock: {
                guard let lockFunction else { throw SessionDisplayFailure.unavailable }
                lockFunction()
            },
            turnOff: {
                // A fixed OS command, with no shell or remotely supplied arguments.
                let operation = Task.detached {
                    try Task.checkCancellation()
                    return try UnlockSystemCommand.run(
                        "/usr/bin/pmset", arguments: ["displaysleepnow"], seconds: 2,
                        maximumBytes: 4096)
                }
                let result = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await operation.value
                } onCancel: {
                    operation.cancel()
                }
                guard result.status == 0 else { throw SessionDisplayFailure.displayUnconfirmed }
            },
            wake: wake,
            preventIdleSleep: preventIdleSleep,
            now: { SRContinuousTime() },
            pause: { try await Task.sleep(for: .milliseconds(50)) })
    }

    private static func snapshot() -> SessionDisplaySnapshot {
        let console = SRReadConsole()
        let eligible = console.known && console.loggedIn && console.userID == getuid()
        let session = withUnsafeBytes(of: console.sessionUUID) {
            String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        let boot = withUnsafeBytes(of: console.bootUUID) {
            String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        return SessionDisplaySnapshot(
            identity: eligible && !session.isEmpty && !boot.isEmpty
                ? "\(console.userID):\(session):\(boot)" : nil,
            locked: eligible ? console.locked : nil,
            displayAsleep: displayAsleep())
    }

    private static func displayAsleep() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, (1...64).contains(count) else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success, count > 0 else {
            return nil
        }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    private static func wake() throws -> () -> Void {
        var assertion = IOPMAssertionID(kIOPMNullAssertionID)
        guard
            IOPMAssertionDeclareUserActivity(
                "Sofa Remote wake display" as CFString, kIOPMUserActiveLocal, &assertion)
                == kIOReturnSuccess
        else { throw SessionDisplayFailure.displayUnconfirmed }
        return { _ = IOPMAssertionRelease(assertion) }
    }

    private static func preventIdleSleep() throws -> () -> Void {
        var assertion = IOPMAssertionID(kIOPMNullAssertionID)
        guard
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Sofa Remote display off" as CFString,
                &assertion) == kIOReturnSuccess
        else { throw SessionDisplayFailure.unavailable }
        return { _ = IOPMAssertionRelease(assertion) }
    }
}
