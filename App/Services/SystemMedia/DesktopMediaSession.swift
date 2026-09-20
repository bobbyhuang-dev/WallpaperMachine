import Foundation

/// Process-wide now-playing session shared by web pages and scene wallpapers.
///
/// One system player, one provider, one relay. The web host and the scene sink
/// attach as listeners and consumers; neither constructs MediaRemote itself.
@MainActor
final class DesktopMediaSession {
    let provider: any SystemMediaProvider
    let relay: WebWallpaperMediaRelay

    init(provider: (any SystemMediaProvider)? = nil) {
        let resolved = provider ?? UnavailableSystemMediaProvider()
        self.provider = resolved
        self.relay = WebWallpaperMediaRelay(provider: resolved)
    }

    var availability: SystemMediaAvailability { relay.availability }

    /// Nil when a provider can supply media; otherwise why it cannot.
    var mediaUnavailableReason: String? {
        switch availability {
        case .available: nil
        case let .unavailable(reason): reason
        }
    }
}
