import Foundation

/// MediaRemote first; Music.app / Spotify only after that path cannot answer.
///
/// A `noReply` probe is the ordinary macOS 15.4+ outcome without Apple's
/// entitlement. Automation permission is requested only then, and only while a
/// wallpaper has asked for media. Both sources staying empty is reported as
/// unavailable: nothing here invents a track.
@MainActor
final class FallbackSystemMediaProvider: SystemMediaProvider {
    /// Whatever the source in use says right now.
    ///
    /// Read through rather than latched: Music or Spotify can start or stop
    /// long after the fallback was chosen, and the panel has to show what is
    /// true when it asks, not what was true at the switch.
    var availability: SystemMediaAvailability {
        guard consumers > 0 else {
            return .unavailable(reason: MediaRemoteUnavailable(code: .notStarted).localizedDescription)
        }
        return usingFallback ? fallback.availability : primary.availability
    }

    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

    private let primary: any SystemMediaProvider
    private let fallback: any SystemMediaProvider
    private let scheduler: any MediaTimerScheduling
    private let probeTimeout: TimeInterval

    private var consumers = 0
    private var usingFallback = false
    private var settleToken: (any MediaTimerToken)?

    init(
        primary: any SystemMediaProvider,
        fallback: any SystemMediaProvider,
        scheduler: (any MediaTimerScheduling)? = nil,
        probeTimeout: TimeInterval = 2
    ) {
        self.primary = primary
        self.fallback = fallback
        self.scheduler = scheduler ?? FoundationMediaTimerScheduler()
        self.probeTimeout = probeTimeout
        bind(primary)
    }

    /// Sends through whichever provider is currently answering, so a command
    /// cannot land on a player that is not the one being reported.
    func send(_ command: SystemMediaCommand) async -> Bool {
        await (usingFallback ? fallback : primary).send(command)
    }

    func addConsumer() {
        consumers += 1
        guard consumers == 1 else { return }
        usingFallback = false
        bind(primary)
        primary.addConsumer()
        if isImmediateNoReply {
            activateFallback()
            return
        }
        settleToken = scheduler.schedule(after: probeTimeout) { [weak self] in
            self?.considerFallback()
        }
    }

    func removeConsumer() {
        guard consumers > 0 else { return }
        consumers -= 1
        guard consumers == 0 else { return }
        settleToken?.cancel()
        settleToken = nil
        if usingFallback {
            fallback.removeConsumer()
        } else {
            primary.removeConsumer()
        }
        usingFallback = false
    }

    func replayCurrentState() {
        if usingFallback {
            fallback.replayCurrentState()
        } else {
            primary.replayCurrentState()
        }
    }

    private func considerFallback() {
        settleToken = nil
        guard consumers > 0, !usingFallback else { return }
        if case .available = primary.availability { return }
        activateFallback()
    }

    /// MediaRemote already answered noReply; do not wait out the probe.
    private var isImmediateNoReply: Bool {
        guard case let .unavailable(reason) = primary.availability else { return false }
        return reason == MediaRemoteUnavailable(code: .noReply).localizedDescription
    }

    private func activateFallback() {
        guard !usingFallback else { return }
        usingFallback = true
        primary.removeConsumer()
        bind(fallback)
        fallback.addConsumer()
    }

    private func bind(_ provider: any SystemMediaProvider) {
        provider.onPropertiesChanged = { [weak self] value in
            self?.onPropertiesChanged?(value)
        }
        provider.onThumbnailChanged = { [weak self] value in
            self?.onThumbnailChanged?(value)
        }
        provider.onPlaybackChanged = { [weak self] value in
            self?.onPlaybackChanged?(value)
        }
        provider.onTimelineChanged = { [weak self] value in
            self?.onTimelineChanged?(value)
        }
    }
}
