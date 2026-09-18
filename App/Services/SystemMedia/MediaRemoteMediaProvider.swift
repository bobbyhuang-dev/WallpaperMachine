import Darwin
import Foundation

/// Names the private framework posts through `NotificationCenter` once registration
/// is active.
struct MediaRemoteNotificationNames: Equatable, Sendable {
    var infoDidChange: Notification.Name
    var isPlayingDidChange: Notification.Name
    var applicationDidChange: Notification.Name
}

/// Keys of the now-playing dictionary the private framework returns. Players populate
/// different subsets of them, which is why every read of one is optional.
enum MediaRemoteInfoKey {
    static let title = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
    static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let albumArtist = "kMRMediaRemoteNowPlayingInfoAlbumArtist"
    static let genre = "kMRMediaRemoteNowPlayingInfoGenre"
    static let mediaType = "kMRMediaRemoteNowPlayingInfoMediaType"
    static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
}

/// The MediaRemote entry points the provider drives, behind a seam so the state machine
/// is exercised without loading the private framework.
///
/// Implementations invoke every completion on the main thread.
@MainActor
protocol MediaRemoteSymbols: AnyObject {
    var notificationNames: MediaRemoteNotificationNames { get }
    /// Asks for the current now-playing dictionary. The completion receives nil when the
    /// framework answered with nothing at all.
    func nowPlayingInfo(_ completion: @escaping ([String: Any]?) -> Void)
    func isPlaying(_ completion: @escaping (Bool) -> Void)
    func registerForNotifications()
    func unregisterForNotifications()
}

/// Why the system cannot say what is playing.
struct MediaRemoteUnavailable: LocalizedError, Equatable {
    enum Code: Equatable {
        case notStarted
        case frameworkMissing
        case symbolMissing(String)
        case noReply
    }

    let code: Code

    var errorDescription: String? {
        switch code {
        case .notStarted:
            String(localized: "Media integration has not been started.")
        case .frameworkMissing:
            String(localized: "This system has no service for reporting what is playing.")
        case .symbolMissing(let name):
            String(localized: "The system media service on this machine does not provide \(name).")
        case .noReply:
            String(localized: "macOS did not let this app read what is playing. Since macOS 15.4 only Apple-signed apps may.")
        }
    }
}

/// Loads the symbol table. Injected so tests never touch a private framework.
@MainActor
protocol MediaRemoteLoading {
    func load() throws -> any MediaRemoteSymbols
}

/// A cancellable piece of scheduled work.
@MainActor
protocol MediaTimerToken: AnyObject {
    func cancel()
}

/// Delayed and repeating work, injected so tests drive time rather than wait on it.
@MainActor
protocol MediaTimerScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken
    func schedule(every seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken
}

/// Reports what the system is playing, for the web media integration.
///
/// macOS has no public API for another application's now-playing state. The private
/// `MediaRemote` framework has one, and since macOS 15.4 it answers nothing to processes
/// without Apple's private entitlement. So every symbol is resolved at runtime, the first
/// consumer pays for a capability probe, and a system that will not answer is reported as
/// unavailable rather than polled in the hope that it starts.
///
/// Nothing happens before the first `addConsumer()`: no framework is loaded, no
/// notification observed, no timer running. At zero consumers all of that is undone.
@MainActor
final class MediaRemoteMediaProvider: SystemMediaProvider {
    private(set) var availability: SystemMediaAvailability
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

    /// Everything needed to compute a position without asking the system again.
    private struct TimelineAnchor: Equatable {
        var elapsed: Double
        var duration: Double
        var rate: Double
        var at: Date
    }

    private let loader: any MediaRemoteLoading
    private let notificationCenter: NotificationCenter
    private let scheduler: any MediaTimerScheduling
    private let artwork: MediaArtwork
    private let now: () -> Date
    private let probeTimeout: TimeInterval

    private var consumers = 0
    private var symbols: (any MediaRemoteSymbols)?
    private var observers: [NSObjectProtocol] = []
    private var probeToken: (any MediaTimerToken)?
    private var timelineTicker: (any MediaTimerToken)?

    private var properties: SystemMediaProperties?
    private var thumbnail: SystemMediaThumbnail?
    private var playback = SystemMediaPlaybackState.stopped
    private var anchor: TimelineAnchor?
    private var emittedTimeline: SystemMediaTimeline?
    private var hasEmittedTimeline = false

