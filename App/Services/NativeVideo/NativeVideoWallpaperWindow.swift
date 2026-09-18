import AVFoundation
import AppKit

/// One desktop window playing a plain local video with the platform player.
///
/// The window is a sibling of the renderer's Metal window and the web
/// wallpaper window, and is discovered by the same class-name lookup, so the
/// presentation policy and the desktop poster sync see it without special
/// cases.
/// What the host needs from one display's surface.
///
/// The real implementation is a desktop window owning the platform player.
/// Keeping it behind this boundary is what lets the host's routing, fallback
/// and suspension rules be checked without opening a window: the desktop is
/// not available to an automated run, and a test that ordered a
/// desktop-level window onto the screen would be doing exactly that.
@MainActor
protocol NativeVideoSurface: AnyObject {
    func setVolume(_ volume: Float, muted: Bool)
    func setScaling(_ mode: BridgeScalingMode)
    func setUserPaused(_ paused: Bool)
    func setPresentationSuspended(_ suspended: Bool)
    var isPlaying: Bool { get }
    func posterImage() async -> CGImage?
    /// Puts the surface on the desktop. Separate from construction so the
    /// caller decides when a surface becomes visible.
    func present()
    func stop()
}

@objc(MWENativeVideoDesktopWindow)
final class NativeVideoWallpaperWindow: NSWindow {
    let player: NativeVideoPlayer

    init(frame: NSRect, player: NativeVideoPlayer) {
        self.player = player
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        isMovable = false
        isRestorable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        backgroundColor = .black
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizesSubviews = true
        contentView = container
        player.attach(to: container)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NativeVideoWallpaperWindow: NativeVideoSurface {
    func setVolume(_ volume: Float, muted: Bool) { player.setVolume(volume, muted: muted) }
    func setScaling(_ mode: BridgeScalingMode) { player.setScaling(mode) }
    func setUserPaused(_ paused: Bool) { player.setUserPaused(paused) }
    func setPresentationSuspended(_ suspended: Bool) {
        player.setPresentationSuspended(suspended)
    }
    var isPlaying: Bool { player.isPlaying }
    func posterImage() async -> CGImage? { await player.posterImage() }
    func present() { orderFrontRegardless() }
    func stop() {
        player.stop()
        orderOut(nil)
        close()
    }
}

/// Why the native player cannot take a wallpaper.
///
/// A refusal is a routing decision, not an error: the wallpaper goes back to
/// the scene engine, which supports everything this does not.
enum NativeVideoRefusal: Equatable {
    /// The user asked for a frame rate below the clip's own rate. There is no
    /// supported way to cap an `AVPlayerLayer`'s presentation rate: lowering
    /// the playback rate would slow the video down rather than limit it, and
    /// dropping frames by hand would mean copying every frame through the CPU.
    case targetFrameRateBelowContent(target: UInt32, content: Float)
    /// The asset is not playable, or carries no video track.
    case notPlayable(String)

    var reason: String {
        switch self {
        case let .targetFrameRateBelowContent(target, content):
            return "target frame rate \(target) is below the clip's \(content) fps, "
                + "which this backend cannot honour without changing playback speed"
        case let .notPlayable(detail):
            return "asset is not playable: \(detail)"
        }
    }
}

/// Owns the `AVQueuePlayer` / `AVPlayerLooper` / `AVPlayerLayer` trio for one
/// display.
///
/// `AVPlayerLooper` is what makes gapless looping the system's problem rather
/// than ours; it keeps more than one copy of the item queued by design, which
/// is why the counters report queued items rather than claiming a single one.
@MainActor
final class NativeVideoPlayer {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let layer = AVPlayerLayer()
    private let surface: RuntimeSurfaceKey
    private let counters: RuntimeCounters
    /// The user's own Play/Pause choice, kept apart from presentation
    /// suspension so revealing a display never overrides it.
    private var userPaused: Bool
    private var presentationSuspended = false
    private var stopped = false

    init(
        surface: RuntimeSurfaceKey,
        counters: RuntimeCounters,
        paused: Bool
    ) {
        self.surface = surface
        self.counters = counters
        self.userPaused = paused
        player.actionAtItemEnd = .advance
        // Nothing here needs the system's "now playing" treatment, and taking
        // the audio session focus would interrupt whatever the user is
        // listening to.
        player.preventsDisplaySleepDuringVideoPlayback = false
        layer.player = player
        layer.videoGravity = .resizeAspectFill
    }

    /// Checks whether this backend can honour the wallpaper before any window
    /// exists, so a refusal costs nothing visible.
    ///
    /// The frame-rate rule is the important one. The user's target rate is a
    /// requirement: playing a 60 fps clip while the user asked for 30 would be
    /// a silent quality and power change, so it is refused instead.
    static func refusal(
        for url: URL, targetFps: UInt32
    ) async -> NativeVideoRefusal? {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else {
                return .notPlayable("asset reports itself unplayable")
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                return .notPlayable("no video track")
            }
            let nominal = try await track.load(.nominalFrameRate)
            guard nominal > 0 else {
                return .notPlayable("video track reports no frame rate")
            }
            // A fractional rate such as 29.97 must not be refused against a
            // target of 30, so the comparison carries one frame of tolerance.
            if Float(targetFps) + 1.0 < nominal {
                return .targetFrameRateBelowContent(target: targetFps, content: nominal)
            }
            return nil
        } catch {
            return .notPlayable(error.localizedDescription)
        }
    }

    func attach(to view: NSView) {
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
    }

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        // AVPlayerLooper takes ownership of the queue, so it is created once
        // per item and replaced wholesale rather than mutated.
        looper = AVPlayerLooper(player: player, templateItem: item)
        counters.record(.nativeVideoItemCreated, for: surface)
        applyPlaybackState()
    }

