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
        let info = bgra
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
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

@MainActor
private final class SystemDesktopPictureWorkspace: DesktopPictureWorkspace {
    static func id(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }

    private func screen(_ display: String) -> NSScreen? {
        NSScreen.screens.first { Self.id($0) == display }
    }

    func currentPicture(display: String) -> DesktopPicture? {
        guard let screen = screen(display), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return DesktopPicture(url: url,
                              scaling: (options[.imageScaling] as? NSNumber)?.intValue ?? Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                              allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true,
                              fill: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent])
    }

    func setPicture(_ picture: DesktopPicture, display: String) throws {
        guard let screen = screen(display) else { return }
        try NSWorkspace.shared.setDesktopImageURL(picture.url, for: screen, options: picture.options)
    }
}

/// Mirrors renderer output into the native wallpaper used by Mission Control.
/// Public NSWorkspace APIs update the active Space only; inactive Spaces are
/// synchronized when the user visits them. Never switches Spaces, edits Apple's
/// private wallpaper database, or restarts Dock/WallpaperAgent.
@MainActor
final class DesktopWallpaperSync {
    private let ledger: DesktopWallpaperLedger
    private var frameObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var posters: [ObjectIdentifier: Data] = [:]
    private var revisions: [ObjectIdentifier: UInt64] = [:]
    private var pendingRefresh: Task<Void, Never>?
    private var stopped = false

    init(folder: URL) throws {
        ledger = try DesktopWallpaperLedger(folder: folder, workspace: SystemDesktopPictureWorkspace())
    }

    func start() {
        frameObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("MacWallpaperEngine.desktopPosterReady"), object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.receive(notification) }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        guard !stopped else { return }
        synchronizeCurrentSpace()
        pendingRefresh?.cancel()
        // Let bridge mutations, layer swaps and Space transitions settle.
        pendingRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, !self.stopped else { return }
            self.synchronizeCurrentSpace()
            for window in self.wallpaperWindows {
                if let layer = window.contentView?.layer {
                    NotificationCenter.default.post(name: Notification.Name("MacWallpaperEngine.requestDesktopPoster"), object: layer)
                }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pendingRefresh?.cancel()
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        for screen in NSScreen.screens {
            guard let id = SystemDesktopPictureWorkspace.id(screen) else { continue }
            do { try ledger.restore(display: id) } catch { report(error) }
        }
        // Inactive Spaces retain their poster until next visited while the app
        // is running. The persistent ledger preserves their original settings.
        posters.removeAll()
        revisions.removeAll()
    }

    private var wallpaperWindows: [NSWindow] {
        guard let type = NSClassFromString("MWEWallpaperDesktopWindow") else { return [] }
        return NSApp.windows.filter { $0.isKind(of: type) && $0.contentView?.layer is CAMetalLayer }
    }

    private func receive(_ notification: Notification) {
        guard !stopped, let layer = notification.object as? CAMetalLayer,
              wallpaperWindows.contains(where: { $0.contentView?.layer === layer }),
              let values = notification.userInfo,
              let pixels = values["pixels"] as? Data,
              let width = values["width"] as? Int, let height = values["height"] as? Int,
              let bgra = values["bgra"] as? Bool else { return }
        let key = ObjectIdentifier(layer)
        let revision = (revisions[key] ?? 0) &+ 1
        revisions[key] = revision
        Task { [weak self, weak layer] in
            do {
                let png = try await Task.detached(priority: .utility) {
                    try DesktopPosterEncoder.png(pixels: pixels, width: width, height: height, bgra: bgra)
                }.value
                guard let self, !self.stopped, let layer,
                      self.revisions[key] == revision,
                      self.wallpaperWindows.contains(where: { $0.contentView?.layer === layer }) else { return }
                self.posters[key] = png
                self.synchronizeCurrentSpace()
            } catch { self?.report(error) }
        }
    }

    private func synchronizeCurrentSpace() {
        let windows = wallpaperWindows
        let keys = Set(windows.compactMap { $0.contentView?.layer.map(ObjectIdentifier.init) })
        posters = posters.filter { keys.contains($0.key) }
        revisions = revisions.filter { keys.contains($0.key) }
        for screen in NSScreen.screens {
            guard let id = SystemDesktopPictureWorkspace.id(screen) else { continue }
            do {
                if let window = windows.first(where: { $0.screen.flatMap(SystemDesktopPictureWorkspace.id) == id }),
                   let layer = window.contentView?.layer {
                    if let png = posters[ObjectIdentifier(layer)] { try ledger.apply(png: png, display: id) }
                } else {
                    try ledger.restore(display: id)
                }
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        // A native-poster failure must not stop live playback or show a modal.
        NSLog("[WE] Native desktop poster sync failed: %@", error.localizedDescription)
    }
}
