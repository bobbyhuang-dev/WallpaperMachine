import Foundation

@MainActor
protocol SystemMediaStreaming: AnyObject {
    func start(receive: @escaping (Data) -> Void, ended: @escaping () -> Void) throws
    func stop()
}

/// Runs the bundled, pinned adapter only while a wallpaper consumes media data.
@MainActor
final class BundledSystemMediaStream: SystemMediaStreaming {
    private var process: Process?
    private var output: Pipe?
    private let bundle: Bundle

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func start(receive: @escaping (Data) -> Void, ended: @escaping () -> Void) throws {
        stop()
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = bundle.privateFrameworksURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script.path, frameworks.appendingPathComponent("MediaRemoteAdapter.framework").path,
                          "stream", "--no-diff", "--debounce=100"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, let task, self.process === task, !data.isEmpty else { return }
                receive(data)
            }
        }
        task.terminationHandler = { [weak self, weak task] _ in
            Task { @MainActor in
                guard let self, let task, self.process === task else { return }
                self.stop()
                ended()
            }
        }
        process = task
        output = pipe
        do { try task.run() } catch { stop(); throw error }
    }

    func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        let previous = process
        process = nil
        previous?.terminationHandler = nil
        if previous?.isRunning == true { previous?.terminate() }
    }
}

@MainActor
final class AdapterSystemMediaProvider: SystemMediaProvider {
    private(set) var availability: SystemMediaAvailability = .unavailable(reason: String(localized: "Media integration has not been started."))
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

    private let stream: any SystemMediaStreaming
    private let artwork: MediaArtwork
    private let scheduler: any MediaTimerScheduling
    private let now: () -> Date
    private var consumers = 0
    private var buffer = Data()
    private var properties = SystemMediaProperties()
    private var thumbnail: SystemMediaThumbnail?
    private var playback = SystemMediaPlaybackState.stopped
    private var timeline: SystemMediaTimeline?
    private var timestamp = Date()
    private var rate = 0.0
    private var ticker: (any MediaTimerToken)?
    private var generation = 0

    init(stream: (any SystemMediaStreaming)? = nil, artwork: MediaArtwork? = nil,
         scheduler: (any MediaTimerScheduling)? = nil, now: @escaping () -> Date = Date.init) {
        self.stream = stream ?? BundledSystemMediaStream()
        self.artwork = artwork ?? MediaArtwork()
        self.scheduler = scheduler ?? FoundationMediaTimerScheduler()
        self.now = now
    }

    func addConsumer() {
        consumers += 1
        guard consumers == 1 else { return }
        generation += 1
        let current = generation
        do {
            try stream.start(receive: { [weak self] data in
                guard let self, self.generation == current, self.consumers > 0 else { return }
                self.receive(data)
            }, ended: { [weak self] in
                guard let self, self.generation == current else { return }
                self.fail()
            })
        } catch { fail() }
    }

    func removeConsumer() {
        guard consumers > 0 else { return }
        consumers -= 1
        guard consumers == 0 else { return }
        generation += 1
        stream.stop()
        ticker?.cancel()
        ticker = nil
        buffer.removeAll()
        properties = SystemMediaProperties()
        thumbnail = nil
        playback = .stopped
        timeline = nil
        availability = .unavailable(reason: String(localized: "Media integration has not been started."))
    }

    func replayCurrentState() {
        onPropertiesChanged?(properties)
        if let thumbnail { onThumbnailChanged?(thumbnail) }
        onPlaybackChanged?(playback)
        emitTimeline()
    }

    private func fail() {
        generation += 1
        stream.stop()
        ticker?.cancel()
        ticker = nil
        apply([:])
        availability = .unavailable(reason: String(localized: "The system media service is unavailable."))
        AppLog.warn("System media adapter stopped or could not start.")
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { buffer.removeAll(); fail(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  envelope["type"] as? String == "data",
                  envelope["diff"] as? Bool != true,
                  let payload = envelope["payload"] as? [String: Any] else { continue }
            availability = .available
            apply(payload)
        }
    }

    private func apply(_ payload: [String: Any]) {
        var next = SystemMediaProperties()
        next.title = payload["title"] as? String ?? ""
        next.artist = payload["artist"] as? String ?? ""
        next.albumTitle = payload["album"] as? String ?? ""
        let changed = next != properties
        if changed { properties = next; onPropertiesChanged?(next) }
        let cover = (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { artwork.thumbnail(for: $0) }
        if let cover, cover != thumbnail {
            thumbnail = cover
            onThumbnailChanged?(cover)
        } else if cover == nil && (changed || payload.isEmpty) {
            // An explicit empty image clears the previous track in both web and scene consumers.
            let empty = SystemMediaThumbnail(pngBase64DataURL: "", primaryColor: "rgb(0, 0, 0)",
                secondaryColor: "rgb(0, 0, 0)", tertiaryColor: "rgb(0, 0, 0)",
                textColor: "rgb(255, 255, 255)", highContrastColor: "rgb(255, 255, 255)")
            thumbnail = empty
            onThumbnailChanged?(empty)
        }
        let nextPlayback: SystemMediaPlaybackState = payload.isEmpty ? .stopped :
            (payload["playing"] as? Bool == true ? .playing : .paused)
        if playback != nextPlayback { playback = nextPlayback; onPlaybackChanged?(playback) }
        if let duration = payload["duration"] as? Double, duration.isFinite, duration > 0,
           let elapsed = payload["elapsedTime"] as? Double, elapsed.isFinite {
            timeline = SystemMediaTimeline(position: max(0, elapsed), duration: duration)
        } else { timeline = nil }
        let reportedTimestamp = payload["timestamp"] as? Double
        timestamp = reportedTimestamp.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            ?? (payload["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? now()
        let reportedRate = payload["playbackRate"] as? Double ?? 1
        rate = playback == .playing && reportedRate.isFinite ? max(0, reportedRate) : 0
        ticker?.cancel()
        ticker = nil
        emitTimeline()
        if playback == .playing, timeline != nil {
            ticker = scheduler.schedule(every: 1) { [weak self] in self?.emitTimeline() }
        }
    }

    private func emitTimeline() {
        guard playback == .playing, var value = timeline else { onTimelineChanged?(nil); return }
        value.position = min(value.duration, max(0, value.position + max(0, now().timeIntervalSince(timestamp)) * rate))
        onTimelineChanged?(value)
    }
}
