import AVFoundation
import AppKit
import XCTest

@testable import WallpaperMachine

/// The real `NativeVideoPlayer` against real media.
///
/// **Opt-in.** These cases drive `AVQueuePlayer`, `AVPlayerLooper`,
/// `AVPlayerLayer`, `AVPlayerItemVideoOutput` and the poster path, which means
/// real video decoding on this machine's media hardware. They are skipped
/// unless `WALLPAPER_MACHINE_MEDIA_TESTS=1` is set, so the routine gate
/// stays a metadata-and-logic suite:
///
/// ```
/// WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py
/// ```
///
/// They still open no window and touch no desktop: an `AVPlayerLayer` that is
/// never added to a window's layer tree presents nothing. Nor is any audio
/// session configured — every fixture is silent.
///
/// **Evidence discipline.** `readyForDisplay` means the layer has a frame it
/// could show. It is not a presented frame. Each case below records which of
/// these it established, and on-screen presentation is recorded as
/// unavailable, never inferred:
///
/// | asset loaded | item ready | time advanced | pixel obtained | layer ready | on screen |
@MainActor
final class NativeVideoPlayerMediaTests: XCTestCase {
    private var directory: URL!
    private var counters: RuntimeCounters!
    private var surface: RuntimeSurfaceKey!
    private var player: NativeVideoPlayer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_MEDIA_TESTS"] == "1",
            "media/device integration tests are opt-in; set WALLPAPER_MACHINE_MEDIA_TESTS=1")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-video-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        counters = RuntimeCounters()
        counters.startSession(duration: .seconds(120))
        surface = RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 1, generation: 1)
    }

    override func tearDown() async throws {
        player?.stop()
        player = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    /// A one-second 30 fps clip: long enough to observe time advancing, short
    /// enough that two loops take two seconds.
    private func makeClip(name: String, frames: Int = 30) async throws -> URL {
        try await SyntheticVideoFixture.write(
            .constantRate(name: name, numerator: 30, denominator: 1, frames: frames),
            into: directory)
    }

    private func makePlayer(url: URL, paused: Bool = false) -> NativeVideoPlayer {
        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: paused)
        // A layer with no window shows nothing, but it still has to be the
        // production object: the poster path reads the item the layer's player
        // is playing.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: url)
        self.player = player
        return player
    }

    /// Waits for `condition`, polling, up to `timeout`. Returns whether it
    /// became true, so a caller reports a timeout rather than asserting on a
    /// value it never waited for.
    private func wait(
        upTo timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testTheRealPlayerReachesReadinessAndAdvancesPlaybackTime() async throws {
        let url = try await makeClip(name: "advance")
        let player = makePlayer(url: url)

        let ready = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(ready, "the item never became readyToPlay")

        let first = player.playbackTimeForTest
        let advanced = await wait {
            CMTimeCompare(player.playbackTimeForTest, first) > 0
        }
        XCTAssertTrue(advanced, "playback time never advanced")
        XCTAssertTrue(player.isPlaying)

        let layerReady = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }
        print(
            "[media] advance: asset loaded=yes item ready=yes time advanced=yes "
                + "layer ready=\(layerReady) on screen=unavailable (no presentation feedback)")
    }

    func testItKeepsPlayingAcrossAtLeastTwoLoopBoundaries() async throws {
        // One second of content; the looper has to restart it. A wrap shows up
        // as the playback time going backwards.
        let url = try await makeClip(name: "loop")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")

        var wraps = 0
        var previous = player.playbackTimeForTest
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline && wraps < 2 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = player.playbackTimeForTest
            if now.isValid && previous.isValid && CMTimeCompare(now, previous) < 0 {
                wraps += 1
            }
            previous = now
        }

        XCTAssertGreaterThanOrEqual(wraps, 2, "the clip did not loop twice")
        XCTAssertNotNil(player.currentItemForTest, "the queue must not run dry across a loop")
        XCTAssertTrue(player.isPlaying)
        print("[media] loop: wraps=\(wraps) queued items=\(player.queuedItemCount)")
    }

    func testAPosterIsProducedFromTheItemPlayingAfterTwoLoops() async throws {
        let url = try await makeClip(name: "poster-loop")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")

        var wraps = 0
        var previous = player.playbackTimeForTest
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline && wraps < 2 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = player.playbackTimeForTest
            if now.isValid && previous.isValid && CMTimeCompare(now, previous) < 0 { wraps += 1 }
            previous = now
        }
        XCTAssertGreaterThanOrEqual(wraps, 2, "needed two loop boundaries to make the point")

        let image = await player.posterImage()
        XCTAssertNotNil(image, "the poster path must survive the item being replaced by a loop")
        XCTAssertEqual(image?.width, 64)
        XCTAssertEqual(image?.height, 36)
        XCTAssertFalse(
            player.posterOutputIsAttachedForTest,
            "the video output must not stay attached; that would be a continuous readback")
        let fallbacks = counters.snapshot().value(.nativeVideoPosterFallback, for: surface)
        print(
            "[media] poster after \(wraps) loops: pixel obtained=yes fallbacks=\(fallbacks) "
                + "on screen=unavailable")
    }

    func testConcurrentPosterRequestsCoalesceIntoOne() async throws {
        let url = try await makeClip(name: "poster-concurrent")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        _ = await wait(upTo: .seconds(3)) { player.layerIsReadyForDisplayForTest }

        async let a = player.posterImage()
        async let b = player.posterImage()
        async let c = player.posterImage()
        let images = await [a, b, c]

        XCTAssertEqual(images.count, 3)
        XCTAssertNotNil(images[0])
        for image in images.dropFirst() {
            XCTAssertTrue(
                image === images[0],
                "overlapping requests must share one read, not open three")
        }
        XCTAssertFalse(player.posterOutputIsAttachedForTest)
    }

    func testAPausedPlayerAnswersAPosterWithoutResuming() async throws {
        let url = try await makeClip(name: "poster-paused")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        // Produce one frame, then stop on the user's behalf.
        _ = await player.posterImage()
        player.setUserPaused(true)
        XCTAssertFalse(player.isPlaying)

        let image = await player.posterImage()

        XCTAssertNotNil(image, "a paused player still has the last frame it produced")
        XCTAssertFalse(
            player.isPlaying,
            "a screenshot request must never restart playback the user stopped")
    }

    func testStoppingReleasesTheItemAndLeavesNothingAttached() async throws {
        let url = try await makeClip(name: "release")
        let player = makePlayer(url: url)
        let itemReady = await wait { player.itemStatusForTest == .readyToPlay }
        XCTAssertTrue(itemReady, "the item never became readyToPlay")
        _ = await player.posterImage()

        player.stop()

        let snapshot = counters.snapshot()
        XCTAssertEqual(
            snapshot.value(.nativeVideoItemCreated, for: surface),
            snapshot.value(.nativeVideoItemReleased, for: surface),
            "a created item that is never released is a leaked player")
        XCTAssertFalse(player.posterOutputIsAttachedForTest)
        XCTAssertFalse(player.isPlaying)
        let afterStop = await player.posterImage()
        XCTAssertNil(afterStop, "a stopped surface must not deliver a frame to whatever is next")
    }

    func testTheRealPlayerReportsAFailureFromTheItemItActuallyPlays() async throws {
        // The producer half of the playback-failure hand-off, which no fake
        // surface can cover. It also pins the fault this test was written
        // after: `AVPlayerLooper` does not play its template item, so an
        // observer attached to the template watches an object that never
        // fails, and the host would never be told.
        let good = try await makeClip(name: "fail-source")
        let broken = directory.appendingPathComponent("fail-truncated.mov")
        let bytes = try Data(contentsOf: good)
        // Keep enough of the container to be openable, lose the media data.
        try bytes.prefix(bytes.count / 3).write(to: broken)

        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: false)
        var reported: (generation: UInt64, detail: String)?
        player.onPreparationFailure = { generation, detail in
            reported = (generation, detail)
        }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: broken)
        self.player = player

        let failed = await wait(upTo: .seconds(10)) { reported != nil }

        XCTAssertTrue(failed, "a truncated asset must reach the failure callback")
        XCTAssertEqual(reported?.generation, surface.generation)
        print("[media] playback failure -> \(reported?.detail ?? "none")")
    }

    func testAFailureRaisedBeforeTheCallbackIsInstalledIsStillDelivered() async throws {
        // The host builds the surface and installs its callback afterwards, so
        // a synchronous failure at load would be dropped on the floor — the
        // one case that ends with a black display and no hand-off.
        let good = try await makeClip(name: "fail-late-observer")
        let broken = directory.appendingPathComponent("fail-late-truncated.mov")
        let bytes = try Data(contentsOf: good)
        try bytes.prefix(bytes.count / 3).write(to: broken)

        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        view.wantsLayer = true
        player.attach(to: view)
        player.load(url: broken)
        self.player = player
        // Let the failure land with nobody listening.
        try? await Task.sleep(for: .milliseconds(500))

        var reported: String?
        player.onPreparationFailure = { _, detail in reported = detail }
        let delivered = await wait(upTo: .seconds(10)) { reported != nil }

        XCTAssertTrue(delivered, "a failure seen before the callback existed must be held")
    }

    func testAnAssetWithNoUsableRateNeverReachesThePlayer() async throws {
        // End to end through the production entry point: admission refuses and
        // the player is never constructed for it.
        let url = try SyntheticVideoFixture.writeCorrupt(name: "corrupt-media", into: directory)
        let refusal = await NativeVideoAdmission.evaluate(url: url, targetFps: 60)
        XCTAssertNotNil(refusal)
        print("[media] corrupt -> \(refusal?.reason ?? "ACCEPTED")")
    }
}
