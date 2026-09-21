import XCTest

@testable import WallpaperMachine

/// The routing policy decides whether an observed desktop pointer event
/// belongs to a web wallpaper page. Window numbers stand in for AppKit windows.
final class WebWallpaperMouseRoutingTests: XCTestCase {
  private let wallpaper = 100
  private let finderDesktop = 10
  private let appWindow = 50
  private var layers: [Int: Int] = [:]

  override func setUp() {
    layers = [10: Int(CGWindowLevelForKey(.desktopIconWindow)), 50: 0]
  }

  private func route(
    _ routing: inout WebWallpaperMouseRouting, _ kind: WebWallpaperMouseRouting.Kind,
    over wallpaper: Int? = 100, front: Int
  ) -> WebWallpaperMouseRouting.Decision {
    routing.route(kind, wallpaperWindow: wallpaper, frontWindow: front) { self.layers[$0] }
  }

  func testEventsOverTheDesktopReachTheWallpaperUnderThePointer() {
    var routing = WebWallpaperMouseRouting()
    XCTAssertEqual(route(&routing, .move, front: finderDesktop), .deliver(to: wallpaper))
    XCTAssertEqual(route(&routing, .scroll, front: finderDesktop), .deliver(to: wallpaper))
    XCTAssertEqual(route(&routing, .down(button: 0), front: wallpaper), .deliver(to: wallpaper),
      "A wallpaper window reported as frontmost needs no layer lookup")
    XCTAssertEqual(route(&routing, .up(button: 0), front: wallpaper), .deliver(to: wallpaper))
  }

  func testApplicationWindowsAndUnknownWindowsShieldTheWallpaper() {
    var routing = WebWallpaperMouseRouting()
    XCTAssertEqual(route(&routing, .down(button: 0), front: appWindow), .ignore)
    XCTAssertEqual(route(&routing, .up(button: 0), front: appWindow), .ignore,
      "A release without a forwarded press is not a click")
    XCTAssertEqual(route(&routing, .scroll, front: 999), .ignore, "unknown layer is not the desktop")
    XCTAssertEqual(route(&routing, .move, over: nil, front: finderDesktop), .ignore,
      "no wallpaper under the pointer")
  }

  func testForwardedPressKeepsItsDragAndReleaseOverOtherWindows() {
    var routing = WebWallpaperMouseRouting()
    XCTAssertEqual(route(&routing, .down(button: 0), front: finderDesktop), .deliver(to: wallpaper))
    XCTAssertTrue(routing.isPressed)
    XCTAssertEqual(route(&routing, .drag(button: 0), over: nil, front: appWindow), .deliver(to: wallpaper))
    XCTAssertEqual(route(&routing, .up(button: 0), over: nil, front: appWindow), .deliver(to: wallpaper))
    XCTAssertFalse(routing.isPressed)
    XCTAssertEqual(route(&routing, .drag(button: 0), front: finderDesktop), .ignore,
      "drags after the release are stale")
    // Buttons are tracked independently.
    XCTAssertEqual(route(&routing, .down(button: 1), front: finderDesktop), .deliver(to: wallpaper))
    XCTAssertEqual(route(&routing, .up(button: 0), front: finderDesktop), .ignore)
    XCTAssertEqual(route(&routing, .up(button: 1), front: appWindow), .deliver(to: wallpaper))
  }

  func testHoverExitsOnceWhenThePointerLeavesTheDesktop() {
    var routing = WebWallpaperMouseRouting()
    XCTAssertEqual(route(&routing, .move, front: finderDesktop), .deliver(to: wallpaper))
    XCTAssertEqual(route(&routing, .move, front: appWindow), .exit(wallpaper))
    XCTAssertEqual(route(&routing, .move, front: appWindow), .ignore, "exit fires only once")
    XCTAssertEqual(route(&routing, .scroll, front: appWindow), .ignore)
    XCTAssertEqual(route(&routing, .move, front: finderDesktop), .deliver(to: wallpaper))
    XCTAssertEqual(route(&routing, .move, over: 200, front: finderDesktop), .exitThenDeliver(exit: wallpaper, to: 200),
      "crossing to another display's wallpaper exits the previous page")
    routing.reset()
    XCTAssertEqual(route(&routing, .move, front: appWindow), .ignore)
  }
}
