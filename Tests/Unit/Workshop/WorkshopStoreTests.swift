import Foundation
import XCTest

@testable import MacWallpaperEngine

@MainActor
final class WorkshopStoreTests: XCTestCase {
  func testPaginationUsesDisplayedQueryUntilDraftIsSubmitted() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.kind = .scene
    store.sort = .popular
    store.tags = ["Nature"]
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 1, tags: ["Nature"])
    store.search()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 1,
      body: pageHTML(id: "101", title: "Forest \"青\"", page: 1, pages: 3, count: 65),
      tags: ["Nature"])
    try await finished(store)
    assertPage(store, id: "101", page: 1, pages: 3, count: 65)
    XCTAssertEqual(store.items.first?.title, "Forest \"青\"")
    XCTAssertEqual(store.items.first?.creator, "Fixture creator")
    XCTAssertEqual(store.items.first?.kind, .scene)

    store.searchText = "rain"
    store.kind = .video
    store.sort = .newest
    store.tags = ["Relaxing"]
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 1, tags: ["Nature"])
    store.loadPage(2)
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 2,
      body: pageHTML(id: "102", page: 2, pages: 3, count: 65), tags: ["Nature"])
    try await finished(store)
    assertPage(store, id: "102", page: 2, pages: 3, count: 65)
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 2, tags: ["Nature"])

    store.search()
    try await fixture.reply(
      text: "rain", kind: .video, sort: .newest, page: 1,
      body: pageHTML(id: "201", kind: .video, page: 1, pages: 2, count: 33), tags: ["Relaxing"])
    try await finished(store)
    assertPage(store, id: "201", page: 1, pages: 2, count: 33)
    assertBrowseURL(store, text: "rain", kind: .video, sort: .newest, page: 1, tags: ["Relaxing"])
    XCTAssertEqual(store.items.first?.kind, .video)
  }

  func testFailedPageAndFailedSubmissionRetryTheirOwnQueryWithoutChangingDraft() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.kind = .scene
    store.sort = .popular
    store.tags = ["Nature", "1920 x 1080"]
    store.search()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 1,
      body: pageHTML(id: "101", page: 1, pages: 3, count: 65), tags: ["Nature", "1920 x 1080"])
    try await finished(store)

    store.loadPage(2)
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 2,
      body: Data(), status: 503, tags: ["Nature", "1920 x 1080"])
    try await finished(store)
    assertPage(store, id: "101", page: 1, pages: 3, count: 65)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(
      store.failedRequest,
      WorkshopRequest(
        query: .init(
          text: "forest", kind: .scene, sort: .popular,
          tags: ["Nature", "1920 x 1080"]), page: 2))
    assertBrowseURL(
      store, text: "forest", kind: .scene, sort: .popular, page: 1, tags: ["Nature", "1920 x 1080"])

    store.searchText = "rain"
    store.kind = .video
    store.sort = .newest
    store.tags = ["Relaxing", "Everyone"]
    store.retrySearch()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 2,
      body: pageHTML(id: "102", page: 2, pages: 3, count: 65), tags: ["Nature", "1920 x 1080"])
    try await finished(store)
    assertPage(store, id: "102", page: 2, pages: 3, count: 65)
    XCTAssertNil(store.errorMessage)
    XCTAssertNil(store.failedRequest)
    XCTAssertEqual(store.searchText, "rain")
    XCTAssertEqual(store.kind, .video)
    XCTAssertEqual(store.sort, .newest)
    XCTAssertEqual(store.tags, ["Relaxing", "Everyone"])

    store.search()
    try await fixture.reply(
      text: "rain", kind: .video, sort: .newest, page: 1,
      body: Data("<html>Not an SSR Workshop page</html>".utf8), tags: ["Relaxing", "Everyone"])
    try await finished(store)
    assertPage(store, id: "102", page: 2, pages: 3, count: 65)
    XCTAssertNotNil(store.errorMessage)
    assertBrowseURL(
      store, text: "forest", kind: .scene, sort: .popular, page: 2, tags: ["Nature", "1920 x 1080"])
    store.searchText = "snow"
    store.kind = .all
    store.sort = .relevance
    store.tags = []
    store.retrySearch()
    try await fixture.reply(
      text: "rain", kind: .video, sort: .newest, page: 1,
      body: pageHTML(id: "201", kind: .video, page: 1, pages: 1, count: 1),
      tags: ["Relaxing", "Everyone"])
    try await finished(store)
    assertPage(store, id: "201", page: 1, pages: 1, count: 1)
    assertBrowseURL(
      store, text: "rain", kind: .video, sort: .newest, page: 1, tags: ["Relaxing", "Everyone"])
    XCTAssertNil(store.errorMessage)
    XCTAssertNil(store.failedRequest)
    XCTAssertEqual(store.searchText, "snow")
    XCTAssertEqual(store.kind, .all)
    XCTAssertEqual(store.sort, .relevance)
    XCTAssertEqual(store.tags, [])
  }

  func testSupersededSuccessCannotPublishOverNewSearch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.search()
    let old = try await fixture.request(text: "forest", kind: .scene, sort: .trending, page: 1)
    store.searchText = "rain"
    store.search()
    try await fixture.reply(
      text: "rain", kind: .scene, sort: .trending, page: 1,
      body: pageHTML(id: "201", page: 1, pages: 2, count: 33))
    try await finished(store)
    try await waitUntil { old.isStopped }
    // A held server response released after cancellation must not revive its request.
    old.succeed(try pageHTML(id: "101", page: 1, pages: 9, count: 270))
    await fixture.drain()
    assertPage(store, id: "201", page: 1, pages: 2, count: 33)
    assertBrowseURL(store, text: "rain", kind: .scene, sort: .trending, page: 1)
    XCTAssertNil(store.errorMessage)
    XCTAssertNil(store.failedRequest)
  }

  func testSupersededTransportErrorCannotReplaceNewResultOrRetryTarget() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.search()
    let old = try await fixture.request(text: "forest", kind: .scene, sort: .trending, page: 1)
    store.searchText = "rain"
    store.search()
    try await fixture.reply(
      text: "rain", kind: .scene, sort: .trending, page: 1,
      body: pageHTML(id: "201", page: 1, pages: 2, count: 33))
    try await finished(store)
    store.loadPage(2)
    try await fixture.reply(
      text: "rain", kind: .scene, sort: .trending, page: 2,
      body: Data(), status: 500)
    try await finished(store)
    try await waitUntil { old.isStopped }
    old.fail(URLError(.timedOut))
    await fixture.drain()
    assertPage(store, id: "201", page: 1, pages: 2, count: 33)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(
      store.failedRequest,
      WorkshopRequest(query: .init(text: "rain", kind: .scene, sort: .trending), page: 2))
    assertBrowseURL(store, text: "rain", kind: .scene, sort: .trending, page: 1)
  }

  func testCompletionRacingReplacementCannotPublishOldSuccessOrError() async throws {
    // Unlike the held-response cases, these completions enter URLSession before cancellation.
    for succeeds in [true, false] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let store = fixture.store
      store.searchText = "forest"
      store.search()
      let old = try await fixture.request(text: "forest", kind: .scene, sort: .trending, page: 1)
      let oldBody = try pageHTML(id: "101", page: 1, pages: 9, count: 270)
      if succeeds { old.succeed(oldBody) } else { old.fail(URLError(.timedOut)) }
      // No actor suspension between completing the old request and superseding it.
      store.searchText = "rain"
      store.search()
      let current = try await fixture.request(text: "rain", kind: .scene, sort: .trending, page: 1)
      XCTAssertTrue(store.isLoading)
      XCTAssertFalse(store.hasLoaded)
      XCTAssertTrue(store.items.isEmpty)
      XCTAssertNil(store.errorMessage)
      XCTAssertNil(store.failedRequest)
      current.succeed(try pageHTML(id: "201", page: 1, pages: 1, count: 1))
      try await finished(store)
      await fixture.drain()
      assertPage(store, id: "201", page: 1, pages: 1, count: 1)
      assertBrowseURL(store, text: "rain", kind: .scene, sort: .trending, page: 1)
      XCTAssertNil(store.errorMessage)
      XCTAssertNil(store.failedRequest)
    }
  }

  func testCancellationDoesNotClaimInitialSuccessOrDiscardLoadedPage() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.search()
    let initial = try await fixture.request(text: "forest", kind: .scene, sort: .trending, page: 1)
    store.cancelSearch()
    try await waitUntil { initial.isStopped }
    initial.succeed(try pageHTML(id: "999", page: 1, pages: 1, count: 1))
    XCTAssertFalse(store.isLoading)
    XCTAssertFalse(store.hasLoaded)
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertNil(store.committedQuery)
    XCTAssertNil(store.failedRequest)
    XCTAssertNil(store.errorMessage)

    store.search()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .trending, page: 1,
      body: pageHTML(id: "101", page: 1, pages: 3, count: 65))
    try await finished(store)
    store.loadPage(2)
    let next = try await fixture.request(text: "forest", kind: .scene, sort: .trending, page: 2)
    store.cancelSearch()
    try await waitUntil { next.isStopped }
    next.succeed(try pageHTML(id: "102", page: 2, pages: 3, count: 65))
    await fixture.drain()
    XCTAssertFalse(store.isLoading)
    assertPage(store, id: "101", page: 1, pages: 3, count: 65)
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .trending, page: 1)
    XCTAssertNil(store.failedRequest)
    XCTAssertNil(store.errorMessage)
  }

  /// The panel reports how many tiles fill its grid; pages of that size are cut from Steam's
  /// pages of 30, fetched on demand and reused from the cache when the size changes again.
  func testPanelPageSizeComposesPagesFromCachedSteamPages() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    // Steam ids are numeric: 1001…1030 fill page 1, 2001…2030 page 2, and so on.
    let steamIDs = { (page: Int, count: Int) in (1...count).map { String(page * 1000 + $0) } }
    store.searchText = "forest"
    store.setPageSize(40)
    XCTAssertEqual(store.pageSize, 40)
    store.search()
    // Steam's page count is unknown, so the first page goes alone before the span is clamped.
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .trending, page: 1,
      body: pageHTML(ids: steamIDs(1, 30), page: 1, pages: 3, count: 65))
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .trending, page: 2,
      body: pageHTML(ids: steamIDs(2, 30), page: 2, pages: 3, count: 65))
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), steamIDs(1, 30) + Array(steamIDs(2, 30).prefix(10)))
    XCTAssertEqual(store.page, 1)
    XCTAssertEqual(store.totalPages, 2, "65 reachable results make two pages of 40")
    XCTAssertEqual(store.totalCount, 65)
    XCTAssertEqual(store.reachableCount, 65)
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .trending, page: 1)

    // The second panel page starts inside cached Steam page 2 and only fetches page 3.
    store.loadPage(2)
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .trending, page: 3,
      body: pageHTML(ids: steamIDs(3, 5), page: 3, pages: 3, count: 65))
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), Array(steamIDs(2, 30).dropFirst(10)) + steamIDs(3, 5))
    XCTAssertEqual(store.page, 2)
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .trending, page: 2)

    // Shrinking the grid keeps the first visible tile: offset 40 lands on page 2 of 30, which
    // is entirely cached, so nothing is requested and the store never reports loading.
    store.setPageSize(30)
    XCTAssertFalse(store.isLoading)
    XCTAssertEqual(store.page, 2)
    XCTAssertEqual(store.totalPages, 3)
    XCTAssertEqual(store.items.map(\.id), steamIDs(2, 30))
    XCTAssertFalse(fixture.inbox.hasRequest, "A cached page must not hit Steam again")

    // A fresh search discards the cache even for the same query.
    store.search()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .trending, page: 1,
      body: pageHTML(ids: steamIDs(1, 30), page: 1, pages: 3, count: 65))
    try await finished(store)
    XCTAssertEqual(store.items.count, 30)
    XCTAssertEqual(store.page, 1)

    // Growing the grid while a page is loading restarts that page at the new size, joining the
    // fetch already in flight instead of repeating it.
    store.loadPage(3)
    let pending = try await fixture.request(text: "forest", kind: .scene, sort: .trending, page: 3)
    store.setPageSize(35)
    XCTAssertTrue(store.isLoading)
    // Page 2 of 35 starts on Steam page 2, which the fresh cache lacks; page 3 is joined.
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .trending, page: 2,
      body: pageHTML(ids: steamIDs(2, 30), page: 2, pages: 3, count: 65))
    pending.succeed(try pageHTML(ids: steamIDs(3, 5), page: 3, pages: 3, count: 65))
    try await finished(store)
    XCTAssertEqual(store.page, 2, "offset 60 falls on the second page of 35")
    XCTAssertEqual(store.items.map(\.id), Array(steamIDs(2, 30).dropFirst(5)) + steamIDs(3, 5))
    XCTAssertFalse(fixture.inbox.hasRequest)
    XCTAssertNil(store.errorMessage)
  }

  private func assertPage(
    _ store: WorkshopStore, id: String, page: Int, pages: Int, count: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(store.hasLoaded, file: file, line: line)
    XCTAssertEqual(store.items.map(\.id), [id], file: file, line: line)
    XCTAssertEqual(store.page, page, file: file, line: line)
    XCTAssertEqual(store.totalPages, pages, file: file, line: line)
    XCTAssertEqual(store.totalCount, count, file: file, line: line)
  }

  private func assertBrowseURL(
    _ store: WorkshopStore, text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int,
    tags: [String] = [], file: StaticString = #filePath, line: UInt = #line
  ) {
    let values =
      URLComponents(url: store.browseURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(values.first { $0.name == "searchtext" }?.value, text, file: file, line: line)
    XCTAssertEqual(
      values.filter { $0.name == "requiredtags[]" }.compactMap(\.value),
      (kind == .all ? [] : [kind.rawValue]) + tags, file: file, line: line)
    XCTAssertEqual(
      values.first { $0.name == "browsesort" }?.value, sort.rawValue, file: file, line: line)
    XCTAssertEqual(values.first { $0.name == "p" }?.value, String(page), file: file, line: line)
  }

  private func finished(_ store: WorkshopStore) async throws {
    try await waitUntil { !store.isLoading }
  }

  private func pageHTML(
    id: String, title: String = "Fixture wallpaper", kind: WorkshopKind = .scene,
    page: Int, pages: Int, count: Int
  ) throws -> Data {
    try pageHTML(ids: [id], title: title, kind: kind, page: page, pages: pages, count: count)
  }

  /// Steam page `page` holding `ids` in order; a full page has 30 of them.
  private func pageHTML(
    ids: [String], title: String = "Fixture wallpaper", kind: WorkshopKind = .scene,
    page: Int, pages: Int, count: Int
  ) throws -> Data {
    let queries: [[String: Any]] = [
      [
        "queryKey": ["PlayerLinkDetails", "76561198000000001"],
        "state": ["data": ["public_data": ["persona_name": "Fixture creator"]]],
      ],
      [
        "queryKey": ["workshop_browse"],
        "state": [
          "data": [
            "eresult": 1, "current_page": page, "total_pages": pages, "total_count": count,
            "results": ids.map { id -> [String: Any] in
              [
                "publishedfileid": id, "consumer_appid": 431960, "title": title,
                "creator": "76561198000000001",
                "short_description": "A real SSR fixture\nwith escaped layers",
                "tags": [["tag": kind.rawValue]], "file_size": "4096", "subscriptions": 12,
              ]
            },
          ]
        ],
      ],
    ]
    let queryData = String(
      decoding: try JSONSerialization.data(withJSONObject: ["queries": queries]), as: UTF8.self)
    let context = String(
      decoding: try JSONSerialization.data(withJSONObject: ["queryData": queryData]), as: UTF8.self)
    let encoded = String(
      decoding: try JSONSerialization.data(withJSONObject: context, options: .fragmentsAllowed),
      as: UTF8.self)
    return Data(
      "<html><script>window.SSR.renderContext = JSON.parse(\(encoded));</script></html>".utf8)
  }

  private static func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    try await Self.waitUntil(condition)
  }

  private enum FixtureError: Error {
    case timedOut
    case unexpectedRequest(URL?)
  }

  @MainActor
  private final class Fixture {
    let root: URL
    let identifier = UUID().uuidString
    let inbox = WorkshopRequestInbox()
    let delegate = WorkshopSessionDelegate()
    let session: URLSession
    let defaults: UserDefaults
    let store: WorkshopStore

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "WorkshopStoreTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [WorkshopFixtureProtocol.self]
      configuration.httpAdditionalHeaders = ["X-Workshop-Test": identifier]
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 5
      configuration.timeoutIntervalForResource = 5
      session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      WorkshopFixtureProtocol.register(identifier, inbox: inbox)
      defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkshopStoreTests.\(identifier)"))
      // Search and setup metadata use only this fixture's isolated storage.
      store = WorkshopStore(
        service: WorkshopService(session: session),
        downloader: WorkshopDownloadManager(
          sessionDirectory: root.appendingPathComponent("SteamSession")),
        supportDirectory: root, defaults: defaults)
    }

    func request(
      text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = []
    ) async throws -> WorkshopFixtureProtocol {
      try await WorkshopStoreTests.waitUntil { self.inbox.hasRequest }
      let pending = inbox.take()
      let values =
        URLComponents(url: pending.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard values.first(where: { $0.name == "searchtext" })?.value == text,
        values.filter({ $0.name == "requiredtags[]" }).compactMap(\.value)
          == (kind == .all ? [] : [kind.rawValue]) + tags,
        values.first(where: { $0.name == "browsesort" })?.value == sort.rawValue,
        values.first(where: { $0.name == "p" })?.value == String(page)
      else {
        pending.fail(URLError(.badURL))
        throw FixtureError.unexpectedRequest(pending.request.url)
      }
      return pending
    }

    func reply(
      text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, body: Data,
      status: Int = 200,
      tags: [String] = []
    ) async throws {
      let pending = try await request(text: text, kind: kind, sort: sort, page: page, tags: tags)
      pending.succeed(body, status: status)
    }

    func drain() async {
      session.finishTasksAndInvalidate()
      let result = await XCTWaiter().fulfillment(of: [delegate.invalidated], timeout: 5)
      XCTAssertEqual(
        result, .completed, "Fixture session must finish all callbacks before final assertions")
    }

    func remove() {
      store.cancelSearch()
      session.invalidateAndCancel()
      WorkshopFixtureProtocol.remove(identifier)
      defaults.removePersistentDomain(forName: "WorkshopStoreTests.\(identifier)")
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private final class WorkshopSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  let invalidated = XCTestExpectation(description: "Fixture session drained")
  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    invalidated.fulfill()
  }
}

