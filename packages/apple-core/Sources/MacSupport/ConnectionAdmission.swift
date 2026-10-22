/// Tracks authenticated and unauthenticated connections for bounded server admission.
/// When the pending pool is full, a new connection replaces its oldest pending entry.
public struct ConnectionAdmission<ID: Hashable> {
    public let maximumAuthenticated: Int
    public let maximumPending: Int

    private var pendingOrder: [ID] = []
    private var authenticated: Set<ID> = []

    public init(maximumAuthenticated: Int = 8, maximumPending: Int = 4) {
        precondition(maximumAuthenticated >= 0)
        precondition(maximumPending > 0)
        self.maximumAuthenticated = maximumAuthenticated
        self.maximumPending = maximumPending
    }

    public var pendingCount: Int { pendingOrder.count }
    public var authenticatedCount: Int { authenticated.count }
    public var totalCount: Int { pendingCount + authenticatedCount }

    /// Registers a pending connection and returns the oldest pending ID evicted, if any.
    @discardableResult
    public mutating func admitPending(_ id: ID) -> ID? {
        precondition(!contains(id), "A connection ID may only be admitted once")
        let evicted = pendingOrder.count >= maximumPending ? pendingOrder.removeFirst() : nil
        pendingOrder.append(id)
        return evicted
    }

    /// Promotes a pending connection unless the authenticated session limit is full.
    public mutating func authenticate(_ id: ID) -> Bool {
        guard authenticated.count < maximumAuthenticated,
            let index = pendingOrder.firstIndex(of: id)
        else { return false }
        pendingOrder.remove(at: index)
        authenticated.insert(id)
        return true
    }

    /// Removes an active connection. Repeated or delayed removals are harmless.
    @discardableResult
    public mutating func remove(_ id: ID) -> Bool {
        if let index = pendingOrder.firstIndex(of: id) {
            pendingOrder.remove(at: index)
            return true
        }
        return authenticated.remove(id) != nil
    }

    private func contains(_ id: ID) -> Bool {
        pendingOrder.contains(id) || authenticated.contains(id)
    }
}