    // The object arguments default to nil rather than to a constructor expression: a
    // default argument is evaluated outside the main actor, where a main-actor type
    // cannot be constructed. Production call sites still pass nothing.
    init(
        loader: (any MediaRemoteLoading)? = nil,
        notificationCenter: NotificationCenter = .default,
        scheduler: (any MediaTimerScheduling)? = nil,
        artwork: MediaArtwork? = nil,
        now: @escaping () -> Date = Date.init,
        probeTimeout: TimeInterval = 2
    ) {
        self.loader = loader ?? DynamicMediaRemoteLoader()
        self.notificationCenter = notificationCenter
        self.scheduler = scheduler ?? FoundationMediaTimerScheduler()
        self.artwork = artwork ?? MediaArtwork()
        self.now = now
        self.probeTimeout = probeTimeout
        availability = .unavailable(reason: MediaRemoteUnavailable(code: .notStarted).localizedDescription)
    }

    // MARK: - Lifetime

    func addConsumer() {
        consumers += 1
        guard consumers == 1 else { return }
        start()
    }

    func removeConsumer() {
        guard consumers > 0 else { return }
        consumers -= 1
        guard consumers == 0 else { return }
        stop()
    }

    func replayCurrentState() {
        if let properties { onPropertiesChanged?(properties) }
        if let thumbnail { onThumbnailChanged?(thumbnail) }
        onPlaybackChanged?(playback)
        // A paused timeline is never pushed, so a replay does not push one either.
        if playback == .playing { onTimelineChanged?(currentTimeline()) }
    }

    private func start() {
        let resolved: any MediaRemoteSymbols
        do {
            resolved = try loader.load()
        } catch {
            availability = .unavailable(reason: error.localizedDescription)
            AppLog.info("System media integration unavailable: \(error.localizedDescription)")
            return
        }
        symbols = resolved
        probe(resolved)
    }

    private func stop() {
        probeToken?.cancel()
        probeToken = nil
        timelineTicker?.cancel()
        timelineTicker = nil
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        symbols?.unregisterForNotifications()
        symbols = nil
        properties = nil
        thumbnail = nil
        playback = .stopped
        anchor = nil
        emittedTimeline = nil
        hasEmittedTimeline = false
        availability = .unavailable(reason: MediaRemoteUnavailable(code: .notStarted).localizedDescription)
    }

    // MARK: - Capability probe

    /// Classifies the framework without touching what it reported: the only question is
    /// whether a reply arrived, never what was in it. An entitlement-gated system answers
    /// nothing at all, which the timeout turns into `unavailable` rather than a silent stall.
    private func probe(_ symbols: any MediaRemoteSymbols) {
        var settled = false
        let timeout = scheduler.schedule(after: probeTimeout) { [weak self] in
            guard !settled else { return }
            settled = true
            self?.finishProbe(replied: false)
        }
        probeToken = timeout
        symbols.nowPlayingInfo { [weak self] information in
            guard !settled else { return }
            settled = true
            timeout.cancel()
            self?.finishProbe(replied: information != nil)
        }
    }

    private func finishProbe(replied: Bool) {
        probeToken = nil
        guard consumers > 0, let symbols else { return }
        guard replied else {
            availability = .unavailable(reason: MediaRemoteUnavailable(code: .noReply).localizedDescription)
            self.symbols = nil
            AppLog.info("System media integration unavailable: the system reported nothing.")
            return
        }
        availability = .available
        observe(symbols)
        symbols.registerForNotifications()
        refresh()
    }

