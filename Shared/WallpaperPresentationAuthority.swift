import Foundation

/// Who is allowed to keep presenting a wallpaper surface, and why not.
///
/// The desktop application and the lock-screen extension are separate processes
/// that each own surfaces for the same displays. Deciding "may this surface keep
/// rendering" in one place, compiled into both targets, is what keeps a preview
/// or a lock-screen instance from quietly rendering for nobody while another
/// process is the one actually on screen.
///
/// Reasons are reported as a set rather than a single verdict: clearing one
/// never clears another, and the user's own pause is deliberately one of them so
/// that becoming visible again cannot resume a wallpaper the user stopped.
enum WallpaperPresentationAuthority {
  /// What a surface is for. The desktop is owned by the application's
  /// presentation policy; these are the roles the extension hosts.
  enum SurfaceRole: Sendable {
    /// A surface the lock screen itself shows.
    case lockScreen
    /// A surface a settings or gallery UI shows while the user is choosing.
    case preview
  }

  /// The host's own activity state for a surface, as reported by the
  /// wallpaper extension point.
  enum HostActivity: Sendable {
    case active
    case suspended
  }

  struct SuspensionReasons: OptionSet, Sendable {
    let rawValue: Int

    /// The user paused playback. Independent of everything else here.
    static let userPaused = SuspensionReasons(rawValue: 1 << 0)
    static let displaysAsleep = SuspensionReasons(rawValue: 1 << 1)
    /// The host told us this surface is no longer active.
    static let hostSuspended = SuspensionReasons(rawValue: 1 << 2)
    /// Nothing is showing this surface: the session is not locked and the host
    /// is not presenting the lock screen.
    static let noConsumer = SuspensionReasons(rawValue: 1 << 3)
    /// A preview had its animated look and has now had long enough.
    static let previewBudgetSpent = SuspensionReasons(rawValue: 1 << 4)
  }

  /// Everything the decision depends on. Grouped so a caller cannot forget one
  /// condition and silently get a permissive answer.
  struct Request: Sendable {
    var role: SurfaceRole
    /// The user's Play/Pause choice for this wallpaper.
    var userPaused: Bool
    var displaysAsleep: Bool
    /// Whether the login session is showing the lock screen.
    var sessionLocked: Bool
    /// The host's presentation mode string for this surface, lowercased by the
    /// caller. `locked` and `idle` are the modes in which the lock screen is
    /// what the user is looking at.
    var presentationMode: String
    var hostActivity: HostActivity
    /// How long this surface has been presenting since its first frame, or nil
    /// while it is still producing that frame.
    var presentedFor: Duration?
    /// An explicit request to keep a preview animating for as long as it exists,
    /// for a UI that really does want continuous motion.
    var continuousPreviewRequested: Bool

    init(
      role: SurfaceRole,
      userPaused: Bool = false,
      displaysAsleep: Bool = false,
      sessionLocked: Bool = false,
      presentationMode: String = "active",
      hostActivity: HostActivity = .active,
      presentedFor: Duration? = nil,
      continuousPreviewRequested: Bool = false
    ) {
      self.role = role
      self.userPaused = userPaused
      self.displaysAsleep = displaysAsleep
      self.sessionLocked = sessionLocked
      self.presentationMode = presentationMode
      self.hostActivity = hostActivity
      self.presentedFor = presentedFor
      self.continuousPreviewRequested = continuousPreviewRequested
    }
  }

  /// How long a preview may animate before it holds its last frame. Long enough
  /// to show what the wallpaper does, short enough that a settings window left
  /// open does not render indefinitely.
  static let previewBudget: Duration = .seconds(10)

  /// Presentation modes in which the lock screen is what the display shows.
  static let presentingModes: Set<String> = ["locked", "idle"]

  /// Every reason this surface may not keep presenting. An empty set means it
  /// may. Producing the first frame is never one of the reasons: readiness has
  /// to be allowed to render, which is exactly why it must not also grant the
  /// right to keep rendering afterwards.
  static func suspensionReasons(for request: Request) -> SuspensionReasons {
    var reasons: SuspensionReasons = []
    if request.userPaused { reasons.insert(.userPaused) }
    if request.displaysAsleep { reasons.insert(.displaysAsleep) }
    if request.hostActivity == .suspended { reasons.insert(.hostSuspended) }

    switch request.role {
    case .lockScreen:
      let showing =
        request.sessionLocked || presentingModes.contains(request.presentationMode)
      if !showing { reasons.insert(.noConsumer) }
    case .preview:
      // A preview is its own consumer while the user is looking at it, so it is
      // not gated on the session being locked. What bounds it is time.
      if !request.continuousPreviewRequested,
        let presentedFor = request.presentedFor, presentedFor >= previewBudget
      {
        reasons.insert(.previewBudgetSpent)
      }
    }
    return reasons
  }

  /// Whether this surface may render now. A surface that is still producing its
  /// first frame is answered on the same conditions as any other: readiness is
  /// requested separately by the caller and is not a presentation right.
  static func mayPresent(_ request: Request) -> Bool {
    suspensionReasons(for: request).isEmpty
  }

  /// When the decision for this surface will change on its own, so the caller
  /// can re-evaluate then instead of polling. Only a preview has such a moment.
  static func nextReevaluation(for request: Request) -> Duration? {
    guard request.role == .preview, !request.continuousPreviewRequested,
      let presentedFor = request.presentedFor, presentedFor < previewBudget
    else { return nil }
    return previewBudget - presentedFor
  }
}
