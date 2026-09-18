import AVFoundation
import AppKit
import VideoToolbox

/// Owns the `AVQueuePlayer` / `AVPlayerLooper` / `AVPlayerLayer` trio for one
/// display.
///
/// `AVPlayerLooper` is what makes gapless looping the system's problem rather
/// than ours; it keeps more than one copy of the item queued by design, which
/// is why the counters report queued items rather than claiming a single one.
@MainActor
final class NativeVideoPlayer {
    /// Ceiling on how long one poster request will wait for the playing item
    /// to hand over a frame before falling back. Bounded so a stalled item
    /// cannot hold a request open, and short enough that a poster request is
    /// never mistaken for a reason to keep the decoder awake.
    static let posterWaitStep = Duration.milliseconds(25)
    static let posterWaitSteps = 12

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

    /// Attached only while a poster request is in flight, and always to the
    /// item that is playing right now rather than to the looper's template.
    /// A permanently attached output would mean a second, continuous readback
    /// of every frame for a picture nobody asked for.
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    /// The single in-flight poster request. Concurrent callers await this one
    /// instead of each opening their own read path.
    private var posterRequest: Task<CGImage?, Never>?
    /// Last frame this player actually produced. A paused player answers from
    /// here rather than resuming to make a picture.
    private var lastPoster: CGImage?
    /// KVO on the item's and the looper's status. Held for the player's life
    /// so a failure that arrives late still reaches the host.
    private var statusObservations: [NSKeyValueObservation] = []
    /// Status observation for the item that is playing right now, re-pointed
    /// as the loop replaces it.
    private var currentItemObservation: NSKeyValueObservation?
    private weak var observedItem: AVPlayerItem?
    private var failureReported = false
    /// A failure seen before anyone was listening. The host installs its
    /// callback after constructing the surface, and a synchronous failure at
    /// load would otherwise be dropped on the floor — which is the one case
    /// where the display ends up black with no hand-off.
    private var pendingFailure: String?

    /// Reported when the platform player cannot prepare or play the asset,
    /// with this surface's generation so a late failure cannot be attributed
    /// to whatever replaced it.
    var onPreparationFailure: (@MainActor (UInt64, String) -> Void)? {
        didSet {
            guard let pendingFailure, onPreparationFailure != nil else { return }
            self.pendingFailure = nil
            onPreparationFailure?(surface.generation, pendingFailure)
        }
    }

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

