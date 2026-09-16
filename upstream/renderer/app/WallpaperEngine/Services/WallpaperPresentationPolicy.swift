import AppKit

/// Suspends the desktop renderer while no wallpaper pixel can reach a display.
/// Suspension never changes the user's Play/Pause choice: the bridge composes
/// this signal with the playback state and restores playback when it clears.
@MainActor
final class WallpaperPresentationPolicy {
    private let workspaceCenter: NotificationCenter
    private let lockCenter: NotificationCenter
    private let windowCenter: NotificationCenter
    private let isDesktopVisible: @MainActor () -> Bool
    private let isSessionLocked: @MainActor () -> Bool
    private let occlusionSettleDelay: Duration
    private let apply: @MainActor (Bool) -> Void

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaysAsleep = false
    private var settle: Task<Void, Never>?
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
        apply: @escaping @MainActor (Bool) -> Void
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

    static func desktopIsVisible() -> Bool {
        guard let type = NSClassFromString("MWEWallpaperDesktopWindow") else { return true }
        let windows = NSApp.windows.filter { $0.isKind(of: type) }
        // No wallpaper window means nothing to suspend.
        return windows.isEmpty || windows.contains { $0.occlusionState.contains(.visible) }
    }

    static func sessionIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
            ?? false
    }

    func evaluate() {
        let blocking = displaysAsleep || isSessionLocked()
        let hidden = !isDesktopVisible()
        let target = blocking || hidden
        settle?.cancel()
        settle = nil
        guard target != isSuspended else { return }
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
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        AppLog.info("presentation policy \(suspended ? "suspended" : "resumed")")
        apply(suspended)
    }
}
