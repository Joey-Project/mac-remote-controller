import AppleCore
import Foundation

public enum MediaRouteError: Error, LocalizedError, Equatable {
    case targetUnavailable
    case actionUnavailable
    case queueFull
    case cancelled
    case adapter(String)

    public var errorDescription: String? {
        switch self {
        case .targetUnavailable: "The selected media source is no longer available."
        case .actionUnavailable: "This media source does not support that action."
        case .queueFull: "The selected media source is busy. Try again."
        case .cancelled: "The media request was cancelled because its connection closed."
        case let .adapter(message): message
        }
    }
}

enum MediaRouteResultDisposition: Equatable {
    case completed
    case retired
}

public struct RoutedMediaCommand: Codable, Sendable, Equatable {
    public let requestID: String
    public let targetID: String
    public let action: MediaAction
    public let value: Double?

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case targetID = "targetId"
        case action
        case value
    }

    public init(requestID: String, targetID: String, action: MediaAction, value: Double?) {
        self.requestID = requestID
        self.targetID = targetID
        self.action = action
        self.value = value
    }
}

@MainActor
public final class MediaRouter {
    private struct Pending {
        let identity: UUID
        let sessionID: String
        let command: RoutedMediaCommand
        let continuation: CheckedContinuation<Void, Error>
        var delivered = false
    }

    private struct RetiredResult {
        let targetID: String
        let expiresAt: ContinuousClock.Instant
    }

    public private(set) var targets: [String: MediaTarget] = [:]
    private var queue: [RoutedMediaCommand] = []
    private var pending: [String: Pending] = [:]
    private var targetLastSeen: [String: ContinuousClock.Instant] = [:]
    private var retiredResults: [String: RetiredResult] = [:]
    private var retiredResultOrder: [String] = []
    private let queueLimit: Int
    private let clock = ContinuousClock()
    private static let adapterResponseTimeout: Duration = .seconds(2)
    private static let retiredResultLifetime: Duration = .seconds(30)
    private static let maximumRetiredResults = 1_024

    public init(queueLimit: Int = 8) {
        self.queueLimit = max(1, queueLimit)
    }

    @discardableResult
    public func update(
        _ target: MediaTarget,
        at now: ContinuousClock.Instant = .now
    ) throws -> Bool {
        try target.validate()
        let validPrefix: String
        switch target.kind {
        case .iina: validPrefix = "iina:"
        case .youtube, .bilibili: validPrefix = "chrome:"
        }
        guard target.id.hasPrefix(validPrefix) else {
            throw WireProtocolError.invalidEnvelope("media target ID does not match its adapter")
        }
        guard targets[target.id] != nil || targets.count < WireLimits.maximumMediaTargets else {
            throw WireProtocolError.invalidEnvelope("too many media targets")
        }
        let changed = targets[target.id] != target
        targets[target.id] = target
        targetLastSeen[target.id] = now
        if changed {
            let invalidRequests = pending.values.filter { item in
                guard item.command.targetID == target.id else { return false }
                guard target.capabilities.supports(item.command.action) else { return true }
                if item.command.action == .setVolume,
                    let value = item.command.value,
                    let maximum = target.capabilities.playerVolumeMaximum
                {
                    return value > maximum
                }
                return false
            }.map { $0.command.requestID }
            for requestID in invalidRequests {
                finish(requestID, error: MediaRouteError.actionUnavailable)
            }
        }
        return changed
    }

    @discardableResult
    public func remove(targetID: String) -> Bool {
        let existed = targets.removeValue(forKey: targetID) != nil
        targetLastSeen.removeValue(forKey: targetID)
        queue.removeAll { $0.targetID == targetID }
        let requestIDs = pending.values.filter { $0.command.targetID == targetID }.map {
            $0.command.requestID
        }
        for requestID in requestIDs { finish(requestID, error: MediaRouteError.targetUnavailable) }
        return existed
    }

    public func expireStaleTargets(at now: ContinuousClock.Instant = .now) -> [String] {
        let stale = targets.values.compactMap { target -> String? in
            guard let lastSeen = targetLastSeen[target.id] else { return target.id }
            let allowedAge: Duration = target.kind == .iina ? .seconds(2) : .seconds(6)
            return now - lastSeen >= allowedAge ? target.id : nil
        }
        for targetID in stale { _ = remove(targetID: targetID) }
        return stale
    }