private final class WorkshopRequestInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [WorkshopFixtureProtocol] = []
  var hasRequest: Bool { lock.withLock { !pending.isEmpty } }
  func append(_ request: WorkshopFixtureProtocol) { lock.withLock { pending.append(request) } }
  func take() -> WorkshopFixtureProtocol { lock.withLock { pending.removeFirst() } }
}

private final class WorkshopFixtureProtocol: URLProtocol, @unchecked Sendable {
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var inboxes: [String: WorkshopRequestInbox] = [:]
  private let responseLock = NSRecursiveLock()
  private var stopped = false
  private var completed = false
  var isStopped: Bool { responseLock.withLock { stopped } }

  static func register(_ identifier: String, inbox: WorkshopRequestInbox) {
    registryLock.withLock { inboxes[identifier] = inbox }
  }
  static func remove(_ identifier: String) {
    _ = registryLock.withLock { inboxes.removeValue(forKey: identifier) }
  }
  // This class is installed only in fixture sessions. Claim every request so no fallback can reach the network.
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let inbox = Self.registryLock.withLock {
      Self.inboxes[request.value(forHTTPHeaderField: "X-Workshop-Test") ?? ""]
    }
    guard let inbox else {
      fail(URLError(.resourceUnavailable))
      return
    }
    inbox.append(self)
  }
  override func stopLoading() { responseLock.withLock { stopped = true } }
  func succeed(_ body: Data, status: Int = 200) {
    responseLock.withLock {
      guard !stopped, !completed else { return }
      completed = true
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/html; charset=utf-8"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  func fail(_ error: Error) {
    responseLock.withLock {
      guard !stopped, !completed else { return }
      completed = true
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}

/// One click must keep the wallpaper the user asked for while prerequisites are resolved.
/// Only Valve's runtime verification is replaced; the queue, PTY session, and stores are real.
@MainActor
final class WorkshopDownloadIntentTests: XCTestCase {
  private var home: URL!
  private var suite = ""
  private var defaults: UserDefaults!
  private var previousHome: String?
  private var fixtures: [Fixture] = []
  private let scene = WorkshopItem(
    id: "111", title: "Scene fixture", creator: "Test", summary: "",
    previewURL: URL(string: "https://example.com/preview.jpg"),
    tags: ["Scene"], size: 0, subscriptions: 0)
  private let otherScene = WorkshopItem(
    id: "333", title: "Second scene", creator: "Test", summary: "",
    previewURL: nil, tags: ["Scene"], size: 0, subscriptions: 0)
  private let video = WorkshopItem(
    id: "222", title: "Video fixture", creator: "Test", summary: "",
    previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("mwe-download-intents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    previousHome = ProcessInfo.processInfo.environment["MAC_WALLPAPER_ENGINE_HOME"]
    setenv("MAC_WALLPAPER_ENGINE_HOME", home.path, 1)
    suite = "WorkshopDownloadIntentTests.\(home.lastPathComponent)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  /// Children own PTYs and staging inside `home`; every one of them must be reaped before the
  /// directory and the environment it resolves through are taken away.
  override func tearDown() async throws {
    for fixture in fixtures {
      await fixture.store.downloader.shutdown()
      await fixture.store.steamCMDSetup.shutdown()
    }
    fixtures.removeAll()
    defaults.removePersistentDomain(forName: suite)
    if let previousHome {
      setenv("MAC_WALLPAPER_ENGINE_HOME", previousHome, 1)
    } else {
      unsetenv("MAC_WALLPAPER_ENGINE_HOME")
    }
    try? FileManager.default.removeItem(at: home)
  }

  func testRetainedIntentWaitsForSetupThenAccountAndNeedsNoSecondClick() async throws {
    let fixture = try makeFixture()
    XCTAssertFalse(fixture.store.sceneAssetsReady)

    fixture.store.requestDownload(item: video, rememberSession: false, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloadRequests.map(\.id), [video.id])
    XCTAssertEqual(try stage(fixture.store), .setup)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "Without a runtime the intent waits instead of failing the click")

    try await makeSetupReady(fixture)
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .account)
    XCTAssertEqual(
      fixture.store.downloadRequests.first?.rememberSession, false,
      "The retained intent keeps the sign-in choice the user made when clicking")
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "An account the user never supplied must not start a download")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "localtest",
        rememberSession: false, includeResources: false,
        bridge: fixture.bridge))
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(fixture.store.downloader.downloads.map(\.id), [video.id])
  }

  func testSceneNeedsExplicitConsentThenQueuesSharedAssetsAheadOfTheWallpaper() async throws {
    let fixture = try makeFixture()
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    fixture.store.requestDownload(item: scene, rememberSession: true, bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .resources)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "Multi-gigabyte shared assets must never be authorized implicitly")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: scene.id, account: "localtest",
        rememberSession: true, includeResources: true,
        bridge: fixture.bridge))
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id),
      [WorkshopStore.sceneAssetsRequestID, scene.id])
    try await waitUntil { fixture.store.downloader.download(for: nil)?.isQueued == false }
    XCTAssertEqual(
      fixture.store.downloader.download(for: scene.id)?.isQueued, true,
      "The wallpaper waits behind the shared assets it needs")

    // A running shared-assets job is the consent for every scene that rides it.
    fixture.store.requestDownload(item: otherScene, rememberSession: true, bridge: fixture.bridge)
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id),
      [WorkshopStore.sceneAssetsRequestID, scene.id, otherScene.id])
  }

  func testFailedSharedAssetsWarnAboutSceneReadinessWithoutLosingTheWallpaper() async throws {
    let fixture = try makeFixture()
    try await makeSetupReady(fixture)
    fixture.store.selectedItem = scene
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: scene.id, account: "localtest",
        rememberSession: true, includeResources: true,
        bridge: fixture.bridge))
    let assets = try XCTUnwrap(fixture.store.downloader.download(for: nil))
    try await waitUntil { assets.isQueued == false }

    fixture.store.downloader.cancel(assets)
    try await waitUntil { !assets.isPending }
    XCTAssertFalse(fixture.store.sceneAssetsReady)
    XCTAssertNotNil(
      fixture.store.sceneAssetsFailure,
      "A wallpaper can finish while scenes stay unplayable; that gap needs a warning")
    let wallpaper = try XCTUnwrap(fixture.store.downloader.download(for: scene.id))
    try await waitUntil { !wallpaper.isQueued }
    XCTAssertTrue(
      wallpaper.isPending, "Failed shared assets must not cancel the wallpaper download")
  }

  func testRetainedIntentSurvivesBrowsingAndResumesWhenSetupFinishes() async throws {
    let fixture = try makeFixture()
    fixture.store.selectedItem = scene
    fixture.store.requestDownload(item: scene, rememberSession: false, bridge: fixture.bridge)
    fixture.store.selectedItem = nil

    XCTAssertEqual(fixture.store.downloadRequests.first?.item?.title, scene.title)
    XCTAssertEqual(
      fixture.store.workshopItem(id: scene.id)?.title, scene.title,
      "A retained intent must still resolve its item after the results change")
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: scene.id, account: "localtest",
        rememberSession: false, includeResources: true,
        bridge: fixture.bridge))
    XCTAssertEqual(try stage(fixture.store), .setup)
    XCTAssertTrue(fixture.store.downloader.downloads.isEmpty)

    try await makeSetupReady(fixture)
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.downloadRequests.isEmpty,
      "Finishing setup must resume an intent the user already continued")
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id),
      [WorkshopStore.sceneAssetsRequestID, scene.id])
  }

  func testRemovedRequestIsNotResumedLater() async throws {
    let fixture = try makeFixture()
    fixture.store.requestDownload(item: video, rememberSession: false, bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "localtest",
        rememberSession: false, includeResources: false,
        bridge: fixture.bridge))
    fixture.store.removeDownloadRequest(id: video.id)
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)

    try await makeSetupReady(fixture)
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "A dismissed intent must stay dismissed once prerequisites arrive")
  }

  /// Correcting a mistyped login must stop that sign-in, keep the wallpaper, and never restart
  /// under the rejected name — not from the typed field and not from the saved suggestion.
  func testChangingAccountCancelsThatJobAndRetainsTheIntentWithoutSigningInAgain() async throws {
    let fixture = try makeFixture()
    try await makeSetupReady(fixture)
    fixture.store.requestDownload(item: video, rememberSession: true, bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "wrongname",
        rememberSession: true, includeResources: false,
        bridge: fixture.bridge))
    let job = try XCTUnwrap(fixture.store.downloader.download(for: video.id))
    try await waitUntil { !job.isQueued }

    await fixture.store.changeDownloadAccount(id: job.id)
    XCTAssertFalse(job.isPending, "The rejected sign-in must be stopped, not left running")
    XCTAssertEqual(fixture.store.downloadRequests.map(\.id), [video.id])
    XCTAssertEqual(fixture.store.downloadRequests.first?.account, "")
    XCTAssertEqual(try stage(fixture.store), .account)

    fixture.store.username = "wrongname"
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertEqual(
      fixture.store.downloadRequests.first?.account, "",
      "A rejected account must not be re-seeded from a suggestion")
    XCTAssertEqual(try stage(fixture.store), .account)
    XCTAssertEqual(
      fixture.store.downloader.downloads.filter(\.isPending).count, 0,
      "Nothing may restart until the user supplies a new account")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "rightname",
        rememberSession: true, includeResources: false,
        bridge: fixture.bridge))
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(fixture.store.downloader.download(for: video.id)?.account, "rightname")
  }

  func testSharedAssetsRequestNeedsConsentEvenWhenAssetsAreAlreadyInstalled() async throws {
    let fixture = try makeFixture(sceneAssetsReady: true)
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    fixture.store.requestDownload(item: nil, rememberSession: true, bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .resources)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "Re-downloading installed shared assets must stay an explicit choice")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: WorkshopStore.sceneAssetsRequestID,
        account: "localtest", rememberSession: true,
        includeResources: true, bridge: fixture.bridge))
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id), [WorkshopStore.sceneAssetsRequestID])
  }

  /// An installed scene wallpaper needs no consent step once its shared assets exist.
  func testSceneSkipsResourceConsentWhenAssetsAreReady() async throws {
    let fixture = try makeFixture(sceneAssetsReady: true)
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    fixture.store.requestDownload(item: scene, rememberSession: true, bridge: fixture.bridge)
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id), [scene.id],
      "Ready assets must not queue a second shared-assets download")
  }

  private struct Fixture {
    let store: WorkshopStore
    let bridge: BridgeStore
    let executable: URL
  }

  /// The fixture runtime blocks on its PTY so queued jobs keep their real pending state, and
  /// scene assets readiness is injected so this machine's Steam install cannot change the ladder.
  private func makeFixture(sceneAssetsReady: Bool = false) throws -> Fixture {
    let runtime = home.appendingPathComponent("runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    let executable = runtime.appendingPathComponent("steamcmd")
    try Data("#!/bin/sh\nIFS= read -r hold\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let downloader = WorkshopDownloadManager(
      sessionDirectory: home.appendingPathComponent("SteamSession", isDirectory: true),
      runtimeProvider: IntentRuntimeProvider())
    let store = WorkshopStore(
      downloader: downloader, supportDirectory: home, defaults: defaults,
      runtimeProvider: IntentRuntimeProvider(),
      sceneAssetsAvailable: { sceneAssetsReady })
    let fixture = Fixture(
      store: store, bridge: BridgeStore(bridge: UnusedBridge(noPointer: .init())),
      executable: executable)
    fixtures.append(fixture)
    return fixture
  }

  private func makeSetupReady(_ fixture: Fixture) async throws {
    fixture.store.steamCMDSetup.selectExisting(at: fixture.executable)
    try await waitUntil { fixture.store.steamCMDSetup.selectedRuntime != nil }
  }

  private func stage(_ store: WorkshopStore) throws -> WorkshopDownloadStage {
    store.stage(for: try XCTUnwrap(store.downloadRequests.first))
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else {
        throw WorkshopFailure(message: "The download queue did not reach the expected state")
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}

/// Replaces only Valve runtime verification; the session, PTY, and queue stay real.
private struct IntentRuntimeProvider: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Missing fixture runtime")
    }
    return SteamCMDRuntime(
      rootURL: executable.deletingLastPathComponent(), executableURL: executable)
  }
  func validateBootstrap(at root: URL) async throws {}
  func prepare(executable: URL, staging: URL) async throws -> URL { executable }
  func validate(at root: URL) async throws {}
}

/// The retained-intent ladder never reaches the engine; a library refresh only runs after an import.
private final class UnusedBridge: WallpaperBridge {}
