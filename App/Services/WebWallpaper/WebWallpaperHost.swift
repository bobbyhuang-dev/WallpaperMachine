import AppKit
import WebKit

/// Keeps one desktop web view per display in step with the bridge's committed
/// web wallpapers. The renderer owns assignment, persistence and playback
/// state; this host only mirrors `webWallpapers()` into windows, pushes
/// property values into the pages, and answers desktop-poster requests.
@MainActor
final class WebWallpaperHost {
    private let fetch: @MainActor () async throws -> [BridgeWebWallpaper]
    private let screens: @MainActor () -> [(id: UInt32, frame: NSRect)]
    private let frameCenter: NotificationCenter
    private var windows: [UInt32: WebWallpaperWindow] = [:]
    private lazy var mouse = WebWallpaperMouseForwarder { [weak self] in
        guard let self else { return [] }
        return Array(self.windows.values)
    }
    private var descriptors: [UInt32: BridgeWebWallpaper] = [:]
    private var posterObserver: NSObjectProtocol?
    private var reconcileInFlight = false
    private var reconcileRequested = false
    private var suspended = false
    private var stopped = false
    /// Surfaced to the app the same way renderer failures are.
    var onError: (@MainActor (String) -> Void)?
    /// Fired after windows open, close, or finish loading their page, so the
    /// presentation policy and the desktop poster sync re-read the desktop.
    var onSurfacesChanged: (@MainActor () -> Void)?
    private var surfaceChangePending = false
    init(
        fetch: @escaping @MainActor () async throws -> [BridgeWebWallpaper],
        screens: (@MainActor () -> [(id: UInt32, frame: NSRect)])? = nil,
        frameCenter: NotificationCenter = .default
    ) {
        self.fetch = fetch
        self.screens = screens ?? { Self.systemScreens() }
        self.frameCenter = frameCenter
    }

    convenience init(bridge: WallpaperBridge) {
        self.init(fetch: { try await bridge.webWallpapers() })
    }

    static func systemScreens() -> [(id: UInt32, frame: NSRect)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.frame)
        }
    }

    var activeDisplayIDs: Set<UInt32> { Set(windows.keys) }
    var isEmpty: Bool { windows.isEmpty }

    func start() {
        guard posterObserver == nil else { return }
        posterObserver = frameCenter.addObserver(
            forName: Notification.Name("MacWallpaperEngine.requestDesktopPoster"), object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.answerPosterRequest(notification) }
        }
        stopped = false
    }

    /// Re-reads the committed web wallpapers and diffs them against open windows.
    /// Overlapping calls coalesce into one trailing pass.
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
                self.apply(wallpapers)
            } catch {
                AppLog.error("web wallpapers could not be read: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    func apply(_ wallpapers: [BridgeWebWallpaper]) {
        let screens = Dictionary(screens().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var next: [UInt32: BridgeWebWallpaper] = [:]
        for wallpaper in wallpapers where screens[wallpaper.displayId] != nil {
            next[wallpaper.displayId] = wallpaper
        }
        var changed = false
        for (displayID, window) in windows where next[displayID] == nil {
            close(window)
            windows[displayID] = nil
            descriptors[displayID] = nil
            changed = true
        }
        for (displayID, wallpaper) in next {
            guard let frame = screens[displayID] else { continue }
            let projectURL = URL(fileURLWithPath: wallpaper.projectPath, isDirectory: true)
            if let window = windows[displayID], window.page.projectURL == projectURL,
               window.page.entryURL.lastPathComponent == wallpaper.entryFile {
                if window.frame != frame {
                    window.setFrame(frame, display: true)
                    changed = true
                }
                push(wallpaper, into: window.page, previous: descriptors[displayID])
            } else {
                if let window = windows[displayID] { close(window) }
                let page = WebWallpaperPage(projectURL: projectURL, entryFile: wallpaper.entryFile)
                page.onFailure = { [weak self] message in
                    AppLog.error("web wallpaper \(wallpaper.wallpaperId) on display \(displayID): \(message)")
                    self?.onError?(String(localized: "Web wallpaper “\(wallpaper.title)” could not load: \(message)"))
                }
                page.onLoaded = { [weak self] in self?.scheduleSurfaceChange() }
                let window = WebWallpaperWindow(frame: frame, page: page)
                windows[displayID] = window
                push(wallpaper, into: page, previous: nil)
                page.load()
                window.orderFrontRegardless()
                AppLog.info("web wallpaper \(wallpaper.wallpaperId) opened on display \(displayID)")
                changed = true
            }
            descriptors[displayID] = wallpaper
        }
        mouse.setActive(!windows.isEmpty)
        if changed { onSurfacesChanged?() }
    }

    /// A page reports `didFinish` before its first meaningful paint, so the
    /// poster is re-read once immediately and once after the page has had time
    /// to render its initial frame.
    private func scheduleSurfaceChange() {
        onSurfacesChanged?()
        guard !surfaceChangePending else { return }
        surfaceChangePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.surfaceChangePending = false
            guard !self.stopped else { return }
            self.onSurfacesChanged?()
        }
    }

    private func push(_ wallpaper: BridgeWebWallpaper, into page: WebWallpaperPage, previous: BridgeWebWallpaper?) {
        if previous?.propertiesJson != wallpaper.propertiesJson {
            page.applyUserProperties(json: wallpaper.propertiesJson)
        }
        if previous?.fps != wallpaper.fps {
            page.applyGeneralProperties(fps: wallpaper.fps)
        }
        if previous?.paused != wallpaper.paused {
            page.setPaused(wallpaper.paused)
        }
        page.setPresentationSuspended(suspended)
    }

    /// Mirrors `WallpaperPresentationPolicy`: pages pause while no pixel can
    /// reach a display, without touching the user's play/pause choice.
    func setPresentationSuspended(_ suspended: Bool) {
        self.suspended = suspended
        for window in windows.values { window.page.setPresentationSuspended(suspended) }
    }

    func shutdown() {
        stopped = true
        if let posterObserver {
            frameCenter.removeObserver(posterObserver)
            self.posterObserver = nil
        }
        mouse.setActive(false)
        for window in windows.values { close(window) }
        windows.removeAll()
        descriptors.removeAll()
    }

    private func close(_ window: WebWallpaperWindow) {
        window.page.stop()
        window.orderOut(nil)
        window.close()
    }

    /// `DesktopWallpaperSync` asks each desktop surface for pixels by its layer.
    /// A web surface answers with a `WKWebView` snapshot in the same RGBA
    /// contract the renderer uses, so Space posters match the live page.
    private func answerPosterRequest(_ notification: Notification) {
        guard let layer = notification.object as? CALayer,
              let window = windows.values.first(where: { $0.contentView?.layer === layer }) else { return }
        let webView = window.page.webView
        let center = frameCenter
        webView.takeSnapshot(with: nil) { image, error in
            MainActor.assumeIsolated {
                guard let image else {
                    if let error { AppLog.warn("web wallpaper poster snapshot failed: \(error.localizedDescription)") }
                    return
                }
                guard let frame = Self.rgbaPixels(of: image) else { return }
                center.post(name: Notification.Name("MacWallpaperEngine.desktopPosterReady"), object: layer,
                            userInfo: ["pixels": frame.pixels, "width": frame.width, "height": frame.height, "bgra": false])
            }
        }
    }

    static func rgbaPixels(of image: NSImage) -> (pixels: Data, width: Int, height: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
