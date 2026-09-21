import XCTest

@testable import WallpaperMachine

/// What a diagnostic report is allowed to claim.
///
/// The report is the only thing a power comparison can be argued from, so two
/// properties have to hold regardless of formatting: work a surface performs
/// alone must be readable apart from work its decoded source performs, and a
/// measurement this platform cannot make must never be approximated by one it
/// can.
@MainActor
final class RuntimeDiagnosticsReportTests: XCTestCase {
    private func surface(
        displayID: String,
        generation: UInt64,
        source: String,
        paused: Bool,
        pauseReasons: [String] = [],
        presentRequests: UInt64 = 0,
        renderSubmissions: UInt64 = 0,
        decodeOutputs: UInt64 = 0,
        framesSkipped: UInt64 = 0,
        conversionLiveBytes: UInt64 = 0,
        conversionPeakLiveBytes: UInt64 = 0,
        sourceInstance: String = "instance:1",
        sourceCount: UInt64 = 1
    ) -> BridgeRendererSurfaceCounters {
        BridgeRendererSurfaceCounters(
            displayId: displayID,
            surfaceId: displayID,
            generation: generation,
            sourceId: sourceInstance,
            sourcePath: source,
            sourceCount: sourceCount,
            backend: "scene",
            effectivePauseReasons: pauseReasons,
            paused: paused,
            timerWakeups: 0,
            drawRequests: 0,
            drawTicksSuppressed: 0,
            drawsExecuted: 0,
            drawsDropped: 0,
            renderSubmissions: renderSubmissions,
            renderFailures: 0,
            presentRequests: presentRequests,
            gpuCompletions: 0,
            simulationTicks: 0,
            tickIntervalMicros: 16666,
            contentPeriodMicros: 0,
            videoDecodeOutputs: decodeOutputs,
            videoSeeks: 0,
            videoFramesSelected: 0,
            videoFramesReused: 0,
            videoFramesSkipped: framesSkipped,
            videoSelectedGeneration: 0,
            videoConversions: 0,
            videoImports: 0,
            videoConversionLiveBytes: conversionLiveBytes,
            videoConversionPeakLiveBytes: conversionPeakLiveBytes)
    }

    private func report(
        _ surfaces: [BridgeRendererSurfaceCounters],
        consumers: UInt32 = 0
    ) -> BridgeRendererCountersReport {
        BridgeRendererCountersReport(
            recording: true,
            surfaces: surfaces,
            audioAnalysisDeliveries: 0,
            audioAcceptedFrames: 0,
            audioActiveConsumers: consumers,
            presentationFeedbackAvailable: false)
    }

    func testSurfaceExclusiveWorkIsReportedApartFromSharedSourceWork() {
        // One hidden and one visible consumer of one decoder. The hidden
        // surface stopped submitting; the decoder kept producing for the other.
        // Merging those into one number would make a hidden surface look busy.
        let lines = RuntimeDiagnosticsSession.rendererLines(
            report([
                surface(
                    displayID: "7", generation: 1, source: "/library/clip/project.json",
                    paused: false, presentRequests: 600, renderSubmissions: 600,
                    decodeOutputs: 600, sourceInstance: "instance:4"),
                surface(
                    displayID: "9", generation: 1, source: "/library/clip/project.json",
                    paused: true, pauseReasons: ["clockStopped"], presentRequests: 120,
                    renderSubmissions: 120, decodeOutputs: 600, sourceInstance: "instance:4"),
            ]))

        let hiddenSurface = lines.first { $0.hasPrefix("surface=scene/9") }
        XCTAssertNotNil(hiddenSurface)
        XCTAssertTrue(hiddenSurface?.contains("present_requests=120") == true)
        XCTAssertTrue(hiddenSurface?.contains("reasons=clockStopped") == true)
        XCTAssertFalse(
            hiddenSurface?.contains("decode_outputs") == true,
            "decoding is source work and must not be reported as this surface's own")
        XCTAssertTrue(
            hiddenSurface?.contains("conversions=") == true,
            "the texture cache that converts is per surface, so conversion is its own work")

        let sourceRows = lines.filter { $0.hasPrefix("source=instance:4 ") }
        XCTAssertEqual(sourceRows.count, 2)
        XCTAssertTrue(sourceRows.allSatisfy { $0.contains("decode_outputs=600") })
    }

