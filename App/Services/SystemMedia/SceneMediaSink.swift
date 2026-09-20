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
    private let listenerKey = ObjectIdentifier(ListenerKey())
    /// Scenes that have already been shown the current state. A scene is born
    /// with none of it, so a handle absent from this set is what makes a
    /// replay necessary — not the moment the first consumer appears.
    private var fedHandles: Set<UInt64> = []

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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handles = await self.fetchHandles()
            self.session.relay.setConsuming(!handles.isEmpty, for: self.listenerKey)
            // Switching wallpapers, adding a display or rebuilding a scene
            // produces a handle that has seen nothing. Replaying reaches every
            // opted-in scene, not only the new one, because the engine has no
            // per-handle submit here; re-sending an unchanged state is
            // idempotent, and the alternative is a new display staying blank
            // until the track changes.
            if !handles.subtracting(self.fedHandles).isEmpty {
                for event in self.session.relay.currentEvents(userEnabled: true) {
                    self.deliver(event)
                }
            }
            self.fedHandles = handles
        }
    }

    func shutdown() {
        session.relay.removeListener(listenerKey)
        session.relay.setConsuming(false, for: listenerKey)
        fedHandles = []
    }

    private func deliver(_ event: WebWallpaperMediaRelay.Event) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case let .thumbnail(thumbnail) = event, thumbnail.width > 0, thumbnail.height > 0,
                thumbnail.rgba.count == thumbnail.width * thumbnail.height * 4
            {
                do {
                    try await self.applyArtwork(
                        UInt32(thumbnail.width), UInt32(thumbnail.height), Data(thumbnail.rgba))
                } catch {
                    AppLog.warn("scene media artwork could not be applied: \(error.localizedDescription)")
                }
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
