import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

@MainActor
final class ControlPanelWindowSizingTests: XCTestCase {
  func testHostedPanelWindowKeepsItsSizeFloor() async throws {
    let bridge = SizingBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    let session = FileManager.default.temporaryDirectory.appendingPathComponent(
      "window-sizing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: session) }
    let defaultsName = "ControlPanelWindowSizingTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: session),
      supportDirectory: session, defaults: defaults)
    let updater = AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient())
    let controller = NSHostingController(
      rootView: AnyView(
        ControlPanelView(
          store: store, navigation: ControlPanelNavigation(), workshop: workshop,
          updater: updater)))
    controller.sizingOptions = []
    let delegate = SizingDelegate()
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: delegate)
    defer { window.close() }
    XCTAssertFalse(window.isVisible, "The window must stay offscreen")

    let minimum = ControlPanelWindow.minimumFrameSize(for: window)
    XCTAssertGreaterThanOrEqual(minimum.width, 760)
    XCTAssertGreaterThanOrEqual(minimum.height, 560)

    // Let SwiftUI attach to the window and apply whatever sizing it wants; the hosting
    // controller is known to zero `contentMinSize`, so the floor must not depend on it.
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))

    let clamped = ControlPanelWindow.clampedFrameSize(NSSize(width: 100, height: 80), for: window)
    XCTAssertEqual(clamped, minimum, "A tiny live-resize proposal must snap to the floor")
    let larger = NSSize(width: minimum.width + 200, height: minimum.height + 100)
    XCTAssertEqual(ControlPanelWindow.clampedFrameSize(larger, for: window), larger)

    window.setFrame(NSRect(x: 0, y: 0, width: 100, height: 80), display: false)
    ControlPanelWindow.constrainToScreen(window)
    XCTAssertGreaterThanOrEqual(window.frame.width, minimum.width, "Reopening must grow a shrunken frame")
    XCTAssertGreaterThanOrEqual(window.frame.height, minimum.height)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 760)
    XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 560)
    XCTAssertFalse(window.isVisible, "The window must stay offscreen")
    await workshop.steamCMDSetup.shutdown()
  }
}

private final class SizingDelegate: NSObject, NSWindowDelegate {}
private final class SizingBridge: WallpaperBridge {}
