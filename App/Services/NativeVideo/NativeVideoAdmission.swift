import AVFoundation
import CoreMedia
import Foundation

/// Why the native player cannot take a wallpaper.
///
/// A refusal is a routing decision, not an error: the wallpaper goes back to
/// the scene engine, which supports everything this backend does not.
enum NativeVideoRefusal: Equatable {
    /// The clip can present frames faster than the user's target rate. There
    /// is no supported way to cap an `AVPlayerLayer`'s presentation rate:
    /// lowering the playback rate would slow the video down rather than limit
    /// it, and dropping frames by hand would mean copying every frame through
    /// the CPU. `bound` is the rate the metadata puts an upper limit at, and
    /// `source` says which field produced it.
    case targetFrameRateBelowContent(target: UInt32, bound: Double, source: String)
    /// Nothing in the track's metadata bounds its presentation rate, so this
    /// backend cannot promise the target rate. The scene engine can, because
    /// it paces its own frames.
    case frameRateNotDeterminable(String)
    /// The asset is not playable, or carries no video track. A settled answer
    /// about this file: retrying it would read the same bytes again.
    case notPlayable(String)
    /// Loading the asset's metadata failed. This is *not* a statement about
    /// the content — an I/O error, a file still being written, a busy
    /// device — so it is retried a bounded number of times before it becomes
    /// a handoff. Kept apart from `notPlayable` precisely so a transient
    /// failure cannot demote a wallpaper for the rest of the session.
    case preparationFailed(String)
    /// Metadata loaded and admission accepted, but the platform player then
    /// failed to prepare or play the asset. A settled answer for this file and
    /// configuration: the decoder read the same bytes and could not play them.
    /// Distinct from `preparationFailed`, which is a metadata read that did
    /// not complete and says nothing about the content.
    case playbackFailed(String)

    /// Whether this answer is settled for the inputs it was decided on. A
    /// settled refusal may be recorded and reported once; an unsettled one
    /// must be retried instead, within a bound.
    var isSettled: Bool {
        if case .preparationFailed = self { return false }
        return true
    }

