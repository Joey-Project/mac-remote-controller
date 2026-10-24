/// Applies absolute player-volume steps and preserves the adapter's exact upper endpoint.
public enum PlayerVolumePolicy {
    public static let step = 10.0
    public static let strongestDetent = 100.0
    public static let strongestDetentRadius = 7.5

    /// Converts the protocol's gain ratio to the percentage value used by the UI.
    public static func uiMaximumPercent(fromGainRatio maximumGainRatio: Double) -> Double? {
        guard maximumGainRatio.isFinite, maximumGainRatio > 0 else { return nil }
        let percent = maximumGainRatio * 100
        return percent.isFinite ? percent : nil
    }

    /// Converts a target's current gain ratio to a bounded UI percentage.
    public static func uiPercent(
        fromGainRatio gainRatio: Double, maximumGainRatio: Double
    ) -> Double? {
        guard gainRatio.isFinite, gainRatio >= 0,
            let maximumPercent = uiMaximumPercent(fromGainRatio: maximumGainRatio),
            gainRatio <= maximumGainRatio
        else { return nil }
        let percent = gainRatio * 100
        guard percent.isFinite, percent <= maximumPercent else { return nil }
        return percent
    }

    /// Converts the UI's percentage value back to the protocol's gain ratio.
    public static func gainRatio(
        fromUIPercent percent: Double, maximumGainRatio: Double
    ) -> Double? {
        guard let maximumPercent = uiMaximumPercent(fromGainRatio: maximumGainRatio),
            percent.isFinite, percent >= 0, percent <= maximumPercent
        else { return nil }
        if percent == maximumPercent { return maximumGainRatio }
        let ratio = percent / 100
        guard ratio.isFinite, ratio >= 0, ratio <= maximumGainRatio else { return nil }
        return ratio
    }

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
