import Foundation

public struct NumericPairingMacIdentity: Sendable {
    public let serviceName: String
    public let name: String
    public let certificateSHA256: String

    public init(serviceName: String, name: String, certificateSHA256: String) {
        self.serviceName = serviceName
        self.name = name
        self.certificateSHA256 = certificateSHA256
    }
}

public struct NumericPairingRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let deviceName: String
    public let code: String
    public let expiresAt: Date
    public let remainingAttempts: Int
}

/// The enrollment state machine shared by the Mac and isolated Simulator tests.
/// Its callbacks cannot issue a credential before both proofs and finish verify.
@MainActor
public final class NumericPairingCoordinator {
    public var onSend: ((UUID, NumericPairingMessage) -> Void)?
    public var onClose: ((UUID) -> Void)?
    public var onChange: ((NumericPairingRequest?) -> Void)?
    public var onAuthorize: ((UUID, String) -> Void)?
    private let identity: NumericPairingMacIdentity
    private let isUnlocked: () -> Bool
    private let canPair: () -> Bool
    private let now: () -> TimeInterval
    private let makeCode: (String?) -> String
    private var lastCode: String?
    private var limiter = NumericPairingRequestLimiter()
    private var pending: Pending?

    private enum Stage {
        case hello, computingChallenge, proof, verifyingProof, finish, verifyingFinish
    }

    private final class Pending {
        let id: UUID
        let connection: UUID
        let name: String
        let code: String
        let expiresAt = Date().addingTimeInterval(120)
        let crypto: NumericPairingServerCrypto
        var budget: NumericPairingAttemptBudget
        var stage: Stage = .hello
        var attemptID: UUID?
        var task: Task<Void, Never>?

        init(packet: NumericPairingMessage, connection: UUID, code: String, now: TimeInterval)
            throws
        {
            id = packet.id
            self.connection = connection
            name = packet.name ?? ""
            self.code = code
            budget = NumericPairingAttemptBudget(startedAt: now)
            crypto = try NumericPairingServerCrypto(requestID: packet.id, code: code)
        }
    }

    public init(
        identity: NumericPairingMacIdentity, isUnlocked: @escaping () -> Bool,
        canPair: @escaping () -> Bool = { true },
        now: @escaping () -> TimeInterval = { NumericPairingClock.now() },
        makeCode: @escaping (String?) -> String = { NumericPairingCode.generate(excluding: $0) }
    ) {
        self.identity = identity
        self.isUnlocked = isUnlocked
        self.canPair = canPair
        self.now = now
        self.makeCode = makeCode
    }

    public func ownsConnection(_ connection: UUID) -> Bool { pending?.connection == connection }

    public func receive(_ packet: NumericPairingMessage, from connection: UUID) {
        do { try packet.validate() } catch { close(connection); return }
        if packet.phase == .request { request(packet, from: connection); return }
        guard let pending, pending.connection == connection, pending.id == packet.id else {
            close(connection); return
        }
        if packet.phase == .cancel { close(connection); return }
        guard isCurrentAndActive(pending) else { expireIfNeeded(); return }
        switch packet.phase {
        case .hello where pending.stage == .hello:
            guard limiter.mayAttempt(at: now()), let publicKey = packet.publicKey else {
                reject(pending, failure: .tooManyAttempts); return
            }
            challenge(publicKey, pending: pending)
        case .proof where pending.stage == .proof && pending.attemptID == packet.attemptID:
            verify(packet, pending: pending)
        case .finish where pending.stage == .finish && pending.attemptID == packet.attemptID:
            finish(packet, pending: pending)
        default: close(connection)
        }
    }

    public func tick() { expireIfNeeded() }

    public func disconnected(_ connection: UUID) {
        guard pending?.connection == connection else { return }
        clear()
    }

    public func cancel() {
        guard let pending else { return }
        reject(pending, failure: .cancelled)
    }

    private func request(_ packet: NumericPairingMessage, from connection: UUID) {
        guard packet.serviceName == identity.serviceName, isUnlocked(), canPair() else {
            sendRejection(packet.id, to: connection, failure: .unavailable); return
        }
        guard pending == nil else {
            if pending?.connection == connection {
                close(connection)
            } else {
                sendRejection(packet.id, to: connection, failure: .busy)
            }
            return
        }
        guard limiter.admitRequest(at: now()) else {
            sendRejection(packet.id, to: connection, failure: .tooManyAttempts); return
        }
        do {
            let code = makeCode(lastCode)
            let pending = try Pending(
                packet: packet, connection: connection, code: code, now: now())
            lastCode = code
            self.pending = pending
            publish(pending)
            guard self.pending === pending else { return }
            var ready = NumericPairingMessage(id: pending.id, phase: .ready)
            ready.serviceName = identity.serviceName
            ready.name = identity.name
            ready.expiresIn = pending.budget.expiresIn(at: now())
            ready.remainingAttempts = pending.budget.remainingAttempts
            onSend?(connection, ready)
        } catch { sendRejection(packet.id, to: connection, failure: .unavailable) }
    }

