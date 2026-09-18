import XCTest

@testable import MacWallpaperEngine

/// The now-playing provider's state machine, driven entirely by injected fakes.
///
/// Nothing here loads `MediaRemote`, calls it, or reads what this machine is playing. The
/// real framework is private and, since macOS 15.4, answers nothing to an app without
/// Apple's entitlement — which is precisely the case `testASystemThatNeverAnswers…` covers.
@MainActor
final class MediaRemoteMediaProviderTests: XCTestCase {
    private var center: NotificationCenter!
    private var scheduler: ManualMediaTimerScheduler!
    private var symbols: FakeMediaRemoteSymbols!
    private var clock: Date!

    private var properties: [SystemMediaProperties] = []
    private var thumbnails: [SystemMediaThumbnail] = []
    private var playback: [SystemMediaPlaybackState] = []
    private var timeline: [SystemMediaTimeline?] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        center = NotificationCenter()
        scheduler = ManualMediaTimerScheduler()
        symbols = FakeMediaRemoteSymbols()
        clock = Date(timeIntervalSince1970: 1_000_000)
        properties = []
        thumbnails = []
        playback = []
        timeline = []
    }

    private func makeProvider(
        loader: (any MediaRemoteLoading)? = nil, artwork: MediaArtwork? = nil
    ) -> MediaRemoteMediaProvider {
        let provider = MediaRemoteMediaProvider(
            loader: loader ?? FakeMediaRemoteLoader(.success(symbols)),
            notificationCenter: center,
            scheduler: scheduler,
            artwork: artwork ?? MediaArtwork(),
            now: { [weak self] in self?.clock ?? Date(timeIntervalSince1970: 0) })
        provider.onPropertiesChanged = { [weak self] in self?.properties.append($0) }
        provider.onThumbnailChanged = { [weak self] in self?.thumbnails.append($0) }
        provider.onPlaybackChanged = { [weak self] in self?.playback.append($0) }
        provider.onTimelineChanged = { [weak self] in self?.timeline.append($0) }
        return provider
    }

    private func postInfoChange() {
        center.post(name: symbols.notificationNames.infoDidChange, object: nil)
    }

    // MARK: - Availability

    func testAMissingSymbolLeavesTheProviderUnavailableAndSilent() {
        let provider = makeProvider(
            loader: FakeMediaRemoteLoader(
                .failure(MediaRemoteUnavailable(code: .symbolMissing("MRMediaRemoteGetNowPlayingInfo")))))
        let initial = provider.availability
        provider.addConsumer()

        guard case .unavailable(let reason) = provider.availability else {
            return XCTFail("A symbol table that will not load cannot be available")
        }
        XCTAssertFalse(reason.isEmpty, "An unavailable provider must say why")
        XCTAssertNotEqual(
            provider.availability, initial,
            "The reason must change from 'not started' to the real classification")
        XCTAssertEqual(properties, [])
        XCTAssertEqual(playback, [])
        XCTAssertEqual(timeline.count, 0)
        XCTAssertTrue(scheduler.liveRepeating.isEmpty, "A dead provider must schedule no work")
    }

    func testASystemThatNeverAnswersIsUnavailableAndIsNotPolled() {
        symbols.answers = false
        symbols.information = [MediaRemoteInfoKey.title: "Something private"]
        let provider = makeProvider()

        provider.addConsumer()
        XCTAssertEqual(
            symbols.registrations, 0,
            "Nothing may be registered until the capability probe has succeeded")
        XCTAssertEqual(scheduler.liveDelayed.count, 1, "The probe must be bounded by a timeout")

        scheduler.fireDelayed()
        guard case .unavailable(let reason) = provider.availability else {
            return XCTFail("A system that never replies cannot be reported as available")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(symbols.registrations, 0)
        XCTAssertEqual(properties, [], "A capability probe must not surface what is playing")
        XCTAssertTrue(
            scheduler.liveRepeating.isEmpty,
            "An unproductive system must not be turned into a polling loop")
    }

    // MARK: - Consumers

    func testRegistrationFollowsTheConsumerCount() {
        symbols.information = [MediaRemoteInfoKey.title: "Track"]
        let provider = makeProvider()

        provider.addConsumer()
        XCTAssertEqual(provider.availability, .available)
        XCTAssertEqual(symbols.registrations, 1)

        provider.addConsumer()
        XCTAssertEqual(symbols.registrations, 1, "A second consumer must not register again")

        let beforeNotification = symbols.infoRequests
        postInfoChange()
        XCTAssertGreaterThan(
            symbols.infoRequests, beforeNotification, "A change notification must refetch state")

        provider.removeConsumer()
        XCTAssertEqual(symbols.unregistrations, 0, "One consumer left keeps the provider running")

        provider.removeConsumer()
        XCTAssertEqual(symbols.unregistrations, 1)
        let afterStop = symbols.infoRequests
        postInfoChange()
        XCTAssertEqual(
            symbols.infoRequests, afterStop,
            "At zero consumers nothing may still be observing the system")
    }

    // MARK: - Properties

    func testPropertiesAreEmittedOnlyWhenTheyChange() throws {
        symbols.information = [
            MediaRemoteInfoKey.title: "Ritual Union",
            MediaRemoteInfoKey.artist: "Little Dragon",
            MediaRemoteInfoKey.album: "Ritual Union",
            MediaRemoteInfoKey.genre: "Electronic",
            MediaRemoteInfoKey.mediaType: "MRMediaRemoteMediaTypeVideo",
        ]
        let provider = makeProvider()
        provider.addConsumer()

        let first = try XCTUnwrap(properties.first)
        XCTAssertEqual(first.title, "Ritual Union")
        XCTAssertEqual(first.artist, "Little Dragon")
        XCTAssertEqual(first.albumTitle, "Ritual Union")
        XCTAssertEqual(first.genres, "Electronic")
        XCTAssertEqual(first.contentType, "video")
        XCTAssertEqual(first.albumArtist, "", "A field the system never sent stays empty")

        postInfoChange()
        XCTAssertEqual(properties.count, 1, "Unchanged properties must not fire the listener")

        symbols.information?[MediaRemoteInfoKey.title] = "Twice"
        postInfoChange()
        XCTAssertEqual(properties.count, 2)
        XCTAssertEqual(properties.last?.title, "Twice")
    }

    func testAnEmptyNowPlayingDictionaryIsReportedAsStopped() {
        symbols.information = [:]
        let provider = makeProvider()
        provider.addConsumer()

        XCTAssertEqual(playback, [], "Stopped is already the starting state; nothing changed")
        XCTAssertEqual(timeline.count, 0)
    }

    // MARK: - Playback

    func testPlaybackReachesPlayingWithoutAPauseThatNeverHappened() {
        symbols.information = [MediaRemoteInfoKey.title: "Track"]
        symbols.playing = true
        let provider = makeProvider()
        provider.addConsumer()

        XCTAssertEqual(
            playback, [.playing],
            "The track and the play flag arrive separately; the page must not see a phantom pause")
    }

    // MARK: - Timeline

    func testTimelineIsNilWhenTheSystemSuppliedNoDuration() {
        symbols.information = [MediaRemoteInfoKey.title: "Live stream"]
        symbols.playing = true
        let provider = makeProvider()
        provider.addConsumer()

        XCTAssertEqual(timeline.count, 1)
        XCTAssertNil(timeline[0], "No duration means no timeline, never a fabricated one")
        XCTAssertTrue(scheduler.liveRepeating.isEmpty, "There is nothing to tick without a duration")
    }

    func testTheTimelineTicksOncePerSecondWhilePlayingAndNotAtAllWhilePaused() throws {
        let anchor: Date = clock
        symbols.information = [
            MediaRemoteInfoKey.title: "Track",
            MediaRemoteInfoKey.duration: 240.0,
            MediaRemoteInfoKey.elapsedTime: 30.0,
            MediaRemoteInfoKey.playbackRate: 1.0,
            MediaRemoteInfoKey.timestamp: anchor,
        ]
        symbols.playing = false
        let provider = makeProvider()
        provider.addConsumer()

        XCTAssertEqual(playback, [.paused])
        XCTAssertEqual(timeline.count, 0, "A paused player must not push a timeline")
        XCTAssertTrue(scheduler.liveRepeating.isEmpty)

        symbols.playing = true
        center.post(name: symbols.notificationNames.isPlayingDidChange, object: nil)
        let started = try XCTUnwrap(timeline.last ?? nil)
        XCTAssertEqual(started.position, 30, accuracy: 0.001)
        XCTAssertEqual(started.duration, 240, accuracy: 0.001)
        XCTAssertEqual(scheduler.liveRepeating.count, 1)
        XCTAssertEqual(scheduler.liveRepeating[0].interval, 1, "The push must be capped at 1 Hz")

        clock = clock.addingTimeInterval(5)
        scheduler.fireRepeating()
        let advanced = try XCTUnwrap(timeline.last ?? nil)
        XCTAssertEqual(
            advanced.position, 35, accuracy: 0.001,
            "The position comes from the system's own anchor, not from counting ticks")

        symbols.playing = false
        center.post(name: symbols.notificationNames.isPlayingDidChange, object: nil)
        let afterPause = timeline.count
        XCTAssertTrue(scheduler.liveRepeating.isEmpty, "Pausing must stop the ticker")
        clock = clock.addingTimeInterval(5)
        scheduler.fireRepeating()
        XCTAssertEqual(timeline.count, afterPause, "No timeline callbacks while paused")
    }

    // MARK: - Artwork

    func testCoverArtIsEmittedOnlyWhenTheSystemActuallySentSome() throws {
        let cover = try makeSolidPNG(40, 90, 160)
        symbols.information = [MediaRemoteInfoKey.title: "Track"]
        let provider = makeProvider()
        provider.addConsumer()
        XCTAssertEqual(thumbnails.count, 0, "No artwork means no thumbnail event, not a blank one")

        symbols.information = [
            MediaRemoteInfoKey.title: "Track", MediaRemoteInfoKey.artworkData: cover,
        ]
        postInfoChange()
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertTrue(try XCTUnwrap(thumbnails.first).pngBase64DataURL.hasPrefix("data:image/png;base64,"))

        symbols.information = [
            MediaRemoteInfoKey.title: "Another track", MediaRemoteInfoKey.artworkData: cover,
        ]
        postInfoChange()
        XCTAssertEqual(properties.count, 2, "The track changed")
        XCTAssertEqual(
            thumbnails.count, 1, "The same cover on a new track is not a thumbnail change")
    }

    // MARK: - Replay

    func testReplayRepeatsKnownStateWithoutInventingATimeline() throws {
        symbols.information = [MediaRemoteInfoKey.title: "Track"]
        symbols.playing = false
        let provider = makeProvider()
        provider.addConsumer()
        properties = []
        playback = []
        timeline = []

        provider.replayCurrentState()
        XCTAssertEqual(properties.count, 1)
        XCTAssertEqual(playback, [.paused])
        XCTAssertEqual(timeline.count, 0, "A paused timeline is never pushed, replay included")
    }
}
