import AppKit
import XCTest

@testable import MacWallpaperEngine

/// The routing and fallback contract of the experimental native video backend.
///
/// Two properties decide whether this backend is safe to ship switched off:
/// a wallpaper it cannot honour goes back to the scene engine exactly once,
/// and a display's own visibility never overrides the user's own pause.
@MainActor
final class NativeVideoWallpaperHostTests: XCTestCase {
    private func wallpaper(
        displayID: UInt32 = 7,
        id: String = "300",
        fps: UInt32 = 60,
        paused: Bool = false,
        volume: Float = 1.0,
        muted: Bool = false
    ) -> BridgeNativeVideoWallpaper {
        BridgeNativeVideoWallpaper(
            displayId: displayID,
            wallpaperId: id,
            title: "Clip",
            mediaPath: "/tmp/does-not-need-to-exist/clip.mp4",
            fps: fps,
            paused: paused,
            volume: volume,
            muted: muted,
            scalingMode: .fill,
            scalingFactor: 1.0)
    }

    private final class Recorder {
        var rejected: [(String, String)] = []
        var fetched = 0
        var presented = 0
        var stopped = 0
    }

    /// Stands in for the desktop window. The controller's rules are what these
    /// tests are about, and an automated run has no authorization to put a
    /// window on the desktop.
    @MainActor
    private final class FakeSurface: NativeVideoSurface {
        private let recorder: Recorder
        private var userPaused: Bool
        private var suspended = false
        private(set) var isStopped = false
        var volume: Float = 1
        var muted = false

        init(recorder: Recorder, paused: Bool) {
            self.recorder = recorder
            self.userPaused = paused
        }

        func setVolume(_ volume: Float, muted: Bool) {
            self.volume = volume
            self.muted = muted
        }
        func setScaling(_ mode: BridgeScalingMode) {}
        func setUserPaused(_ paused: Bool) { userPaused = paused }
        func setPresentationSuspended(_ suspended: Bool) { self.suspended = suspended }
        var isPlaying: Bool { !isStopped && !userPaused && !suspended }
        func posterImage() async -> CGImage? { nil }
        func present() { recorder.presented += 1 }
        func stop() {
            isStopped = true
            recorder.stopped += 1
        }
    }

    private func makeHost(
        wallpapers: [BridgeNativeVideoWallpaper],
        refusal: NativeVideoRefusal? = nil,
        recorder: Recorder
    ) -> NativeVideoWallpaperHost {
        NativeVideoWallpaperHost(
            fetch: {
                recorder.fetched += 1
                return wallpapers
            },
            reject: { id, reason in recorder.rejected.append((id, reason)) },
            screens: {
                [
                    (id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                    (id: UInt32(9), frame: NSRect(x: 200, y: 0, width: 200, height: 100)),
                ]
            },
            refusal: { _, _ in refusal },
            makeSurface: { _, _, _, paused in FakeSurface(recorder: recorder, paused: paused) },
            frameCenter: NotificationCenter(),
            counters: RuntimeCounters())
    }

    func testAWallpaperTheBackendCannotHonourIsHandedBackExactlyOnce() async {
        // A 60 fps clip under a 30 fps target cannot be honoured without either
        // slowing the video down or copying every frame through the CPU, so the
        // scene engine has to take it. Handing it back twice would let the two
        // backends pass it between them forever.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(fps: 30)],
            refusal: .targetFrameRateBelowContent(target: 30, content: 60),
            recorder: recorder)

        await host.apply([wallpaper(fps: 30)])
        await host.apply([wallpaper(fps: 30)])

        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.0, "300")
        XCTAssertTrue(recorder.rejected.first?.1.contains("target frame rate") == true)
        XCTAssertTrue(host.isEmpty, "a refused wallpaper must not leave a window behind")
        host.shutdown()
    }

    func testAnUnplayableAssetIsHandedBackWithItsReason() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper()],
            refusal: .notPlayable("no video track"),
            recorder: recorder)

        await host.apply([wallpaper()])

        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertTrue(recorder.rejected.first?.1.contains("no video track") == true)
        XCTAssertTrue(host.isEmpty)
        host.shutdown()
    }

    func testAnAcceptedWallpaperOpensExactlyOneSurfacePerDisplay() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)

        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertTrue(recorder.rejected.isEmpty)
        XCTAssertEqual(recorder.presented, 2)
        host.shutdown()
        XCTAssertTrue(host.isEmpty, "shutdown must leave no player running")
        XCTAssertEqual(recorder.stopped, 2, "every surface has to be stopped, not just dropped")
    }

    func testHidingOneDisplayLeavesTheOtherPlaying() async {
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")],
            recorder: recorder)
        await host.apply([wallpaper(displayID: 7), wallpaper(displayID: 9, id: "301")])

        host.setPresentationSuspended(true, forDisplay: 9)

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertTrue(host.isPlaying(displayID: 7) == true)
        XCTAssertTrue(host.isPlaying(displayID: 9) == false)
        host.shutdown()
    }

    func testRevealingADisplayDoesNotStartAWallpaperTheUserPaused() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper(paused: true)], recorder: recorder)
        await host.apply([wallpaper(paused: true)])

        host.setPresentationSuspended(true, forDisplay: 7)
        host.setPresentationSuspended(false, forDisplay: 7)

        XCTAssertEqual(
            host.isPlaying(displayID: 7), false,
            "visibility must never clear the user's own pause")
        host.shutdown()
    }

    func testAGlobalResumeKeepsADisplayThatIsStillHiddenStopped() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])

        host.setPresentationSuspended(true, forDisplay: 7)
        host.setPresentationSuspended(true)
        host.setPresentationSuspended(false)

        XCTAssertEqual(host.isPlaying(displayID: 7), false)
        host.setPresentationSuspended(false, forDisplay: 7)
        XCTAssertEqual(host.isPlaying(displayID: 7), true)
        host.shutdown()
    }

    func testAWallpaperThatLeavesTheNativeBackendStopsPlayingImmediately() async {
        // The bridge stops returning it — because the user switched wallpaper,
        // turned the backend off, or the routing changed. Leaving the player
        // running would mean two backends decoding for one display.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper()])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        await host.apply([])

        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(
            recorder.stopped, 1,
            "the player must stop in the same pass, not when something else happens to run")
        host.shutdown()
    }

    func testSwitchingWallpaperOnOneDisplayReplacesTheSurface() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder)
        await host.apply([wallpaper(id: "300")])
        let firstGeneration = host.surfaceGenerationForTest

        await host.apply([wallpaper(id: "301")])

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertNotEqual(
            host.surfaceGenerationForTest, firstGeneration,
            "a new wallpaper is a new surface, so its counters are not merged with the old one's")
        host.shutdown()
    }
}
