import XCTest
import CoreGraphics
import AppKit

final class MacWallpaperEngineUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "app.mac-wallpaper-engine")
        app.launchEnvironment["MAC_WALLPAPER_ENGINE_HOME"] = NSTemporaryDirectory() + "mac-wallpaper-engine-ui-" + UUID().uuidString
        if name.contains("testInvalidVideo") {
            let root = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["MAC_WALLPAPER_ENGINE_HOME"]))
            let folder = root.appendingPathComponent("Library/broken-video")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("not valid media".utf8).write(to: folder.appendingPathComponent("broken.mp4"))
            try JSONSerialization.data(withJSONObject: ["title": "Broken Video", "type": "video", "file": "broken.mp4"])
                .write(to: folder.appendingPathComponent("project.json"))
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "The client must open a real window")
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    private func navigate(_ label: String) {
        let item = app.outlines.staticTexts[label].firstMatch
        if item.exists { item.click() }
        else { app.staticTexts[label].firstMatch.click() }
    }

    func testLaunchHasNoBlankFloatingWindows() {
        XCTAssertTrue(app.buttons["library.item.starter-aurora"].waitForExistence(timeout: 15))
        // Some empty SwiftUI panels are absent from the accessibility tree.
        // Check WindowServer too, ignoring the menu bar and desktop wallpapers.
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "app.mac-wallpaper-engine")
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?.processIdentifier
        XCTAssertNotNil(pid)
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let clientWindows = windows.filter {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid
                && $0[kCGWindowLayer as String] as? Int == 0
                && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100
        }
        XCTAssertEqual(clientWindows.count, 1, "Launch should show only the library: \(clientWindows)")
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(app.dialogs.count, 0)
    }

    func testSettingsShortcutUsesExistingWindow() {
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 15))
        app.windows.firstMatch.click()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["steamcmd.install"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        navigate("Library")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["steamcmd.install"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
    }

    func testFirstLaunchNavigationAndSettings() {
        XCTAssertTrue(app.buttons["library.item.starter-aurora"].waitForExistence(timeout: 15))
        navigate("Settings")
        XCTAssertTrue(app.buttons["steamcmd.install"].waitForExistence(timeout: 10))
        navigate("Display")
        XCTAssertTrue(app.windows.firstMatch.exists)
        navigate("Library")
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.alerts.count, 0)
    }
    func testImportSheetCancelAndEmptyLibrarySearch() {
        app.buttons["Import"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Import Items"].isEnabled)
        app.buttons["Cancel"].click()
        XCTAssertEqual(app.sheets.count, 0)
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("no-local-wallpaper-with-this-title")
        search.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.buttons["library.item.starter-aurora"].exists)
        app.buttons["Clear Search & Filters"].click()
        XCTAssertTrue(app.buttons["library.item.starter-aurora"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testWorkshopLoadsRealResultsAndSetup() {
        navigate("Workshop")
        XCTAssertTrue(app.textFields["workshop.search"].waitForExistence(timeout: 10))
        let setup = app.buttons["Download setup"]
        XCTAssertTrue(setup.exists)
        setup.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Workshop account setup"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testSelectionSurvivesLibraryRefresh() {
        app.buttons["library.item.starter-aurora"].click()
        XCTAssertTrue(app.staticTexts["wallpaper.activationStatus"].waitForExistence(timeout: 30))
        let selectedValue = app.buttons["library.item.starter-aurora"].value as? String
        app.buttons["Refresh"].click()
        XCTAssertEqual(app.buttons["library.item.starter-aurora"].value as? String, selectedValue)
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testCloseAndReopenDoesNotQuitOrCrash() {
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testApplyPauseResumeAndRelaunch() {
        app.buttons["library.item.starter-aurora"].click()
        XCTAssertTrue(app.staticTexts["wallpaper.activationStatus"].waitForExistence(timeout: 30))
        app.buttons["playback.toggle"].click()
        XCTAssertTrue(app.buttons["Resume wallpapers"].waitForExistence(timeout: 5))
        app.buttons["playback.toggle"].click()
        XCTAssertTrue(app.buttons["Pause wallpapers"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Pause wallpapers"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testWorkshopSearchPaginationAndNavigationPersistence() {
        navigate("Workshop")
        let search = app.textFields["workshop.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("forest")
        search.typeKey(.return, modifierFlags: [])
        app.buttons["Search"].click()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workshop.item.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 40))
        let firstID = cards.firstMatch.identifier
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Page 2 of'")).firstMatch.waitForExistence(timeout: 40))
        XCTAssertNotEqual(cards.firstMatch.identifier, firstID)
        navigate("Library")
        navigate("Workshop")
        XCTAssertEqual(app.textFields["workshop.search"].value as? String, "forest")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Page 2 of'")).firstMatch.exists)
        XCTAssertEqual(app.alerts.count, 0)
    }
    func testInvalidVideoReportsFailureAndRemainsUsable() throws {
        XCTAssertTrue(app.buttons["library.item.broken-video"].waitForExistence(timeout: 5))
        app.buttons["library.item.broken-video"].click()
        let status = app.staticTexts["wallpaper.activationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let failureStatus = status.label
        XCTAssertFalse(app.buttons["playback.toggle"].isEnabled)
        XCTAssertTrue(app.buttons["library.item.starter-aurora"].isEnabled)
        app.buttons["library.item.starter-aurora"].click()
        expectation(for: NSPredicate(format: "label != %@ AND label != ''", failureStatus), evaluatedWith: status)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(app.buttons["playback.toggle"].isEnabled)
    }
}
