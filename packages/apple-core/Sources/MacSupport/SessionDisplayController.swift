import AppleCore
import Foundation

public enum SessionDisplayFailure: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case sessionChanged
    case busy
    case lockUnconfirmed
    case displayUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This Mac's native session or display control is unavailable."
        case .sessionChanged: "The active Mac login session changed or could not be verified."
        case .busy: "Another lock, unlock or display request is already in progress."
        case .lockUnconfirmed: "The Mac did not confirm that its session was locked."
        case .displayUnconfirmed: "The Mac did not confirm the requested display state."
        }
    }
}

struct SessionDisplaySnapshot {
    var identity: String?
    var locked: Bool?
    var displayAsleep: Bool?
}

/// Executes each native action once and confirms its effect independently.
@MainActor
public final class SessionDisplayController {
    struct Operations {
        var snapshot: () -> SessionDisplaySnapshot
        var lock: () throws -> Void
        var turnOff: () async throws -> Void
        var wake: () throws -> () -> Void
        var preventIdleSleep: () throws -> () -> Void
        var now: () -> TimeInterval
        var pause: () async throws -> Void
    }

    private let operations: Operations
    private var releaseIdleSleep: (() -> Void)?
    public private(set) var isBusy = false
    public let supportsLock: Bool

    public convenience init() {
        self.init(
            operations: SessionDisplayNative.operations,
            supportsLock: SessionDisplayNative.supportsLock)
    }

    init(operations: Operations, supportsLock: Bool = true) {
        self.operations = operations
        self.supportsLock = supportsLock
    }

    public var displayAsleep: Bool? { operations.snapshot().displayAsleep }
    public var sessionLocked: Bool? { operations.snapshot().locked }

    /// Called by the companion's existing one-second state refresh, not an input timer.
    @discardableResult
    public func refresh() -> Bool? {
        let asleep = displayAsleep
        if !isBusy, asleep == false { endRemoteControl() }
        return asleep
    }

    public func endRemoteControl() {
        releaseIdleSleep?()
        releaseIdleSleep = nil
    }

    public func execute(_ command: CommandName) async throws {
        guard SessionControlPolicy.isControl(command) else {
            throw SessionDisplayFailure.unavailable
        }
        guard !isBusy else { throw SessionDisplayFailure.busy }
        guard let identity = operations.snapshot().identity else {
            throw SessionDisplayFailure.sessionChanged
        }
        isBusy = true
        defer { isBusy = false }
        try validate(identity)
        switch command {
        case .sessionLock:
            try await lock(identity)
        case .displayOff:
            try await turnOff(identity)
        case .displayWake:
            let releaseWake = try operations.wake()
            defer { releaseWake() }
            try await confirm(identity, failure: .displayUnconfirmed) { $0.displayAsleep == false }
            endRemoteControl()
        case .sessionLockAndDisplayOff:
            try await lock(identity)
            try await turnOff(identity)
        default:
            throw SessionDisplayFailure.unavailable
        }
    }

    private func lock(_ identity: String) async throws {
        let snapshot = try validate(identity)
        guard let locked = snapshot.locked else {
            throw SessionDisplayFailure.unavailable
        }
        if locked { return }
        guard supportsLock else { throw SessionDisplayFailure.unavailable }
        try operations.lock()
        try await confirm(identity, failure: .lockUnconfirmed) { $0.locked == true }
    }

    private func turnOff(_ identity: String) async throws {
        let snapshot = try validate(identity)
        guard snapshot.displayAsleep != nil else {
            throw SessionDisplayFailure.unavailable
        }
        if releaseIdleSleep == nil { releaseIdleSleep = try operations.preventIdleSleep() }
        do {
            if snapshot.displayAsleep != true { try await operations.turnOff() }
            try await confirm(identity, failure: .displayUnconfirmed) { $0.displayAsleep == true }
        } catch {
            endRemoteControl()
            throw error
        }
    }

    @discardableResult
    private func validate(_ identity: String) throws -> SessionDisplaySnapshot {
        try Task.checkCancellation()
        let snapshot = operations.snapshot()
        guard snapshot.identity == identity else {
            throw SessionDisplayFailure.sessionChanged
        }
        return snapshot
    }

    private func confirm(
        _ identity: String, failure: SessionDisplayFailure,
        matches: (SessionDisplaySnapshot) -> Bool
    ) async throws {
        let deadline = operations.now() + 2
        while true {
            let snapshot = try validate(identity)
            guard operations.now() < deadline else { throw failure }
            if matches(snapshot) { return }
            try await operations.pause()
        }
    }
}
