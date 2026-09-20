import XCTest

@testable import MacWallpaperEngine

@MainActor
final class SceneMediaSinkTests: XCTestCase {
    /// Swapping one opted-in Scene for another, or lighting a second display,
    /// hands the engine a scene that has been told nothing. The track has not
    /// changed, so no provider callback will fire; without a replay keyed on
    /// the new handle the new instance stays blank until the song does change.
    func testAReplacementSceneIsToldTheUnchangedTrack() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var submitted: [String] = []
        var artwork: [(UInt32, UInt32, Int)] = []
        var handles: Set<UInt64> = [11]
        let sink = SceneMediaSink(
            session: session,
            submit: { submitted.append($0) },
            applyArtwork: { width, height, data in artwork.append((width, height, data.count)) },
            fetchHandles: { handles })

        sink.reconcile()
        try await poll { !submitted.isEmpty }
        provider.emitPlaying(title: "Bohemian Rhapsody")
        try await poll { submitted.contains { $0.contains("Bohemian Rhapsody") } }

        submitted.removeAll()
        artwork.removeAll()
        handles = [12]
        sink.reconcile()
        try await poll { submitted.contains { $0.contains("Bohemian Rhapsody") } }

        XCTAssertTrue(
            submitted.contains { $0.contains("\"state\":0") },
            "the replacement is told playback too, not only the title")
        XCTAssertEqual(artwork.first?.2, 4, "the cover pixels are re-uploaded for the new scene")

        submitted.removeAll()
        sink.reconcile()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(submitted.isEmpty, "a handle already fed is not replayed to again")
    }

    /// Consent gone means the source stops; nothing is read and nothing is sent.
    func testNoConsentingSceneStopsTheProvider() async throws {
        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        var handles: Set<UInt64> = [11]
        let sink = SceneMediaSink(
            session: session, submit: { _ in }, applyArtwork: { _, _, _ in },
            fetchHandles: { handles })

        sink.reconcile()
        try await poll { provider.consumers == 1 }

        handles = []
        sink.reconcile()
        try await poll { provider.consumers == 0 }
    }

    private func poll(timeout: TimeInterval = 2, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not reached within \(timeout)s") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A provider whose state a test writes directly. Nothing here loads
/// MediaRemote, runs a script or reads what the machine is playing.
@MainActor
final class ScriptedSystemMediaProvider: SystemMediaProvider {
    var availability: SystemMediaAvailability = .available
    var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
    var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
    var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
    var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?
    private(set) var consumers = 0
    private var properties = SystemMediaProperties()
    private var thumbnail: SystemMediaThumbnail?
    private var playback = SystemMediaPlaybackState.stopped

    func addConsumer() { consumers += 1 }
    func removeConsumer() { consumers = max(0, consumers - 1) }

    func replayCurrentState() {
        onPropertiesChanged?(properties)
        if let thumbnail { onThumbnailChanged?(thumbnail) }
        onPlaybackChanged?(playback)
    }

    func emitPlaying(title: String) {
        properties.title = title
        playback = .playing
        thumbnail = SystemMediaThumbnail(
            pngBase64DataURL: "data:image/png;base64,",
            primaryColor: "rgb(232, 80, 58)", secondaryColor: "rgb(30, 22, 21)",
            tertiaryColor: "rgb(190, 150, 100)", textColor: "rgb(255, 255, 255)",
            highContrastColor: "rgb(0, 0, 0)", rgba: [232, 80, 58, 255], width: 1, height: 1)
        replayCurrentState()
    }
}