    private func observe(_ symbols: any MediaRemoteSymbols) {
        let names = symbols.notificationNames
        for name in [names.infoDidChange, names.isPlayingDidChange, names.applicationDidChange] {
            observers.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
    }

    // MARK: - State

    /// Both halves of the system's answer are gathered before anything is emitted: the
    /// track and the play/pause flag come from separate calls, and applying them one at a
    /// time would show the page a pause that never happened.
    private func refresh() {
        guard let symbols else { return }
        symbols.nowPlayingInfo { [weak self] information in
            guard let self, self.symbols === symbols else { return }
            symbols.isPlaying { [weak self] playing in
                self?.apply(information: information, isPlaying: playing)
            }
        }
    }

    private func apply(information: [String: Any]?, isPlaying: Bool) {
        guard consumers > 0 else { return }
        let information = information ?? [:]

        var next = SystemMediaProperties()
        next.title = Self.string(information[MediaRemoteInfoKey.title])
        next.artist = Self.string(information[MediaRemoteInfoKey.artist])
        // MediaRemote has no subtitle field; the protocol's `subTitle` stays empty rather
        // than being filled with something the system never said.
        next.albumTitle = Self.string(information[MediaRemoteInfoKey.album])
        next.albumArtist = Self.string(information[MediaRemoteInfoKey.albumArtist])
        next.genres = Self.string(information[MediaRemoteInfoKey.genre])
        next.contentType = Self.contentType(information[MediaRemoteInfoKey.mediaType])
        if next != properties {
            properties = next
            onPropertiesChanged?(next)
        }

        // No artwork means no thumbnail event: a page still showing the previous cover is
        // a better outcome than a page told to show a blank one.
        if let data = information[MediaRemoteInfoKey.artworkData] as? Data, !data.isEmpty,
            let cover = artwork.thumbnail(for: data), cover != thumbnail
        {
            thumbnail = cover
            onThumbnailChanged?(cover)
        }

        let duration = Self.double(information[MediaRemoteInfoKey.duration])
        let elapsed = Self.double(information[MediaRemoteInfoKey.elapsedTime])
        if let duration, duration > 0, let elapsed {
            anchor = TimelineAnchor(
                elapsed: elapsed,
                duration: duration,
                rate: Self.double(information[MediaRemoteInfoKey.playbackRate]) ?? 0,
                at: information[MediaRemoteInfoKey.timestamp] as? Date ?? now())
        } else {
            anchor = nil
        }

        let state: SystemMediaPlaybackState =
            information.isEmpty ? .stopped : (isPlaying ? .playing : .paused)
        if state != playback {
            playback = state
            onPlaybackChanged?(state)
        }
        updateTimeline()
    }

    // MARK: - Timeline

    /// The timeline is the only field that has to be interpolated, and it must not become
    /// a clock: the position is computed from the system's own anchor when it is asked
    /// for, and pushed at most once a second, only while something is playing.
    private func updateTimeline() {
        guard playback == .playing else {
            timelineTicker?.cancel()
            timelineTicker = nil
            return
        }
        emitTimeline()
        guard anchor != nil else {
            timelineTicker?.cancel()
            timelineTicker = nil
            return
        }
        if timelineTicker == nil {
            timelineTicker = scheduler.schedule(every: 1) { [weak self] in self?.emitTimeline() }
        }
    }

    private func emitTimeline() {
        let current = currentTimeline()
        guard !hasEmittedTimeline || current != emittedTimeline else { return }
        hasEmittedTimeline = true
        emittedTimeline = current
        onTimelineChanged?(current)
    }

    /// Nil when the system supplied no duration or elapsed time. Nothing here invents one.
    private func currentTimeline() -> SystemMediaTimeline? {
        guard let anchor else { return nil }
        let drift = anchor.rate > 0 ? now().timeIntervalSince(anchor.at) * anchor.rate : 0
        let position = min(max(anchor.elapsed + drift, 0), anchor.duration)
        return SystemMediaTimeline(position: position, duration: anchor.duration)
    }

    // MARK: - Dictionary reading

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func contentType(_ value: Any?) -> String {
        guard let raw = value as? String else { return "music" }
        if raw.localizedCaseInsensitiveContains("video") { return "video" }
        if raw.localizedCaseInsensitiveContains("image") { return "image" }
        return "music"
    }
}

private typealias MediaRemoteNowPlayingInfoFunction =
    @convention(c) (DispatchQueue, @convention(block) (CFDictionary?) -> Void) -> Void
private typealias MediaRemoteIsPlayingFunction =
    @convention(c) (DispatchQueue, @convention(block) (Bool) -> Void) -> Void
private typealias MediaRemoteRegisterFunction = @convention(c) (DispatchQueue) -> Void
private typealias MediaRemoteUnregisterFunction = @convention(c) () -> Void

/// Resolves MediaRemote the first time a consumer asks for it.
///
/// Loading a private framework at static-initialiser time would make every launch pay for
/// a capability almost no machine grants, so the `dlopen` happens on the first `load()`.
/// The handle is then kept: unloading a system framework buys nothing back.
@MainActor
final class DynamicMediaRemoteLoader: MediaRemoteLoading {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    private var cached: (any MediaRemoteSymbols)?

