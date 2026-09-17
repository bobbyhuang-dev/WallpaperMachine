import XCTest

@testable import MacWallpaperEngine

@MainActor
final class WebPanelAssetsTests: XCTestCase {
  func testThumbnailRouteServesOnlyAnnouncedSecurePreviews() throws {
    let assets = WebPanelAssets()
    let steam = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/1/A/"))
    let insecure = try XCTUnwrap(URL(string: "http://images.steamusercontent.com/ugc/2/B/"))
    assets.thumbnails = ["100": steam, "200": insecure]

    XCTAssertEqual(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/100"))), .thumbnail(steam))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/200"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/300"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail:8080/100"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "https://thumbnail/100"))))

    assets.thumbnails = [:]
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/100"))))
  }

  func testServesEveryBundledPanelModule() throws {
    let assets = WebPanelAssets()
    for name in ["index.html", "panel.js", "settings.js", "theme.js", "icons.js", "panel.css", "settings.css"] {
      let route = assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/\(name)")))
      guard case .file(let file)? = route else { return XCTFail("\(name) is not served") }
      XCTAssertEqual(file.lastPathComponent, name)
    }
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/missing.js"))))
  }
}
