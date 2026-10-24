import XCTest

@testable import AppleCore

final class RTTBenchmarkTests: XCTestCase {
    func testDefaultPlanExcludesWarmupsAndRunsThreeGroupsOfThirty() {
        var benchmark = RTTBenchmarkAccumulator(transport: "Wi-Fi")
        XCTAssertEqual(benchmark.groups, 3)
        XCTAssertEqual(benchmark.samplesPerGroup, 30)
        XCTAssertEqual(benchmark.warmupCount, 3)

        for _ in 0..<benchmark.warmupCount {
            benchmark.record(roundTripNanoseconds: 99)
        }
        XCTAssertEqual(benchmark.progress, 0)
        XCTAssertEqual(benchmark.currentGroup, 1)

        let sampleCount = benchmark.groups * benchmark.samplesPerGroup
        for sample in 0..<sampleCount {
            benchmark.record(roundTripNanoseconds: UInt64(sample + 1) * 1_000_000)
            if sample == 29 {
                XCTAssertEqual(benchmark.currentGroup, 2)
                XCTAssertEqual(benchmark.currentSampleInGroup, 1)
            } else if sample == 59 {
                XCTAssertEqual(benchmark.currentGroup, 3)
                XCTAssertEqual(benchmark.currentSampleInGroup, 1)
            }
        }

        let report = benchmark.report()
        XCTAssertTrue(benchmark.isComplete)
        XCTAssertEqual(report.measuredAttemptCount, 90)
        XCTAssertEqual(report.successfulRoundTripsNanoseconds.count, 90)
        XCTAssertEqual(report.timeoutCount, 0)
        XCTAssertEqual(report.minimumMilliseconds, 1)
        XCTAssertEqual(report.medianMilliseconds, 45)
        XCTAssertEqual(report.p95Milliseconds, 86)
        XCTAssertEqual(report.maximumMilliseconds, 90)
        XCTAssertEqual(report.jitterMilliseconds, 41)
    }

    func testWarmupsAreExcludedAndMeasuredTimeoutsContributeToLoss() {
        var benchmark = RTTBenchmarkAccumulator(
            transport: "Bluetooth LE", groups: 1, samplesPerGroup: 4, warmupCount: 2)
        benchmark.record(roundTripNanoseconds: 99)
        benchmark.record(roundTripNanoseconds: nil)
        benchmark.record(roundTripNanoseconds: 1_000_000)
        benchmark.record(roundTripNanoseconds: 2_000_000)
        benchmark.record(roundTripNanoseconds: nil)
        benchmark.record(roundTripNanoseconds: 3_000_000)

        let report = benchmark.report()
        XCTAssertEqual(report.measuredAttemptCount, 4)
        XCTAssertEqual(report.successfulRoundTripsNanoseconds.count, 3)
        XCTAssertEqual(report.timeoutCount, 1)
        XCTAssertEqual(report.lossRate, 0.25)
        XCTAssertEqual(report.minimumMilliseconds, 1)
        XCTAssertEqual(report.medianMilliseconds, 2)
        XCTAssertEqual(report.p95Milliseconds, 3)
        XCTAssertEqual(report.maximumMilliseconds, 3)
        XCTAssertEqual(report.jitterMilliseconds, 1)
    }

    func testCancellationKeepsPartialResultsAndRejectsLaterSamples() {
        var benchmark = RTTBenchmarkAccumulator(
            transport: "Bluetooth LE", groups: 2, samplesPerGroup: 4, warmupCount: 1)
        benchmark.record(roundTripNanoseconds: 99)
        benchmark.record(roundTripNanoseconds: 2_000_000)
        benchmark.record(roundTripNanoseconds: nil)
        benchmark.cancel()
        benchmark.record(roundTripNanoseconds: 3_000_000)

        let report = benchmark.report()
        XCTAssertTrue(benchmark.isComplete)
        XCTAssertEqual(benchmark.progress, 2)
        XCTAssertEqual(report.measuredAttemptCount, 2)
        XCTAssertEqual(report.expectedAttemptCount, 8)
        XCTAssertEqual(report.successfulRoundTripsNanoseconds, [UInt64(2_000_000)])
        XCTAssertEqual(report.timeoutCount, 1)
        XCTAssertTrue(report.cancelled)
    }

    func testLatencyStatisticsAreAbsentWhenEveryMeasuredProbeTimesOut() {
        var benchmark = RTTBenchmarkAccumulator(
            transport: "Bluetooth LE", groups: 1, samplesPerGroup: 2, warmupCount: 0)
        benchmark.record(roundTripNanoseconds: nil)
        benchmark.record(roundTripNanoseconds: nil)

        let report = benchmark.report()
        XCTAssertEqual(report.lossRate, 1)
        XCTAssertNil(report.minimumMilliseconds)
        XCTAssertNil(report.medianMilliseconds)
        XCTAssertNil(report.p95Milliseconds)
        XCTAssertNil(report.maximumMilliseconds)
        XCTAssertNil(report.jitterMilliseconds)
    }

    func testRetiredPongAfterQuickRestartDoesNotConsumeNewActiveRequest() {
        var tracker = RTTBenchmarkRequestTracker(retiredCapacity: 4)
        XCTAssertTrue(tracker.begin(id: "cancelled", sequence: 7))
        XCTAssertTrue(tracker.retireActive())
        XCTAssertTrue(tracker.begin(id: "new-run", sequence: 8))

        XCTAssertEqual(tracker.consumePong(id: "cancelled", sequence: 7), .retired)
        XCTAssertEqual(tracker.consumePong(id: "new-run", sequence: 8), .active)
        XCTAssertEqual(tracker.consumePong(id: "new-run", sequence: 8), .unexpected)
        XCTAssertTrue(tracker.canBegin)
    }

    func testRetiredPongTrackingIsBoundedAndResetClearsSessionState() {
        var tracker = RTTBenchmarkRequestTracker(retiredCapacity: 2)
        XCTAssertTrue(tracker.begin(id: "one", sequence: 1))
        XCTAssertTrue(tracker.retireActive())
        XCTAssertTrue(tracker.begin(id: "two", sequence: 2))
        XCTAssertTrue(tracker.retireActive())
        XCTAssertEqual(tracker.retiredCount, 2)
        XCTAssertFalse(tracker.canBegin)

        XCTAssertEqual(tracker.consumePong(id: "one", sequence: 1), .retired)
        XCTAssertTrue(tracker.canBegin)
        tracker.reset()
        XCTAssertEqual(tracker.retiredCount, 0)
        XCTAssertTrue(tracker.canBegin)
        XCTAssertEqual(tracker.consumePong(id: "two", sequence: 2), .unexpected)
    }

    func testSummaryIncludesMinimumAndMaximumForDisplayRows() {
        var benchmark = RTTBenchmarkAccumulator(
            transport: "Wi-Fi", groups: 1, samplesPerGroup: 3, warmupCount: 0)
        benchmark.record(roundTripNanoseconds: 1_000_000)
        benchmark.record(roundTripNanoseconds: 2_000_000)
        benchmark.record(roundTripNanoseconds: 3_000_000)

        let report = benchmark.report()
        XCTAssertTrue(report.summary.contains("min 1.00 ms"))
        XCTAssertTrue(report.summary.contains("max 3.00 ms"))
        XCTAssertTrue(report.summary.contains("p50 2.00 ms"))
        XCTAssertTrue(report.summary.contains("p95 3.00 ms"))
    }
}