    func load() throws -> any MediaRemoteSymbols {
        if let cached { return cached }
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            throw MediaRemoteUnavailable(code: .frameworkMissing)
        }
        let info = try Self.symbol("MRMediaRemoteGetNowPlayingInfo", in: handle)
        let playing = try Self.symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", in: handle)
        let register = try Self.symbol("MRMediaRemoteRegisterForNowPlayingNotifications", in: handle)
        let unregister = dlsym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications")
        let symbols = DynamicMediaRemoteSymbols(
            getNowPlayingInfo: unsafeBitCast(info, to: MediaRemoteNowPlayingInfoFunction.self),
            getIsPlaying: unsafeBitCast(playing, to: MediaRemoteIsPlayingFunction.self),
            register: unsafeBitCast(register, to: MediaRemoteRegisterFunction.self),
            unregister: unregister.map { unsafeBitCast($0, to: MediaRemoteUnregisterFunction.self) },
            notificationNames: Self.notificationNames(in: handle))
        cached = symbols
        return symbols
    }

    private static func symbol(
        _ name: String, in handle: UnsafeMutableRawPointer
    ) throws -> UnsafeMutableRawPointer {
        guard let pointer = dlsym(handle, name) else {
            throw MediaRemoteUnavailable(code: .symbolMissing(name))
        }
        return pointer
    }

    /// The framework exports its notification names as `CFStringRef` constants. A constant
    /// that is not exported falls back to its own symbol name, which is the value these
    /// constants hold. That is a weaker guarantee than the function symbols carry, so a
    /// missing name is not a reason to refuse an otherwise complete symbol table.
    private static func notificationNames(
        in handle: UnsafeMutableRawPointer
    ) -> MediaRemoteNotificationNames {
        func name(_ symbol: String) -> Notification.Name {
            guard let pointer = dlsym(handle, symbol),
                let raw = pointer.load(as: UnsafeRawPointer?.self)
            else { return Notification.Name(symbol) }
            return Notification.Name(Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
        }
        return MediaRemoteNotificationNames(
            infoDidChange: name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            isPlayingDidChange: name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            applicationDidChange: name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"))
    }
}

/// The resolved MediaRemote functions, with their replies brought onto the main queue.
@MainActor
private final class DynamicMediaRemoteSymbols: MediaRemoteSymbols {
    private let getNowPlayingInfo: MediaRemoteNowPlayingInfoFunction
    private let getIsPlaying: MediaRemoteIsPlayingFunction
    private let register: MediaRemoteRegisterFunction
    private let unregister: MediaRemoteUnregisterFunction?
    let notificationNames: MediaRemoteNotificationNames

    init(
        getNowPlayingInfo: @escaping MediaRemoteNowPlayingInfoFunction,
        getIsPlaying: @escaping MediaRemoteIsPlayingFunction,
        register: @escaping MediaRemoteRegisterFunction,
        unregister: MediaRemoteUnregisterFunction?,
        notificationNames: MediaRemoteNotificationNames
    ) {
        self.getNowPlayingInfo = getNowPlayingInfo
        self.getIsPlaying = getIsPlaying
        self.register = register
        self.unregister = unregister
        self.notificationNames = notificationNames
    }

    func nowPlayingInfo(_ completion: @escaping ([String: Any]?) -> Void) {
        getNowPlayingInfo(.main) { information in
            var dictionary: [String: Any]?
            if let information { dictionary = (information as NSDictionary) as? [String: Any] }
            MainActor.assumeIsolated { completion(dictionary) }
        }
    }

    func isPlaying(_ completion: @escaping (Bool) -> Void) {
        getIsPlaying(.main) { playing in
            MainActor.assumeIsolated { completion(playing) }
        }
    }

    func registerForNotifications() {
        register(.main)
    }

    func unregisterForNotifications() {
        unregister?()
    }
}

/// Run-loop timers for the probe timeout and the once-a-second timeline push.
@MainActor
final class FoundationMediaTimerScheduler: MediaTimerScheduling {
    @MainActor
    private final class Token: MediaTimerToken {
        private var timer: Timer?

        init(_ timer: Timer) { self.timer = timer }

        func cancel() {
            timer?.invalidate()
            timer = nil
        }
    }

    func schedule(after seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken {
        make(interval: seconds, repeats: false, handler: handler)
    }

    func schedule(every seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken {
        make(interval: seconds, repeats: true, handler: handler)
    }

    private func make(
        interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void
    ) -> any MediaTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { handler() }
        }
        // A timeline second may slide; letting the run loop coalesce it costs the page
        // nothing and keeps the app off a wake-up schedule of its own.
        timer.tolerance = interval / 4
        return Token(timer)
    }
}
