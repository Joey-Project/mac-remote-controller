/// Tracks authenticated and unauthenticated connections for bounded server admission.
/// A full pool replaces its oldest unprotected pending entry, preserving active enrollment.
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

    /// Returns the ID to close: the oldest unprotected pending entry, or the
    /// newcomer itself if every slot is protected. Rejected IDs are not stored.
    @discardableResult
    public mutating func admitPending(_ id: ID, protecting protectedID: ID? = nil) -> ID? {
        precondition(!contains(id), "A connection ID may only be admitted once")
        var evicted: ID?
        if pendingOrder.count >= maximumPending {
            guard let index = pendingOrder.firstIndex(where: { $0 != protectedID }) else {
                return id
            }
            evicted = pendingOrder.remove(at: index)
        }
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
