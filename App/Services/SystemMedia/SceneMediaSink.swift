import Foundation

/// Feeds live now-playing events into every desktop scene that opted in.
///
/// Scenes do not register listeners. Demand is the set of applied scenes whose
/// user turned media integration on, which the bridge reports by handle. The
/// engine drops events when a scene's live flag is off, so this fans out to
/// every opted-in wallpaper without asking for handles of its own.
@MainActor
final class SceneMediaSink {
    private let session: DesktopMediaSession
    private let submit: (String) async throws -> Void
    private let applyArtwork: (UInt32, UInt32, Data) async throws -> Void
    private let fetchHandles: () async -> Set<UInt64>
    /// Held, not derived from a temporary. `ObjectIdentifier` is an address,
    /// and an address freed the moment it was taken can be handed to the next
    /// allocation — which would let two listeners share one key in the shared
    /// relay and silently overwrite or remove each other.
    private let listenerToken = ListenerKey()
    private var listenerKey: ObjectIdentifier { ObjectIdentifier(listenerToken) }
    /// Whether this sink currently has anything to feed.
    ///
    /// The relay hands every event to every listener, because a listener key
    /// is not a consumer key — the web host keeps one listener for all its
    /// pages. So the decision not to do the work belongs here, where the
    /// effective demand is known.
    private var consuming = false
    /// Bumped whenever `consuming` changes, and captured by each delivery.
    ///
    /// A delivery awaits the engine twice, so a pause can land in the middle
    /// of one. A boolean cannot retire that delivery: by the time it resumes
    /// the scene may have been resumed too, and `consuming` would be true
    /// again — letting a cover from before the pause overwrite the one
    /// published after it. The epoch only ever moves forward, so a delivery
    /// that started in an earlier one is dropped whatever the flag says.
    private var deliveryEpoch: UInt64 = 0
    /// The tail of the delivery queue, so covers and their metadata reach the
    /// engine in publication order rather than in whatever order the engine
    /// happened to answer.
    private var deliveryChain: Task<Void, Never>?
    /// Scenes that have already been shown the current state. A scene is born
    /// with none of it, so a handle absent from this set is what makes a
    /// replay necessary — not the moment the first consumer appears.
    private var fedHandles: Set<UInt64> = []
    /// Reconciles can overlap: a pause and a resume each start one, and the
    /// bridge call is awaited. Applying a stale answer would re-open the
    /// provider after a pause, so only the newest reconcile may act.
    private var generation: UInt64 = 0

    private final class ListenerKey {}

    init(
        session: DesktopMediaSession,
        submit: @escaping (String) async throws -> Void,
        applyArtwork: @escaping (UInt32, UInt32, Data) async throws -> Void,
        fetchHandles: @escaping () async -> Set<UInt64>
    ) {
        self.session = session
        self.submit = submit
        self.applyArtwork = applyArtwork
        self.fetchHandles = fetchHandles
        session.relay.addListener(listenerKey) { [weak self] event in
            self?.deliver(event)
        }
    }

    func reconcile() {
        generation &+= 1
        let generation = self.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handles = await self.fetchHandles()
            guard generation == self.generation else { return }
            self.setConsuming(!handles.isEmpty)
            // Switching wallpapers, adding a display, rebuilding a scene or
            // resuming after a pause produces a handle that has seen nothing.
            // Replaying reaches every opted-in scene, not only the new one,
            // because the engine has no per-handle submit here; re-sending an
            // unchanged state is idempotent, and the alternative is a new
            // display staying blank until the track changes.
            if !handles.subtracting(self.fedHandles).isEmpty {
                for event in self.session.relay.currentEvents(userEnabled: true) {
                    self.deliver(event)
                }
            }
            self.fedHandles = handles
        }
    }

    func shutdown() {
        // Retires any reconcile still in flight, and any delivery already past
        // its first await, along with the listener. `setConsuming` tells the
        // relay; saying it twice would only rely on its remove-guard.
        generation &+= 1
        setConsuming(false)
        session.relay.removeListener(listenerKey)
        fedHandles = []
    }

    /// Moves the epoch only when the answer actually changed, so an unrelated
    /// reconcile does not retire deliveries that are still wanted.
    private func setConsuming(_ value: Bool) {
        if consuming != value {
            consuming = value
            deliveryEpoch &+= 1
        }
        session.relay.setConsuming(value, for: listenerKey)
    }

    private func deliver(_ event: WebWallpaperMediaRelay.Event) {
        // Nothing visible is opted in, so there is nothing to copy, encode or
        // send.
        guard consuming else { return }
        let epoch = deliveryEpoch
        var cover: (width: UInt32, height: UInt32, rgba: Data)?
        if case let .thumbnail(thumbnail) = event, thumbnail.width > 0, thumbnail.height > 0,
            thumbnail.rgba.count == thumbnail.width * thumbnail.height * 4
        {
            cover = (UInt32(thumbnail.width), UInt32(thumbnail.height), Data(thumbnail.rgba))
        }
        // Chained, not parallel. A slow cover must not be overtaken by the one
        // that replaced it and then land on top of it: the engine applies
        // whatever arrives last, so the order covers reach it is the order
        // they were published in.
        let previous = deliveryChain
        deliveryChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.deliveryEpoch == epoch else { return }
            if let cover {
                do {
                    try await self.applyArtwork(cover.width, cover.height, cover.rgba)
                } catch {
                    AppLog.warn("scene media artwork could not be applied: \(error.localizedDescription)")
                }
                // The cover await is where a pause and a resume can both land.
                // The call already inside the engine cannot be taken back, but
                // this event's own metadata must not follow a newer one.
                guard self.deliveryEpoch == epoch else { return }
            }
            guard let json = SystemMediaEventCodec.json(for: event) else { return }
            do {
                try await self.submit(json)
            } catch {
                AppLog.warn("scene media event could not be submitted: \(error.localizedDescription)")
            }
        }
    }
}
