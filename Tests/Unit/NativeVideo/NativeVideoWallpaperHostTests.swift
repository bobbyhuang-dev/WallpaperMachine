import AppKit
import XCTest

@testable import MacWallpaperEngine

/// The routing and fallback contract of the experimental native video backend.
///
/// Three properties decide whether this backend is safe to ship switched off:
/// a wallpaper it cannot honour goes back to the scene engine exactly once, a
/// display's own visibility never overrides the user's own pause, and a
/// refusal stops applying once the configuration it described has changed.
@MainActor
final class NativeVideoWallpaperHostTests: XCTestCase {
    private func wallpaper(
        displayID: UInt32 = 7,
        id: String = "300",
        fps: UInt32 = 60,
        admissionFps: UInt32? = nil,
        paused: Bool = false,
        volume: Float = 1.0,
        muted: Bool = false,
        admissionKey: UInt64 = 1
    ) -> BridgeNativeVideoWallpaper {
        BridgeNativeVideoWallpaper(
            displayId: displayID,
            wallpaperId: id,
            title: "Clip",
            mediaPath: "/tmp/does-not-need-to-exist/clip.mp4",
            fps: fps,
            admissionFps: admissionFps ?? fps,
            admissionKey: admissionKey,
            paused: paused,
            volume: volume,
            muted: muted,
            scalingMode: .fill,
            scalingFactor: 1.0)
    }

    private final class Recorder {
        var rejected: [(id: String, key: UInt64, reason: String)] = []
        var fetched = 0
        var presented = 0
        var stopped = 0
        var admissionProbes: [UInt64] = []
        var refusalSequence: [NativeVideoRefusal?] = []
    }

    /// Stands in for the desktop window. The controller's rules are what these
    /// tests are about, and an automated run has no authorization to put a
    /// window on the desktop. The real window and player are covered by
    /// `NativeVideoPlayerMediaTests`, which is opt-in.
    @MainActor
    private final class FakeSurface: NativeVideoSurface {
        private let recorder: Recorder
        private var userPaused: Bool
        private var suspended = false
        private(set) var isStopped = false
        var volume: Float = 1
        var muted = false
        /// Poster answer, and how long it takes. The delay is what lets a test
        /// replace the surface while a request is still in flight.
        var poster: CGImage?
        var posterDelay: Duration = .zero
        /// Delivered synchronously the moment a callback is installed, which
        /// is what the real player does when it was already holding a failure.
        var failureOnInstall: String?
        var onPreparationFailure: (@MainActor (UInt64, String) -> Void)? {
            didSet {
                guard let failureOnInstall, onPreparationFailure != nil else { return }
                self.failureOnInstall = nil
                onPreparationFailure?(generation, failureOnInstall)
            }
        }
        /// The generation this surface was opened with, so a test can report a
        /// failure as either this surface's or a stale one's.
        let generation: UInt64

        init(recorder: Recorder, paused: Bool, generation: UInt64) {
            self.recorder = recorder
            self.userPaused = paused
            self.generation = generation
        }

        /// Stands in for `AVPlayerItem.status` becoming `.failed`.
        func failPreparation(_ detail: String, generation: UInt64? = nil) {
            onPreparationFailure?(generation ?? self.generation, detail)
        }

        func setVolume(_ volume: Float, muted: Bool) {
            self.volume = volume
            self.muted = muted
        }
        func setScaling(_ mode: BridgeScalingMode) {}
        func setUserPaused(_ paused: Bool) { userPaused = paused }
        func setPresentationSuspended(_ suspended: Bool) { self.suspended = suspended }
        var isPlaying: Bool { !isStopped && !userPaused && !suspended }
        func posterImage() async -> CGImage? {
            if posterDelay != .zero { try? await Task.sleep(for: posterDelay) }
            return poster
        }
        func present() { recorder.presented += 1 }
        func stop() {
            isStopped = true
            recorder.stopped += 1
        }
    }

    private static func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private var surfacesMade: [UInt32: FakeSurface] = [:]
    /// Makes every surface this factory builds fail as its callback is installed.
    private var surfaceFailureOnInstall: String?