    private func challenge(_ publicKey: Data, pending: Pending) {
        pending.stage = .computingChallenge
        let attemptID = UUID()
        pending.attemptID = attemptID
        let context = NumericPairingContext(
            requestID: pending.id, attemptID: attemptID, serviceName: identity.serviceName,
            certificateSHA256: identity.certificateSHA256, deviceName: pending.name,
            macName: identity.name)
        pending.task = Task { [weak self, weak pending] in
            guard let self, let pending else { return }
            do {
                let challenge = try await pending.crypto.challenge(
                    clientPublicKey: publicKey, context: context)
                guard !Task.isCancelled, self.isCurrentAndActive(pending) else { return }
                pending.stage = .proof
                pending.task = nil
                var response = NumericPairingMessage(id: pending.id, phase: .challenge)
                response.attemptID = attemptID
                response.salt = challenge.salt
                response.publicKey = challenge.publicKey
                self.onSend?(pending.connection, response)
            } catch {
                guard self.pending === pending else { return }
                self.reject(pending, failure: .invalidHandshake)
            }
        }
    }

    private func verify(_ packet: NumericPairingMessage, pending: Pending) {
        guard let proof = packet.proof, let binding = packet.binding else { return }
        pending.stage = .verifyingProof
        pending.task = Task { [weak self, weak pending] in
            guard let self, let pending else { return }
            do {
                let response = try await pending.crypto.verify(
                    NumericPairingProof(proof: proof, binding: binding))
                guard !Task.isCancelled, self.isCurrentAndActive(pending) else { return }
                pending.stage = .finish
                pending.task = nil
                var accepted = NumericPairingMessage(id: pending.id, phase: .accepted)
                accepted.attemptID = pending.attemptID
                accepted.proof = response.proof
                accepted.binding = response.binding
                self.onSend?(pending.connection, accepted)
            } catch {
                guard self.pending === pending, !Task.isCancelled else { return }
                self.incorrect(pending)
            }
        }
    }

    private func finish(_ packet: NumericPairingMessage, pending: Pending) {
        guard let binding = packet.binding else { return }
        pending.stage = .verifyingFinish
        pending.task = Task { [weak self, weak pending] in
            guard let self, let pending else { return }
            do {
                try await pending.crypto.finish(binding)
                guard !Task.isCancelled, self.isCurrentAndActive(pending),
                    pending.budget.consume(at: self.now())
                else { return }
                let connection = pending.connection
                let name = pending.name
                pending.task = nil
                self.clear()
                self.onAuthorize?(connection, name)
            } catch {
                guard self.pending === pending else { return }
                self.reject(pending, failure: .invalidHandshake)
            }
        }
    }

    private func incorrect(_ pending: Pending) {
        pending.task = nil
        pending.budget.recordFailure(at: now())
        limiter.recordFailure(at: now())
        guard pending.budget.isActive(at: now()), limiter.mayAttempt(at: now()) else {
            reject(pending, failure: .tooManyAttempts); return
        }
        pending.stage = .hello
        pending.attemptID = nil
        publish(pending)
        guard self.pending === pending else { return }
        var retry = NumericPairingMessage(id: pending.id, phase: .retry)
        retry.expiresIn = pending.budget.expiresIn(at: now())
        retry.remainingAttempts = pending.budget.remainingAttempts
        onSend?(pending.connection, retry)
    }

    private func isCurrentAndActive(_ pending: Pending) -> Bool {
        self.pending === pending && pending.budget.isActive(at: now()) && isUnlocked() && canPair()
    }

    private func expireIfNeeded() {
        guard let pending else { return }
        if !pending.budget.isActive(at: now()) {
            reject(pending, failure: .expired)
        } else if !isUnlocked() || !canPair() {
            reject(pending, failure: .unavailable)
        }
    }

    private func publish(_ pending: Pending) {
        onChange?(
            NumericPairingRequest(
                id: pending.id, deviceName: pending.name, code: pending.code,
                expiresAt: pending.expiresAt, remainingAttempts: pending.budget.remainingAttempts))
    }

    private func clear() {
        let pending = self.pending
        self.pending = nil
        pending?.task?.cancel()
        if let crypto = pending?.crypto { Task { await crypto.cancel() } }
        onChange?(nil)
    }

    private func reject(_ pending: Pending, failure: NumericPairingFailure) {
        clear()
        sendRejection(pending.id, to: pending.connection, failure: failure)
    }

    private func sendRejection(_ id: UUID, to connection: UUID, failure: NumericPairingFailure) {
        var packet = NumericPairingMessage(id: id, phase: .rejected)
        packet.failure = failure
        onSend?(connection, packet)
    }

    private func close(_ connection: UUID) {
        disconnected(connection)
        onClose?(connection)
    }
}
