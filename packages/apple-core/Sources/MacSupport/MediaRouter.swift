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
        let sessionID: String
        let command: RoutedMediaCommand
        let continuation: CheckedContinuation<Void, Error>
    }

    public private(set) var targets: [String: MediaTarget] = [:]
    private var queue: [RoutedMediaCommand] = []
    private var pending: [String: Pending] = [:]
    private var targetLastSeen: [String: ContinuousClock.Instant] = [:]
    private let queueLimit: Int
    private let clock = ContinuousClock()

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
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = Pending(
                    sessionID: sessionID, command: command, continuation: continuation)
                queue.append(command)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.pending[requestID] != nil else { return }
                    self.finish(
                        requestID,
                        error: MediaRouteError.adapter("The media player did not respond."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(requestID, error: MediaRouteError.cancelled)
            }
        }
    }

    public func takeNext(for kind: MediaTargetKind) -> RoutedMediaCommand? {
        guard let index = queue.firstIndex(where: { targets[$0.targetID]?.kind == kind }) else {
            return nil
        }
        return queue.remove(at: index)
    }

    public func takeNext(targetID: String) -> RoutedMediaCommand? {
        guard let index = queue.firstIndex(where: { $0.targetID == targetID }) else { return nil }
        return queue.remove(at: index)
    }

    @discardableResult
    public func complete(
        requestID: String,
        targetID: String,
        errorMessage: String? = nil
    ) -> Bool {
        guard let item = pending[requestID], item.command.targetID == targetID else { return false }
        finish(requestID, error: errorMessage.map(MediaRouteError.adapter))
        return true
    }

    public func cancel(sessionID: String) {
        let requestIDs = pending.values.filter { $0.sessionID == sessionID }.map {
            $0.command.requestID
        }
        for requestID in requestIDs { finish(requestID, error: MediaRouteError.cancelled) }
    }

    private func finish(_ requestID: String, error: Error?) {
        guard let item = pending.removeValue(forKey: requestID) else { return }
        queue.removeAll { $0.requestID == requestID }
        if let error {
            item.continuation.resume(throwing: error)
        } else {
            item.continuation.resume()
        }
    }
}