    private func makeHost(
        wallpapers: [BridgeNativeVideoWallpaper],
        refusal: NativeVideoRefusal? = nil,
        refusalByKey: [UInt64: NativeVideoRefusal] = [:],
        /// Consumed one entry per probe, so a transient failure that clears on
        /// a retry can be expressed. Falls through to the other two once empty.
        refusalSequence: [NativeVideoRefusal?] = [],
        recorder: Recorder,
        frameCenter: NotificationCenter = NotificationCenter()
    ) -> NativeVideoWallpaperHost {
        recorder.refusalSequence = refusalSequence
        return NativeVideoWallpaperHost(
            fetch: {
                recorder.fetched += 1
                return wallpapers
            },
            reject: { id, key, reason in
                recorder.rejected.append((id: id, key: key, reason: reason))
            },
            screens: {
                [
                    (id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                    (id: UInt32(9), frame: NSRect(x: 200, y: 0, width: 200, height: 100)),
                ]
            },
            refusal: { _, fps in
                // The injected decision stands in for the asset probe; the key
                // is reconstructed from the target rate the host passed, which
                // is the input the real rule reads.
                recorder.admissionProbes.append(UInt64(fps))
                if !recorder.refusalSequence.isEmpty {
                    return recorder.refusalSequence.removeFirst()
                }
                return refusalByKey[UInt64(fps)] ?? refusal
            },
            makeSurface: { [weak self] _, _, key, paused in
                let surface = FakeSurface(
                    recorder: recorder, paused: paused, generation: key.generation)
                surface.failureOnInstall = self?.surfaceFailureOnInstall
                self?.surfacesMade[key.displayID] = surface
                return surface
            },
            frameCenter: frameCenter,
            counters: RuntimeCounters())
    }

    override func setUp() {
        super.setUp()
        surfacesMade = [:]
        surfaceFailureOnInstall = nil
    }

    func testAWallpaperTheBackendCannotHonourIsHandedBack() async {
        // A 60 fps clip under a 30 fps target cannot be honoured without either
        // slowing the video down or copying every frame through the CPU, so the
        // scene engine has to take it.
        //
        // This deliberately does NOT assert "exactly once across two offers".
        // That was the old local skip list, and it is what left a display with
        // no backend when the bridge legitimately re-offered a key. Not
        // oscillating between backends is the bridge's guarantee, pinned by
        // `a_refused_wallpaper_goes_back_to_the_engine_and_stays_there`: it
        // records the refusal and stops offering. The host's job is to answer
        // what it is actually offered.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(fps: 30)],
            refusal: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration"),
            recorder: recorder)

        await host.apply([wallpaper(fps: 30)])

        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.id, "300")
        XCTAssertTrue(recorder.rejected.first?.reason.contains("target frame rate") == true)
        XCTAssertTrue(host.isEmpty, "a refused wallpaper must not leave a window behind")
        host.shutdown()
    }

    func testTheRefusalTravelsWithTheKeyItWasDecidedAgainst() async {
        // A verdict that arrives after the user changed the target rate
        // describes a configuration that no longer exists. The bridge can only
        // tell that if the key is reported with the refusal.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [wallpaper(fps: 30, admissionKey: 0xBEEF)],
            refusal: .targetFrameRateBelowContent(target: 30, bound: 60, source: "nominalFrameRate"),
            recorder: recorder)

        await host.apply([wallpaper(fps: 30, admissionKey: 0xBEEF)])

        XCTAssertEqual(recorder.rejected.first?.key, 0xBEEF)
        host.shutdown()
    }

    func testChangingTheTargetRateIsEvaluatedAgainRatherThanStayingRefused() async {
        // The round-3 behaviour: once refused, refused for the session. Raising
        // the target to something the clip fits has to bring it back.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "nominalFrameRate")
            ],
            recorder: recorder)

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(fps: 60, admissionKey: 60)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the new configuration must be evaluated")
        XCTAssertEqual(recorder.rejected.count, 1, "and must not inherit the old verdict")
        host.shutdown()
    }

    func testLoweringTheTargetRateUnderARunningClipReEvaluatesIt() async {
        // The wallpaper id does not change, so round 4's first version kept
        // the player and only pushed the new descriptor at it: a 60 fps clip
        // carried on playing at 60 under a 30 fps target. Admission exists to
        // stop exactly that, so a changed admission key has to go through it.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration")
            ],
            recorder: recorder)
        await host.apply([wallpaper(fps: 60, admissionKey: 60)])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])

        XCTAssertTrue(
            host.isEmpty, "the accepted player must not survive a target it was never admitted for")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 30)
        XCTAssertEqual(recorder.stopped, 1, "and it must be stopped, not merely dropped")
        host.shutdown()
    }

    func testReplacingTheMediaAtTheSamePathReloadsTheSurface() async {
        // Same id, same path, different bytes — which the key covers through
        // the file's length and mtime. Keeping the player would go on showing
        // the file that is no longer there.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 1)])
        let first = host.surfaceGenerationForTest

        await host.apply([wallpaper(admissionKey: 2)])

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertNotEqual(
            host.surfaceGenerationForTest, first, "new media identity is a new surface")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(recorder.admissionProbes.count, 2, "and it is admitted again, not assumed")
        host.shutdown()
    }

    func testAnAssetThatFailsToPlayAfterAdmissionIsHandedToTheSceneEngine() async {
        // Metadata loading and playback are different things. A clip whose
        // track properties read cleanly can still fail to decode, and only the
        // player sees that. Without a hand-off the display shows black with
        // the scene engine excluded — both backends off one display.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(admissionKey: 9)])
        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertTrue(recorder.rejected.isEmpty, "admission accepted it")

        surfacesMade[7]?.failPreparation("decoder could not open the track")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(host.isEmpty, "the failed player must stop")
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 9)
        XCTAssertTrue(
            recorder.rejected.first?.reason.contains("could not play") == true,
            "the reason must say playback failed, not that the metadata was refused")
        host.shutdown()
    }

    func testAFailureOnTheFirstDisplayIsNotDiscardedBecauseASecondOpened() async {
        // `surfaceGeneration` is host-wide, so comparing a failure against it
        // discarded display 7's real failure the moment display 9 opened: that
        // display stayed native-selected with the scene engine excluded and
        // showed black. Staleness has to be surface identity, not a counter.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([
            wallpaper(displayID: 7, id: "300", admissionKey: 1),
            wallpaper(displayID: 9, id: "301", admissionKey: 2),
        ])
        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        let first = surfacesMade[7]

        first?.failPreparation("decoder could not open the track")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            host.activeDisplayIDs, [9],
            "the failing display must hand over; the other must keep playing")
        XCTAssertEqual(recorder.rejected.count, 1)
        XCTAssertEqual(recorder.rejected.first?.key, 1)
        host.shutdown()
    }

    func testASurfaceThatFailsWhileItsCallbackIsInstalledIsNeverPresented() async {
        // The player can already be holding a failure when the host installs
        // its callback, and installing delivers it synchronously — so the
        // hand-off closes this surface in the middle of opening it. Carrying on
        // to present() would order a stopped, unregistered window onto the
        // desktop: an orphan nothing owns and nothing can close.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        surfaceFailureOnInstall = "decoder could not open the track"

        await host.apply([wallpaper(admissionKey: 12)])
        // The hand-off is spawned from the failure callback, so let it drain.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.presented, 0, "a surface that failed on install must not be shown")
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(recorder.stopped, 1, "and it must have been stopped")
        XCTAssertEqual(recorder.rejected.count, 1, "the scene engine takes it")
        host.shutdown()
    }

    func testAPlaybackFailureFromAReplacedSurfaceIsIgnored() async {
        // The asynchronous twin of the poster case: a failure that arrives
        // after this display moved on must not condemn whatever is playing now.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        let stale = surfacesMade[7]
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        XCTAssertEqual(host.activeDisplayIDs, [7])

        stale?.failPreparation("late failure", generation: 1)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            host.activeDisplayIDs, [7], "the current wallpaper must still be playing")
        XCTAssertTrue(recorder.rejected.isEmpty, "and nothing may be handed back for it")
        host.shutdown()
    }

    func testATransientMetadataFailureIsRetriedRatherThanDemotingTheWallpaper() async {
        // A file still being written, or a busy volume, says nothing about
        // whether this backend can honour the content. Treating it as a
        // refusal would hand the wallpaper away for the whole session.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalSequence: [.preparationFailed("resource temporarily unavailable"), nil],
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 5)])

        XCTAssertEqual(host.activeDisplayIDs, [7], "the retry has to be allowed to succeed")
        XCTAssertTrue(recorder.rejected.isEmpty, "a transient failure is not a refusal")
        XCTAssertEqual(recorder.admissionProbes.count, 2)
        host.shutdown()
    }

    func testAPersistentMetadataFailureStopsRetryingAndHandsOff() async {
        // The other half of the bound: a file that never loads must not leave
        // the display with no wallpaper at all, and must not be re-read
        // forever.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .preparationFailed("input/output error"),
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 6)])
        await host.apply([wallpaper(admissionKey: 6)])

        XCTAssertEqual(
            recorder.admissionProbes.count, NativeVideoWallpaperHost.admissionAttemptLimit,
            "retries are bounded and the settled answer is cached, so the second offer "
                + "costs no further file reads")
        XCTAssertEqual(
            recorder.rejected.count, 2, "each offer is answered; the bridge is what stops offering")
        XCTAssertTrue(host.isEmpty)
        host.shutdown()
    }

    func testAKeyRefusedThenSupersededThenOfferedAgainIsReportedAgain() async {
        // The bridge prunes a refusal whose key no longer matches any live
        // display slot. Going 30 -> 60 -> 30 therefore brings key 30 back as a
        // fresh offer. A permanent local skip list made the host ignore it
        // while the bridge had already excluded the scene engine for that
        // display: no native surface, no scene, nothing on screen.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration")
            ],
            recorder: recorder)

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])
        XCTAssertEqual(recorder.rejected.count, 1)

        await host.apply([wallpaper(fps: 60, admissionKey: 60)])
        XCTAssertEqual(host.activeDisplayIDs, [7], "60 is admissible")

        await host.apply([wallpaper(fps: 30, admissionKey: 30)])

        XCTAssertTrue(host.isEmpty, "30 is still not admissible")
        XCTAssertEqual(
            recorder.rejected.count, 2,
            "the offer must be answered again, not silently skipped")
        XCTAssertEqual(recorder.rejected.last?.key, 30)
        host.shutdown()
    }

    func testARepeatedOfferOfAStillRefusedKeyIsAnsweredEachTimeItIsOffered() async {
        // The bridge stops offering a key once it records the refusal, so in
        // practice this does not repeat. What must not happen is the host
        // deciding on its own to stop answering: that is the state where the
        // two sides disagree and a display falls through the gap.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusal: .notPlayable("no video track"),
            recorder: recorder)

        await host.apply([wallpaper(admissionKey: 77)])
        await host.apply([wallpaper(admissionKey: 77)])

        XCTAssertEqual(recorder.rejected.count, 2)
        XCTAssertEqual(
            recorder.admissionProbes.count, 1,
            "but the file is still only read once, because the verdict is cached")
        host.shutdown()
    }

    func testAMirrorIsJudgedByItsGroupsStrictestTargetNotTheSourcesOwn() async {
        // A 60 fps clip on a source display targeting 60, mirrored to a display
        // targeting 30. The bridge gives both members the same admission key
        // and an admissionFps of 30 — the strictest in the group. Probing the
        // per-display `fps` instead would evaluate 60, accept, and then play
        // the mirror at 60 under a 30 fps target: the silent rate change
        // admission exists to prevent, reached through the one path that used
        // to skip admission entirely.
        let recorder = Recorder()
        let host = makeHost(
            wallpapers: [],
            refusalByKey: [
                30: .targetFrameRateBelowContent(target: 30, bound: 60, source: "minFrameDuration")
            ],
            recorder: recorder)

        await host.apply([
            wallpaper(displayID: 7, fps: 60, admissionFps: 30, admissionKey: 99),
            wallpaper(displayID: 9, fps: 30, admissionFps: 30, admissionKey: 99),
        ])

        XCTAssertEqual(recorder.admissionProbes, [30], "the group is probed at its strictest target")
        XCTAssertTrue(host.isEmpty, "neither member may play a rate the group cannot honour")
        XCTAssertFalse(recorder.rejected.isEmpty)
        XCTAssertTrue(
            recorder.rejected.allSatisfy { $0.key == 99 },
            "one key covers the group, so one recorded refusal sends all of it back")
        host.shutdown()
    }

    func testAMirrorGroupWithinTheClipsRateIsStillAdmitted() async {
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)

        await host.apply([
            wallpaper(displayID: 7, fps: 120, admissionFps: 60, admissionKey: 100),
            wallpaper(displayID: 9, fps: 60, admissionFps: 60, admissionKey: 100),
        ])

        XCTAssertEqual(host.activeDisplayIDs, [7, 9])
        XCTAssertEqual(recorder.admissionProbes, [60], "one probe covers the group")
        XCTAssertTrue(recorder.rejected.isEmpty)
        host.shutdown()
    }

    func testTheSameOfferIsProbedOnceEvenAcrossRepeatedPasses() async {
        // Reconcile runs on display changes, wallpaper changes and suspension
        // changes. Re-reading the media file on each of those would be a file
        // read per pass for a decision that cannot have changed.
        let recorder = Recorder()
        let host = makeHost(wallpapers: [], recorder: recorder)

        await host.apply([wallpaper(admissionKey: 11)])
        await host.apply([])
        await host.apply([wallpaper(admissionKey: 11)])

        XCTAssertEqual(recorder.admissionProbes.count, 1)
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
        XCTAssertTrue(recorder.rejected.first?.reason.contains("no video track") == true)
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

        await host.apply([wallpaper(id: "301", admissionKey: 2)])

        XCTAssertEqual(host.activeDisplayIDs, [7])
        XCTAssertNotEqual(
            host.surfaceGenerationForTest, firstGeneration,
            "a new wallpaper is a new surface, so its counters are not merged with the old one's")
        host.shutdown()
    }

    func testAPosterFromAReplacedSurfaceIsNotPublished() async {
        // The request outlives the wallpaper it was made against. Publishing
        // its frame would put the previous clip's picture under the new one.
        let recorder = Recorder()
        let center = NotificationCenter()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder, frameCenter: center)
        host.start()
        await host.apply([wallpaper(id: "300", admissionKey: 1)])
        surfacesMade[7]?.poster = Self.makeImage()
        surfacesMade[7]?.posterDelay = .milliseconds(60)

        var published: [UInt32] = []
        let observer = center.addObserver(
            forName: Notification.Name("MacWallpaperEngine.desktopPoster"), object: nil,
            queue: .main
        ) { note in
            if let id = note.userInfo?["displayID"] as? UInt32 { published.append(id) }
        }
        defer { center.removeObserver(observer) }

        center.post(
            name: Notification.Name("MacWallpaperEngine.requestDesktopPoster"), object: nil,
            userInfo: ["displayID": UInt32(7)])
        // Replace the wallpaper while the request is still in flight.
        await host.apply([wallpaper(id: "301", admissionKey: 2)])
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(
            published.isEmpty,
            "a frame produced by the surface that has been replaced must not be delivered")
        host.shutdown()
    }

    func testAPosterFromTheCurrentSurfaceIsPublished() async {
        let recorder = Recorder()
        let center = NotificationCenter()
        let host = makeHost(wallpapers: [wallpaper()], recorder: recorder, frameCenter: center)
        host.start()
        await host.apply([wallpaper()])
        surfacesMade[7]?.poster = Self.makeImage()

        var published: [UInt32] = []
        let observer = center.addObserver(
            forName: Notification.Name("MacWallpaperEngine.desktopPoster"), object: nil,
            queue: .main
        ) { note in
            if let id = note.userInfo?["displayID"] as? UInt32 { published.append(id) }
        }
        defer { center.removeObserver(observer) }

        center.post(
            name: Notification.Name("MacWallpaperEngine.requestDesktopPoster"), object: nil,
            userInfo: ["displayID": UInt32(7)])
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(published, [7])
        host.shutdown()
    }
}