    func testConversionMemoryIsReportedPerSurfaceWithItsPeakKeptSeparate() {
        // A surface that has released its imported frames reads near zero
        // right now and still cost 324 MiB while they were live. Reporting
        // only the current value would make that surface look free, which is
        // exactly the reading the old cached-bytes-only figure gave.
        let lines = RuntimeDiagnosticsSession.rendererLines(
            report([
                surface(
                    displayID: "7", generation: 1, source: "/library/clip/project.json",
                    paused: false, conversionLiveBytes: 84_934_656,
                    conversionPeakLiveBytes: 339_738_624, sourceInstance: "instance:4"),
                surface(
                    displayID: "9", generation: 1, source: "/library/still/project.json",
                    paused: false, sourceInstance: "instance:5"),
            ]))

        let converting = lines.first { $0.hasPrefix("surface=scene/7") }
        XCTAssertNotNil(converting)
        XCTAssertTrue(converting?.contains("conversion_live_bytes=84934656") == true)
        XCTAssertTrue(
            converting?.contains("conversion_peak_live_bytes=339738624") == true,
            "the peak is what a ceiling is judged against and must not be collapsed into the "
                + "current value")

        // A surface whose texture cache converts nothing reports zero, and
        // zero is a measurement here rather than an absence: the row is the
        // converting surface's own, never the decoder's or another surface's.
        let direct = lines.first { $0.hasPrefix("surface=scene/9") }
        XCTAssertNotNil(direct)
        XCTAssertTrue(direct?.contains("conversion_live_bytes=0") == true)
        XCTAssertTrue(direct?.contains("conversion_peak_live_bytes=0") == true)
    }

    func testOneDecoderConsumedTwiceIsTotalledOnce() {
        // Both consumers report the same decoder's running total, so adding the
        // rows would claim twice the decoding that happened.
        let lines = RuntimeDiagnosticsSession.sourceRollupLines([
            surface(
                displayID: "7", generation: 1, source: "/library/clip/project.json",
                paused: false, decodeOutputs: 600, sourceInstance: "instance:4"),
            surface(
                displayID: "9", generation: 1, source: "/library/clip/project.json",
                paused: true, decodeOutputs: 600, sourceInstance: "instance:4"),
        ])

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("source-total=instance:4"))
        XCTAssertTrue(lines[0].contains("consumers=2"))
        XCTAssertTrue(lines[0].contains("decode_outputs=600"))
    }

    func testTwoDecodersOnTheSameFileAreNeverFoldedTogether() {
        // Same path, two running decoders: that is two decodes, and a report
        // that keyed on the path would hide one of them.
        let lines = RuntimeDiagnosticsSession.sourceRollupLines([
            surface(
                displayID: "7", generation: 1, source: "/library/clip/project.json",
                paused: false, decodeOutputs: 600, sourceInstance: "instance:4"),
            surface(
                displayID: "9", generation: 1, source: "/library/clip/project.json",
                paused: false, decodeOutputs: 590, sourceInstance: "instance:5"),
        ])

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("source-total=instance:4") })
        XCTAssertTrue(lines.contains { $0.contains("source-total=instance:5") })
        XCTAssertTrue(lines.allSatisfy { $0.contains("consumers=1") })
    }

    func testASurfaceWithNoSingleDecoderIsReportedUnknownNotZero() {
        // A surface consuming several decoders cannot have its decode work
        // attributed to one of them. Reporting zero would look like work that
        // stopped; reporting one id would move another decoder's work onto it.
        let lines = RuntimeDiagnosticsSession.sourceRollupLines([
            surface(
                displayID: "7", generation: 1, source: "/library/scene/project.json",
                paused: false, decodeOutputs: 900, sourceInstance: "unknown", sourceCount: 3)
        ])

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("source-total=unknown"))
        XCTAssertTrue(lines[0].contains("decode_outputs=unknown"))
        XCTAssertFalse(lines[0].contains("decode_outputs=0"))
    }

    func testPresentRequestsAreNeverReportedAsDisplayedFrames() {
        let lines = RuntimeDiagnosticsSession.rendererLines(
            report([
                surface(
                    displayID: "7", generation: 1, source: "/library/clip/project.json",
                    paused: false, presentRequests: 300, renderSubmissions: 300)
            ]))

        XCTAssertTrue(lines.contains("presented_frames=unavailable"))
        XCTAssertFalse(
            lines.contains { $0.contains("presented_frames=300") },
            "a request to present is not evidence that a frame reached a display")
    }

    func testDroppedFramesAreVisibleSoAPacingRegressionCanBeFalsified() {
        // A demand-driven clock that ticks too slowly still shows moving video.
        // The only thing that exposes it is decoded frames that never reached
        // the screen, so the report has to carry that number.
        let lines = RuntimeDiagnosticsSession.rendererLines(
            report([
                surface(
                    displayID: "7", generation: 1, source: "/library/clip/project.json",
                    paused: false, decodeOutputs: 600, framesSkipped: 240)
            ]))

        XCTAssertTrue(lines.contains { $0.contains("frames_skipped=240") })
    }

    func testTwoWallpapersThatReusedOneDisplayKeepSeparateRows() {
        let lines = RuntimeDiagnosticsSession.rendererLines(
            report([
                surface(
                    displayID: "7", generation: 1, source: "/library/old/project.json",
                    paused: false, presentRequests: 900),
                surface(
                    displayID: "7", generation: 2, source: "/library/new/project.json",
                    paused: false, presentRequests: 4),
            ]))

        XCTAssertTrue(lines.contains { $0.contains("/gen1 ") && $0.contains("present_requests=900") })
        XCTAssertTrue(lines.contains { $0.contains("/gen2 ") && $0.contains("present_requests=4") })
    }
}
