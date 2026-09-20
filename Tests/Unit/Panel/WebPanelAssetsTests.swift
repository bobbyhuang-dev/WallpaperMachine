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
    XCTAssertEqual(assets.route(try XCTUnwrap(URL(string: "mwe-ui://animated/100"))), .animated(steam))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://animated/200"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://preview-cdn/100"))))

    assets.thumbnails = [:]
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/100"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://animated/100"))))
  }

  func testServesEveryBundledPanelModule() throws {
    let assets = WebPanelAssets()
    let locales = AppLanguage.supported.map(\.tag).filter { $0 != "en" }.map { "locales/\($0).js" }
    XCTAssertFalse(locales.isEmpty)
    for name in ["index.html", "panel.js", "settings.js", "theme.js", "icons.js", "i18n.js", "panel.css", "settings.css"] + locales {
      let route = assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/\(name)")))
      guard case .file(let file)? = route else { return XCTFail("\(name) is not served") }
      XCTAssertTrue(file.path.hasSuffix("/WebUI/\(name)"), file.path)
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(name) is not bundled")
    }
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/missing.js"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/locales/en.js"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/locales/../panel.js"))))
  }
}
