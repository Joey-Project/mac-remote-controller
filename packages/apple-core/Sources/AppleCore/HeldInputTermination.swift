import Foundation

/// Exit is permitted only after every active and disconnected session releases.
public enum HeldInputTermination {
    public static func prepare<ID: Hashable>(
        active: inout [ID: HeldInputState], pending: inout [ID: HeldInputState],
        release: (inout HeldInputState) -> Void
    ) -> Bool {
        for id in Array(active.keys) {
            guard var state = active[id] else { continue }
            release(&state)
            active[id] = state
        }
        for id in Array(pending.keys) {
            guard var state = pending[id] else { continue }
            release(&state)
            if state.buttons.isEmpty {
                pending.removeValue(forKey: id)
            } else {
                pending[id] = state
            }
        }
        return pending.isEmpty && active.values.allSatisfy { $0.buttons.isEmpty }
    }
}
