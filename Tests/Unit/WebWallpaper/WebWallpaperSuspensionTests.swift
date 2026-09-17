import WebKit
import XCTest

@testable import MacWallpaperEngine

/// Host-side suspension for pages that do not cooperate. The Wallpaper Engine
/// `setPaused` callback is optional, so a page can ignore it and keep its
/// timers, workers and media running; what the host controls instead is media
/// playback and whether the web view is in the window tree at all.
///
/// The page used here deliberately implements no `wallpaperPropertyListener`.
@MainActor
final class WebWallpaperSuspensionTests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-suspension-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    // No pause listener at all: rAF, interval and CSS keep advancing until the
    // host stops them from the outside.
    try """
      <!doctype html><html><head><style>
      @keyframes spin { from { opacity: 0 } to { opacity: 1 } }
      #anim { animation: spin 100ms infinite; width: 10px; height: 10px; background: red }
      </style></head>
      <body style="margin:0;background:#123456"><div id="anim"></div>
      <script>
      window.__ticks = { frames: 0, intervals: 0 };
      const step = () => { window.__ticks.frames++; requestAnimationFrame(step); };
      requestAnimationFrame(step);
      setInterval(() => { window.__ticks.intervals++; }, 10);
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  /// A page hosted in a container view the way `WebWallpaperWindow` does, but
  /// without opening a desktop window.
  private func hostedPage(counters: RuntimeCounters? = nil) -> (WebWallpaperPage, NSView) {
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html",
      surface: RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4), counters: counters)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    container.wantsLayer = true
    page.attach(to: container)
    return (page, container)
  }

  func testSuspensionTakesTheWebViewOutOfTheViewTreeAndBringsItBack() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(counters: counters)
    page.load()
    try await waitUntilLoaded(page)
    XCTAssertTrue(page.isInWindowTree)

    page.setPresentationSuspended(true)
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(
      page.isInWindowTree,
      "WebKit's inactive scheduling policy keys off not being in a window")
    XCTAssertTrue(
      container.subviews.contains { $0 is NSImageView },
      "a placeholder keeps the last frame on screen while the page is detached")
    XCTAssertNotNil(container.layer, "the poster sync identifies this surface by the container layer")

    let generation = page.documentGeneration
    page.setPresentationSuspended(false)
    XCTAssertTrue(page.isInWindowTree)
    XCTAssertFalse(container.subviews.contains { $0 is NSImageView })
    XCTAssertEqual(
      page.documentGeneration, generation,
      "suspension must not reload the document, which would lose its JS state")
    XCTAssertTrue(page.isLoaded, "the same document is still the loaded one")

    let snapshot = counters.snapshot()
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(snapshot.value(.webMediaSuspended, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webMediaResumed, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webDetached, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webAttached, for: surface), 1)
  }

  // A page that implements no pause listener cannot be asked to stop, and once
  // its web view leaves the window tree WebKit stops running its script — so a
  // detached page cannot be asked anything either. Whether the page's own work
  // stops and restarts needs a real window and is recorded as unverified in the
  // progress document. The precedence of a user pause over presentation resume
  // is covered by WebWallpaperPageTests, whose page is never detached.

  func testRepeatedSuspendAndResumeSettlesAttached() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(counters: counters)
    page.load()
    try await waitUntilLoaded(page)

    for _ in 0..<6 {
      page.setPresentationSuspended(true)
      page.setPresentationSuspended(false)
    }
    // The detach poster is asynchronous; a resume that overtakes it must not
    // leave the page out of the tree or leave a placeholder behind.
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(page.isInWindowTree, "flapping visibility must settle attached")
    XCTAssertFalse(container.subviews.contains { $0 is NSImageView })

    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(counters.snapshot().value(.webMediaSuspended, for: surface), 6)
    XCTAssertEqual(counters.snapshot().value(.webMediaResumed, for: surface), 6)
  }

  func testASuspendedPageReceivesNoPointerEvents() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, _) = hostedPage(counters: counters)
    page.load()
    try await waitUntilLoaded(page)

    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 0)!
    page.deliverMouse(event)
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(counters.snapshot().value(.pointerDelivered, for: surface), 1)

    page.setPresentationSuspended(true)
    page.deliverMouse(event)
    page.deliverMouse(event)
    XCTAssertEqual(
      counters.snapshot().value(.pointerDelivered, for: surface), 1,
      "a suspended page consumes no pointer input")

    page.setPresentationSuspended(false)
    page.deliverMouse(event)
    XCTAssertEqual(counters.snapshot().value(.pointerDelivered, for: surface), 2)
  }

  func testSuspendingBeforeTheFirstLoadDoesNotAttachThePage() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.setPresentationSuspended(true)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    page.attach(to: container)
    XCTAssertFalse(
      page.isInWindowTree,
      "a surface that is already hidden must not start by rendering into a window")

    page.setPresentationSuspended(false)
    XCTAssertTrue(page.isInWindowTree)
  }

  // MARK: - helpers

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
  }

  private func poll(
    timeout: TimeInterval = 5, until condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
