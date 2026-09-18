import AVFoundation
import AppKit

/// Keeps one native video window per display in step with the bridge's
/// committed native video wallpapers.
///
/// This is the experimental backend's whole host side. The bridge decides
/// which wallpapers are eligible and stops giving them to the scene engine;
/// this host either plays them or hands them back. It never runs alongside the
/// scene engine for the same wallpaper, and it never silently substitutes a
/// setting it cannot honour.
@MainActor
final class NativeVideoWallpaperHost {
    private let fetch: @MainActor () async throws -> [BridgeNativeVideoWallpaper]
    private let reject: @MainActor (String, String) async throws -> Void
    private let screens: @MainActor () -> [(id: UInt32, frame: NSRect)]
    /// Decides whether a wallpaper can be honoured. Injected so the routing and
    /// fallback rules can be tested without an asset or a window server.
    private let refusal: @MainActor (URL, UInt32) async -> NativeVideoRefusal?
    /// Builds one display's surface. Injected so the routing and suspension
    /// rules can be exercised without opening a desktop window.
    private let makeSurface: @MainActor (URL, NSRect, RuntimeSurfaceKey, Bool) -> NativeVideoSurface
    private let counters: RuntimeCounters
    private let frameCenter: NotificationCenter

    private var surfaces: [UInt32: NativeVideoSurface] = [:]
    private var descriptors: [UInt32: BridgeNativeVideoWallpaper] = [:]
    /// Displays suspended on their own, kept apart from the global flag so one
    /// occluded screen cannot stop a video on a visible screen.
    private var suspendedDisplays: Set<UInt32> = []
    private var suspended = false
    /// Wallpapers already handed back, so one refusal is never reported twice
    /// and the two backends cannot pass a wallpaper between them.
    private var refused: Set<String> = []
    private var surfaceGeneration: UInt64 = 0
    private var reconcileInFlight = false
    private var reconcileRequested = false
    private var stopped = false
    private var posterObserver: NSObjectProtocol?

    var onError: (@MainActor (String) -> Void)?
    var onSurfacesChanged: (@MainActor () -> Void)?

    init(
        fetch: @escaping @MainActor () async throws -> [BridgeNativeVideoWallpaper],
        reject: @escaping @MainActor (String, String) async throws -> Void,
        screens: (@MainActor () -> [(id: UInt32, frame: NSRect)])? = nil,
        refusal: (@MainActor (URL, UInt32) async -> NativeVideoRefusal?)? = nil,
        makeSurface: (
            @MainActor (URL, NSRect, RuntimeSurfaceKey, Bool) -> NativeVideoSurface
        )? = nil,
        frameCenter: NotificationCenter = .default,
        counters: RuntimeCounters? = nil
    ) {
        self.fetch = fetch
        self.reject = reject
        self.screens = screens ?? { WebWallpaperHost.systemScreens() }
        self.refusal = refusal ?? { url, fps in
            await NativeVideoPlayer.refusal(for: url, targetFps: fps)
        }
        let sharedCounters = counters ?? .shared
        self.makeSurface = makeSurface ?? { url, frame, surface, paused in
            let player = NativeVideoPlayer(
                surface: surface, counters: sharedCounters, paused: paused)
            let window = NativeVideoWallpaperWindow(frame: frame, player: player)
            player.load(url: url)
            return window
        }
        self.frameCenter = frameCenter
        self.counters = counters ?? .shared
    }

    convenience init(bridge: WallpaperBridge) {
        self.init(
            fetch: { try await bridge.nativeVideoWallpapers() },
            reject: { id, reason in
                try await bridge.rejectNativeVideo(wallpaperId: id, reason: reason)
            })
    }

    var activeDisplayIDs: Set<UInt32> { Set(surfaces.keys) }
    var isEmpty: Bool { surfaces.isEmpty }

    /// Whether this display's player is running. The observable the suspension
    /// rules are argued from: a decision delivered is not a player stopped.
    func isPlaying(displayID: UInt32) -> Bool? {
        surfaces[displayID]?.isPlaying
    }

    var surfaceGenerationForTest: UInt64 { surfaceGeneration }

