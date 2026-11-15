import AppleCore
import Foundation

public struct WebPairingPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let deviceName: String
    public let code: String
    public let expiresAt: Date
    public let remainingAttempts: Int
}

/// Not Codable: the owner secret belongs only in a Secure, HttpOnly cookie.
public struct WebPairingStart {
    public let requestID: UUID
    public let ownerCookie: String
    public let expiresIn: Int
}

public enum WebPairingFailure: Error, Equatable {
    case unavailable
    case busy
    case expired
    case rateLimited
    case incorrectCode
    case codeChanged
    case randomFailure
}

/// HTTPS supplies server identity; the Mac-displayed PIN supplies local consent.
@MainActor
public final class WebPairingCoordinator {
    public var onChange: ((WebPairingPrompt?) -> Void)?
    public private(set) var prompt: WebPairingPrompt?
    private let isUnlocked: () -> Bool
    private let canPair: () -> Bool
    private let authorize: (String) throws -> String
    private let now: () -> TimeInterval
    private let makeCode: () -> String
    private var limiter = NumericPairingRequestLimiter()
    private var pending: Pending?

    private struct Pending {
        let id: UUID
        let owner: String
        let name: String
        let startedAt: TimeInterval
        let expiresAt: Date
        var code: String
        var budget: NumericPairingAttemptBudget
    }

    public init(
        isUnlocked: @escaping () -> Bool,
        canPair: @escaping () -> Bool,
        authorize: @escaping (String) throws -> String,
        now: @escaping () -> TimeInterval = NumericPairingClock.now,
        makeCode: @escaping () -> String = { String(format: "%04d", Int.random(in: 0..<10_000)) }
    ) {
        self.isUnlocked = isUnlocked
        self.canPair = canPair
        self.authorize = authorize
        self.now = now
        self.makeCode = makeCode
    }

    public func start(name: String, ownerCookie: String?) throws -> WebPairingStart {
        refresh()
        guard isUnlocked(), canPair() else { throw WebPairingFailure.unavailable }
        let time = now()
        if let pending {
            guard let ownerCookie, PairingSecurity.matches(pending.owner, ownerCookie) else {
                throw WebPairingFailure.busy
            }
            return WebPairingStart(
                requestID: pending.id, ownerCookie: pending.owner,
                expiresIn: pending.budget.expiresIn(at: time))
        }
        guard limiter.admitRequest(at: time) else { throw WebPairingFailure.rateLimited }
        let cleaned = String(
            String.UnicodeScalarView(
                name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let request = Pending(
            id: UUID(), owner: try PairingSecurity.randomToken(),
            name: DeviceName.bounded(cleaned, fallback: "Web browser"), startedAt: time,
            expiresAt: Date().addingTimeInterval(120), code: try nextCode(excluding: nil),
            budget: NumericPairingAttemptBudget(startedAt: time))
        pending = request
        publish()
        return WebPairingStart(requestID: request.id, ownerCookie: request.owner, expiresIn: 120)
    }

    public func confirm(id: UUID, ownerCookie: String?, code: String) throws -> String {
        refresh()
        guard isUnlocked(), canPair() else { throw WebPairingFailure.unavailable }
        guard var request = pending, request.id == id, let ownerCookie,
            PairingSecurity.matches(request.owner, ownerCookie)
        else { throw WebPairingFailure.expired }
        let time = now()
        guard limiter.mayAttempt(at: time) else { throw WebPairingFailure.rateLimited }
        guard request.budget.isActive(at: time) else { cancel(); throw WebPairingFailure.expired }
        guard validCode(code), PairingSecurity.matches(request.code, code) else {
            limiter.recordFailure(at: time)
            request.budget.recordFailure(at: time)
            if request.budget.remainingAttempts == 0 {
                request.code = try nextCode(excluding: request.code)
                request.budget = NumericPairingAttemptBudget(startedAt: request.startedAt)
                pending = request
                publish()
                throw WebPairingFailure.codeChanged
            }
            pending = request
            publish()
            throw WebPairingFailure.incorrectCode
        }
        guard request.budget.consume(at: time) else { throw WebPairingFailure.expired }
        // Consume before persistence: a failed/ambiguous response cannot reuse a PIN.
        cancel()
        do { return try authorize(request.name) } catch { throw WebPairingFailure.unavailable }
    }

    public func refresh() {
        guard let pending else { return }
        if !isUnlocked() || !pending.budget.isActive(at: now()) { cancel() }
    }

    public func cancel() {
        pending = nil
        prompt = nil
        onChange?(nil)
    }

    func cancel(ownerCookie: String?) {
        guard let pending, let ownerCookie, PairingSecurity.matches(pending.owner, ownerCookie)
        else { return }
        cancel()
    }

    private func publish() {
        guard let pending else { return }
        prompt = WebPairingPrompt(
            id: pending.id, deviceName: pending.name, code: pending.code,
            expiresAt: pending.expiresAt, remainingAttempts: pending.budget.remainingAttempts)
        onChange?(prompt)
    }

    private func nextCode(excluding previous: String?) throws -> String {
        for _ in 0..<8 {
            let code = makeCode()
            if validCode(code), code != previous { return code }
        }
        throw WebPairingFailure.randomFailure
    }

    private func validCode(_ code: String) -> Bool {
        code.utf8.count == 4 && code.utf8.allSatisfy { (48...57).contains($0) }
    }
}
