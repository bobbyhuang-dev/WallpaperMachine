import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
private final class PolicyProbe {
    /// Global decisions delivered to the bridge.
    var applied: [Bool] = []
    /// Per-display decisions, in delivery order.
    var appliedDisplays: [(display: UInt32, suspended: Bool)] = []
    var surfaces: [WallpaperSurfaceVisibility] = [
        WallpaperSurfaceVisibility(displayID: 1, isVisible: true)
    ]
    var sessionLocked = false

    func setVisible(_ visible: Bool, display: UInt32 = 1) {
        if let index = surfaces.firstIndex(where: { $0.displayID == display }) {
            surfaces[index] = WallpaperSurfaceVisibility(displayID: display, isVisible: visible)
        } else {
            surfaces.append(WallpaperSurfaceVisibility(displayID: display, isVisible: visible))
        }
    }

    func displayDecisions(for display: UInt32) -> [Bool] {
        appliedDisplays.filter { $0.display == display }.map(\.suspended)
    }
}

@MainActor
final class WallpaperPresentationPolicyTests: XCTestCase {
    private let workspaceCenter = NotificationCenter()
    private let lockCenter = NotificationCenter()
    private let windowCenter = NotificationCenter()

    private func makePolicy(
        _ probe: PolicyProbe,
        settle: Duration = .milliseconds(20),
        counters: RuntimeCounters? = nil
    ) -> WallpaperPresentationPolicy {
        WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: settle,
            counters: counters,
            applyGlobal: { suspended, completion in
                probe.applied.append(suspended)
                completion(.success(()))
            },
            applyDisplay: { display, suspended, completion in
                probe.appliedDisplays.append((display, suspended))
                completion(.success(()))
            }
        )
    }

    func testDisplaySleepSuspendsGloballyAndWakeResumes() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.applied, [], "A visible, unlocked desktop must keep rendering")

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.applied, [true], "Sleeping displays must suspend immediately")
        XCTAssertTrue(
            probe.appliedDisplays.isEmpty,
            "A condition that covers every screen is delivered once, not per display")

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(probe.applied, [true, false], "Waking displays must resume without delay")
    }

    func testSessionLockSuspendsWhileDesktopIsVisible() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        XCTAssertEqual(probe.applied, [true], "The lock screen hides the desktop even when its windows report visible")
    }

    func testFullOcclusionSuspendsOnlyAfterTheSettleDelay() async throws {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertEqual(probe.appliedDisplays.count, 0, "A Space switch must not freeze the wallpaper instantly")

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.displayDecisions(for: 1), [true], "A wallpaper hidden past the settle delay must stop rendering")
        XCTAssertEqual(probe.applied, [], "Occlusion is a per-display condition")
    }

    func testRevealingTheDesktopDuringTheSettleDelayNeverSuspends() async throws {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        probe.setVisible(true)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(probe.appliedDisplays.isEmpty, "Mission Control passes must never reach the engine")
        XCTAssertFalse(policy.isSuspended)
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
    }

    // MARK: - P01: per-display granularity

    func testHidingOneDisplayLeavesTheOtherRunning() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false, display: 2)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
        XCTAssertEqual(probe.displayDecisions(for: 1), [], "A visible display is never told to stop")
        XCTAssertEqual(probe.applied, [], "One hidden screen is not a global condition")
        XCTAssertFalse(policy.isSuspended)
    }

    func testBothDisplaysHiddenSuspendEachOnItsOwn() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false, display: 1)
        probe.setVisible(false, display: 2)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [1, 2])
        XCTAssertEqual(probe.displayDecisions(for: 1), [true])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
    }

    func testRevealingOneDisplayResumesOnlyThatDisplay() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: false),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [1, 2])

        probe.setVisible(true, display: 1)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 1), [true, false])
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true],
            "A visible consumer on one display must not resume a hidden one")
    }

    func testADisconnectedDisplayStopsCarryingState() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])

        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 1, isVisible: true)]
        policy.evaluate()
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true],
            "A display that went away needs no resume")
    }

    func testReconnectedDisplayIsReevaluatedRatherThanRememberedAsSuspended() {
        let probe = PolicyProbe()
        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 2, isVisible: false)]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])

        probe.surfaces = []
        policy.evaluate()
        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 2, isVisible: true)]
        policy.evaluate()
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true],
            "A hot-plugged display that comes back visible needs no new decision")
    }

    func testRapidHideAndRevealSettlesOnTheLastState() async throws {
        let probe = PolicyProbe()
        let policy = makePolicy(probe, settle: .milliseconds(20))
        policy.start()
        defer { policy.stop() }

        for _ in 0..<5 {
            probe.setVisible(false)
            policy.evaluate()
            probe.setVisible(true)
            policy.evaluate()
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(
            probe.appliedDisplays.isEmpty,
            "occlusion flapping must not produce a burst of transitions")
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
    }

    func testGlobalSuspensionDoesNotClearAPerDisplaySuspension() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(probe.applied, [true, false])
        XCTAssertEqual(
            policy.suspendedDisplayIDs, [2],
            "waking the displays must not resume a screen that is still covered")
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
    }

    func testCountersRecordEachDeliveredDecisionForItsOwnSurface() {
        let counters = RuntimeCounters()
        counters.startSession(duration: .seconds(60))
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero, counters: counters)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false, display: 2)
        policy.evaluate()
        probe.setVisible(true, display: 2)
        policy.evaluate()

        let hidden = RuntimeSurfaceKey(kind: .desktopScene, displayID: 2)
        let visible = RuntimeSurfaceKey(kind: .desktopScene, displayID: 1)
        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.value(.presentationSuspended, for: hidden), 1)
        XCTAssertEqual(snapshot.value(.presentationResumed, for: hidden), 1)
        XCTAssertEqual(snapshot.value(.presentationSuspended, for: visible), 0)
    }

    // MARK: - delivery serialization

    func testReapplyingAfterCanceledShutdownResumesRenderer() {
        let probe = PolicyProbe()
        var acceptingUpdates = true
        var rendererSuspended: [UInt32: Bool] = [:]
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { display, suspended, completion in
                guard acceptingUpdates else {
                    completion(.failure(CancellationError()))
                    return
                }
                rendererSuspended[display] = suspended
                completion(.success(()))
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        policy.evaluate()
        XCTAssertEqual(rendererSuspended[1], true)

        acceptingUpdates = false
        probe.setVisible(true)
        policy.evaluate()
        XCTAssertEqual(rendererSuspended[1], true, "Shutdown temporarily withholds bridge updates")

        acceptingUpdates = true
        policy.evaluate()
        XCTAssertEqual(rendererSuspended[1], false, "Canceling shutdown must deliver the withheld resume")
    }

    func testFailedResumeRetriesWithUnchangedVisibility() {
        let probe = PolicyProbe()
        var rendererSuspended = false
        var failResume = true
        var resumeAttempts = 0
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { _, suspended, completion in
                if !suspended {
                    resumeAttempts += 1
                    if failResume {
                        completion(.failure(NSError(domain: "AudioCapture", code: 1)))
                        return
                    }
                }
                rendererSuspended = suspended
                completion(.success(()))
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        policy.evaluate()
        XCTAssertTrue(rendererSuspended)

        probe.setVisible(true)
        policy.evaluate()
        XCTAssertTrue(rendererSuspended, "A failed audio restart leaves the renderer rolled back")
        XCTAssertEqual(resumeAttempts, 1, "A failed delivery must not retry in a busy loop")

        failResume = false
        policy.evaluate()
        XCTAssertFalse(rendererSuspended, "Unchanged visibility must retry the unacknowledged resume")
        XCTAssertEqual(resumeAttempts, 2)
        policy.evaluate()
        XCTAssertEqual(resumeAttempts, 2, "An acknowledged state must not be sent again")
    }

    func testVisibilityChangesWaitForInFlightAcknowledgement() {
        let probe = PolicyProbe()
        var requests: [Bool] = []
        var completions: [WallpaperPresentationPolicy.ApplyCompletion] = []
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { _, suspended, completion in
                requests.append(suspended)
                completions.append(completion)
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        policy.evaluate()
        probe.setVisible(true)
        policy.evaluate()
        policy.evaluate()
        XCTAssertEqual(requests, [true], "Only one transition may be outstanding")

        completions.removeFirst()(.success(()))
        XCTAssertEqual(requests, [true, false], "The newest visibility decision follows the acknowledgement")
        completions.removeFirst()(.success(()))
        policy.evaluate()
        XCTAssertEqual(requests, [true, false])
        XCTAssertTrue(completions.isEmpty)
    }

    func testStopResumesEverySuspendedSurface() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: false),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.applied, [true])
        XCTAssertEqual(policy.suspendedDisplayIDs, [1])

        policy.stop()
        XCTAssertEqual(probe.applied.last, false, "Teardown must never leave the engine suspended")
        XCTAssertFalse(policy.isSuspended)
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 1), [true, false],
            "Teardown must resume a display it had suspended")
    }
}
