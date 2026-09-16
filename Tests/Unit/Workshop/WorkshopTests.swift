import XCTest
@testable import MacWallpaperEngine

final class WorkshopTests: XCTestCase {
    func testLiveSearchRespectsTypeAndPagination() async throws {
        let service = WorkshopService()
        let first = try await service.browse(search: "forest", kind: .scene, sort: .popular, page: 1)
        let second = try await service.browse(search: "forest", kind: .scene, sort: .popular, page: 2)
        XCTAssertFalse(first.items.isEmpty)
        XCTAssertTrue(first.items.allSatisfy { $0.kind == .scene })
        XCTAssertEqual(second.page, 2)
        XCTAssertNotEqual(Set(first.items.map(\.id)), Set(second.items.map(\.id)))
    }

    func testLiveEmptySearchIsNotReplacedByUnrelatedResults() async throws {
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
}
