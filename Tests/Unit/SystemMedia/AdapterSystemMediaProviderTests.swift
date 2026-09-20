import XCTest
@testable import MacWallpaperEngine

@MainActor
private final class TestMediaStream: SystemMediaStreaming {
    var receive: ((Data) -> Void)?
    var ended: (() -> Void)?
    var starts = 0
    var stops = 0
    func start(receive: @escaping (Data) -> Void, ended: @escaping () -> Void) throws {
        starts += 1
        self.receive = receive
        self.ended = ended
    }
    func stop() { stops += 1 }
    func send(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": payload])
        data.append(10)
        receive?(data)
    }
}

final class AdapterSystemMediaProviderTests: XCTestCase {
    @MainActor
    func testFragmentedMessagesDeliverMetadataAndInterpolateTimeline() throws {
        let stream = TestMediaStream()
        let timer = ManualMediaTimerScheduler()
        var now = Date(timeIntervalSince1970: 100)
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: timer, now: { now })
        var properties: SystemMediaProperties?
        var timeline: SystemMediaTimeline?
        provider.onPropertiesChanged = { properties = $0 }
        provider.onTimelineChanged = { timeline = $0 }
        XCTAssertEqual(stream.starts, 0)
        provider.addConsumer()
        let line = Data("{\"type\":\"data\",\"diff\":false,\"payload\":{\"title\":\"Track\",\"artist\":\"Artist\",\"playing\":true,\"duration\":120,\"elapsedTime\":10,\"timestamp\":100}}\n".utf8)
        stream.receive?(line.prefix(35))
        XCTAssertNil(properties)
        stream.receive?(line.dropFirst(35))
        XCTAssertEqual(properties?.title, "Track")
        XCTAssertEqual(properties?.artist, "Artist")
        XCTAssertEqual(timeline?.position, 10)
        now.addTimeInterval(5)
        timer.fireRepeating()
        XCTAssertEqual(timeline?.position, 15)
        try stream.send(["title": "Track", "playing": false])
        XCTAssertNil(timeline)
        XCTAssertTrue(timer.liveRepeating.isEmpty)
        provider.removeConsumer()
    }

    @MainActor
    func testTrackChangeWithoutArtworkAndEmptyPlayerClearPreviousData() throws {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: ManualMediaTimerScheduler())
        var covers: [String] = []
        var title = ""
        var playback = SystemMediaPlaybackState.stopped
        provider.onThumbnailChanged = { covers.append($0.pngBase64DataURL) }
        provider.onPropertiesChanged = { title = $0.title }
        provider.onPlaybackChanged = { playback = $0 }
        provider.addConsumer()
        let png = try makeSyntheticPNG(width: 2, height: 2) { _, _ in (255, 0, 0) }
        try stream.send(["title": "First", "playing": true, "artworkData": png.base64EncodedString()])
        XCTAssertTrue(covers.last?.hasPrefix("data:image/png;base64,") == true)
        try stream.send(["title": "Second", "playing": true])
        XCTAssertEqual(covers.last, "")
        try stream.send([:])
        XCTAssertEqual(title, "")
        XCTAssertEqual(playback, .stopped)
        provider.removeConsumer()
    }

    @MainActor
    func testLastConsumerStopsStreamAndLateCallbacksCannotReviveIt() throws {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: ManualMediaTimerScheduler())
        var titles: [String] = []
        provider.onPropertiesChanged = { titles.append($0.title) }
        provider.addConsumer()
        provider.addConsumer()
        XCTAssertEqual(stream.starts, 1)
        provider.removeConsumer()
        XCTAssertEqual(stream.stops, 0)
        provider.removeConsumer()
        XCTAssertEqual(stream.stops, 1)
        try stream.send(["title": "Late", "playing": true])
        XCTAssertTrue(titles.isEmpty)
    }

    @MainActor
    func testUnexpectedExitClearsStateAndReportsUnavailableWithoutRestartLoop() throws {
        let stream = TestMediaStream()
        let provider = AdapterSystemMediaProvider(stream: stream, scheduler: ManualMediaTimerScheduler())
        var title = ""
        provider.onPropertiesChanged = { title = $0.title }
        provider.addConsumer()
        try stream.send(["title": "Playing", "playing": true])
        stream.ended?()
        XCTAssertEqual(title, "")
        guard case .unavailable = provider.availability else { return XCTFail("exit must report unavailable") }
        XCTAssertEqual(stream.starts, 1)
        provider.removeConsumer()
    }
}
