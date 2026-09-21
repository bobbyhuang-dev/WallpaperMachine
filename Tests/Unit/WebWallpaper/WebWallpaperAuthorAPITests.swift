import WebKit
import XCTest

@testable import WallpaperMachine

/// The Wallpaper Engine author APIs as a page actually sees them: audio, the
/// five media listeners, random-file requests and directory callbacks, driven
/// against a real offscreen `WKWebView`. No desktop window is created and the
/// page is never put in a window tree.
@MainActor
final class WebWallpaperAuthorAPITests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-author-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    // Registration is driven from the test rather than from the page, so the
    // order of registration against host delivery is exact.
    try """
      <!doctype html><html><body><script>
      window.__received = {
        audio: [], status: [], properties: [], thumbnail: [], playback: [], timeline: [],
        random: [], dirAdded: [], dirRemoved: [],
      };
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  // MARK: - audio

  func testReRegisteringTheAudioListenerNeitherDoublesDeliveryNorReopensTheTap() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [Bool] = []
    page.onAudioDemandChanged = { demands.append($0) }
    page.setAudioResponseEnabled(true)
    page.load()
    try await waitUntilLoaded(page)

    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await poll { demands == [true] }
    XCTAssertEqual(demands, [true], "a second registration replaces the first; it does not subscribe again")

    page.deliverAudio(Self.spectrum(first: 0.25))
    let delivered = try await pollState(page) { ($0["audio"] as? [Double])?.count == 1 }
    XCTAssertEqual((delivered["audio"] as? [Double])?.first, 0.25)
    try await Task.sleep(for: .milliseconds(300))
    var settled = try await state(page)
    XCTAssertEqual(
      (settled["audio"] as? [Double])?.count, 1,
      "one frame must reach the page once, not once per registration")

    try await eval(page, "window.wallpaperRegisterAudioListener(null);")
    try await poll { demands == [true, false] }
    page.deliverAudio(Self.spectrum(first: 0.5))
    try await Task.sleep(for: .milliseconds(300))
    settled = try await state(page)
    XCTAssertEqual((settled["audio"] as? [Double])?.count, 1)
  }

  func testAudioDeliveryStopsWhileSuspendedAndResumes() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [Bool] = []
    page.onAudioDemandChanged = { demands.append($0) }
    page.setAudioResponseEnabled(true)
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await poll { demands.last == true }

    page.setPresentationSuspended(true)
    XCTAssertEqual(demands.last, false, "a suspended page must not be fed audio")
    page.deliverAudio(Self.spectrum(first: 0.25))
    try await Task.sleep(for: .milliseconds(300))
    let suspended = try await state(page)
    XCTAssertEqual((suspended["audio"] as? [Double])?.count ?? 0, 0)

    page.setPresentationSuspended(false)
    XCTAssertEqual(demands.last, true)
    page.deliverAudio(Self.spectrum(first: 0.75))
    let resumed = try await pollState(page) { ($0["audio"] as? [Double])?.count == 1 }
    XCTAssertEqual((resumed["audio"] as? [Double])?.first, 0.75)
  }

  func testAudioIsNotDeliveredWhileTheUserSettingIsOff() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [Bool] = []
    page.onAudioDemandChanged = { demands.append($0) }
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperRegisterAudioListener(b => window.__received.audio.push(b[0]));")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(demands.isEmpty, "a page that registered must not open the tap while the setting is off")
    page.deliverAudio(Self.spectrum(first: 0.25))
    try await Task.sleep(for: .milliseconds(200))
    let ignored = try await state(page)
    XCTAssertEqual((ignored["audio"] as? [Double])?.count ?? 0, 0)

    page.setAudioResponseEnabled(true)
    try await poll { demands == [true] }
    page.deliverAudio(Self.spectrum(first: 0.25))
    _ = try await pollState(page) { ($0["audio"] as? [Double])?.count == 1 }
  }

  // MARK: - media

  func testAnUnchangedMediaStateSendsNothingAndFieldsAreIndependent() async throws {
    let page = try await mediaPage()
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "First"))
    page.deliverMediaEvent(slot: .thumbnail, event: Self.thumbnail)
    _ = try await pollState(page) {
      ($0["properties"] as? [[String: Any]])?.count == 1 && ($0["thumbnail"] as? [[String: Any]])?.count == 1
    }

    // Same values again: the protocol fires a listener only when its own part
    // changed, so a replay of unchanged state must be silent.
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "First"))
    page.deliverMediaEvent(slot: .thumbnail, event: Self.thumbnail)
    try await Task.sleep(for: .milliseconds(300))
    var received = try await state(page)
    XCTAssertEqual((received["properties"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual((received["thumbnail"] as? [[String: Any]])?.count, 1)

    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "Second"))
    received = try await pollState(page) { ($0["properties"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(
      (received["thumbnail"] as? [[String: Any]])?.count, 1,
      "a properties change must not re-send the artwork")
    XCTAssertEqual(
      ((received["properties"] as? [[String: Any]])?.last)?["title"] as? String, "Second")
  }

  func testAMediaListenerRegisteredLateReceivesTheCurrentStateOnce() async throws {
    let page = try await mediaPage()
    page.deliverMediaEvent(slot: .playback, event: ["state": 0])
    _ = try await pollState(page) { ($0["playback"] as? [[String: Any]])?.count == 1 }

    try await eval(page, "window.wallpaperRegisterMediaPlaybackListener(e => window.__received.playback.push(e));")
    var received = try await pollState(page) { ($0["playback"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(((received["playback"] as? [[String: Any]])?.last)?["state"] as? Int, 0)

    // The replacement listener already holds the current state, so re-sending
    // it must still change nothing.
    page.deliverMediaEvent(slot: .playback, event: ["state": 0])
    try await Task.sleep(for: .milliseconds(300))
    received = try await state(page)
    XCTAssertEqual((received["playback"] as? [[String: Any]])?.count, 2)
  }

  func testMediaDeliveryStopsWhileSuspendedAndTheNewStateArrivesOnResume() async throws {
    let page = try await mediaPage()
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "Before"))
    _ = try await pollState(page) { ($0["properties"] as? [[String: Any]])?.count == 1 }

    page.setPresentationSuspended(true)
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "During"))
    try await Task.sleep(for: .milliseconds(300))
    let suspended = try await state(page)
    XCTAssertEqual(
      ((suspended["properties"] as? [[String: Any]])?.last)?["title"] as? String, "Before",
      "a suspended page must not be fed media")

    // Resume replays whatever is current, which is what the host does with the
    // relay's state; the page must then see the value it missed.
    page.setPresentationSuspended(false)
    page.deliverMediaEvent(slot: .properties, event: Self.properties(title: "During"))
    let resumed = try await pollState(page) { ($0["properties"] as? [[String: Any]])?.count == 2 }
    XCTAssertEqual(((resumed["properties"] as? [[String: Any]])?.last)?["title"] as? String, "During")
  }

  func testPlaybackConstantsAreExposedUnderBothDocumentedSpellings() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    let values = try await eval(page, """
      const m = window.wallpaperMediaIntegration;
      return [m.PLAYBACK_PLAYING, m.PLAYBACK_PAUSED, m.PLAYBACK_STOPPED,
              m.playback.PLAYING, m.playback.PAUSED, m.playback.STOPPED];
      """) as? [Int]
    XCTAssertEqual(values, [0, 1, 2, 0, 1, 2])
  }

  func testStoppingThePageWithdrawsEveryDemand() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var audio: [Bool] = []
    var media: [WebWallpaperPage.MediaDemand] = []
    page.onAudioDemandChanged = { audio.append($0) }
    page.onMediaDemandChanged = { media.append($0) }
    page.setAudioResponseEnabled(true)
    page.setMediaIntegrationEnabled(true)
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, "window.wallpaperRegisterAudioListener(() => {});")
    try await eval(page, "window.wallpaperRegisterMediaStatusListener(() => {});")
    try await poll { audio.last == true && media.last?.consuming == true }

    page.stop()
    XCTAssertEqual(audio.last, false)
    XCTAssertEqual(media.last, WebWallpaperPage.MediaDemand())
  }

  // MARK: - random file

  func testARandomFileAnswerForAnOldDocumentIsDropped() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var requests: [(token: String, property: String)] = []
    page.onRandomFileRequest = { requests.append((token: $0, property: $1)) }
    page.load()
    try await waitUntilLoaded(page)
    try await requestRandomFile(page, property: "gallery")
    try await poll { requests.count == 1 }
    let stale = requests[0].token

    // A reload restarts the page's own request numbering from one, so the stale
    // answer carries an identifier the new document will also hand out.
    page.load()
    try await waitUntilLoaded(page)
    try await requestRandomFile(page, property: "gallery")
    try await poll { requests.count == 2 }
    XCTAssertNotEqual(stale, requests[1].token)

    page.deliverRandomFile(requestId: stale, property: "gallery", path: "tmp/old.png")
    try await Task.sleep(for: .milliseconds(300))
    let afterStale = try await state(page)
    XCTAssertEqual(
      (afterStale["random"] as? [[Any]])?.count ?? 0, 0,
      "the previous document's answer must not reach the new page")

    page.deliverRandomFile(requestId: requests[1].token, property: "gallery", path: "tmp/new.png")
    let answered = try await pollState(page) { ($0["random"] as? [[Any]])?.count == 1 }
    let reply = try XCTUnwrap((answered["random"] as? [[Any]])?.first)
    XCTAssertEqual(reply[0] as? String, "gallery")
    XCTAssertEqual(reply[1] as? String, "tmp/new.png")
  }

  func testARandomFileRequestWithNothingStagedStillCallsBack() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var requests: [String] = []
    page.onRandomFileRequest = { token, _ in requests.append(token) }
    page.load()
    try await waitUntilLoaded(page)
    try await requestRandomFile(page, property: "gallery")
    try await poll { requests.count == 1 }

    // What the host answers when no directory is staged. A wallpaper waiting on
    // this callback would never draw if it simply never fired.
    page.deliverRandomFile(requestId: requests[0], property: "gallery", path: "")
    let answered = try await pollState(page) { ($0["random"] as? [[Any]])?.count == 1 }
    XCTAssertEqual((answered["random"] as? [[Any]])?.first?[1] as? String, "")
  }

  // MARK: - directory properties

  func testDirectoryChangesReachTheListenerAndSurviveASuspension() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    try await eval(page, """
      window.wallpaperPropertyListener = {
        userDirectoryFilesAddedOrChanged(name, files) { window.__received.dirAdded.push([name, files]); },
        userDirectoryFilesRemoved(name, files) { window.__received.dirRemoved.push([name, files]); },
      };
      """)

    page.deliverDirectoryFiles(property: "gallery", added: ["a.png", "b.png"], removed: [])
    var received = try await pollState(page) { ($0["dirAdded"] as? [[Any]])?.count == 1 }
    XCTAssertEqual((received["dirAdded"] as? [[Any]])?.first?[1] as? [String], ["a.png", "b.png"])

    // Removals are ordered against additions, so a suspension has to hold them
    // rather than collapse them into "whatever is current on resume".
    page.setPresentationSuspended(true)
    page.deliverDirectoryFiles(property: "gallery", added: [], removed: ["a.png"])
    page.deliverDirectoryFiles(property: "gallery", added: ["c.png"], removed: [])
    try await Task.sleep(for: .milliseconds(300))
    received = try await state(page)
    XCTAssertEqual((received["dirRemoved"] as? [[Any]])?.count ?? 0, 0)
    XCTAssertEqual((received["dirAdded"] as? [[Any]])?.count, 1)

    page.setPresentationSuspended(false)
    received = try await pollState(page) {
      ($0["dirAdded"] as? [[Any]])?.count == 2 && ($0["dirRemoved"] as? [[Any]])?.count == 1
    }
    XCTAssertEqual((received["dirRemoved"] as? [[Any]])?.first?[1] as? [String], ["a.png"])
    XCTAssertEqual((received["dirAdded"] as? [[Any]])?.last?[1] as? [String], ["c.png"])
  }

  func testAPropertyListenerRegisteredAfterTheFilesArrivedStillSeesThem() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    page.deliverDirectoryFiles(property: "gallery", added: ["a.png", "b.png"], removed: [])
    page.deliverDirectoryFiles(property: "gallery", added: [], removed: ["a.png"])
    try await Task.sleep(for: .milliseconds(300))

    try await eval(page, """
      window.wallpaperPropertyListener = {
        userDirectoryFilesAddedOrChanged(name, files) { window.__received.dirAdded.push([name, files]); },
      };
      """)
    let received = try await pollState(page) { ($0["dirAdded"] as? [[Any]])?.count == 1 }
    XCTAssertEqual(
      (received["dirAdded"] as? [[Any]])?.first?[1] as? [String], ["b.png"],
      "a late listener is given what the directory currently holds, not the deltas it missed")
  }

  // MARK: - helpers

  private static func spectrum(first: Float) -> [Float] {
    var bins = [Float](repeating: 0, count: 128)
    bins[0] = first
    return bins
  }

  private static func properties(title: String) -> [String: Any] {
    [
      "title": title, "artist": "Artist", "subTitle": "", "albumTitle": "Album",
      "albumArtist": "", "genres": "", "contentType": "music",
    ]
  }

  private static let thumbnail: [String: Any] = [
    "thumbnail": "data:image/png;base64,iVBORw0KGgo=",
    "primaryColor": "rgb(10, 20, 30)", "secondaryColor": "rgb(40, 50, 60)",
    "tertiaryColor": "rgb(70, 80, 90)", "textColor": "rgb(255, 255, 255)",
    "highContrastColor": "rgb(255, 255, 255)",
  ]

  /// A loaded page with every media listener registered and the user setting on.
  private func mediaPage() async throws -> WebWallpaperPage {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var demands: [WebWallpaperPage.MediaDemand] = []
    page.onMediaDemandChanged = { demands.append($0) }
    page.setMediaIntegrationEnabled(true)
    page.load()
    try await waitUntilLoaded(page)
    for slot in ["Status", "Properties", "Thumbnail", "Playback", "Timeline"] {
      try await eval(page, """
        window.wallpaperRegisterMedia\(slot)Listener(
          e => window.__received.\(slot.lowercased()).push(e));
        """)
    }
    try await poll { demands.last?.consuming == true }
    return page
  }

  private func requestRandomFile(_ page: WebWallpaperPage, property: String) async throws {
    try await eval(page, """
      window.wallpaperRequestRandomFileForProperty(
        "\(property)", (name, path) => window.__received.random.push([name, path]));
      """)
  }

  @discardableResult
  private func eval(_ page: WebWallpaperPage, _ script: String) async throws -> Any? {
    try await page.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
  }

  private func state(_ page: WebWallpaperPage) async throws -> [String: Any] {
    guard page.isLoaded,
      let received = try? await page.webView.callAsyncJavaScript(
        "return window.__received", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    else { return [:] }
    return received
  }

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(page.isLoaded, "the page did not load")
  }

  private func poll(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("condition not met before timeout")
  }

  @discardableResult
  private func pollState(
    _ page: WebWallpaperPage, timeout: TimeInterval = 5,
    until condition: ([String: Any]) -> Bool
  ) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    var last: [String: Any] = [:]
    while Date() < deadline {
      last = try await state(page)
      if condition(last) { return last }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("condition not met before timeout; last state: \(last)")
    return last
  }
}
