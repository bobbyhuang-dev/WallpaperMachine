import Foundation

/// Whether this machine will report what another application is playing.
///
/// macOS publishes no API for reading another process's now-playing state, so
/// `unavailable` is the ordinary answer rather than an error path, and it carries
/// the sentence shown in place of a media panel.
enum SystemMediaAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

/// Playback states of the Wallpaper Engine media protocol. The raw values are the
/// `wallpaperMediaIntegration.PLAYBACK_*` constants handed to author pages.
enum SystemMediaPlaybackState: Int, Sendable {
    case playing = 0
    case paused = 1
    case stopped = 2
}

/// The text fields of a `wallpaperRegisterMediaPropertiesListener` event. Every field
/// is a string because the protocol hands the page strings, and an absent field is an
/// empty string rather than a missing key.
struct SystemMediaProperties: Equatable, Sendable {
    var title = ""
    var artist = ""
    var subTitle = ""
    var albumTitle = ""
    var albumArtist = ""
    var genres = ""
    var contentType = "music"
}

/// The payload of a `wallpaperRegisterMediaThumbnailListener` event: cover art the page
/// can assign straight to `img.src`, plus the palette pages tint themselves with.
///
/// `rgba` is the same image as the data URL, kept so a scene wallpaper can upload
/// `$mediaThumbnail` without decoding the PNG again. Empty when a test or a
/// provider supplied colours without pixels.
struct SystemMediaThumbnail: Equatable, Sendable {
    var pngBase64DataURL: String
    var primaryColor: String
    var secondaryColor: String
    var tertiaryColor: String
    /// Readable against `primaryColor`; see `MediaArtwork` for the contrast rule.
    var textColor: String
    var highContrastColor: String
    /// Premultiplied RGBA8, `width * height * 4` bytes. Empty when unknown.
    var rgba: [UInt8] = []
    var width: Int = 0
    var height: Int = 0
}

/// The payload of a `wallpaperRegisterMediaTimelineListener` event, in seconds.
struct SystemMediaTimeline: Equatable, Sendable {
    var position: Double
    var duration: Double
}

/// Source of system now-playing state for web and scene media integration.
///
/// The provider is dormant until a wallpaper asks for it: nothing is loaded, probed or
/// observed before the first `addConsumer()`, and everything is released again at zero.
/// Each callback fires only when its own part of the state changed, matching the
/// protocol's promise that a listener is called when that specific part changes.
@MainActor
protocol SystemMediaProvider: AnyObject {
    var availability: SystemMediaAvailability { get }
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)? { get set }
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)? { get set }
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)? { get set }
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)? { get set }
    func addConsumer()
    func removeConsumer()
    /// Re-emits whatever is currently known, for a page that registered its listeners
    /// after the state was first delivered.
    func replayCurrentState()
}
