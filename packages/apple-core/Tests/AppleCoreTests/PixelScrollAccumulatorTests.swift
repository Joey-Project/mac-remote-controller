import XCTest
@testable import AppleCore

final class PixelScrollAccumulatorTests: XCTestCase {
    func testAccumulatesSlowPositiveAndNegativeScrolls() throws {
        var positive = PixelScrollAccumulator()
        assertScroll(try positive.consume(x: 0.4, y: 0), x: 0, y: 0)
        assertScroll(try positive.consume(x: 0.4, y: 0), x: 0, y: 0)
        assertScroll(try positive.consume(x: 0.4, y: 0), x: 1, y: 0)

        var negative = PixelScrollAccumulator()
        assertScroll(try negative.consume(x: -0.4, y: 0), x: 0, y: 0)
        assertScroll(try negative.consume(x: -0.4, y: 0), x: 0, y: 0)
        assertScroll(try negative.consume(x: -0.4, y: 0), x: -1, y: 0)
    }

    func testAccumulatesAxesIndependentlyAcrossSignChanges() throws {
        var accumulator = PixelScrollAccumulator()
        assertScroll(try accumulator.consume(x: 0.8, y: -0.8), x: 0, y: 0)
        assertScroll(try accumulator.consume(x: -0.3, y: 0.3), x: 0, y: 0)
        assertScroll(try accumulator.consume(x: 0.6, y: -0.6), x: 1, y: -1)
        assertScroll(try accumulator.consume(x: 0, y: 0.4), x: 0, y: 0)
    }

    func testInvalidDeltaDoesNotChangeEitherAxisRemainder() throws {
        var accumulator = PixelScrollAccumulator()
        assertScroll(try accumulator.consume(x: 0.6, y: 0.6), x: 0, y: 0)

        XCTAssertThrowsError(try accumulator.consume(x: 0.6, y: 100.01)) { error in
            XCTAssertEqual(error as? PixelScrollAccumulatorError, .invalidDelta)
        }
        XCTAssertThrowsError(try accumulator.consume(x: 0.6, y: .nan)) { error in
            XCTAssertEqual(error as? PixelScrollAccumulatorError, .invalidDelta)
        }
        assertScroll(try accumulator.consume(x: 0.4, y: 0.4), x: 1, y: 1)
    }

    private func assertScroll(
        _ result: (x: Int32, y: Int32),
        x expectedX: Int32,
        y expectedY: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.x, expectedX, file: file, line: line)
        XCTAssertEqual(result.y, expectedY, file: file, line: line)
    }
}
