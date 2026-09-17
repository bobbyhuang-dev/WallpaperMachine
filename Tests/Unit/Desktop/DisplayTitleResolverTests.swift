import XCTest

@testable import MacWallpaperEngine

@MainActor
final class DisplayTitleResolverTests: XCTestCase {
    private let titles = DisplayTitleResolver(names: {
        [
            "1": "Built-in Retina Display", "7": "  ", "9": "LG UltraFine",
            "37D8832A-2D66-02CA-B9F7-8F30A301B230": "Studio Display",
        ]
    }).resolved()

    func testReplacesVendorModelLabelWithLocalizedNameKeepingSuffix() {
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (1 - Primary)", displayId: "1"),
            "Built-in Retina Display (1 - Primary)")
        XCTAssertEqual(titles.title("Vendor 7789 - Model 30460 (9)", displayId: "9"), "LG UltraFine (9)")
    }

    func testReplacesTheWholeLabelWhenTheRendererHasNoSuffix() {
        XCTAssertEqual(titles.title("Vendor 1552 - Model 41055", displayId: "1"), "Built-in Retina Display")
        XCTAssertEqual(titles.title("(1)", displayId: "1"), "Built-in Retina Display")
    }

    func testResolvesPrimaryAndIdentitySelectorsThroughTheLiveIdInTheSuffix() {
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (1 - Primary)", displayId: "primary"),
            "Built-in Retina Display (1 - Primary)")
        let identity = #"identity:{"uuid":"37d8832a-2d66-02ca-b9f7-8f30a301b230","vendor_id":1552}"#
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (9)", displayId: identity), "LG UltraFine (9)")
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (4)", displayId: identity), "Studio Display (4)")
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055", displayId: "identity:{not json"),
            "Vendor 1552 - Model 41055")
    }

    func testKeepsRendererTitleWithoutAUsableName() {
        XCTAssertEqual(titles.title("Vendor 4 - Model 5 (3)", displayId: "3"), "Vendor 4 - Model 5 (3)")
        XCTAssertEqual(titles.title("Vendor 4 - Model 5 (7)", displayId: "7"), "Vendor 4 - Model 5 (7)")
        XCTAssertEqual(DisplayTitleResolver.renderer.resolved().title("Display (1)", displayId: "1"), "Display (1)")
    }

    func testSystemResolverKeysNamesByScreenNumberAndUUID() throws {
        let names = DisplayTitleResolver.system.names()
        for screen in NSScreen.screens {
            guard let id = SystemDesktopPictureWorkspace.id(screen), let number = UInt32(id) else { continue }
            XCTAssertEqual(names[id], screen.localizedName)
            let uuid = try XCTUnwrap(CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue())
            XCTAssertEqual(names[(CFUUIDCreateString(nil, uuid) as String).uppercased()], screen.localizedName)
        }
    }
}
