import Foundation

@MainActor
public final class UnlockServiceClient {
    private var connection: NSXPCConnection?
    private var generation = UUID()
    private var pending: [UUID: UnlockRPCReply] = [:]

    public init() {}

    public func invalidate() {
        let previous = connection
        connection = nil
        generation = UUID()
        previous?.invalidate()
        let replies = pending.values
        pending.removeAll()
        for reply in replies { reply.finish(.failure(UnlockFailure.unavailable)) }
    }

    public func send(_ request: UnlockRequest, timeout: TimeInterval = 3) async throws
        -> UnlockResponse
    {
        try request.validate()
        if connection == nil { try connect() }
        guard let connection, pending.count < 8 else { throw UnlockFailure.busy }
        let data = try JSONEncoder().encode(request)
        let identifier = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = UnlockRPCReply(continuation)
            pending[identifier] = reply
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                    Task { @MainActor in
                        self?.complete(identifier, result: .failure(UnlockFailure.unavailable))
                    }
                } as? UnlockServiceProtocol
            guard let proxy else {
                complete(identifier, result: .failure(UnlockFailure.unavailable)); return
            }
            proxy.perform(data) { [weak self] bytes in
                Task { @MainActor in
                    do {
                        guard bytes.count <= 16_384 else { throw UnlockFailure.invalidRequest }
                        let response = try JSONDecoder().decode(UnlockResponse.self, from: bytes)
                        if let failure = response.failure {
                            throw UnlockFailure(rawValue: failure) ?? .unavailable
                        }
                        self?.complete(identifier, result: .success(response))
                    } catch { self?.complete(identifier, result: .failure(error)) }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.complete(identifier, result: .failure(UnlockFailure.timedOut))
            }
        }
    }

    private func connect() throws {
        let status = try UnlockPublicStatus.load()
        guard try UnlockSigning.runningAppRequirement() == status.clientRequirement else {
            throw UnlockFailure.signature
        }
        let connection = NSXPCConnection(machServiceName: UnlockPaths.service, options: .privileged)
        let identifier = UUID()
        generation = identifier
        connection.remoteObjectInterface = NSXPCInterface(with: UnlockServiceProtocol.self)
        connection.setCodeSigningRequirement(status.helperRequirement)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == identifier else { return }
                self.invalidate()
            }
        }
        self.connection = connection
        connection.activate()
    }

    private func complete(_ identifier: UUID, result: Result<UnlockResponse, Error>) {
        pending.removeValue(forKey: identifier)?.finish(result)
    }
}

@MainActor
private final class UnlockRPCReply {
    private var continuation: CheckedContinuation<UnlockResponse, Error>?
    init(_ continuation: CheckedContinuation<UnlockResponse, Error>) {
        self.continuation = continuation
    }
    func finish(_ result: Result<UnlockResponse, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
