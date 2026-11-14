import AppleCore
import Foundation
import XCTest

final class MediaSeekIntervalTests: XCTestCase {
    func testSavedIntervalsRemainValidInBothWireDirections() throws {
        for value in [5, 10, 15, 30] {
            let interval = MediaSeekInterval(savedValue: value)
            XCTAssertEqual(interval.rawValue, value)
            XCTAssertEqual(interval.forwardSeconds, Double(value))
            XCTAssertEqual(interval.backwardSeconds, -Double(value))
            for seconds in [interval.forwardSeconds, interval.backwardSeconds] {
                let command = RemoteCommand(
                    name: .mediaControl,
                    mediaRequest: MediaRequest(targetID: "iina:test", action: .seek, value: seconds)
                )
                try command.validate()
                XCTAssertEqual(
                    try JSONDecoder().decode(
                        RemoteCommand.self, from: JSONEncoder().encode(command)), command)
            }
        }
    }

    func testMissingOrUnsupportedSavedValuesUseTheExistingTenSecondDefault() {
        for value in [Int.min, -10, 0, 1, 20, 3_600, Int.max] {
            XCTAssertEqual(MediaSeekInterval(savedValue: value), .ten)
        }
    }
}
