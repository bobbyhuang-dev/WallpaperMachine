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
        assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 1)
        store.search()
        try await fixture.reply(text: "forest", kind: .scene, sort: .popular, page: 1,
                                body: pageHTML(id: "101", title: "Forest \"青\"", page: 1, pages: 3, count: 65))
        try await finished(store)
        assertPage(store, id: "101", page: 1, pages: 3, count: 65)
        XCTAssertEqual(store.items.first?.title, "Forest \"青\"")
        XCTAssertEqual(store.items.first?.creator, "Fixture creator")
        XCTAssertEqual(store.items.first?.kind, .scene)

        store.searchText = "rain"
        store.kind = .video
        store.sort = .newest
        assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 1)
        store.loadPage(2)
        try await fixture.reply(text: "forest", kind: .scene, sort: .popular, page: 2,
                                body: pageHTML(id: "102", page: 2, pages: 3, count: 65))
        try await finished(store)
        assertPage(store, id: "102", page: 2, pages: 3, count: 65)
        assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 2)

        store.search()
        try await fixture.reply(text: "rain", kind: .video, sort: .newest, page: 1,
                                body: pageHTML(id: "201", kind: .video, page: 1, pages: 2, count: 33))
        try await finished(store)
        assertPage(store, id: "201", page: 1, pages: 2, count: 33)
        assertBrowseURL(store, text: "rain", kind: .video, sort: .newest, page: 1)
        XCTAssertEqual(store.items.first?.kind, .video)
    }

    func testFailedPageAndFailedSubmissionRetryTheirOwnQueryWithoutChangingDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store
        store.searchText = "forest"
        store.kind = .scene
        store.sort = .popular
        store.search()
        try await fixture.reply(text: "forest", kind: .scene, sort: .popular, page: 1,
                                body: pageHTML(id: "101", page: 1, pages: 3, count: 65))
        try await finished(store)

        store.loadPage(2)
        try await fixture.reply(text: "forest", kind: .scene, sort: .popular, page: 2,
                                body: Data(), status: 503)
        try await finished(store)
        assertPage(store, id: "101", page: 1, pages: 3, count: 65)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.failedRequest, WorkshopRequest(query: .init(text: "forest", kind: .scene, sort: .popular), page: 2))
        assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 1)

        store.searchText = "rain"
        store.kind = .video
        store.sort = .newest
        store.retrySearch()
        try await fixture.reply(text: "forest", kind: .scene, sort: .popular, page: 2,
                                body: pageHTML(id: "102", page: 2, pages: 3, count: 65))
        try await finished(store)
        assertPage(store, id: "102", page: 2, pages: 3, count: 65)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.failedRequest)
        XCTAssertEqual(store.searchText, "rain")
        XCTAssertEqual(store.kind, .video)
        XCTAssertEqual(store.sort, .newest)

        store.search()
        try await fixture.reply(text: "rain", kind: .video, sort: .newest, page: 1,
                                body: Data("<html>Not an SSR Workshop page</html>".utf8))
        try await finished(store)
        assertPage(store, id: "102", page: 2, pages: 3, count: 65)
        XCTAssertNotNil(store.errorMessage)
        assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 2)
        store.searchText = "snow"
        store.kind = .all
        store.sort = .relevance
        store.retrySearch()
        try await fixture.reply(text: "rain", kind: .video, sort: .newest, page: 1,
                                body: pageHTML(id: "201", kind: .video, page: 1, pages: 1, count: 1))
        try await finished(store)
        assertPage(store, id: "201", page: 1, pages: 1, count: 1)
        assertBrowseURL(store, text: "rain", kind: .video, sort: .newest, page: 1)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.failedRequest)
        XCTAssertEqual(store.searchText, "snow")
        XCTAssertEqual(store.kind, .all)
        XCTAssertEqual(store.sort, .relevance)
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
        try await fixture.reply(text: "rain", kind: .scene, sort: .trending, page: 1,
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
        try await fixture.reply(text: "rain", kind: .scene, sort: .trending, page: 1,
                                body: pageHTML(id: "201", page: 1, pages: 2, count: 33))
        try await finished(store)
        store.loadPage(2)
        try await fixture.reply(text: "rain", kind: .scene, sort: .trending, page: 2,
                                body: Data(), status: 500)
        try await finished(store)
        try await waitUntil { old.isStopped }
        old.fail(URLError(.timedOut))
        await fixture.drain()
        assertPage(store, id: "201", page: 1, pages: 2, count: 33)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.failedRequest, WorkshopRequest(query: .init(text: "rain", kind: .scene, sort: .trending), page: 2))
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
        try await fixture.reply(text: "forest", kind: .scene, sort: .trending, page: 1,
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

    private func assertPage(_ store: WorkshopStore, id: String, page: Int, pages: Int, count: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(store.hasLoaded, file: file, line: line)
        XCTAssertEqual(store.items.map(\.id), [id], file: file, line: line)
        XCTAssertEqual(store.page, page, file: file, line: line)
        XCTAssertEqual(store.totalPages, pages, file: file, line: line)
        XCTAssertEqual(store.totalCount, count, file: file, line: line)
    }

    private func assertBrowseURL(_ store: WorkshopStore, text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let values = URLComponents(url: store.browseURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(values.first { $0.name == "searchtext" }?.value, text, file: file, line: line)
        XCTAssertEqual(values.first { $0.name == "requiredtags[]" }?.value, kind == .all ? nil : kind.rawValue, file: file, line: line)
        XCTAssertEqual(values.first { $0.name == "browsesort" }?.value, sort.rawValue, file: file, line: line)
        XCTAssertEqual(values.first { $0.name == "p" }?.value, String(page), file: file, line: line)
    }

    private func finished(_ store: WorkshopStore) async throws {
        try await waitUntil { !store.isLoading }
    }

    private func pageHTML(id: String, title: String = "Fixture wallpaper", kind: WorkshopKind = .scene,
                          page: Int, pages: Int, count: Int) throws -> Data {
        let queries: [[String: Any]] = [
            ["queryKey": ["PlayerLinkDetails", "76561198000000001"], "state": ["data": ["public_data": ["persona_name": "Fixture creator"]]]],
            ["queryKey": ["workshop_browse"], "state": ["data": [
                "eresult": 1, "current_page": page, "total_pages": pages, "total_count": count,
                "results": [["publishedfileid": id, "consumer_appid": 431960, "title": title,
                             "creator": "76561198000000001", "short_description": "A real SSR fixture\nwith escaped layers",
                             "tags": [["tag": kind.rawValue]], "file_size": "4096", "subscriptions": 12]]
            ]]]
        ]
        let queryData = String(decoding: try JSONSerialization.data(withJSONObject: ["queries": queries]), as: UTF8.self)
        let context = String(decoding: try JSONSerialization.data(withJSONObject: ["queryData": queryData]), as: UTF8.self)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: context, options: .fragmentsAllowed), as: UTF8.self)
        return Data("<html><script>window.SSR.renderContext = JSON.parse(\(encoded));</script></html>".utf8)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws { try await Self.waitUntil(condition) }

    private enum FixtureError: Error { case timedOut, unexpectedRequest(URL?) }

    @MainActor
    private final class Fixture {
        let root: URL
        let identifier = UUID().uuidString
        let inbox = WorkshopRequestInbox()
        let delegate = WorkshopSessionDelegate()
        let session: URLSession
        let store: WorkshopStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkshopStoreTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WorkshopFixtureProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Workshop-Test": identifier]
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            WorkshopFixtureProtocol.register(identifier, inbox: inbox)
            // Search never starts setup discovery or downloads; the only session read is isolated here.
            store = WorkshopStore(service: WorkshopService(session: session),
                                  downloader: WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession")))
        }

        func request(text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int) async throws -> WorkshopFixtureProtocol {
            try await WorkshopStoreTests.waitUntil { self.inbox.hasRequest }
            let pending = inbox.take()
            let values = URLComponents(url: pending.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard values.first(where: { $0.name == "searchtext" })?.value == text,
                  values.first(where: { $0.name == "requiredtags[]" })?.value == (kind == .all ? nil : kind.rawValue),
                  values.first(where: { $0.name == "browsesort" })?.value == sort.rawValue,
                  values.first(where: { $0.name == "p" })?.value == String(page) else {
                pending.fail(URLError(.badURL))
                throw FixtureError.unexpectedRequest(pending.request.url)
            }
            return pending
        }

        func reply(text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, body: Data, status: Int = 200) async throws {
            let pending = try await request(text: text, kind: kind, sort: sort, page: page)
            pending.succeed(body, status: status)
        }

        func drain() async {
            session.finishTasksAndInvalidate()
            let result = await XCTWaiter().fulfillment(of: [delegate.invalidated], timeout: 5)
            XCTAssertEqual(result, .completed, "Fixture session must finish all callbacks before final assertions")
        }

        func remove() {
            store.cancelSearch()
            session.invalidateAndCancel()
            WorkshopFixtureProtocol.remove(identifier)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class WorkshopSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let invalidated = XCTestExpectation(description: "Fixture session drained")
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { invalidated.fulfill() }
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
    static func remove(_ identifier: String) { _ = registryLock.withLock { inboxes.removeValue(forKey: identifier) } }
    // This class is installed only in fixture sessions. Claim every request so no fallback can reach the network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let inbox = Self.registryLock.withLock { Self.inboxes[request.value(forHTTPHeaderField: "X-Workshop-Test") ?? ""] }
        guard let inbox else { fail(URLError(.resourceUnavailable)); return }
        inbox.append(self)
    }
    override func stopLoading() { responseLock.withLock { stopped = true } }
    func succeed(_ body: Data, status: Int = 200) {
        responseLock.withLock {
            guard !stopped, !completed else { return }
            completed = true
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/html; charset=utf-8"] )!
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
