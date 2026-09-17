import XCTest
@testable import MacWallpaperEngine

@MainActor
final class RuntimeCountersTests: XCTestCase {
    /// Advances only when a test says so, so session expiry is deterministic.
    private final class TestClock {
        private(set) var instant = ContinuousClock.now
        func advance(by duration: Duration) { instant = instant.advanced(by: duration) }
    }

    private func counters(_ clock: TestClock) -> RuntimeCounters {
        RuntimeCounters(now: { clock.instant })
    }

    private let desktop = RuntimeSurfaceKey(kind: .desktopScene, displayID: 1)
    private let web = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 2)

    func testRecordingIsIgnoredWithoutAnOpenSession() {
        let counters = counters(TestClock())
        counters.record(.presentationSuspended, for: desktop)
        let snapshot = counters.snapshot()
        XCTAssertFalse(snapshot.isRecording)
        XCTAssertEqual(snapshot.total(.presentationSuspended), 0)
        XCTAssertTrue(counters.aggregatedReport().isEmpty)
    }

    func testSessionExpiresOnItsOwnAndStopsCounting() {
        let clock = TestClock()
        let counters = counters(clock)
        counters.startSession(duration: .seconds(5))
        counters.record(.presentationSuspended, for: desktop)
        clock.advance(by: .seconds(4))
        counters.record(.presentationSuspended, for: desktop)
        XCTAssertEqual(counters.snapshot().value(.presentationSuspended, for: desktop), 2)

        clock.advance(by: .seconds(2))
        counters.record(.presentationSuspended, for: desktop)
        let expired = counters.snapshot()
        XCTAssertFalse(expired.isRecording)
        XCTAssertEqual(
            expired.value(.presentationSuspended, for: desktop), 2,
            "an expired session must stop counting while keeping what it already recorded")
    }

    func testCountsStaySeparatePerSurfaceAndCounter() {
        let counters = counters(TestClock())
        counters.startSession(duration: .seconds(30))
        counters.record(.presentationSuspended, for: desktop)
        counters.record(.presentationSuspended, for: web, by: 3)
        counters.record(.webMediaSuspended, for: web)

        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.value(.presentationSuspended, for: desktop), 1)
        XCTAssertEqual(snapshot.value(.presentationSuspended, for: web), 3)
        XCTAssertEqual(snapshot.value(.webMediaSuspended, for: desktop), 0)
        XCTAssertEqual(snapshot.value(.webMediaSuspended, for: web), 1)
        XCTAssertEqual(snapshot.total(.presentationSuspended), 4)
    }

    func testTheSameDisplayAcrossGenerationsIsNotMerged() {
        let counters = counters(TestClock())
        counters.startSession(duration: .seconds(30))
        let first = RuntimeSurfaceKey(kind: .desktopScene, displayID: 7, generation: 1)
        let second = RuntimeSurfaceKey(kind: .desktopScene, displayID: 7, generation: 2)
        counters.record(.webPageCreated, for: first)
        counters.record(.webPageCreated, for: second, by: 2)

        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.value(.webPageCreated, for: first), 1)
        XCTAssertEqual(snapshot.value(.webPageCreated, for: second), 2)
    }

    func testSurfaceTableIsBoundedAndReportsWhatItDropped() {
        let counters = counters(TestClock())
        counters.startSession(duration: .seconds(30))
        let overflow = RuntimeCounters.maximumTrackedSurfaces + 4
        for index in 0..<overflow {
            counters.record(
                .pointerDelivered,
                for: RuntimeSurfaceKey(kind: .preview, displayID: UInt32(index)), by: 2)
        }

        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.surfaces.count, RuntimeCounters.maximumTrackedSurfaces)
        XCTAssertEqual(snapshot.droppedSurfaceEvents, 8, "four evicted surfaces held two events each")
        XCTAssertEqual(
            snapshot.value(.pointerDelivered, for: RuntimeSurfaceKey(kind: .preview, displayID: 0)), 0,
            "the oldest surface is the one evicted")
        XCTAssertEqual(
            snapshot.value(
                .pointerDelivered,
                for: RuntimeSurfaceKey(kind: .preview, displayID: UInt32(overflow - 1))),
            2)
    }

    func testANewSessionStartsFromZero() {
        let counters = counters(TestClock())
        counters.startSession(duration: .seconds(30))
        counters.record(.presentationResumed, for: desktop)
        counters.startSession(duration: .seconds(30))
        XCTAssertEqual(counters.snapshot().total(.presentationResumed), 0)
    }

    func testEndSessionStopsRecordingWithoutDiscardingCounts() {
        let counters = counters(TestClock())
        counters.startSession(duration: .seconds(30))
        counters.record(.webStateReplayed, for: web)
        counters.endSession()
        counters.record(.webStateReplayed, for: web)

        let snapshot = counters.snapshot()
        XCTAssertFalse(snapshot.isRecording)
        XCTAssertEqual(snapshot.value(.webStateReplayed, for: web), 1)
    }

    func testAggregatedReportOmitsCountersThatNeverFired() {
        let counters = counters(TestClock())
        counters.startSession(duration: .seconds(30))
        counters.record(.webDetached, for: web, by: 2)

        XCTAssertEqual(counters.aggregatedReport(), ["surface=desktopWeb/2/gen0 webDetached=2"])
    }
}
