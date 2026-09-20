import Foundation

/// Turns a `SystemMediaProvider` into the five Wallpaper Engine media events,
/// holding only what the provider actually reported.
///
/// It never invents a title, artwork, playback state or position. A provider
/// that is unavailable — no entitlement, nothing playing, integration off —
/// simply leaves this in its empty state, and the empty state is what the page
/// is told: no properties, `PLAYBACK_STOPPED`, and no timeline event at all.
@MainActor
final class WebWallpaperMediaRelay {
    enum Event: Equatable {
        case status(Bool)
        case properties(SystemMediaProperties)
        case thumbnail(SystemMediaThumbnail)
        case playback(SystemMediaPlaybackState)
        case timeline(SystemMediaTimeline)
    }

    private let provider: any SystemMediaProvider
    private var consumers: Set<ObjectIdentifier> = []
    private var properties = SystemMediaProperties()
    private var thumbnail: SystemMediaThumbnail?
    private var playback = SystemMediaPlaybackState.stopped
    private var timeline: SystemMediaTimeline?

    /// A part of the current state changed. Fires only for the part that
    /// changed, so a new track title does not re-send its artwork.
    var onChange: (@MainActor (Event) -> Void)?
    /// Extra listeners besides `onChange`, so a shared relay can feed the web
    /// host and the scene sink without either overwriting the other.
    private var extraListeners: [ObjectIdentifier: @MainActor (Event) -> Void] = [:]

    var consumerCount: Int { consumers.count }
    var availability: SystemMediaAvailability { provider.availability }

    init(provider: any SystemMediaProvider) {
        self.provider = provider
        provider.onPropertiesChanged = { [weak self] value in
            MainActor.assumeIsolated { self?.apply(properties: value) }
        }
        provider.onThumbnailChanged = { [weak self] value in
            MainActor.assumeIsolated { self?.apply(thumbnail: value) }
        }
        provider.onPlaybackChanged = { [weak self] value in
            MainActor.assumeIsolated { self?.apply(playback: value) }
        }
        provider.onTimelineChanged = { [weak self] value in
            MainActor.assumeIsolated { self?.apply(timeline: value) }
        }
    }

    /// Everything currently known, in the order a page that has just
    /// registered, reloaded or resumed should receive it.
    ///
    /// `userEnabled` is the user's own per-wallpaper setting and is the only
    /// thing the status listener reports: a page whose user turned media
    /// integration on is told `enabled: true` even when no provider can supply
    /// anything, because the page is being told about the setting, not about
    /// the system's capabilities.
    func currentEvents(userEnabled: Bool) -> [Event] {
        var events: [Event] = [.status(userEnabled), .properties(properties)]
        if let thumbnail { events.append(.thumbnail(thumbnail)) }
        events.append(.playback(playback))
        if let timeline { events.append(.timeline(timeline)) }
        return events
    }

    /// Adds or removes one consumer. The provider runs only while at least one
    /// exists, and a consumer that is already counted does not count twice.
    func setConsuming(_ consuming: Bool, for key: ObjectIdentifier) {
        if consuming {
            guard consumers.insert(key).inserted else { return }
            provider.addConsumer()
            provider.replayCurrentState()
        } else {
            guard consumers.remove(key) != nil else { return }
            provider.removeConsumer()
            if consumers.isEmpty { forget() }
        }
    }

    func addListener(_ key: ObjectIdentifier, _ handler: @escaping @MainActor (Event) -> Void) {
        extraListeners[key] = handler
    }

    func removeListener(_ key: ObjectIdentifier) {
        extraListeners.removeValue(forKey: key)
    }

    private func emit(_ event: Event) {
        onChange?(event)
        for handler in extraListeners.values { handler(event) }
    }

    func removeAllConsumers() {
        let count = consumers.count
        guard count > 0 else { return }
        consumers.removeAll()
        for _ in 0..<count { provider.removeConsumer() }
        forget()
    }

    /// Nothing is being watched any more, so nothing is known. Keeping the last
    /// track would hand it to the next page before the provider had said
    /// anything, which is indistinguishable from making it up.
    private func forget() {
        properties = SystemMediaProperties()
        thumbnail = nil
        playback = .stopped
        timeline = nil
    }

    private func apply(properties: SystemMediaProperties) {
        guard properties != self.properties else { return }
        self.properties = properties
        emit(.properties(properties))
    }

    private func apply(thumbnail: SystemMediaThumbnail) {
        guard thumbnail != self.thumbnail else { return }
        self.thumbnail = thumbnail
        emit(.thumbnail(thumbnail))
    }

    private func apply(playback: SystemMediaPlaybackState) {
        guard playback != self.playback else { return }
        self.playback = playback
        emit(.playback(playback))
    }

    /// A provider that lost the timeline reports nil. The protocol has no "no
    /// timeline" event and a wallpaper must work if the listener never fires,
    /// so the value is forgotten and nothing is sent — reporting 0/0 would be a
    /// position the provider never supplied.
    private func apply(timeline: SystemMediaTimeline?) {
        guard timeline != self.timeline else { return }
        self.timeline = timeline
        if let timeline { emit(.timeline(timeline)) }
    }
}

extension WebWallpaperMediaRelay.Event {
    var slot: WebWallpaperPage.MediaSlot {
        switch self {
        case .status: .status
        case .properties: .properties
        case .thumbnail: .thumbnail
        case .playback: .playback
        case .timeline: .timeline
        }
    }

    /// The object the page's listener receives, with the field names the
    /// Wallpaper Engine documentation specifies.
    var payload: [String: Any] {
        switch self {
        case let .status(enabled):
            return ["enabled": enabled]
        case let .properties(properties):
            return [
                "title": properties.title, "artist": properties.artist,
                "subTitle": properties.subTitle, "albumTitle": properties.albumTitle,
                "albumArtist": properties.albumArtist, "genres": properties.genres,
                "contentType": properties.contentType,
            ]
        case let .thumbnail(thumbnail):
            return [
                "thumbnail": thumbnail.pngBase64DataURL,
                "primaryColor": thumbnail.primaryColor, "secondaryColor": thumbnail.secondaryColor,
                "tertiaryColor": thumbnail.tertiaryColor, "textColor": thumbnail.textColor,
                "highContrastColor": thumbnail.highContrastColor,
            ]
        case let .playback(state):
            return ["state": state.rawValue]
        case let .timeline(timeline):
            return ["position": timeline.position, "duration": timeline.duration]
        }
    }
}

/// The provider used when the host was built without one: nothing is ever
/// known, so the page is told media integration reports nothing rather than
/// being told a fabricated silence.
@MainActor
final class UnavailableSystemMediaProvider: SystemMediaProvider {
    let availability = SystemMediaAvailability.unavailable(reason: "No system media provider is configured.")
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

    func addConsumer() {}
    func removeConsumer() {}
    func replayCurrentState() {}
}