    var reason: String {
        switch self {
        case let .targetFrameRateBelowContent(target, bound, source):
            return "target frame rate \(target) is below the clip's \(Self.format(bound)) fps "
                + "(from \(source)), which this backend cannot honour without changing "
                + "playback speed"
        case let .frameRateNotDeterminable(detail):
            return "frame rate cannot be bounded from metadata: \(detail)"
        case let .notPlayable(detail):
            return "asset is not playable: \(detail)"
        case let .preparationFailed(detail):
            return "asset metadata could not be read: \(detail)"
        case let .playbackFailed(detail):
            return "the platform player could not play the asset: \(detail)"
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// What the asset actually reported.
///
/// Recorded verbatim, including the unusable values, so a test can report the
/// API's own answer instead of the number its fixture generator was asked for.
struct NativeVideoTrackProbe: Equatable, Sendable {
    var isPlayable: Bool
    var hasVideoTrack: Bool
    /// `AVAssetTrack.nominalFrameRate`. An *average* over the track, and for
    /// interlaced content the *field* rate rather than the frame rate, so it
    /// is never a guarantee on its own.
    var nominalFrameRate: Float
    /// `AVAssetTrack.minFrameDuration`. Either a usable rational, or one of
    /// the unusable answers AVFoundation returns for a track it cannot
    /// summarise: invalid, indefinite, or zero.
    var minFrameDuration: CMTime
    /// Fields per frame from the format description, when it carries one.
    /// Two means interlaced, which makes `nominalFrameRate` ambiguous.
    var fieldCount: Int?

    init(
        isPlayable: Bool,
        hasVideoTrack: Bool,
        nominalFrameRate: Float,
        minFrameDuration: CMTime,
        fieldCount: Int? = nil
    ) {
        self.isPlayable = isPlayable
        self.hasVideoTrack = hasVideoTrack
        self.nominalFrameRate = nominalFrameRate
        self.minFrameDuration = minFrameDuration
        self.fieldCount = fieldCount
    }

    /// Human-readable dump of exactly what the API returned, for test records
    /// and log lines. `CMTime` is printed as its own rational so an invalid or
    /// indefinite answer stays distinguishable from a numeric one.
    var apiDescription: String {
        let duration: String
        if minFrameDuration.flags.contains(.indefinite) {
            duration = "indefinite"
        } else if !minFrameDuration.isValid || !minFrameDuration.flags.contains(.valid) {
            duration = "invalid"
        } else {
            duration = "\(minFrameDuration.value)/\(minFrameDuration.timescale)"
        }
        let fields = fieldCount.map(String.init) ?? "unknown"
        return "isPlayable=\(isPlayable) hasVideoTrack=\(hasVideoTrack) "
            + "nominalFrameRate=\(nominalFrameRate) minFrameDuration=\(duration) "
            + "fieldCount=\(fields)"
    }
}

/// Result of reading a candidate's metadata. A refusal here is a routing
/// decision like any other, so it is not modelled as a thrown error.
enum NativeVideoProbeOutcome: Equatable {
    case probed(NativeVideoTrackProbe)
    case refused(NativeVideoRefusal)
}

/// Decides whether the native backend may take a wallpaper.
///
/// The decision is split in two on purpose: `probe` is the only part that
/// touches AVFoundation, and `decide` is a pure function of what the probe
/// returned. That is what lets the rule be exercised over both real media and
/// metadata shapes no encoder here can produce.
enum NativeVideoAdmission {
    /// Relative slack for the float comparison. `nominalFrameRate` is a
    /// `Float`, so a rate that is exactly the target can come back a few ULPs
    /// either side of it. This absorbs that and nothing else: it is four parts
    /// in ten thousand, far below the smallest rate difference that matters
    /// (30 against 29.97 is one part in a thousand).
    static let floatRepresentationSlack = 1e-4

    static func evaluate(url: URL, targetFps: UInt32) async -> NativeVideoRefusal? {
        switch await probe(url: url) {
        case let .refused(refusal): return refusal
        case let .probed(probe): return decide(probe: probe, targetFps: targetFps)
        }
    }

    /// Reads the track metadata the decision needs, asynchronously. Nothing
    /// here decodes the media or walks the file: these are the asynchronous
    /// property loads AVFoundation offers for exactly this purpose.
    static func probe(url: URL) async -> NativeVideoProbeOutcome {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else {
                return .refused(.notPlayable("asset reports itself unplayable"))
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                return .refused(.notPlayable("no video track"))
            }
            let (nominal, minimum, formats) = try await track.load(
                .nominalFrameRate, .minFrameDuration, .formatDescriptions)
            return .probed(
                NativeVideoTrackProbe(
                    isPlayable: true,
                    hasVideoTrack: true,
                    nominalFrameRate: nominal,
                    minFrameDuration: minimum,
                    fieldCount: fieldCount(of: formats)))
        } catch {
            // A thrown load says nothing about the content: the file may be
            // half-written, the volume may be busy, the decoder may be
            // contended. `AVError.fileFormatNotRecognized` and friends are the
            // settled cases and AVFoundation reports them through
            // `isPlayable` above, which is why this arm is the unsettled one.
            return .refused(.preparationFailed(error.localizedDescription))
        }
    }

    /// The whole rule, as a pure function.
    ///
    /// The target rate is a playback constraint the user set, not a hint. This
    /// backend cannot cap what `AVPlayerLayer` presents, so a clip that can
    /// present faster than the target is refused rather than played at its own
    /// rate. Admission is therefore conservative in both directions: an upper
    /// bound that cannot be established at all is a refusal too.
    static func decide(probe: NativeVideoTrackProbe, targetFps: UInt32) -> NativeVideoRefusal? {
        guard probe.isPlayable else {
            return .notPlayable("asset reports itself unplayable")
        }
        guard probe.hasVideoTrack else {
            return .notPlayable("no video track")
        }
        guard targetFps > 0 else {
            return .frameRateNotDeterminable("target frame rate is zero")
        }
        // Interlaced content makes `nominalFrameRate` ambiguous — it is the
        // field rate for some encodes and the frame rate for others — and this
        // backend has no way to tell which presentation rate the display path
        // will choose. The scene engine paces its own frames, so it takes it.
        if let fields = probe.fieldCount, fields > 1 {
            return .frameRateNotDeterminable(
                "interlaced track: \(fields) fields per frame make nominalFrameRate ambiguous")
        }

        let target = CMTime(value: 1, timescale: CMTimeScale(min(targetFps, 0x7FFF_FFFF)))
        // An upper bound requires `minFrameDuration`. `nominalFrameRate` is an
        // *average* over the track, so a 24 fps average is equally consistent
        // with a constant 24 fps clip and with one that sits at 12 and bursts
        // to 60 — and the burst is what would be presented above the target.
        // An average can therefore only ever make the verdict stricter; it can
        // never be the thing that admits a clip. Without a usable shortest
        // frame duration nothing bounds the fastest moment, so the scene
        // engine, which paces its own frames, takes it.
        guard isUsable(probe.minFrameDuration) else {
            return .frameRateNotDeterminable(
                "minFrameDuration is not a usable duration, so no upper bound on the "
                    + "presentation rate exists (\(probe.apiDescription))")
        }
        // Compared as the rational it is, against the target's own rational.
        // No slack: a rational comparison has no representation error to
        // absorb, and 29.97 is already below 30 without one.
        if CMTimeCompare(probe.minFrameDuration, target) < 0 {
            return .targetFrameRateBelowContent(
                target: targetFps,
                bound: rate(of: probe.minFrameDuration),
                source: "minFrameDuration")
        }
        // The average is still checked, because a track whose average already
        // exceeds the target cannot possibly stay under it.
        if probe.nominalFrameRate > 0 {
            let nominal = Double(probe.nominalFrameRate)
            if nominal > Double(targetFps) * (1.0 + floatRepresentationSlack) {
                return .targetFrameRateBelowContent(
                    target: targetFps, bound: nominal, source: "nominalFrameRate")
            }
        }
        return nil
    }

    /// The highest presentation rate this track's metadata establishes, and
    /// which field established it — or `nil` when nothing does.
    ///
    /// `minFrameDuration` is required. It is the only field that speaks about
    /// the track's *fastest moment*; `nominalFrameRate` is an average, and an
    /// average cannot bound a maximum. Once a shortest frame duration exists,
    /// the larger of the two implied rates is the bound, because a nominal
    /// rate above it (a field rate on an interlaced encode, say) is still a
    /// rate the display path might produce.
    static func presentationRateBound(
        _ probe: NativeVideoTrackProbe
    ) -> (rate: Double, source: String)? {
        guard isUsable(probe.minFrameDuration) else { return nil }
        var best = (rate: rate(of: probe.minFrameDuration), source: "minFrameDuration")
        if probe.nominalFrameRate > 0 {
            let nominal = Double(probe.nominalFrameRate)
            if nominal > best.rate { best = (nominal, "nominalFrameRate") }
        }
        return best
    }

    /// Whether a `CMTime` from AVFoundation can be treated as a duration.
    /// Invalid, indefinite and zero all mean "no answer", and each of them
    /// silently becomes a huge or infinite frame rate if divided through.
    static func isUsable(_ time: CMTime) -> Bool {
        guard time.isValid, !time.isIndefinite, !time.flags.contains(.negativeInfinity),
            !time.flags.contains(.positiveInfinity)
        else { return false }
        return time.value > 0 && time.timescale > 0
    }

    static func rate(of duration: CMTime) -> Double {
        Double(duration.timescale) / Double(duration.value)
    }

    /// Fields per frame, read through the C accessor so an extension value of
    /// an unexpected type is a miss rather than a compile-time assumption.
    private static func fieldCount(of formats: [CMFormatDescription]) -> Int? {
        for format in formats {
            let value = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_FieldCount)
            if let number = value as? NSNumber {
                return number.intValue
            }
        }
        return nil
    }
}
