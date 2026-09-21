import ImageIO
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import MacWallpaperEngine

/// Stands in for WebKit's scheme task so a load can be started, stopped and restarted on
/// the same object identity, which is what a freed-and-reallocated task looks like.
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
  var request: URLRequest
  var responses: [URLResponse] = []
  var body = Data()
  var finished = 0
  var failures: [Error] = []
  var onSettle: (() -> Void)?

  init(_ url: URL) { request = URLRequest(url: url) }

  func didReceive(_ response: URLResponse) { responses.append(response) }
  func didReceive(_ data: Data) { body.append(data) }
  func didFinish() {
    finished += 1
    onSettle?()
  }
  func didFailWithError(_ error: Error) {
    failures.append(error)
    onSettle?()
  }
}

/// Answers Steam preview requests only once the test releases it.
private final class GatedFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private let payload: Data

  init(payload: Data) { self.payload = payload }

  func release() {
    lock.lock()
    released = true
    let waiters = self.waiters
    self.waiters = []
    lock.unlock()
    waiters.forEach { $0.resume() }
  }

  func fetch(_ url: URL) async throws -> Data {
    await withCheckedContinuation { continuation in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
    return payload
  }
}

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

  func testRestartedTaskStillReceivesItsResponse() async throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("mwe-assets-\(UUID().uuidString)", isDirectory: true)
    let previous = ProcessInfo.processInfo.environment["MAC_WALLPAPER_ENGINE_HOME"]
    setenv("MAC_WALLPAPER_ENGINE_HOME", home.path, 1)
    defer {
      if let previous { setenv("MAC_WALLPAPER_ENGINE_HOME", previous, 1) } else { unsetenv("MAC_WALLPAPER_ENGINE_HOME") }
      try? FileManager.default.removeItem(at: home)
    }
    let folder = ClientPaths.libraryURL.appendingPathComponent("42", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let preview = folder.appendingPathComponent("preview.png")
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    try bytes.write(to: preview)

    let fetcher = GatedFetcher(payload: try Self.png(width: 32, height: 32))
    let cache = WorkshopThumbnailCache(
      directory: home.appendingPathComponent("thumbs", isDirectory: true), fetcher: fetcher)
    let assets = WebPanelAssets(thumbnailCache: cache)
    let steam = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/1/A/"))
    assets.previews = ["42": preview]
    assets.thumbnails = ["100": steam]
    let webView = WKWebView()
    let task = FakeSchemeTask(try XCTUnwrap(URL(string: "mwe-ui://preview/42")))

    // WebKit stops the first load, frees the task, and the next load lands on the same
    // identity. The stale job finishes first and must neither answer nor evict the fresh one.
    assets.webView(webView, start: task)
    assets.webView(webView, stop: task)
    task.request = URLRequest(url: try XCTUnwrap(URL(string: "mwe-ui://thumbnail/100")))
    let settled = expectation(description: "restarted load settles")
    task.onSettle = { settled.fulfill() }
    assets.webView(webView, start: task)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(task.responses.isEmpty, "the stopped load must stay silent")
    fetcher.release()
    await fulfillment(of: [settled], timeout: 5)

    XCTAssertEqual(task.finished, 1)
    XCTAssertTrue(task.failures.isEmpty, "\(task.failures)")
    XCTAssertEqual((task.responses.first as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(task.responses.first?.mimeType, "image/jpeg")
    XCTAssertFalse(task.body.isEmpty)
    XCTAssertNotEqual(task.body, bytes, "the stopped file load must not leak into the restarted one")
  }

  private static func png(width: Int, height: Int) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
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
