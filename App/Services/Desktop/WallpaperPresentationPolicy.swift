import AppKit

/// Suspends the desktop renderer while no wallpaper pixel can reach a display.
/// Suspension never changes the user's Play/Pause choice: the bridge composes
/// this signal with the playback state and restores playback when it clears.
@MainActor
final class WallpaperPresentationPolicy {
    typealias ApplyCompletion = @MainActor (Result<Void, Error>) -> Void

    private let workspaceCenter: NotificationCenter
    private let lockCenter: NotificationCenter
    private let windowCenter: NotificationCenter
    private let isDesktopVisible: @MainActor () -> Bool
    private let isSessionLocked: @MainActor () -> Bool
    private let occlusionSettleDelay: Duration
    private let apply: @MainActor (Bool, @escaping ApplyCompletion) -> Void

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaysAsleep = false
    private var settle: Task<Void, Never>?
    private var appliedSuspension: Bool? = false
    private var deliveryInFlight = false
    private(set) var isSuspended = false

    /// Closures are optional so their `@MainActor` defaults are built inside
    /// this (already `@MainActor`) initializer rather than in a default-argument
    /// expression evaluated in the caller's isolation.
    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        lockCenter: NotificationCenter = DistributedNotificationCenter.default(),
        windowCenter: NotificationCenter = .default,
        isDesktopVisible: (@MainActor () -> Bool)? = nil,
        isSessionLocked: (@MainActor () -> Bool)? = nil,
        occlusionSettleDelay: Duration = .seconds(1),
        apply: @escaping @MainActor (Bool, @escaping ApplyCompletion) -> Void
    ) {
        self.workspaceCenter = workspaceCenter
        self.lockCenter = lockCenter
        self.windowCenter = windowCenter
        self.isDesktopVisible = isDesktopVisible ?? { Self.desktopIsVisible() }
        self.isSessionLocked = isSessionLocked ?? { Self.sessionIsLocked() }
        self.occlusionSettleDelay = occlusionSettleDelay
        self.apply = apply
    }

    func start() {
        guard observers.isEmpty else { return }
        for (name, asleep) in [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
        ] {
            observers.append((workspaceCenter, workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displaysAsleep = asleep
                    self?.evaluate()
                }
            }))
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append((lockCenter, lockCenter.addObserver(
                forName: .init(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }))
        }
        // object: nil — the control panel appearing over the desktop is exactly
        // what changes a wallpaper window's occlusion, and evaluate() recomputes
        // from every wallpaper window anyway.
        observers.append((windowCenter, windowCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }))
        evaluate()
    }

    func stop() {
        settle?.cancel()
        settle = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        commit(false)
    }

    /// Both window kinds host wallpaper pixels: the renderer's Metal window and
    /// the app's web wallpaper window.
    static let wallpaperWindowClassNames = ["MWEWallpaperDesktopWindow", "MWEWebWallpaperDesktopWindow"]

    static func wallpaperWindows() -> [NSWindow] {
        let types = wallpaperWindowClassNames.compactMap(NSClassFromString)
        guard !types.isEmpty else { return [] }
        return NSApp.windows.filter { window in types.contains { window.isKind(of: $0) } }
    }

    static func desktopIsVisible() -> Bool {
        let windows = wallpaperWindows()
        // No wallpaper window means nothing to suspend.
        return windows.isEmpty || windows.contains { $0.occlusionState.contains(.visible) }
    }

    static func sessionIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
            ?? false
    }

    /// Retry unacknowledged delivery even when desktop visibility is unchanged.
    func evaluate() {
        let blocking = displaysAsleep || isSessionLocked()
        let hidden = !isDesktopVisible()
        let target = blocking || hidden
        settle?.cancel()
        settle = nil
        guard target != isSuspended else {
            deliverPending()
            return
        }
        // Resume instantly; delay only occlusion-driven suspension so a Space
        // switch or a Mission Control pass does not freeze a visible wallpaper.
        guard target, !blocking, occlusionSettleDelay > .zero else {
            commit(target)
            return
        }
        settle = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.occlusionSettleDelay) } catch { return }
            guard !Task.isCancelled, !self.isDesktopVisible() else { return }
            self.commit(true)
        }
    }

    private func commit(_ suspended: Bool) {
        if suspended != isSuspended {
            isSuspended = suspended
            AppLog.info("presentation policy \(suspended ? "suspended" : "resumed")")
        }
        deliverPending()
    }

    private func deliverPending() {
        guard !deliveryInFlight, appliedSuspension != isSuspended else { return }
        let suspended = isSuspended
        deliveryInFlight = true
        apply(suspended) { [self] result in
            deliveryInFlight = false
            if case .success = result {
                appliedSuspension = suspended
            } else {
                // A failed bridge transaction may have rolled rendering back.
                // Keep it pending until a later evaluation retries delivery.
                appliedSuspension = nil
            }
            // Serialize transitions so a late acknowledgement cannot overwrite
            // a newer visibility decision. Do not spin on a failed same-state call.
            if isSuspended != suspended { deliverPending() }
        }
    }
}
