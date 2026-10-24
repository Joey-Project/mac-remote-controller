/// Applies absolute player-volume steps and preserves the adapter's exact upper endpoint.
public enum PlayerVolumePolicy {
    public static let step = 10.0
    public static let strongestDetent = 100.0
    public static let strongestDetentRadius = 7.5

    public static func snappedValue(proposed: Double, maximum: Double) -> Double? {
        guard proposed.isFinite, maximum.isFinite, maximum > 0 else { return nil }
        let bounded = min(max(proposed, 0), maximum)
        if bounded == 0 || bounded == maximum { return bounded }
        let effectiveStep = min(step, maximum)
        if maximum >= strongestDetent,
            abs(bounded - strongestDetent) <= strongestDetentRadius
        {
            return strongestDetent
        }
        let stepped = (bounded / effectiveStep).rounded(.toNearestOrAwayFromZero) * effectiveStep
        return min(stepped, maximum)
    }

    public static func accessibilityAdjustedValue(
        current: Double, increasing: Bool, maximum: Double
    ) -> Double? {
        guard let snappedCurrent = snappedValue(proposed: current, maximum: maximum) else {
            return nil
        }
        let delta = increasing ? step : -step
        return snappedValue(proposed: snappedCurrent + delta, maximum: maximum)
    }

    public static func shouldSend(
        value: Double, current: Double?, previouslySent: Double?
    ) -> Bool {
        value.isFinite && current != value && previouslySent != value
    }

    public static func isAtStrongestDetent(_ value: Double) -> Bool {
        value.isFinite && value == strongestDetent
    }
}
