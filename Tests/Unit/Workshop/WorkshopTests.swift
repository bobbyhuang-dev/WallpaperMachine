import XCTest
@testable import WallpaperMachine

final class WorkshopTests: XCTestCase {
    /// Skips the case unless live-network tests are opted in.
    ///
    /// The `testLive…` cases below contact Steam's real community pages, so they
    /// depend on network access and on Valve's current markup and result set. A
    /// failure there says nothing about this tree, but it still turns the routine
    /// gate red and invites a pointless re-run, so they are opt-in:
    ///
    /// ```
    /// WALLPAPER_MACHINE_NETWORK_TESTS=1 python3 scripts/test.py
    /// ```
    ///
    /// Steam's page format itself stays covered offline: `decodePage` is exercised
    /// against recorded markup by `WorkshopStoreTests`.
    private func skipUnlessNetworkTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_NETWORK_TESTS"] == "1",
            "live Steam tests are opt-in; set WALLPAPER_MACHINE_NETWORK_TESTS=1")
    }

    func testLiveSearchRespectsTypeAndPagination() async throws {
        try skipUnlessNetworkTestsEnabled()
        let service = WorkshopService()
        let first = try await service.browse(search: "forest", kind: .scene, sort: .popular, page: 1)
        let second = try await service.browse(search: "forest", kind: .scene, sort: .popular, page: 2)
        XCTAssertFalse(first.items.isEmpty)
        XCTAssertTrue(first.items.allSatisfy { $0.kind == .scene })
        XCTAssertEqual(second.page, 2)
        XCTAssertNotEqual(Set(first.items.map(\.id)), Set(second.items.map(\.id)))
    }

    func testLiveEmptySearchIsNotReplacedByUnrelatedResults() async throws {
        try skipUnlessNetworkTestsEnabled()
        let result = try await WorkshopService().browse(search: "zzqvwxjkrpnmabcxyzqvwxjkrpnmabcxyz", kind: .scene, sort: .relevance, page: 1)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.totalCount, 0)
    }

    func testUnexpectedSteamResponseReportsFailure() {
        XCTAssertThrowsError(try WorkshopService.decodePage("<html>Sign in required</html>"))
    }

    func testSearchSpecialCharactersRemainWithinSingleQueryParameter() {
        let query = "rain & snow #winter + night / 日本語"
        let url = WorkshopService.browseURL(search: query, kind: .video, sort: .relevance, page: 1)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "searchtext" }?.value, query)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "appid" }?.value, "431960")
        XCTAssertNil(components?.fragment)
    }

    func testSortOrdersMapToSteamBrowseSortAndTrendWindow() {
        func query(_ sort: WorkshopSort) -> (sort: String?, days: String?) {
            let url = WorkshopService.browseURL(search: "", kind: .scene, sort: sort, page: 1)
            let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return (values.first { $0.name == "browsesort" }?.value, values.first { $0.name == "days" }?.value)
        }
        XCTAssertEqual(query(.topRated).sort, "toprated")
        XCTAssertEqual(query(.trendingToday).sort, "trend")
        XCTAssertEqual(query(.trendingToday).days, "1")
        XCTAssertEqual(query(.trending).sort, "trend")
        XCTAssertEqual(query(.trending).days, "7")
        XCTAssertEqual(query(.trendingMonth).sort, "trend")
        XCTAssertEqual(query(.trendingMonth).days, "30")
        XCTAssertEqual(query(.trendingYear).sort, "trend")
        XCTAssertEqual(query(.trendingYear).days, "365")
        XCTAssertEqual(query(.popular).sort, "totaluniquesubscribers")
        XCTAssertEqual(query(.newest).sort, "mostrecent")
        XCTAssertEqual(query(.relevance).sort, "textsearch")
        // The panel round-trips raw values, so every case must survive the trip.
        for sort in WorkshopSort.allCases { XCTAssertEqual(WorkshopSort(rawValue: sort.rawValue), sort) }
    }

    func testRequiredTagsDeduplicateTypeAndPreserveQueryBoundaries() {
        let specialTag = "rain & snow #winter + 日本語"
        let url = WorkshopService.browseURL(search: "", kind: .scene, sort: .popular, page: 2,
                                             tags: ["Scene", "1920 x 1080", specialTag, "1920 x 1080", specialTag])
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values = components?.queryItems ?? []
        XCTAssertEqual(values.filter { $0.name == "requiredtags[]" }.compactMap(\.value),
                       ["Scene", "1920 x 1080", specialTag])
        XCTAssertEqual(values.first { $0.name == "p" }?.value, "2")
        XCTAssertNil(components?.fragment)

        let allTypesURL = WorkshopService.browseURL(search: "", kind: .all, sort: .popular, page: 1,
                                                     tags: ["Everyone", "Everyone"])
        let allTypesValues = URLComponents(url: allTypesURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(allTypesValues.filter { $0.name == "requiredtags[]" }.compactMap(\.value), ["Everyone"])
    }

    func testExcludedTagsAreSentOnceAndNeverContradictRequiredTags() {
        let url = WorkshopService.browseURL(search: "", kind: .scene, sort: .trendingYear, page: 1,
                                             tags: ["Approved"],
                                             excludedTags: ["Mature", "Scene", "Approved", "Mature", "Unspecified"])
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(values.filter { $0.name == "requiredtags[]" }.compactMap(\.value), ["Scene", "Approved"])
        // Steam drops an item carrying any excluded tag, so a tag that is also required must not be sent.
        XCTAssertEqual(values.filter { $0.name == "excludedtags[]" }.compactMap(\.value), ["Mature", "Unspecified"])

        let plain = WorkshopService.browseURL(search: "", kind: .all, sort: .trendingYear, page: 1)
        let plainValues = URLComponents(url: plain, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(plainValues.allSatisfy { $0.name != "excludedtags[]" && $0.name != "requiredtags[]" })
    }
}
