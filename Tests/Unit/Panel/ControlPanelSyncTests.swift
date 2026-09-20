import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import MacWallpaperEngine

/// State push while hidden, page-scoped pushes, option fetches and display-title resolution.
@MainActor
final class ControlPanelSyncTests: ControlPanelTestCase {
  func testHiddenPanelCoalescesChangesAndStillRepliesToCommands() async throws {
    try await withPanel { panel in
      for index in 0..<4 {
        panel.store.librarySnapshot.wallpapers = [
          BridgeWallpaperEntry(
            id: "latest", title: "Revision \(index)", kind: .video, supported: true,
            active: false, selected: false, previewPath: nil)
        ]
        panel.workshop.searchText = "Query \(index)"
        try await Task.sleep(for: .milliseconds(20))
      }
      let reply = try await panel.js("""
        const state = await window.webkit.messageHandlers.native.postMessage({action:'navigate',page:'settings'});
        return {title:state.wallpapers[0].title, text:state.workshop.text, page:state.page,
                pushes:window.powerProbe.received.length};
        """) as? [String: Any]
      XCTAssertEqual(reply?["title"] as? String, "Revision 3")
      XCTAssertEqual(reply?["text"] as? String, "Query 3")
      XCTAssertEqual(reply?["page"] as? String, "settings")
      XCTAssertEqual(reply?["pushes"] as? Int, 0)
      panel.show()
      try await panel.waitJS("powerProbe.received.length === 1")
      try await panel.quiet()
      let delivered = try await panel.js("""
        return {count:powerProbe.received.length, title:powerProbe.received.at(-1).wallpapers[0].title,
                text:powerProbe.received.at(-1).workshop.text};
        """) as? [String: Any]
      XCTAssertEqual(delivered?["count"] as? Int, 1)
      XCTAssertEqual(delivered?["title"] as? String, "Revision 3")
      XCTAssertEqual(delivered?["text"] as? String, "Query 3")
    }
  }

  func testHiddenPanelContinuesSetupAndObservesNestedDownloadChanges() async throws {
    try await withPanel { panel in
      _ = try await panel.js("powerProbe.hold = true")
      panel.show()
      try await panel.waitJS("powerProbe.pending.length === 1")
      panel.hide()
      let item = WorkshopItem(
        id: "222", title: "Local video", creator: "Fixture", summary: "",
        previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
      panel.workshop.username = "localtest"
      panel.workshop.requestDownload(item: item, rememberSession: false, bridge: panel.store)
      XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["222"])
      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil { panel.workshop.downloader.download(for: "222")?.worker.prompt == .password }
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
      try await panel.expectJS("return powerProbe.received.length", equals: 1)
      _ = try await panel.js("powerProbe.hold = false; powerProbe.pending.shift()()")
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.downloads[0]?.securePrompt === true")
      try Data().write(to: panel.root.appendingPathComponent("advance"))
      try await panel.waitJS("powerProbe.received.at(-1)?.downloads[0]?.securePrompt === false")
      panel.hide()
      try await panel.quiet()
      let count = try await panel.js("return powerProbe.received.length") as? Int ?? -1
      let job = try XCTUnwrap(panel.workshop.downloader.download(for: "222"))
      panel.workshop.downloader.cancel(job)
      try await panel.waitUntil { !job.isPending }
      try await panel.quiet()
      try await panel.expectJS("return powerProbe.received.length", equals: count)
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.downloads[0]?.cancelled === true")
    }
  }

  func testPanelPushWaitsForReceiveAndKeepsOnlyLatestPendingState() async throws {
    try await withPanel { panel in
      _ = try await panel.js("powerProbe.hold = true")
      panel.show()
      try await panel.waitJS("powerProbe.pending.length === 1")
      for index in 0..<4 {
        panel.workshop.searchText = "Pending \(index)"
        try await Task.sleep(for: .milliseconds(20))
      }
      let busy = try await panel.js("return [powerProbe.received.length, powerProbe.maxActive]") as? [Int]
      XCTAssertEqual(busy, [1, 1])
      _ = try await panel.js("powerProbe.pending.shift()()")
      try await panel.waitJS("powerProbe.received.length === 2")
      try await panel.expectJS("return powerProbe.received.at(-1).workshop.text", equals: "Pending 3")
      try await panel.expectJS("return powerProbe.maxActive", equals: 1)
      panel.controller.stop()
      panel.workshop.searchText = "Must not be pushed"
      _ = try await panel.js("powerProbe.pending.shift()()")
      panel.controller.scheduleUpdate()
      try await panel.quiet()
      try await panel.expectJS("return powerProbe.received.length", equals: 2)
    }
  }

  func testOldPageCompletionCannotReleaseNewPagesInFlightPush() async throws {
    try await withPanel { panel in
      _ = try await panel.js("powerProbe.hold = true")
      panel.show()
      try await panel.waitJS("powerProbe.pending.length === 1")
      let oldPage = panel.web
      panel.hide()
      // Keep the old page's pending Promise alive while simulating the replacement page.
      panel.web = panel.controller.makeWebView()
      panel.controller.webViewWebContentProcessDidTerminate(panel.web)
      try await panel.waitUntil { panel.controller.isReady }
      try await panel.installRecorder()
      _ = try await panel.js("powerProbe.hold = true")
      panel.show()
      try await panel.waitJS("powerProbe.pending.length === 1")
      _ = try await oldPage.callAsyncJavaScript(
        "powerProbe.pending.shift()()", arguments: [:], in: nil, contentWorld: .page)
      panel.workshop.searchText = "New page latest"
      try await panel.quiet()
      try await panel.expectJS("return powerProbe.received.length", equals: 1)
      _ = try await panel.js("powerProbe.pending.shift()()")
      try await panel.waitJS("powerProbe.received.length === 2")
      try await panel.expectJS(
        "return powerProbe.received.at(-1).workshop.text", equals: "New page latest")
      _ = try await panel.js("powerProbe.pending.shift()()")
      XCTAssertNil(oldPage.window)
    }
  }

