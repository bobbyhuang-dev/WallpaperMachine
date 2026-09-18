import XCTest

@testable import MacWallpaperEngine

/// The two host-side machines behind the author APIs: the single audio poller
/// shared by every display, and the media relay that decides what a page is
/// told about the system's playback. Neither needs a web view.
@MainActor
final class WebWallpaperAudioMediaTests: XCTestCase {
  // MARK: - audio pump

  func testPollingRunsOnlyWhileSomethingIsSubscribed() async throws {
    var reads = 0
    let pump = WebWallpaperAudioPump(
      read: {
        reads += 1
        return BridgeAudioSpectrum(
          generation: UInt64(reads), stereo: false, bins: [Float](repeating: 0, count: 128))
      },
      interval: .milliseconds(1))
    var delivered = 0
    pump.onSpectrum = { _ in delivered += 1 }
    let first = NSObject()
    let second = NSObject()

    XCTAssertFalse(pump.isPolling, "an idle desktop must not run a timer at all")
    pump.setSubscribed(true, for: ObjectIdentifier(first))
    XCTAssertTrue(pump.isPolling)
    try await poll { delivered >= 2 }

    pump.setSubscribed(true, for: ObjectIdentifier(second))
    pump.setSubscribed(true, for: ObjectIdentifier(second))
    XCTAssertEqual(pump.subscriberCount, 2, "subscribing twice is one subscriber")
    pump.setSubscribed(false, for: ObjectIdentifier(first))
    XCTAssertTrue(pump.isPolling, "a second page is still listening")

    pump.setSubscribed(false, for: ObjectIdentifier(second))
    XCTAssertFalse(pump.isPolling)
    let settled = reads
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(reads, settled, "nothing is read once the last page has gone")
  }

  func testASpectrumTheAnalyserDidNotRecomputeIsNotDeliveredAgain() async throws {
    var generation: UInt64 = 7
    var reads = 0
    let pump = WebWallpaperAudioPump(
      read: {
        reads += 1
        return BridgeAudioSpectrum(
          generation: generation, stereo: false, bins: [Float](repeating: 0.5, count: 128))
      },
      interval: .milliseconds(1))
    var delivered: [UInt64] = []
    pump.onSpectrum = { delivered.append($0.generation) }
    let page = NSObject()
    pump.setSubscribed(true, for: ObjectIdentifier(page))

    try await poll { reads >= 5 }
    XCTAssertEqual(delivered, [7], "repeated reads of one generation wake the page once")

    generation = 8
    try await poll { delivered.count == 2 }
    XCTAssertEqual(delivered, [7, 8])
    pump.setSubscribed(false, for: ObjectIdentifier(page))
  }

  func testAFailingAnalyserStopsDeliveryWithoutStoppingThePump() async throws {
    struct Unavailable: Error {}
    var reads = 0
    let pump = WebWallpaperAudioPump(
      read: {
        reads += 1
        throw Unavailable()
      },
      interval: .milliseconds(1))
    var delivered = 0
    pump.onSpectrum = { _ in delivered += 1 }
    let page = NSObject()
    pump.setSubscribed(true, for: ObjectIdentifier(page))

    try await poll { reads >= 3 }
    XCTAssertEqual(delivered, 0, "a failed read is not a frame")
    XCTAssertTrue(pump.isPolling, "one failure must not permanently silence a recovering analyser")
    pump.setSubscribed(false, for: ObjectIdentifier(page))
  }

  // MARK: - media relay

  func testProviderConsumersReturnToZeroWhenEveryPageLeaves() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    let first = NSObject()
    let second = NSObject()

    relay.setConsuming(true, for: ObjectIdentifier(first))
    relay.setConsuming(true, for: ObjectIdentifier(first))
    XCTAssertEqual(provider.consumers, 1, "one page is one consumer however often it says so")

    relay.setConsuming(true, for: ObjectIdentifier(second))
    XCTAssertEqual(provider.consumers, 2)
    relay.setConsuming(false, for: ObjectIdentifier(first))
    XCTAssertEqual(provider.consumers, 1, "another visible page must keep the provider running")

