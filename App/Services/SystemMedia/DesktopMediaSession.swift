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

    /// Carries a transport command to whichever provider is answering, so a
    /// press cannot land on a player that is not the one being reported.
    func send(_ command: SystemMediaCommand) async -> Bool {
        await provider.send(command)
    }

    /// Nil when a provider can supply media; otherwise why it cannot.
    var mediaUnavailableReason: String? {
        switch availability {
        case .available: nil
        case let .unavailable(reason): reason
        }
    }
}