    func start() {
        guard posterObserver == nil else { return }
        posterObserver = frameCenter.addObserver(
            forName: Notification.Name("MacWallpaperEngine.requestDesktopPoster"),
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.answerPosterRequest(notification) }
        }
        stopped = false
    }

    /// Re-reads the committed native wallpapers and diffs them against open
    /// windows. Overlapping calls coalesce into one trailing pass.
    func reconcile() {
        guard !stopped else { return }
        guard !reconcileInFlight else {
            reconcileRequested = true
            return
        }
        reconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.reconcileInFlight = false
                if self.reconcileRequested {
                    self.reconcileRequested = false
                    self.reconcile()
                }
            }
            do {
                let wallpapers = try await self.fetch()
                guard !self.stopped else { return }
                await self.apply(wallpapers)
            } catch {
                AppLog.error("native video wallpapers could not be read: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    func apply(_ wallpapers: [BridgeNativeVideoWallpaper]) async {
        let screenFrames = Dictionary(
            screens().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var wanted: [UInt32: BridgeNativeVideoWallpaper] = [:]
        for wallpaper in wallpapers where screenFrames[wallpaper.displayId] != nil {
            wanted[wallpaper.displayId] = wallpaper
        }

        // Close first. A wallpaper that moved to another backend, or to another
        // display, must stop playing here before anything else starts, so the
        // clip is never decoded or heard twice.
        for (displayID, surface) in surfaces where wanted[displayID] == nil {
            close(displayID: displayID, surface: surface)
        }
        for (displayID, wallpaper) in wanted {
            if let existing = descriptors[displayID], existing.wallpaperId != wallpaper.wallpaperId,
                let surface = surfaces[displayID] {
                close(displayID: displayID, surface: surface)
            }
        }

        for (displayID, wallpaper) in wanted.sorted(by: { $0.key < $1.key }) {
            guard !refused.contains(wallpaper.wallpaperId) else { continue }
            if let surface = surfaces[displayID] {
                update(surface: surface, with: wallpaper, displayID: displayID)
                continue
            }
            guard let frame = screenFrames[displayID] else { continue }
            await open(wallpaper: wallpaper, displayID: displayID, frame: frame)
        }
        notifySurfacesChanged()
    }

    private func open(
        wallpaper: BridgeNativeVideoWallpaper, displayID: UInt32, frame: NSRect
    ) async {
        let url = URL(fileURLWithPath: wallpaper.mediaPath)
        // Decided before a window exists, so a refusal never shows a black
        // rectangle on the desktop.
        if let refusal = await refusal(url, wallpaper.fps) {
            await handOff(wallpaper: wallpaper, refusal: refusal)
            return
        }
        guard !stopped else { return }
        surfaceGeneration += 1
        let key = RuntimeSurfaceKey(
            kind: .desktopNativeVideo, displayID: displayID, generation: surfaceGeneration)
        let surface = makeSurface(url, frame, key, wallpaper.paused)
        surfaces[displayID] = surface
        descriptors[displayID] = wallpaper
        update(surface: surface, with: wallpaper, displayID: displayID)
        surface.present()
    }

    private func handOff(
        wallpaper: BridgeNativeVideoWallpaper, refusal: NativeVideoRefusal
    ) async {
        guard refused.insert(wallpaper.wallpaperId).inserted else { return }
        counters.record(
            .nativeVideoRefused,
            for: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 0))
        AppLog.warn(
            "native video wallpaper \(wallpaper.wallpaperId): \(refusal.reason); "
                + "falling back to the scene engine")
        do {
            try await reject(wallpaper.wallpaperId, refusal.reason)
        } catch {
            AppLog.error(
                "native video fallback for \(wallpaper.wallpaperId) failed: "
                    + error.localizedDescription)
            onError?(error.localizedDescription)
        }
    }

    private func update(
        surface: NativeVideoSurface, with wallpaper: BridgeNativeVideoWallpaper,
        displayID: UInt32
    ) {
        descriptors[displayID] = wallpaper
        surface.setVolume(wallpaper.volume, muted: wallpaper.muted)
        surface.setScaling(wallpaper.scalingMode)
        // The descriptor's paused flag already carries the user's own choice
        // and this display's suspension, as the activation rules combined them.
        surface.setUserPaused(wallpaper.paused)
        surface.setPresentationSuspended(suspended || suspendedDisplays.contains(displayID))
    }

    private func close(displayID: UInt32, surface: NativeVideoSurface) {
        surface.stop()
        surfaces.removeValue(forKey: displayID)
        descriptors.removeValue(forKey: displayID)
    }

    /// Global suspension: no display can show a wallpaper pixel at all.
    func setPresentationSuspended(_ value: Bool) {
        suspended = value
        for (displayID, surface) in surfaces {
            surface.setPresentationSuspended(value || suspendedDisplays.contains(displayID))
        }
    }

    /// One display's own suspension. A hidden screen must not stop a visible
    /// one, and resuming must not clear the global reason.
    func setPresentationSuspended(_ value: Bool, forDisplay displayID: UInt32) {
        if value {
            suspendedDisplays.insert(displayID)
        } else {
            suspendedDisplays.remove(displayID)
        }
        guard let surface = surfaces[displayID] else { return }
        surface.setPresentationSuspended(suspended || value)
    }

    func shutdown() {
        stopped = true
        if let posterObserver {
            frameCenter.removeObserver(posterObserver)
            self.posterObserver = nil
        }
        for (displayID, surface) in surfaces {
            close(displayID: displayID, surface: surface)
        }
        surfaces.removeAll()
        descriptors.removeAll()
    }

    /// Answers a desktop poster request from the player that is already
    /// running. A second player would decode the same clip twice.
    private func answerPosterRequest(_ notification: Notification) {
        guard let displayID = notification.userInfo?["displayID"] as? UInt32,
            let surface = surfaces[displayID]
        else { return }
        Task { @MainActor [weak self] in
            guard let image = await surface.posterImage(), self?.stopped == false else {
                return
            }
            self?.frameCenter.post(
                name: Notification.Name("MacWallpaperEngine.desktopPoster"), object: nil,
                userInfo: ["displayID": displayID, "image": image])
        }
    }

    private func notifySurfacesChanged() {
        onSurfacesChanged?()
    }
}
