import Foundation

/// Shares one player subscription across opted-in desktop scene wallpapers.
@MainActor
final class SceneMediaCoordinator {
    private let bridge: WallpaperBridge
    private let provider: any SystemMediaProvider
    private var task: Task<Void, Never>?
    private var consuming = false
    private var properties = SystemMediaProperties()
    private var playback = SystemMediaPlaybackState.stopped
    private var timeline: SystemMediaTimeline?
    private var raster: MediaArtworkRaster?
    private var coverURL = ""
    var availability: SystemMediaAvailability { provider.availability }

    init(bridge: WallpaperBridge, provider: (any SystemMediaProvider)? = nil) {
        self.bridge = bridge
        self.provider = provider ?? AdapterSystemMediaProvider()
        self.provider.onPropertiesChanged = { [weak self] in self?.properties = $0 }
        self.provider.onPlaybackChanged = { [weak self] in self?.playback = $0 }
        self.provider.onTimelineChanged = { [weak self] in self?.timeline = $0 }
        self.provider.onThumbnailChanged = { [weak self] cover in
            guard let self, cover.pngBase64DataURL != self.coverURL else { return }
            self.coverURL = cover.pngBase64DataURL
            let prefix = "data:image/png;base64,"
            self.raster = cover.pngBase64DataURL.hasPrefix(prefix)
                ? Data(base64Encoded: String(cover.pngBase64DataURL.dropFirst(prefix.count)))
                    .flatMap { CoreGraphicsArtworkRenderer().render($0, maxPixelSize: 256) } : nil
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if consuming { provider.removeConsumer(); consuming = false }
    }

    private func refresh() async {
        do {
            // Delivery is owned by SceneMediaSink over the shared session.
            // This coordinator only keeps the provider subscribed while any
            // consented desktop scene is live.
            let handles = try await bridge.systemMediaSceneHandles()
            guard !Task.isCancelled else { return }
            if handles.isEmpty {
                if consuming { provider.removeConsumer(); consuming = false }
                properties = SystemMediaProperties()
                playback = .stopped
                timeline = nil
                raster = nil
                coverURL = ""
                return
            }
            if !consuming { consuming = true; provider.addConsumer() }
        } catch { AppLog.warn("Scene media delivery failed: \(error.localizedDescription)") }
    }
}
