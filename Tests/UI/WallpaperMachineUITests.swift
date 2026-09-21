import AppKit
import CoreGraphics
import XCTest

final class WallpaperMachineUITests: XCTestCase {
  private var app: XCUIApplication!
  private var panel: XCUIElement { app.webViews.firstMatch }

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication(bundleIdentifier: "app.wallpapermachine")
    app.launchEnvironment["WALLPAPER_MACHINE_HOME"] =
      NSTemporaryDirectory() + "WallpaperMachine-ui-" + UUID().uuidString
    if name.contains("testInvalidVideo") {
      let root = URL(
        fileURLWithPath: try XCTUnwrap(app.launchEnvironment["WALLPAPER_MACHINE_HOME"]))
      let folder = root.appendingPathComponent("Library/broken-video")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("not valid media".utf8).write(to: folder.appendingPathComponent("broken.mp4"))
      try JSONSerialization.data(withJSONObject: [
        "title": "Broken Video", "type": "video", "file": "broken.mp4",
      ])
      .write(to: folder.appendingPathComponent("project.json"))
    }
    app.launch()
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistence(timeout: 30), "The client must open a real window")
    XCTAssertTrue(panel.waitForExistence(timeout: 30), "The window must expose its WebKit panel")
  }

  override func tearDownWithError() throws {
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.terminate()
  }

  private func button(_ label: String) -> XCUIElement {
    panel.buttons[label].firstMatch
  }

  private func wallpaper(_ title: String) -> XCUIElement {
    panel.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
  }

  private func searchField(_ label: String) -> XCUIElement {
    panel.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "label == %@ AND (elementType == %d OR elementType == %d)",
          label, XCUIElement.ElementType.searchField.rawValue,
          XCUIElement.ElementType.textField.rawValue)
      ).firstMatch
  }

  private func pageText(_ prefix: String) -> XCUIElement {
    panel.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
  }

  private func navigate(_ label: String) {
    let tab = button(label)
    XCTAssertTrue(tab.waitForExistence(timeout: 10))
    tab.click()
  }

  private func selectAurora() {
    let tile = wallpaper("Aurora Drift")
    XCTAssertTrue(tile.waitForExistence(timeout: 15))
    tile.click()
    XCTAssertTrue(button("Apply wallpaper").waitForExistence(timeout: 10))
  }

  private func applyAurora() {
    selectAurora()
    button("Apply wallpaper").click()
    XCTAssertTrue(
      button("Reapply wallpaper").waitForExistence(timeout: 30),
      "The selected wallpaper must become active on the target display")
  }

  func testLaunchHasNoBlankFloatingWindows() {
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 15))
    // Empty native windows can be absent from the accessibility tree. Ignore
    // the menu bar and desktop wallpaper windows in the WindowServer check.
    let pid = NSRunningApplication.runningApplications(
      withBundleIdentifier: "app.wallpapermachine"
    )
    .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?.processIdentifier
    XCTAssertNotNil(pid)
    let windows =
      CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let clientWindows = windows.filter {
      $0[kCGWindowOwnerPID as String] as? pid_t == pid
        && $0[kCGWindowLayer as String] as? Int == 0
        && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100
    }
    XCTAssertEqual(
      clientWindows.count, 1, "Launch should show only the control panel: \(clientWindows)")
    XCTAssertEqual(app.sheets.count, 0)
    XCTAssertEqual(app.dialogs.count, 0)
  }

  func testSettingsShortcutUsesExistingWindow() {
    XCTAssertTrue(searchField("Search installed wallpapers").waitForExistence(timeout: 15))
    app.windows.firstMatch.click()
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(button("Library & Steam").waitForExistence(timeout: 10))
    XCTAssertEqual(app.windows.count, 1)
    navigate("Installed")
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(button("Library & Steam").waitForExistence(timeout: 10))
    XCTAssertEqual(app.windows.count, 1)
  }

  func testFirstLaunchNavigationAndSettingsCategories() {
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 15))
    navigate("Settings")
    XCTAssertTrue(button("General").waitForExistence(timeout: 10))
    button("Displays").click()
    XCTAssertTrue(pageText("Display mode").waitForExistence(timeout: 10))
    button("Library & Steam").click()
    XCTAssertTrue(pageText("SteamCMD").waitForExistence(timeout: 10))
    navigate("Discover")
    XCTAssertTrue(searchField("Search Steam Workshop").waitForExistence(timeout: 10))
    navigate("Installed")
    XCTAssertTrue(searchField("Search installed wallpapers").waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testImportPanePickerCancelAndEmptyLibrarySearch() {
    XCTAssertTrue(button("Import").waitForExistence(timeout: 15))
    button("Import").click()
    XCTAssertTrue(pageText("Import wallpapers").waitForExistence(timeout: 5))
    XCTAssertTrue(button("Choose wallpapers").exists)
    XCTAssertEqual(app.sheets.count, 0, "Opening the import pane must not open the native picker")
    button("Choose wallpapers").click()
    let picker = app.sheets.firstMatch
    XCTAssertTrue(
      picker.waitForExistence(timeout: 10), "Choosing files must open the native picker")
    picker.buttons["Cancel"].click()
    XCTAssertFalse(picker.exists)
    button("Close import").click()
    XCTAssertFalse(pageText("Import wallpapers").exists)

    let search = searchField("Search installed wallpapers")
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.click()
    search.typeText("no-local-wallpaper-with-this-title")
    XCTAssertTrue(pageText("No matching wallpapers").waitForExistence(timeout: 10))
    XCTAssertFalse(wallpaper("Aurora Drift").exists)
    button("Clear search and filters").click()
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testSelectionSurvivesLibraryRefreshWithoutApplying() {
    selectAurora()
    XCTAssertFalse(
      button("Reapply wallpaper").exists,
      "Selecting a tile must not activate the wallpaper")
    button("Refresh library").click()
    XCTAssertTrue(
      button("Apply wallpaper").waitForExistence(timeout: 30),
      "Refresh must retain the selected wallpaper without activating it")
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testCloseAndReopenDoesNotQuitOrCrash() {
    app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testApplyPauseResumeAndRelaunch() {
    applyAurora()
    button("Pause wallpaper playback").click()
    XCTAssertTrue(button("Resume wallpaper playback").waitForExistence(timeout: 5))
    XCTAssertTrue(pageText("Playback paused").exists)
    button("Resume wallpaper playback").click()
    XCTAssertTrue(button("Pause wallpaper playback").waitForExistence(timeout: 5))
    XCTAssertTrue(pageText("Playback running").exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(panel.waitForExistence(timeout: 30))
    XCTAssertTrue(button("Pause wallpaper playback").waitForExistence(timeout: 30))
    XCTAssertTrue(wallpaper("Aurora Drift").waitForExistence(timeout: 15))
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testWorkshopSearchPaginationAndNavigationPersistence() {
    navigate("Discover")
    let search = searchField("Search Steam Workshop")
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.click()
    search.typeText("forest")
    button("Search").click()
    XCTAssertTrue(pageText("Page 1 of").waitForExistence(timeout: 40))
    let next = button("Next page")
    XCTAssertTrue(next.waitForExistence(timeout: 40))
    XCTAssertTrue(
      next.isEnabled, "The Workshop query needs more than one page to exercise pagination")
    next.click()
    XCTAssertTrue(pageText("Page 2 of").waitForExistence(timeout: 40))
    navigate("Installed")
    navigate("Discover")
    XCTAssertEqual(searchField("Search Steam Workshop").value as? String, "forest")
    XCTAssertTrue(pageText("Page 2 of").exists)
    XCTAssertEqual(app.alerts.count, 0)
  }

  func testInvalidVideoReportsFailureAndRemainsUsable() {
    let broken = wallpaper("Broken Video")
    XCTAssertTrue(broken.waitForExistence(timeout: 15))
    broken.click()
    XCTAssertTrue(button("Apply wallpaper").waitForExistence(timeout: 10))
    button("Apply wallpaper").click()
    XCTAssertTrue(
      button("Dismiss error").waitForExistence(timeout: 30),
      "The invalid video must report an error in the panel")
    XCTAssertFalse(
      button("Reapply wallpaper").exists,
      "A failed activation must not mark the invalid video active")
    applyAurora()
    XCTAssertTrue(button("Pause wallpaper playback").isEnabled)
  }
}
