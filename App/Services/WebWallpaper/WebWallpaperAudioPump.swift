import Foundation

/// Reads the renderer's audio analysis and hands each newly computed spectrum
/// to whoever is subscribed.
///
/// One pump serves every display. The analysis is process-global, so a timer
/// per page would repeat the same read once per screen, and the tap it feeds is
/// opened by demand rather than by the wallpaper merely existing: with nothing
/// subscribed there is no timer at all, not a timer that reads and discards.
@MainActor
final class WebWallpaperAudioPump {
    /// The Wallpaper Engine listener contract fires at roughly 20 Hz. 30 Hz is
    /// the ceiling here so a page that reacts per frame is not starved, while a
    /// 120 Hz display never drags the renderer into a per-refresh read.
    nonisolated static let defaultInterval = Duration.milliseconds(33)

    private let read: @MainActor () throws -> BridgeAudioSpectrum?
    private let wait: @Sendable (Duration) async throws -> Void
    private let interval: Duration
    private var subscribers: Set<ObjectIdentifier> = []
    private var task: Task<Void, Never>?
    /// Only a spectrum the analyser actually recomputed is worth waking a page
    /// for; between recomputations the buffer holds the same numbers.
    private var lastGeneration: UInt64?
    private var readFailureLogged = false

    /// Called on the main actor with each new spectrum, never with a repeat.
    var onSpectrum: (@MainActor (BridgeAudioSpectrum) -> Void)?

    /// Whether the shared timer exists at all.
    var isPolling: Bool { task != nil }
    var subscriberCount: Int { subscribers.count }

    init(
        read: @escaping @MainActor () throws -> BridgeAudioSpectrum?,
        interval: Duration = WebWallpaperAudioPump.defaultInterval,
        wait: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.read = read
        self.interval = interval
        self.wait = wait ?? { try await Task.sleep(for: $0) }
    }

    func setSubscribed(_ subscribed: Bool, for key: ObjectIdentifier) {
        let changed = subscribed ? subscribers.insert(key).inserted : subscribers.remove(key) != nil
        guard changed else { return }
        if subscribers.isEmpty {
            stop()
        } else if task == nil {
            start()
        }
    }

    func removeAllSubscribers() {
        guard !subscribers.isEmpty else { return }
        subscribers.removeAll()
        stop()
    }

    private func start() {
        // A serial loop rather than a repeating timer: the next read is only
        // issued after the previous delivery, so a slow frame delays the next
        // sample instead of queueing a backlog of stale spectra behind it.
        task = Task { @MainActor [weak self, wait, interval] in
            while !Task.isCancelled {
                guard let self, !self.subscribers.isEmpty else { return }
                self.pollOnce()
                guard !Task.isCancelled else { return }
                do { try await wait(interval) } catch { return }
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        // The next subscriber must be given the first spectrum it sees, even if
        // the analyser has not recomputed since the last one left.
        lastGeneration = nil
    }

    private func pollOnce() {
        do {
            guard let spectrum = try read() else { return }
            readFailureLogged = false
            guard spectrum.generation != lastGeneration else { return }
            lastGeneration = spectrum.generation
            onSpectrum?(spectrum)
        } catch {
            // A failing analyser fails every poll; one line is the whole story.
            guard !readFailureLogged else { return }
            readFailureLogged = true
            AppLog.warn("web wallpaper audio: spectrum unavailable: \(error.localizedDescription)")
        }
    }
}
