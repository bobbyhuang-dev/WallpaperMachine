import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Encodes final renderer pixels, not a screen capture or a Workshop cover.
enum DesktopPosterEncoder {
    static func png(pixels: Data, width: Int, height: Int, bgra: Bool) throws -> Data {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1024 * 1024,
              pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let info = bgra
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}

struct DesktopPosterFrame: Sendable {
    var pixels: Data
    var width: Int
    var height: Int
    var bgra: Bool
}

/// `layer` identifies the surface: the renderer's `CAMetalLayer`, or a web
/// wallpaper view's backing layer. Its owner answers the poster request.
struct DesktopPosterSurface {
    var layer: CALayer
    var display: String
}

/// The first ready frame is submitted to all native desktop Spaces immediately.
/// Window enumeration and frame encoding are injected for headless regression
/// tests, including layer replacement and out-of-order completion.
@MainActor
final class DesktopWallpaperSync {
    private let ledger: DesktopWallpaperLedger
    private var frameObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var posters: [ObjectIdentifier: Data] = [:]
    private var revisions: [ObjectIdentifier: UInt64] = [:]
    private let surfaces: @MainActor () -> [DesktopPosterSurface]
    private let frameCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter?
    private let encode: @Sendable (DesktopPosterFrame) async throws -> Data
    private var retry: Task<Void, Never>?
    private var lastRefresh: ContinuousClock.Instant?
    private var coalesced: Task<Void, Never>?
    private static let refreshInterval: Duration = .milliseconds(500)
    private var stopped = false
    var isSuspended: Bool { stopped }

    convenience init(folder: URL) throws {
        try self.init(folder: folder, workspace: SystemDesktopPictureWorkspace(), surfaces: {
            WallpaperPresentationPolicy.wallpaperWindows().compactMap { window in
                guard let layer = window.contentView?.layer,
                      let screen = window.screen, let id = SystemDesktopPictureWorkspace.id(screen) else { return nil }
                return DesktopPosterSurface(layer: layer, display: id)
            }
        }, frameCenter: .default, workspaceCenter: NSWorkspace.shared.notificationCenter)
    }

    init(folder: URL, workspace: any DesktopPictureWorkspace,
         surfaces: @escaping @MainActor () -> [DesktopPosterSurface],
         frameCenter: NotificationCenter, workspaceCenter: NotificationCenter? = nil,
         encode: @escaping @Sendable (DesktopPosterFrame) async throws -> Data = { frame in
             try await Task.detached(priority: .userInitiated) {
                 try DesktopPosterEncoder.png(pixels: frame.pixels, width: frame.width, height: frame.height, bgra: frame.bgra)
             }.value
         }) throws {
        ledger = try DesktopWallpaperLedger(folder: folder, workspace: workspace)
        self.surfaces = surfaces
        self.frameCenter = frameCenter
        self.workspaceCenter = workspaceCenter
        self.encode = encode
    }

    func start() {
        guard frameObserver == nil, !stopped else { return }
        frameObserver = frameCenter.addObserver(
            forName: Notification.Name("MacWallpaperEngine.desktopPosterReady"), object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.receive(notification) }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            guard let workspaceCenter else { break }
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        guard !stopped else { return }
        let now = ContinuousClock.now
        if let last = lastRefresh, now - last < Self.refreshInterval {
            guard coalesced == nil else { return }
            let wait = Self.refreshInterval - (now - last)
            coalesced = Task { [weak self] in
                do { try await Task.sleep(for: wait) } catch { return }
                guard let self, !self.stopped else { return }
                self.coalesced = nil
                self.lastRefresh = ContinuousClock.now
                self.performRefresh()
            }
            return
        }
        lastRefresh = now
        performRefresh()
    }

    private func performRefresh() {
        guard !stopped else { return }
        // Request GPU pixels before potentially slow native Space enumeration
        // and journal I/O, so readback can overlap synchronization.
        // No debounce: an Apply must not wait for a 400 ms timer, another
        // snapshot, or an activeSpaceDidChange notification to request pixels.
        for surface in surfaces() {
            frameCenter.post(name: Notification.Name("MacWallpaperEngine.requestDesktopPoster"), object: surface.layer)
        }
        synchronizeAllSpaces()
    }

    func stop() {
        do { try stopAndRestore() } catch { report(error) }
    }

    /// Stop poster writes without restoring through the legacy image API. The
    /// native provider journals the current poster; keep its file and ledger
    /// alive until that provider releases ownership.
    func suspendForNativeProvider() {
        stopped = true
        retry?.cancel()
        coalesced?.cancel()
        coalesced = nil
        lastRefresh = nil
        if let frameObserver { frameCenter.removeObserver(frameObserver) }
        frameObserver = nil
        for observer in workspaceObservers { workspaceCenter?.removeObserver(observer) }
        workspaceObservers.removeAll()
        posters.removeAll()
        revisions.removeAll()
    }

    func stopAndRestore() throws {
        suspendForNativeProvider()
        try ledger.restoreAll()
    }

    private func receive(_ notification: Notification) {
        guard !stopped, let layer = notification.object as? CALayer,
              surfaces().contains(where: { $0.layer === layer }),
              let values = notification.userInfo,
              let pixels = values["pixels"] as? Data,
              let width = values["width"] as? Int, let height = values["height"] as? Int,
              let bgra = values["bgra"] as? Bool else { return }
        let key = ObjectIdentifier(layer)
        let revision = (revisions[key] ?? 0) &+ 1
        revisions[key] = revision
        let encode = self.encode
        Task(priority: .userInitiated) { [weak self, weak layer] in
            do {
                let png = try await encode(DesktopPosterFrame(pixels: pixels, width: width, height: height, bgra: bgra))
                guard let self, !self.stopped, let layer,
                      self.revisions[key] == revision,
                      self.surfaces().contains(where: { $0.layer === layer }) else { return }
                self.posters[key] = png
                self.synchronizeAllSpaces()
            } catch { self?.report(error) }
        }
    }

    private func synchronizeAllSpaces(attempt: Int = 0) {
        let surfaces = surfaces()
        let keys = Set(surfaces.map { ObjectIdentifier($0.layer) })
        posters = posters.filter { keys.contains($0.key) }
        revisions = revisions.filter { keys.contains($0.key) }
        var byDisplay: [String: Data] = [:]
        for surface in surfaces { byDisplay[surface.display] = posters[ObjectIdentifier(surface.layer)] }
        retry?.cancel()
        do {
            try ledger.synchronize(posters: byDisplay, liveDisplays: Set(surfaces.map(\.display)))
        } catch {
            report(error)
            // Retry native asynchronous acknowledgement/Space creation races,
            // not the initial update. Never require the user to visit a Space.
            guard attempt < 3, !stopped else { return }
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100 * (attempt + 1))) } catch { return }
                guard let self, !self.stopped else { return }
                self.synchronizeAllSpaces(attempt: attempt + 1)
            }
        }
    }

    private func report(_ error: Error) {
        // A native-poster failure must not stop live playback or show a modal.
        NSLog("[WE] Native desktop poster sync failed: %@", error.localizedDescription)
    }
}