    public func execute(
        _ request: MediaRequest,
        requestID: String,
        sessionID: String
    ) async throws {
        try request.validate()
        purgeRetiredResults(at: clock.now)
        guard pending[requestID] == nil, retiredResults[requestID] == nil else {
            throw WireProtocolError.invalidCommand("duplicate media request ID")
        }
        guard let target = targets[request.targetID] else {
            throw MediaRouteError.targetUnavailable
        }
        guard target.capabilities.supports(request.action) else {
            throw MediaRouteError.actionUnavailable
        }
        if request.action == .setVolume,
            let maximum = target.capabilities.playerVolumeMaximum,
            let value = request.value, value > maximum
        {
            throw WireProtocolError.invalidCommand("volume exceeds the selected player's maximum")
        }
        guard pending.count < queueLimit else { throw MediaRouteError.queueFull }
        let command = RoutedMediaCommand(
            requestID: requestID, targetID: request.targetID, action: request.action,
            value: request.value)
        let pendingIdentity = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = Pending(
                    identity: pendingIdentity, sessionID: sessionID, command: command,
                    continuation: continuation)
                queue.append(command)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.adapterResponseTimeout)
                    guard let self, self.pending[requestID]?.identity == pendingIdentity else {
                        return
                    }
                    self.finish(
                        requestID,
                        expectedIdentity: pendingIdentity,
                        error: MediaRouteError.adapter("The media player did not respond."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(
                    requestID, expectedIdentity: pendingIdentity,
                    error: MediaRouteError.cancelled)
            }
        }
    }

    public func takeNext(for kind: MediaTargetKind) -> RoutedMediaCommand? {
        guard let index = queue.firstIndex(where: { targets[$0.targetID]?.kind == kind }) else {
            return nil
        }
        return takeNext(at: index)
    }

    public func takeNext(targetID: String) -> RoutedMediaCommand? {
        guard let index = queue.firstIndex(where: { $0.targetID == targetID }) else { return nil }
        return takeNext(at: index)
    }

    @discardableResult
    public func complete(
        requestID: String,
        targetID: String,
        errorMessage: String? = nil
    ) -> Bool {
        completeResult(
            requestID: requestID, targetID: targetID, errorMessage: errorMessage) == .completed
    }

    func completeResult(
        requestID: String,
        targetID: String,
        errorMessage: String? = nil
    ) -> MediaRouteResultDisposition? {
        purgeRetiredResults(at: clock.now)
        if let item = pending[requestID] {
            guard item.delivered, item.command.targetID == targetID else { return nil }
            finish(requestID, error: errorMessage.map(MediaRouteError.adapter))
            return .completed
        }
        guard retiredResults[requestID]?.targetID == targetID else { return nil }
        return .retired
    }

    public func cancel(sessionID: String) {
        let requestIDs = pending.values.filter { $0.sessionID == sessionID }.map {
            $0.command.requestID
        }
        for requestID in requestIDs { finish(requestID, error: MediaRouteError.cancelled) }
    }

    private func finish(
        _ requestID: String,
        expectedIdentity: UUID? = nil,
        error: Error?
    ) {
        guard let item = pending[requestID] else { return }
        if let expectedIdentity, item.identity != expectedIdentity { return }
        pending.removeValue(forKey: requestID)
        queue.removeAll { $0.requestID == requestID }
        if item.delivered { retireResult(for: item, at: clock.now) }
        if let error {
            item.continuation.resume(throwing: error)
        } else {
            item.continuation.resume()
        }
    }

    private func takeNext(at index: Int) -> RoutedMediaCommand? {
        let command = queue.remove(at: index)
        guard var item = pending[command.requestID] else { return nil }
        item.delivered = true
        pending[command.requestID] = item
        return command
    }

    private func retireResult(for item: Pending, at now: ContinuousClock.Instant) {
        purgeRetiredResults(at: now)
        let requestID = item.command.requestID
        guard retiredResults[requestID] == nil else { return }
        while retiredResults.count >= Self.maximumRetiredResults,
            let oldest = retiredResultOrder.first
        {
            retiredResultOrder.removeFirst()
            retiredResults.removeValue(forKey: oldest)
        }
        retiredResults[requestID] = RetiredResult(
            targetID: item.command.targetID,
            expiresAt: now.advanced(by: Self.retiredResultLifetime))
        retiredResultOrder.append(requestID)
    }

    private func purgeRetiredResults(at now: ContinuousClock.Instant) {
        let expired = retiredResults.compactMap { requestID, result in
            result.expiresAt <= now ? requestID : nil
        }
        for requestID in expired { retiredResults.removeValue(forKey: requestID) }
        retiredResultOrder.removeAll { retiredResults[$0] == nil }
    }
}