    relay.setConsuming(false, for: ObjectIdentifier(second))
    XCTAssertEqual(provider.consumers, 0)
    XCTAssertEqual(relay.consumerCount, 0)
  }

  func testRemovingEveryConsumerAtOnceReleasesThemAll() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    let pages = [NSObject(), NSObject(), NSObject()]
    for page in pages { relay.setConsuming(true, for: ObjectIdentifier(page)) }
    XCTAssertEqual(provider.consumers, 3)

    relay.removeAllConsumers()
    XCTAssertEqual(provider.consumers, 0)
    relay.removeAllConsumers()
    XCTAssertEqual(provider.consumers, 0, "a second sweep must not drive the count negative")
  }

  func testAnUnavailableProviderIsReportedAsTheUserSettingWithNothingInvented() {
    let provider = FakeSystemMediaProvider()
    provider.availability = .unavailable(reason: "MediaRemote returns nothing without the entitlement")
    let relay = WebWallpaperMediaRelay(provider: provider)
    relay.setConsuming(true, for: ObjectIdentifier(self))

    XCTAssertEqual(
      relay.currentEvents(userEnabled: true),
      [.status(true), .properties(SystemMediaProperties()), .playback(.stopped)],
      "the status listener reports the user's setting; nothing else may be made up")
  }

  func testUnchangedProviderValuesEmitNothingAndFieldsAreIndependent() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    var events: [WebWallpaperMediaRelay.Event] = []
    relay.onChange = { events.append($0) }
    relay.setConsuming(true, for: ObjectIdentifier(self))
    events.removeAll()

    let track = SystemMediaProperties(title: "Track", artist: "Artist")
    provider.onPropertiesChanged?(track)
    provider.onPropertiesChanged?(track)
    XCTAssertEqual(events, [.properties(track)])

    events.removeAll()
    provider.onPlaybackChanged?(.playing)
    provider.onPlaybackChanged?(.playing)
    XCTAssertEqual(events, [.playback(.playing)], "a repeated state is not a change")

    events.removeAll()
    provider.onPropertiesChanged?(SystemMediaProperties(title: "Next", artist: "Artist"))
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first, .properties(SystemMediaProperties(title: "Next", artist: "Artist")))
  }

  func testATimelineTheProviderWithdrewEmitsNothingRatherThanZero() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    var events: [WebWallpaperMediaRelay.Event] = []
    relay.onChange = { events.append($0) }
    relay.setConsuming(true, for: ObjectIdentifier(self))
    events.removeAll()

    let timeline = SystemMediaTimeline(position: 12, duration: 240)
    provider.onTimelineChanged?(timeline)
    XCTAssertEqual(events, [.timeline(timeline)])

    events.removeAll()
    provider.onTimelineChanged?(nil)
    XCTAssertTrue(events.isEmpty, "there is no 'no timeline' event; a wallpaper must cope with silence")
    XCTAssertFalse(
      relay.currentEvents(userEnabled: true).contains {
        if case .timeline = $0 { return true } else { return false }
      },
      "a withdrawn timeline must not be replayed to the next page")
  }

  func testTheLastConsumerLeavingForgetsTheTrack() {
    let provider = FakeSystemMediaProvider()
    let relay = WebWallpaperMediaRelay(provider: provider)
    let page = NSObject()
    relay.setConsuming(true, for: ObjectIdentifier(page))
    provider.onPropertiesChanged?(SystemMediaProperties(title: "Track"))
    provider.onPlaybackChanged?(.playing)
    provider.onThumbnailChanged?(Self.thumbnail)

    relay.setConsuming(false, for: ObjectIdentifier(page))
    XCTAssertEqual(
      relay.currentEvents(userEnabled: true),
      [.status(true), .properties(SystemMediaProperties()), .playback(.stopped)],
      "nothing is being watched, so nothing is known; handing the next page the old track invents it")
  }

  func testReplayingAnAlreadyKnownStateDoesNotRebroadcastIt() {
    let provider = FakeSystemMediaProvider()
    provider.properties = SystemMediaProperties(title: "Track")
    provider.playback = .playing
    let relay = WebWallpaperMediaRelay(provider: provider)
    var events: [WebWallpaperMediaRelay.Event] = []
    relay.onChange = { events.append($0) }

    let first = NSObject()
    relay.setConsuming(true, for: ObjectIdentifier(first))
    XCTAssertEqual(
      events, [.properties(SystemMediaProperties(title: "Track")), .playback(.playing)],
      "the first consumer learns the current state")

    // A second page joining replays the provider, which must not re-deliver
    // state the pages already listening have seen.
    events.removeAll()
    let second = NSObject()
    relay.setConsuming(true, for: ObjectIdentifier(second))
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(
      relay.currentEvents(userEnabled: false).first, .status(false),
      "the joining page is given the state directly, with its own wallpaper's setting")
  }

  // MARK: - helpers

  private static let thumbnail = SystemMediaThumbnail(
    pngBase64DataURL: "data:image/png;base64,iVBORw0KGgo=",
    primaryColor: "rgb(10, 20, 30)", secondaryColor: "rgb(40, 50, 60)",
    tertiaryColor: "rgb(70, 80, 90)", textColor: "rgb(255, 255, 255)",
    highContrastColor: "rgb(255, 255, 255)")

  private func poll(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("condition not met before timeout")
  }
}

/// A `SystemMediaProvider` that reports exactly what the test set, so the relay
/// is exercised without MediaRemote, a running player or an entitlement.
@MainActor
final class FakeSystemMediaProvider: SystemMediaProvider {
  var availability: SystemMediaAvailability = .available
  var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
  var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
  var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
  var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

  private(set) var consumers = 0
  private(set) var replays = 0
  var properties = SystemMediaProperties()
  var playback = SystemMediaPlaybackState.stopped
  var thumbnail: SystemMediaThumbnail?
  var timeline: SystemMediaTimeline?

  func addConsumer() { consumers += 1 }
  func removeConsumer() { consumers -= 1 }

  func replayCurrentState() {
    replays += 1
    onPropertiesChanged?(properties)
    if let thumbnail { onThumbnailChanged?(thumbnail) }
    onPlaybackChanged?(playback)
    if let timeline { onTimelineChanged?(timeline) }
  }
}
