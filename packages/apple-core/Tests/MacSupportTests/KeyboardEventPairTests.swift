import XCTest
@testable import MacSupport

final class KeyboardEventPairTests: XCTestCase {
    func testSecondEventCreationFailureDoesNotConfigureOrPostFirstEvent() {
        var attempts: [Bool] = []
        var trace: [String] = []

        let emitted = KeyboardEventPair.emit(
            create: { isDown in
                attempts.append(isDown)
                return isDown ? "down" : nil
            },
            configure: { event, isDown in
                trace.append("configure:\(event):\(isDown)")
            },
            post: { event in trace.append("post:\(event)") })

        XCTAssertFalse(emitted)
        XCTAssertEqual(attempts, [true, false])
        XCTAssertTrue(trace.isEmpty)
    }

    func testCreatesAndConfiguresBothEventsBeforePostingDownThenUp() {
        var trace: [String] = []

        let emitted = KeyboardEventPair.emit(
            create: { isDown in
                let event = isDown ? "down" : "up"
                trace.append("create:\(event)")
                return event
            },
            configure: { event, _ in trace.append("configure:\(event)") },
            post: { event in trace.append("post:\(event)") })

        XCTAssertTrue(emitted)
        XCTAssertEqual(
            trace,
            [
                "create:down", "create:up", "configure:down", "configure:up", "post:down",
                "post:up"
            ])
    }
}
