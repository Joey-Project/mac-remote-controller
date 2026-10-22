import Foundation

public enum PixelScrollAccumulatorError: Error, Sendable, Equatable {
    case invalidDelta
}

/// Converts bounded fractional scroll deltas to integral pixels per connection.
public struct PixelScrollAccumulator: Sendable {
    private var remainderX = 0.0
    private var remainderY = 0.0

    public init() {}

    /// Emits whole pixels toward zero and retains the fractional remainder.
    /// Both deltas are validated before either axis is changed.
    public mutating func consume(x: Double, y: Double) throws -> (x: Int32, y: Int32) {
        guard x.isFinite, y.isFinite, abs(x) <= 100, abs(y) <= 100 else {
            throw PixelScrollAccumulatorError.invalidDelta
        }

        let totalX = remainderX + x
        let totalY = remainderY + y
        let pixelsX = Int32(totalX.rounded(.towardZero))
        let pixelsY = Int32(totalY.rounded(.towardZero))
        remainderX = totalX - Double(pixelsX)
        remainderY = totalY - Double(pixelsY)
        return (pixelsX, pixelsY)
    }
}