  func testFailedPagePushWaitsForAnExternalChangeBeforeRetrying() async throws {
    try await withPanel { panel in
      _ = try await panel.js("""
        const receive = wallpaperUI.receive;
        window.failedPushes = 0;
        wallpaperUI.receive = state => { failedPushes++; throw new Error('injected'); };
        window.restoreReceive = () => { wallpaperUI.receive = receive; };
        """)
      panel.show()
      try await panel.waitJS("failedPushes === 1")
      try await panel.quiet()
      try await panel.expectJS("return failedPushes", equals: 1)
      _ = try await panel.js("restoreReceive()")
      panel.workshop.searchText = "Retry latest"
      try await panel.waitJS("powerProbe.received.at(-1)?.workshop.text === 'Retry latest'")
    }
  }

  func testSupplementalOptionsAreOnlyFetchedForVisibleSettings() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.show()
      try await panel.waitJS("powerProbe.received.length > 0")
      XCTAssertTrue(panel.bridge.optionRequests.isEmpty)
      panel.navigation.selection = .settings
      try await panel.waitJS("powerProbe.received.at(-1)?.displays[1]?.fps === 48")
      XCTAssertEqual(panel.bridge.optionRequests, ["second"])
      let values = try await panel.js("""
        return ['primary','secondary'].map(id => [
          Number(document.querySelector(`[data-display="${id}"][data-display-setting="fps"]`).value),
          Number(document.querySelector(`[data-display="${id}"][data-display-setting="volume"]`).value)
        ]);
        """) as? [[Double]]
      XCTAssertEqual(values, [[24, 0.2], [48, 0.7]])
    }
  }

  func testDisplayTitlesUseTheSystemNameEverywhereTheRendererLabelAppears() async throws {
    let names = DisplayTitleResolver(names: { ["primary": "Built-in Retina Display"] })
    try await withPanel(displayTitles: names) { panel in
      panel.configureDisplays()
      panel.store.settingsSnapshot.displays[1].mirrorTargets = ["primary"]
      panel.store.settingsSnapshot.displays[0].title = "Vendor 1552 - Model 41055 (primary - Primary)"
      panel.store.snapshotRevision &+= 1
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.displays[1]?.fps === 48")
      let titles = try await panel.js("""
        const state = powerProbe.received.at(-1);
        return [state.displays[0].title, state.displays[1].title,
          state.displays[1].mirrorTargets[0].title, state.options.displays[0].title];
        """) as? [String]
      XCTAssertEqual(
        titles,
        [
          "Built-in Retina Display (primary - Primary)", "secondary",
          "Built-in Retina Display (primary - Primary)", "Built-in Retina Display",
        ])
    }
  }

  func testOptionsFailureFallsBackWithoutLoopingAndRetriesOnReentry() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.bridge.failedOptionIDs = ["second"]
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitUntil { panel.bridge.optionRequests.count == 1 }
      try await panel.quiet()
      XCTAssertEqual(panel.bridge.optionRequests, ["second"])
      try await panel.expectJS("return powerProbe.received.at(-1).displays[1].fps", equals: 30)
      panel.navigation.selection = .wallpaper
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'installed'")
      panel.bridge.failedOptionIDs = []
      panel.navigation.selection = .settings
      try await panel.waitJS("powerProbe.received.at(-1)?.displays[1]?.fps === 48")
      XCTAssertEqual(panel.bridge.optionRequests, ["second", "second"])
    }
  }

  func testCancelledOptionsCannotOverwriteNewRevisionOrRemovedDisplay() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      let oldOptions = try XCTUnwrap(panel.bridge.options["second"])
      panel.bridge.holdOptions = true
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitUntil { panel.bridge.pendingOptions.count == 1 }
      panel.hide()
      panel.navigation.selection = .wallpaper
      try await panel.quiet()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitUntil { panel.bridge.pendingOptions.count == 2 }
      panel.bridge.finishOption(oldOptions)
      try await panel.quiet()
      XCTAssertEqual(panel.bridge.optionRequests, ["second", "second"])
      try await panel.expectJS("return powerProbe.received.at(-1).displays[1].fps", equals: 30)

      panel.store.monitorInformationSnapshot.rows[1].wallpaperId = "replacement"
      panel.store.snapshotRevision &+= 1
      try await panel.waitUntil { panel.bridge.optionRequests.last == "replacement" }
      panel.bridge.finishOption(oldOptions)
      try await panel.quiet()
      try await panel.expectJS(
        "return powerProbe.received.at(-1).displays[1].wallpaperID", equals: "replacement")
      try await panel.expectJS("return powerProbe.received.at(-1).displays[1].fps", equals: 30)
      panel.store.monitorInformationSnapshot.rows.removeLast()
      panel.store.settingsSnapshot.displays.removeLast()
      panel.store.snapshotRevision &+= 1
      try await panel.waitJS("powerProbe.received.at(-1)?.displays.length === 1")
      panel.bridge.finishOption(oldOptions)
      try await panel.quiet()
      try await panel.expectJS("return powerProbe.received.at(-1).displays.length", equals: 1)
      XCTAssertEqual(panel.bridge.optionRequests, ["second", "second", "replacement"])
    }
  }
}
