import Foundation

/// Retry explicit denials and reconstruct orphaned permissions after a restart.
public struct UnlockDeviceRevocations {
    public private(set) var pending: Set<String> = []
    public var next: String? { pending.sorted().first }

    public init() {}

    public mutating func request(_ identifier: String) {
        pending.insert(identifier)
    }

    public mutating func cancel(_ identifier: String) {
        pending.remove(identifier)
    }

    /// Only an authenticated helper response can acknowledge a denial. Missing
    /// pairing data must never be treated as an empty list of paired devices.
    public mutating func reconcile(allowed: Set<String>, paired: Set<String>?) {
        pending.formIntersection(allowed)
        if let paired { pending.formUnion(allowed.subtracting(paired)) }
    }
}
