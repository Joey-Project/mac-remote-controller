public enum MediaSeekInterval: Int, CaseIterable, Sendable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30

    public init(savedValue: Int) {
        self = Self(rawValue: savedValue) ?? .ten
    }

    public var forwardSeconds: Double { Double(rawValue) }
    public var backwardSeconds: Double { -forwardSeconds }
}
