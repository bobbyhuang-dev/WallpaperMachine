import AppKit
import XCTest
@testable import MacWallpaperEngine

@MainActor
private final class PolicyProbe {
    var applied: [Bool] = []
    var desktopVisible = true
    var sessionLocked = false
}

@MainActor
final class WallpaperPresentationPolicyTests: XCTestCase {
    private let workspaceCenter = NotificationCenter()
    private let lockCenter = NotificationCenter()
    private let windowCenter = NotificationCenter()

    private func makePolicy(
        _ probe: PolicyProbe,
        settle: Duration = .milliseconds(20)
    ) -> WallpaperPresentationPolicy {
        WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            isDesktopVisible: { probe.desktopVisible },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: settle,
            apply: { suspended, completion in
                probe.applied.append(suspended)
                completion(.success(()))
            }
        )
    }

    func testDisplaySleepSuspendsAndWakeResumes() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.applied, [], "A visible, unlocked desktop must keep rendering")

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.applied, [true], "Sleeping displays must suspend immediately")

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

        probe.desktopVisible = false
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertEqual(probe.applied, [], "A Space switch must not freeze the wallpaper instantly")

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.applied, [true], "A wallpaper hidden past the settle delay must stop rendering")
    }

    func testRevealingTheDesktopDuringTheSettleDelayNeverSuspends() async throws {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.desktopVisible = false
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        probe.desktopVisible = true

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.applied, [], "Mission Control passes must never reach the engine")
        XCTAssertFalse(policy.isSuspended)
    }

    func testReapplyingAfterCanceledShutdownResumesRenderer() {
        let probe = PolicyProbe()
        var acceptingUpdates = true
        var rendererSuspended = false
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            isDesktopVisible: { probe.desktopVisible },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            apply: { suspended, completion in
                guard acceptingUpdates else {
                    completion(.failure(CancellationError()))
                    return
                }
                rendererSuspended = suspended
                completion(.success(()))
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.desktopVisible = false
        policy.evaluate()
        XCTAssertTrue(rendererSuspended)

        acceptingUpdates = false
        probe.desktopVisible = true
        policy.evaluate()
        XCTAssertTrue(rendererSuspended, "Shutdown temporarily withholds bridge updates")

        acceptingUpdates = true
        policy.evaluate()
        XCTAssertFalse(rendererSuspended, "Canceling shutdown must deliver the withheld resume")
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
            isDesktopVisible: { probe.desktopVisible },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            apply: { suspended, completion in
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

        probe.desktopVisible = false
        policy.evaluate()
        XCTAssertTrue(rendererSuspended)

        probe.desktopVisible = true
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
            isDesktopVisible: { probe.desktopVisible },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            apply: { suspended, completion in
                requests.append(suspended)
                completions.append(completion)
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.desktopVisible = false
        policy.evaluate()
        probe.desktopVisible = true
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

    func testStopResumesASuspendedEngine() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.applied, [true])

        policy.stop()
        XCTAssertEqual(probe.applied.last, false, "Teardown must never leave the engine suspended")
        XCTAssertFalse(policy.isSuspended)
    }
}
