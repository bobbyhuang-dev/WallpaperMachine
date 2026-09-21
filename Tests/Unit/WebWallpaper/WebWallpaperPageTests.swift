import WebKit
import XCTest

@testable import WallpaperMachine

/// Exercises the Wallpaper Engine host protocol against a real offscreen
/// `WKWebView`: module scripts from the project folder, property and pause
/// delivery, and replay to a listener that registers after the host's first
/// push. No desktop window is ever created.
@MainActor
final class WebWallpaperPageTests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-wallpaper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try """
      export const loaded = true;
      window.__moduleLoaded = true;
      """.write(
        to: project.appendingPathComponent("assets/main.js"), atomically: true, encoding: .utf8)
    try """
      <!doctype html><html><head>
      <script type="module" crossorigin src="./assets/main.js"></script>
      <script>
      window.__received = { user: [], general: [], paused: [] };
      // Register late, after the host has already pushed its initial values.
      setTimeout(() => {
        window.wallpaperPropertyListener = {
          applyUserProperties(p) { window.__received.user.push(p); },
          applyGeneralProperties(p) { window.__received.general.push(p); },
          setPaused(v) { window.__received.paused.push(v); },
        };
      }, 50);
      </script></head><body><div id="stage"></div></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  func testPageDeliversHostPropertiesAndPauseToLateListener() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.webView.setFrameSize(NSSize(width: 640, height: 400))
    var failures: [String] = []
    page.onFailure = { failures.append($0) }
    page.applyUserProperties(json: #"{"theme":{"value":"dark"},"tint":{"value":"1 0.5 0"}}"#)
    page.applyGeneralProperties(fps: 30)
    page.setPaused(false)
    page.load()

    let received = try await poll(page) { received in
      (received["user"] as? [[String: Any]])?.isEmpty == false
        && (received["paused"] as? [Bool])?.isEmpty == false
    }
    XCTAssertTrue(failures.isEmpty, "\(failures)")
    let moduleLoaded =
      try await page.webView.callAsyncJavaScript(
        "return window.__moduleLoaded === true", arguments: [:], in: nil, contentWorld: .page)
      as? Bool
    XCTAssertEqual(
      moduleLoaded, true,
      "ES modules must load from the project folder like they do under Wallpaper Engine")
    let user = try XCTUnwrap((received["user"] as? [[String: Any]])?.last)
    XCTAssertEqual((user["theme"] as? [String: Any])?["value"] as? String, "dark")
    XCTAssertEqual((user["tint"] as? [String: Any])?["value"] as? String, "1 0.5 0")
    XCTAssertEqual((received["general"] as? [[String: Any]])?.last?["fps"] as? Int, 30)
    XCTAssertEqual((received["paused"] as? [Bool])?.last, false)

    // Presentation suspension pauses the page without changing the user's
    // playback choice; clearing it resumes only if the user is not paused.
    page.setPresentationSuspended(true)
    _ = try await poll(page) { ($0["paused"] as? [Bool])?.last == true }
    page.setPaused(true)
    page.setPresentationSuspended(false)
    let stillPaused = try await poll(page) { ($0["paused"] as? [Bool])?.count ?? 0 >= 4 }
    XCTAssertEqual((stillPaused["paused"] as? [Bool])?.last, true)
    page.setPaused(false)
    let resumed = try await poll(page) { ($0["paused"] as? [Bool])?.last == false }
    XCTAssertEqual((resumed["paused"] as? [Bool])?.last, false)
    XCTAssertNil(page.webView.window, "This regression must not open a desktop window")
  }

  func testTopFrameCannotNavigateAwayFromTheEntryPage() async throws {
    try """
      <!doctype html><html><body><script>location.href = "https://example.invalid/";</script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(page.webView.url?.standardizedFileURL, page.entryURL.standardizedFileURL)
  }

  func testForwardedPointerEventsReachThePageWithoutANativeContextMenu() async throws {
    try """
      <!doctype html><html><body style="margin:0"><div id="stage" style="position:absolute;left:0;top:0;width:640px;height:400px"></div>
      <script>
      window.__received = { pointer: [] };
      for (const name of ["mousedown", "mouseup", "click", "contextmenu"]) {
        window.addEventListener(name, event => window.__received.pointer.push(
          [name, event.clientX, event.clientY, event.button, event.defaultPrevented]), false);
      }
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.webView.setFrameSize(NSSize(width: 640, height: 400))
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)

    // AppKit points, origin bottom-left: (100, 300) is CSS (100, 100).
    let point = NSPoint(x: 100, y: 300)
    let event = { (type: NSEvent.EventType) in
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
    }
    page.deliverMouse(event(.leftMouseDown))
    page.deliverMouse(event(.leftMouseUp))
    page.deliverMouse(event(.rightMouseDown))
    page.deliverMouse(event(.rightMouseUp))
    // Wheel events ride WebKit's scrolling thread, which only exists for a page
    // in a window; they are covered by the desktop probe, not here.

    let received = try await poll(page) { ($0["pointer"] as? [[Any]])?.count ?? 0 >= 6 }
    let pointer = try XCTUnwrap(received["pointer"] as? [[Any]])
    XCTAssertEqual(
      pointer.map { $0[0] as? String },
      ["mousedown", "mouseup", "click", "mousedown", "contextmenu", "mouseup"], "\(pointer)")
    let click = try XCTUnwrap(pointer.first { $0[0] as? String == "click" })
    XCTAssertEqual(click[1] as? Int, 100)
    XCTAssertEqual(click[2] as? Int, 100)
    XCTAssertEqual(click[3] as? Int, 0)
    let contextMenu = try XCTUnwrap(pointer.first { $0[0] as? String == "contextmenu" })
    XCTAssertEqual(contextMenu[3] as? Int, 2)
    XCTAssertEqual(contextMenu[4] as? Bool, true, "WebKit's context menu must never open over the desktop")
    XCTAssertNil(page.webView.window, "This regression must not open a desktop window")
  }

  private func poll(
    _ page: WebWallpaperPage, timeout: TimeInterval = 10,
    until condition: ([String: Any]) -> Bool
  ) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    var last: [String: Any] = [:]
    while Date() < deadline {
      if page.isLoaded,
        let received = try? await page.webView.callAsyncJavaScript(
          "return window.__received", arguments: [:], in: nil, contentWorld: .page)
          as? [String: Any]
      {
        last = received
        if condition(received) { return received }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("condition not met before timeout; last state: \(last)")
    return last
  }
}