    func setScaling(_ mode: BridgeScalingMode) {
        // The subset this backend declares. Anything else is refused before a
        // window is created, so there is no silent substitution here.
        layer.videoGravity = mode == .stretch ? .resize : .resizeAspectFill
    }

    func setVolume(_ volume: Float, muted: Bool) {
        player.volume = max(0, min(volume, 1))
        player.isMuted = muted
    }

    /// The user's own pause. Independent of presentation suspension: a display
    /// becoming visible again must not start a wallpaper the user paused.
    func setUserPaused(_ paused: Bool) {
        userPaused = paused
        applyPlaybackState()
    }

    func setPresentationSuspended(_ suspended: Bool) {
        guard presentationSuspended != suspended else { return }
        presentationSuspended = suspended
        counters.record(
            suspended ? .presentationSuspended : .presentationResumed, for: surface)
        applyPlaybackState()
    }

    var isPlaying: Bool { player.rate > 0 }

    /// One frame for a poster request. The existing player is asked for it; a
    /// second player would mean decoding the same clip twice.
    func posterImage() async -> CGImage? {
        guard let asset = (player.currentItem?.asset as? AVURLAsset) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = player.currentTime()
        counters.record(.readinessFrameRendered, for: surface)
        return try? await generator.image(at: time).image
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        player.pause()
        // The looper holds the queue; disabling it first stops it re-filling
        // the queue while the items are being removed.
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        layer.player = nil
        layer.removeFromSuperlayer()
        counters.record(.nativeVideoItemReleased, for: surface)
    }

    /// Queued item count, as the system actually reports it.
    ///
    /// `AVPlayerLooper` keeps more than one copy of the template item queued to
    /// make the seam gapless, so this is deliberately not claimed to be one.
    var queuedItemCount: Int { player.items().count }

    private func applyPlaybackState() {
        guard !stopped else { return }
        if userPaused || presentationSuspended {
            player.pause()
        } else {
            player.play()
        }
    }
}