    func attach(to view: NSView) {
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
    }

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        // AVPlayerLooper takes ownership of the queue, so it is created once
        // per item and replaced wholesale rather than mutated.
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        counters.record(.nativeVideoItemCreated, for: surface)
        observeFailures(looper: looper)
        applyPlaybackState()
    }

    /// Watches for the asset turning out to be unplayable after admission
    /// already accepted it.
    ///
    /// Admission reads metadata; this is playback. A track whose properties
    /// load cleanly can still fail to decode — a truncated file, a codec this
    /// machine cannot play, a busy decoder. Nothing else observes that, so
    /// without this the wallpaper stays selected by a backend that cannot show
    /// it while the scene engine is excluded.
    ///
    /// **Not the template item.** `AVPlayerLooper` does not play the item it
    /// was constructed with; it enqueues copies of it. Observing the template
    /// watches an object that never plays and never fails, which is a fault
    /// that no fake-surface test can see. What matters is whatever
    /// `currentItem` is at the time, and the loop replaces that, so the
    /// observation follows it.
    private func observeFailures(looper: AVPlayerLooper) {
        statusObservations = [
            // `.initial` matters: the looper can already be `.failed` by the
            // time this runs, and a `.new`-only subscription would miss it.
            looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let detail = looper.error?.localizedDescription ?? "player looper failed"
                MainActor.assumeIsolated { self?.reportPreparationFailure(detail) }
            },
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                MainActor.assumeIsolated { self?.followCurrentItem(player.currentItem) }
            },
        ]
    }

    /// Re-points the item-status observation at whatever is playing now.
    private func followCurrentItem(_ item: AVPlayerItem?) {
        guard !stopped else { return }
        guard let item else {
            currentItemObservation = nil
            return
        }
        guard item !== observedItem else { return }
        observedItem = item
        currentItemObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            guard item.status == .failed else { return }
            let detail = item.error?.localizedDescription ?? "player item failed"
            MainActor.assumeIsolated { self?.reportPreparationFailure(detail) }
        }
    }

    /// Reported once. Both observations can fire for one underlying fault, and
    /// a second report would be a second hand-off for a wallpaper the host has
    /// already given away.
    private func reportPreparationFailure(_ detail: String) {
        guard !stopped, !failureReported else { return }
        failureReported = true
        guard onPreparationFailure != nil else {
            // Nobody is listening yet. Held rather than dropped; installing
            // the callback delivers it.
            pendingFailure = detail
            return
        }
        onPreparationFailure?(surface.generation, detail)
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

    /// Queued item count, as the system actually reports it.
    ///
    /// `AVPlayerLooper` keeps more than one copy of the template item queued to
    /// make the seam gapless, so this is deliberately not claimed to be one.
    var queuedItemCount: Int { player.items().count }

    /// The item the player is actually playing. Exposed because the loop
    /// replaces it: a poster taken from the looper's template would be a
    /// frame from a different object than the one on screen.
    var currentItemForTest: AVPlayerItem? { player.currentItem }
    var posterOutputIsAttachedForTest: Bool { videoOutput != nil }
    /// Playback position inside the item that is playing. A loop restarts it,
    /// which is how a test tells a wrap from a stall.
    var playbackTimeForTest: CMTime { player.currentItem?.currentTime() ?? .invalid }
    /// `AVPlayerLayer.isReadyForDisplay`. This means the layer has a frame it
    /// could display — not that anything reached a screen. The two are
    /// reported separately and the second one is not observable here.
    var layerIsReadyForDisplayForTest: Bool { layer.isReadyForDisplay }
    var itemStatusForTest: AVPlayerItem.Status? { player.currentItem?.status }

    /// One frame for a poster request, from the item that is playing.
    ///
    /// Concurrent requests coalesce into one. Nothing here resumes playback:
    /// a paused player answers from the last frame it produced, because
    /// resuming to take a screenshot would restart decode, audio and power
    /// draw the user had stopped.
    func posterImage() async -> CGImage? {
        guard !stopped else { return nil }
        if let posterRequest { return await posterRequest.value }
        let request = Task { @MainActor [weak self] in
            await self?.producePoster() ?? nil
        }
        posterRequest = request
        let image = await request.value
        if posterRequest == request { posterRequest = nil }
        return image
    }

    private func producePoster() async -> CGImage? {
        defer { detachPosterOutput() }
        for step in 0..<Self.posterWaitSteps {
            guard !stopped, let item = player.currentItem else { return lastPoster }
            // Re-resolved every step: crossing a loop boundary replaces
            // `currentItem`, and an output attached to the retired copy would
            // never produce another frame.
            let output = attachPosterOutput(to: item)
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
                let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                let image = Self.makeImage(from: buffer)
            {
                counters.record(.readinessFrameRendered, for: surface)
                lastPoster = image
                return image
            }
            if step + 1 < Self.posterWaitSteps {
                try? await Task.sleep(for: Self.posterWaitStep)
            }
        }
        guard !stopped else { return nil }
        // One-shot fallback, created and released inside this request. It is
        // a second decode of a few frames, which is why it is counted: a
        // permanently retained generator would be a second decoder for the
        // whole session.
        if let item = player.currentItem, let asset = item.asset as? AVURLAsset {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            counters.record(.nativeVideoPosterFallback, for: surface)
            if let image = try? await generator.image(at: item.currentTime()).image {
                lastPoster = image
                return image
            }
        }
        // Still nothing: the last frame this player produced is a truthful
        // answer, and nil is a truthful "none yet". Neither resumes playback.
        return lastPoster
    }

    private func attachPosterOutput(to item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let output = videoOutput, outputItem === item { return output }
        detachPosterOutput()
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        outputItem = item
        return output
    }

    private func detachPosterOutput() {
        if let output = videoOutput, let item = outputItem {
            item.remove(output)
        }
        videoOutput = nil
        outputItem = nil
    }

    private static func makeImage(from buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        // Retains nothing: no Core Image context is kept alive between
        // requests, so a failed poster leaves no converter behind.
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            == noErr
        else { return nil }
        return image
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // A request still in flight belongs to this surface. Cancelling it
        // here is what keeps its frame from being delivered to whatever opens
        // next on the same display.
        posterRequest?.cancel()
        posterRequest = nil
        detachPosterOutput()
        lastPoster = nil
        // Tearing the queue down below makes the item fail on its way out;
        // that is this stop, not a fault worth handing to another backend.
        statusObservations.removeAll()
        currentItemObservation = nil
        observedItem = nil
        pendingFailure = nil
        onPreparationFailure = nil
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

    private func applyPlaybackState() {
        guard !stopped else { return }
        if userPaused || presentationSuspended {
            player.pause()
        } else {
            player.play()
        }
    }
}
