import AppKit

/// Visibility of the wallpaper surface on one display.
struct WallpaperSurfaceVisibility: Equatable, Sendable {
    let displayID: UInt32
    let isVisible: Bool
}

/// Suspends wallpaper presentation per display while no pixel from that display
/// can reach the user, and globally only for conditions that really do cover
/// every screen. Suspension never changes the user's Play/Pause choice: the
/// bridge composes this signal with the playback state and restores playback
/// when it clears.
///
/// The split matters for power: a window covering the wallpaper on one display
/// must stop that display's decoding and rendering, and must not stop a display
/// the user is still looking at.
@MainActor
final class WallpaperPresentationPolicy {
    typealias ApplyCompletion = @MainActor (Result<Void, Error>) -> Void

    private let workspaceCenter: NotificationCenter
    private let lockCenter: NotificationCenter
    private let windowCenter: NotificationCenter
    private let surfaces: @MainActor () -> [WallpaperSurfaceVisibility]
    private let isSessionLocked: @MainActor () -> Bool
    private let occlusionSettleDelay: Duration
    private let counters: RuntimeCounters
    private let applyGlobal: @MainActor (Bool, @escaping ApplyCompletion) -> Void
    private let applyDisplay: @MainActor (UInt32, Bool, @escaping ApplyCompletion) -> Void

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaysAsleep = false
    private var settle: Task<Void, Never>?
    private var appliedGlobal: Bool? = false
    /// Acknowledged state per display. A display with no entry has never been
    /// told anything, so it is presenting.
    private var appliedDisplays: [UInt32: Bool] = [:]
    /// Displays whose decision still has to reach the renderer, including one
    /// whose delivery failed; a later evaluation retries it.
    private var pendingDisplays: Set<UInt32> = []
    private var deliveryInFlight = false
    /// Conditions under which no display at all can present.
    private(set) var isSuspended = false
    /// Displays suspended on their own, by occlusion.
    private(set) var suspendedDisplayIDs: Set<UInt32> = []

