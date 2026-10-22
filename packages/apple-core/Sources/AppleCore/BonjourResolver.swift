import Foundation
import dnssd

public enum BonjourResolverError: Error, LocalizedError, Sendable {
    case invalidServiceName
    case resolveFailed(Int32)
    case dispatchQueueFailed(Int32)
    case serviceUnavailable(Int32)
    case timedOut
    case invalidHost

    public var errorDescription: String? {
        switch self {
        case .invalidServiceName:
            "The Bonjour service name is not a UUID."
        case .resolveFailed(let status):
            "Bonjour could not start service resolution (status \(status))."
        case .dispatchQueueFailed(let status):
            "Bonjour could not schedule service resolution (status \(status))."
        case .serviceUnavailable(let status):
            "The Bonjour service could not be resolved (status \(status))."
        case .timedOut:
            "The Bonjour service did not resolve within five seconds."
        case .invalidHost:
            "Bonjour returned an invalid service host."
        }
    }
}

@MainActor
public final class BonjourResolver {
    private static let serviceType = "_sofaremote._tcp"
    private static let serviceDomain = "local."
    private static let resolutionTimeout: TimeInterval = 5

    private var serviceRef: DNSServiceRef?
    private var callbackContext: ResolveContext?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: (@MainActor (Result<URL, Error>) -> Void)?

    public init() {}

    public func resolve(
        serviceName: String,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        cancel()
        guard UUID(uuidString: serviceName) != nil else {
            completion(.failure(BonjourResolverError.invalidServiceName))
            return
        }

        let requestID = UUID()
        let context = ResolveContext(resolver: self, requestID: requestID)
        self.callbackContext = context
        self.completion = completion

        let (resolveStatus, resolvedRef) = startResolution(
            serviceName: serviceName,
            context: context
        )

        guard resolveStatus == kDNSServiceErr_NoError, let resolvedRef else {
            finish(
                requestID: requestID,
                result: .failure(.resolveFailed(Int32(resolveStatus)))
            )
            return
        }

        serviceRef = resolvedRef
        let queueStatus = DNSServiceSetDispatchQueue(resolvedRef, DispatchQueue.main)
        guard queueStatus == kDNSServiceErr_NoError else {
            finish(
                requestID: requestID,
                result: .failure(.dispatchQueueFailed(Int32(queueStatus)))
            )
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finish(requestID: requestID, result: .failure(.timedOut))
            }
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.resolutionTimeout,
            execute: timeout
        )
    }

    private func startResolution(
        serviceName: String,
        context: ResolveContext
    ) -> (DNSServiceErrorType, DNSServiceRef?) {
        var resolvedRef: DNSServiceRef?
        let status = serviceName.withCString { serviceInstance in
            Self.serviceType.withCString { serviceType in
                Self.serviceDomain.withCString { serviceDomain in
                    DNSServiceResolve(
                        &resolvedRef,
                        0,
                        0,
                        serviceInstance,
                        serviceType,
                        serviceDomain,
                        bonjourResolveCallback,
                        Unmanaged.passUnretained(context).toOpaque()
                    )
                }
            }
        }
        return (status, resolvedRef)
    }

    public func cancel() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
        }
        serviceRef = nil
        callbackContext = nil
        completion = nil
    }

    isolated deinit {
        timeoutWorkItem?.cancel()
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
        }
    }

    nonisolated static func webSocketURL(host: String, port: UInt16) throws -> URL {
        guard !host.isEmpty,
            !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" })
        else {
            throw BonjourResolverError.invalidHost
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        guard let url = components.url, url.scheme == "wss", url.host != nil else {
            throw BonjourResolverError.invalidHost
        }
        return url
    }

    fileprivate func finish(requestID: UUID, result: Result<URL, BonjourResolverError>) {
        guard callbackContext?.requestID == requestID else { return }

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
        }
        serviceRef = nil
        callbackContext = nil

        let completion = self.completion
        self.completion = nil
        switch result {
        case .success(let url):
            completion?(.success(url))
        case .failure(let error):
            completion?(.failure(error))
        }
    }
}

private final class ResolveContext: @unchecked Sendable {
    weak var resolver: BonjourResolver?
    let requestID: UUID

    init(resolver: BonjourResolver, requestID: UUID) {
        self.resolver = resolver
        self.requestID = requestID
    }
}

// DNS-SD's C callback ABI requires the complete ten-parameter signature.
// swiftlint:disable:next function_parameter_count
private func bonjourResolveCallback(
    _ serviceRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullName: UnsafePointer<CChar>?,
    _ hostTarget: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ txtLength: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?,
    _ contextPointer: UnsafeMutableRawPointer?
) {
    guard let contextPointer else { return }

    let context = Unmanaged<ResolveContext>.fromOpaque(contextPointer).takeUnretainedValue()
    let result: Result<URL, BonjourResolverError>
    if errorCode != kDNSServiceErr_NoError {
        result = .failure(.serviceUnavailable(Int32(errorCode)))
    } else if let hostTarget {
        let host = String(cString: hostTarget)
        do {
            result = .success(
                try BonjourResolver.webSocketURL(host: host, port: UInt16(bigEndian: port)))
        } catch let error as BonjourResolverError {
            result = .failure(error)
        } catch {
            result = .failure(.invalidHost)
        }
    } else {
        result = .failure(.invalidHost)
    }

    Task { @MainActor in
        context.resolver?.finish(requestID: context.requestID, result: result)
    }
}
