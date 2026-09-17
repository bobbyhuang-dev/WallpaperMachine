import XCTest

@testable import MacWallpaperEngine

/// Presentation eligibility for the surfaces the lock-screen extension hosts.
/// The rules are shared with the extension target, so these cases bind what
/// that process does even though the extension's own code cannot be imported
/// into a test hosted in the application.
final class WallpaperPresentationAuthorityTests: XCTestCase {
  private typealias Authority = WallpaperPresentationAuthority
  private typealias Reasons = WallpaperPresentationAuthority.SuspensionReasons

  // MARK: - lock-screen surfaces

  func testALockScreenSurfacePresentsOnlyWhileTheLockScreenIsShowing() {
    XCTAssertTrue(
      Authority.mayPresent(.init(role: .lockScreen, sessionLocked: true)),
      "a locked session is looking at this surface")
    for mode in ["locked", "idle"] {
      XCTAssertTrue(
        Authority.mayPresent(.init(role: .lockScreen, presentationMode: mode)),
        "the host says it is presenting the lock screen (\(mode))")
    }
    for mode in ["active", "inactive", "unknown", ""] {
      XCTAssertEqual(
        Authority.suspensionReasons(for: .init(role: .lockScreen, presentationMode: mode)),
        .noConsumer,
        "an unlocked session with mode \(mode) has nobody watching this surface")
    }
  }

  func testUnlockingStopsALockScreenSurface() {
    let locked = Authority.Request(role: .lockScreen, sessionLocked: true, presentationMode: "locked")
    XCTAssertTrue(Authority.mayPresent(locked))

    var unlocked = locked
    unlocked.sessionLocked = false
    unlocked.presentationMode = "active"
    XCTAssertEqual(Authority.suspensionReasons(for: unlocked), .noConsumer)
  }

  func testDisplaySleepAndHostSuspensionStopEvenAVisibleLockScreen() {
    let showing = Authority.Request(role: .lockScreen, sessionLocked: true)
    XCTAssertTrue(Authority.mayPresent(showing))

    var asleep = showing
    asleep.displaysAsleep = true
    XCTAssertEqual(Authority.suspensionReasons(for: asleep), .displaysAsleep)

    var suspended = showing
    suspended.hostActivity = .suspended
    XCTAssertEqual(Authority.suspensionReasons(for: suspended), .hostSuspended)
  }

  // MARK: - the user's pause stays its own reason

  func testAUserPauseIsIndependentOfVisibility() {
    var request = Authority.Request(role: .lockScreen, userPaused: true, sessionLocked: true)
    XCTAssertEqual(
      Authority.suspensionReasons(for: request), .userPaused,
      "a visible surface the user paused stays paused for that reason alone")

    // Losing and regaining visibility must not clear the user's choice.
    request.sessionLocked = false
    XCTAssertEqual(Authority.suspensionReasons(for: request), [.userPaused, .noConsumer])
    request.sessionLocked = true
    XCTAssertEqual(Authority.suspensionReasons(for: request), .userPaused)

    request.userPaused = false
    XCTAssertTrue(Authority.mayPresent(request), "only the user clears the user's pause")
  }

  func testEveryReasonIsReportedRatherThanTheFirstOne() {
    let request = Authority.Request(
      role: .lockScreen, userPaused: true, displaysAsleep: true, sessionLocked: false,
      presentationMode: "active", hostActivity: .suspended)
    XCTAssertEqual(
      Authority.suspensionReasons(for: request),
      [.userPaused, .displaysAsleep, .hostSuspended, .noConsumer])
  }

  // MARK: - preview surfaces

  func testAPreviewAnimatesForItsBudgetAndThenHoldsItsLastFrame() {
    // A preview is its own consumer, so it starts presenting on an unlocked
    // session, which is the whole point of a preview.
    XCTAssertTrue(
      Authority.mayPresent(.init(role: .preview, presentedFor: .zero)),
      "a fresh preview animates without the session being locked")
    XCTAssertTrue(
      Authority.mayPresent(
        .init(role: .preview, presentedFor: Authority.previewBudget - .milliseconds(1))))

    XCTAssertEqual(
      Authority.suspensionReasons(for: .init(role: .preview, presentedFor: Authority.previewBudget)),
      .previewBudgetSpent,
      "a preview left open must stop animating instead of rendering indefinitely")
    XCTAssertEqual(
      Authority.suspensionReasons(
        for: .init(role: .preview, presentedFor: Authority.previewBudget + .seconds(600))),
      .previewBudgetSpent)
  }

  func testTheReadinessFrameDoesNotBuyAPreviewPermanentPlayback() {
    // While the first frame is still being produced there is no elapsed time
    // yet, and the surface is allowed to render it.
    let readiness = Authority.Request(role: .preview, presentedFor: nil)
    XCTAssertTrue(Authority.mayPresent(readiness))

    // Once that frame has been presented, the same surface is judged on time,
    // so rendering for readiness cannot become an open-ended right.
    var presenting = readiness
    presenting.presentedFor = Authority.previewBudget
    XCTAssertFalse(Authority.mayPresent(presenting))
  }

  func testAnExplicitContinuousPreviewIsNotBounded() {
    let request = Authority.Request(
      role: .preview, presentedFor: Authority.previewBudget + .seconds(60),
      continuousPreviewRequested: true)
    XCTAssertTrue(
      Authority.mayPresent(request),
      "a UI that asks for continuous motion keeps it")

    var paused = request
    paused.userPaused = true
    XCTAssertEqual(
      Authority.suspensionReasons(for: paused), .userPaused,
      "continuous preview does not override the user's pause")
  }

  func testAPreviewStopsImmediatelyWhenItsHostGoesAway() {
    let request = Authority.Request(
      role: .preview, hostActivity: .suspended, presentedFor: .milliseconds(1))
    XCTAssertEqual(
      Authority.suspensionReasons(for: request), .hostSuspended,
      "a closed preview must not wait out its budget before stopping")
  }

  func testAPreviewIsNotGatedOnTheSessionBeingLocked() {
    XCTAssertEqual(
      Authority.suspensionReasons(for: .init(role: .preview, presentedFor: .zero)), [],
      "gating a preview on the lock screen would leave the picker showing a still image")
  }

  // MARK: - scheduled re-evaluation

  func testOnlyAPreviewSchedulesItsOwnExpiry() {
    XCTAssertNil(
      Authority.nextReevaluation(for: .init(role: .lockScreen, sessionLocked: true)),
      "a lock-screen surface changes state on an event, not on a timer")
    XCTAssertNil(
      Authority.nextReevaluation(
        for: .init(role: .preview, presentedFor: nil)),
      "a surface that has not presented yet has no deadline")
    XCTAssertNil(
      Authority.nextReevaluation(
        for: .init(
          role: .preview, presentedFor: .zero, continuousPreviewRequested: true)))
    XCTAssertNil(
      Authority.nextReevaluation(
        for: .init(role: .preview, presentedFor: Authority.previewBudget)),
      "an expired preview has nothing left to wait for")

    let halfway = Authority.previewBudget / 2
    XCTAssertEqual(
      Authority.nextReevaluation(for: .init(role: .preview, presentedFor: halfway)),
      Authority.previewBudget - halfway,
      "the remaining budget is what the caller waits for")
  }
}