    /// Closures are optional so their `@MainActor` defaults are built inside
    /// this (already `@MainActor`) initializer rather than in a default-argument
    /// expression evaluated in the caller's isolation.
    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        lockCenter: NotificationCenter = DistributedNotificationCenter.default(),
        windowCenter: NotificationCenter = .default,
        surfaces: (@MainActor () -> [WallpaperSurfaceVisibility])? = nil,
        isSessionLocked: (@MainActor () -> Bool)? = nil,
        occlusionSettleDelay: Duration = .seconds(1),
        counters: RuntimeCounters? = nil,
        applyGlobal: @escaping @MainActor (Bool, @escaping ApplyCompletion) -> Void,
        applyDisplay: @escaping @MainActor (UInt32, Bool, @escaping ApplyCompletion) -> Void
    ) {
        self.workspaceCenter = workspaceCenter
        self.lockCenter = lockCenter
        self.windowCenter = windowCenter
        self.surfaces = surfaces ?? { Self.systemSurfaces() }
        self.isSessionLocked = isSessionLocked ?? { Self.sessionIsLocked() }
        self.occlusionSettleDelay = occlusionSettleDelay
        self.counters = counters ?? .shared
        self.applyGlobal = applyGlobal
        self.applyDisplay = applyDisplay
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
        displaysAsleep = false
        // Teardown must never leave a surface suspended.
        pendingDisplays.formUnion(suspendedDisplayIDs)
        suspendedDisplayIDs.removeAll()
        isSuspended = false
        deliverPending()
    }

    /// Every window kind that hosts wallpaper pixels: the renderer's Metal
    /// window, the web wallpaper window, and the native video window. A backend
    /// missing from this list is invisible to occlusion tracking, so its
    /// display would never be suspended or resumed.
    static let wallpaperWindowClassNames = [
        "MWEWallpaperDesktopWindow",
        "MWEWebWallpaperDesktopWindow",
        "MWENativeVideoDesktopWindow",
    ]

    static func wallpaperWindows() -> [NSWindow] {
        let types = wallpaperWindowClassNames.compactMap(NSClassFromString)
        guard !types.isEmpty else { return [] }
        return NSApp.windows.filter { window in types.contains { window.isKind(of: $0) } }
    }

    /// Wallpaper visibility grouped by display. A display counts as visible
    /// when any of its wallpaper windows is visible, so a second window that
    /// AppKit reports as occluded cannot hide a live one.
    static func systemSurfaces() -> [WallpaperSurfaceVisibility] {
        var visibility: [UInt32: Bool] = [:]
        for window in wallpaperWindows() {
            guard let screen = window.screen,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let displayID = number.uint32Value
            let visible = window.occlusionState.contains(.visible)
            visibility[displayID] = (visibility[displayID] ?? false) || visible
        }
        return visibility
            .map { WallpaperSurfaceVisibility(displayID: $0.key, isVisible: $0.value) }
            .sorted { $0.displayID < $1.displayID }
    }

    static func sessionIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
            ?? false
    }

    /// Retry unacknowledged delivery even when visibility is unchanged.
    func evaluate() {
        let blocking = displaysAsleep || isSessionLocked()
        let current = surfaces()
        let hidden = Set(current.filter { !$0.isVisible }.map(\.displayID))
        let known = Set(current.map(\.displayID))
        settle?.cancel()
        settle = nil

        // Surfaces that no longer exist carry no state; a stale entry would keep
        // resending a decision for a display that is gone.
        appliedDisplays = appliedDisplays.filter { known.contains($0.key) }
        pendingDisplays.formIntersection(known)
        suspendedDisplayIDs.formIntersection(known)

        if blocking != isSuspended {
            commitGlobal(blocking)
            return
        }
        // Resume instantly; delay only occlusion-driven suspension so a Space
        // switch or a Mission Control pass does not freeze a visible wallpaper.
        let revealed = suspendedDisplayIDs.subtracting(hidden)
        let newlyHidden = hidden.subtracting(suspendedDisplayIDs)
        if !revealed.isEmpty {
            suspendedDisplayIDs.subtract(revealed)
            pendingDisplays.formUnion(revealed)
            AppLog.info("presentation resumed for displays \(revealed.sorted())")
            deliverPending()
            if newlyHidden.isEmpty { return }
        }
        guard !newlyHidden.isEmpty else {
            deliverPending()
            return
        }
        guard occlusionSettleDelay > .zero else {
            commitHidden(newlyHidden)
            return
        }
        settle = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.occlusionSettleDelay) } catch { return }
            guard !Task.isCancelled else { return }
            let stillHidden = Set(self.surfaces().filter { !$0.isVisible }.map(\.displayID))
            self.commitHidden(newlyHidden.intersection(stillHidden))
        }
    }

    private func commitGlobal(_ suspended: Bool) {
        if suspended != isSuspended {
            isSuspended = suspended
            AppLog.info("presentation \(suspended ? "suspended" : "resumed")")
        }
        deliverPending()
    }

    private func commitHidden(_ hidden: Set<UInt32>) {
        guard !hidden.isEmpty else {
            deliverPending()
            return
        }
        suspendedDisplayIDs.formUnion(hidden)
        pendingDisplays.formUnion(hidden)
        AppLog.info("presentation suspended for displays \(hidden.sorted())")
        deliverPending()
    }

    private func deliverPending() {
        guard !deliveryInFlight else { return }
        // The global condition is the coarser one, so it goes first.
        if appliedGlobal != isSuspended {
            let suspended = isSuspended
            deliveryInFlight = true
            applyGlobal(suspended) { [self] result in
                deliveryInFlight = false
                guard case .success = result else {
                    // A failed bridge transaction may have rolled rendering
                    // back. Keep it pending for a later evaluation, and stop
                    // here: retrying now would spin on a rejecting renderer.
                    appliedGlobal = nil
                    return
                }
                appliedGlobal = suspended
                record(suspended, for: RuntimeSurfaceKey(kind: .desktopScene, displayID: 0))
                // Deliveries are serialized, so the rest of the queue — and any
                // decision that changed while this one was in flight — follows
                // the acknowledgement.
                deliverPending()
            }
            return
        }
        for displayID in pendingDisplays.sorted() {
            let target = suspendedDisplayIDs.contains(displayID)
            guard appliedDisplays[displayID] != target else {
                pendingDisplays.remove(displayID)
                continue
            }
            deliveryInFlight = true
            applyDisplay(displayID, target) { [self] result in
                deliveryInFlight = false
                guard case .success = result else {
                    // Leave it pending. Retrying here would spin on a renderer
                    // that keeps rejecting the transition.
                    appliedDisplays[displayID] = nil
                    return
                }
                appliedDisplays[displayID] = target
                record(target, for: RuntimeSurfaceKey(kind: .desktopScene, displayID: displayID))
                // The decision may have changed while this one was in flight,
                // in which case the display stays pending and is sent again.
                if appliedDisplays[displayID] == suspendedDisplayIDs.contains(displayID) {
                    pendingDisplays.remove(displayID)
                }
                deliverPending()
            }
            return
        }
    }

    private func record(_ suspended: Bool, for surface: RuntimeSurfaceKey) {
        counters.record(suspended ? .presentationSuspended : .presentationResumed, for: surface)
    }
}
