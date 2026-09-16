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
            apply: { probe.applied.append($0) }
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
