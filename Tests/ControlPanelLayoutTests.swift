import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import MacWallpaperEngine

@MainActor
final class ControlPanelLayoutTests: XCTestCase {
  func testControlPanelAcceptsSmallWindowProposalsWithLongDisplayTitle() async throws {
    let fixture = makeStore()
    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: fixture.store.monitorInformationSnapshot,
      settings: fixture.store.settingsSnapshot
    )
    try await fixture.store.refreshAllAsync()
    let session = FileManager.default.temporaryDirectory.appendingPathComponent(
      "layout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: session) }
    let defaultsName = "ControlPanelLayoutTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: session),
      supportDirectory: session, defaults: defaults)
    let updater = AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient())

    for language in ["en", "zh-Hans"] {
      let controller = NSHostingController(
        rootView:
          ControlPanelView(
            store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
            updater: updater
          )
          .environment(\.locale, Locale(identifier: language))
          .defaultAppStorage(defaults)
      )
      controller.sizingOptions = []
      for size in [
        NSSize(width: 760, height: 560), NSSize(width: 960, height: 640),
        NSSize(width: 1240, height: 800),
      ] {
        controller.view.setFrameSize(size)
        controller.view.layoutSubtreeIfNeeded()
        let measured = controller.sizeThatFits(in: size)
        XCTAssertEqual(
          measured.width, size.width, accuracy: 1,
          "\(language): the root must accept the window width")
        XCTAssertLessThanOrEqual(
          measured.height, size.height + 1, "\(language): content must not force a taller window")
        XCTAssertNil(controller.view.window, "Layout measurement must stay offscreen")
      }
    }
  }

  func testBundledWebKitInterfaceLoadsAndRoutesSettingsWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-panel-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let navigation = ControlPanelNavigation()
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(
      controller.isReady,
      "Bundled ES modules must load under the custom scheme and reach the native reply bridge")
    guard controller.isReady else { return }
    let result =
      try await web.callAsyncJavaScript(
        """
        const state = await window.webkit.messageHandlers.native.postMessage({action:'navigate',page:'settings'});
        window.wallpaperUI.receive(state);
        return {page:state.page, visible:!document.getElementById('settings-content').hidden};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["page"] as? String, "settings")
    XCTAssertEqual(result?["visible"] as? Bool, true)
    XCTAssertEqual(navigation.selection, .settings)
    let denied =
      try await web.callAsyncJavaScript(
        """
        try { await window.webkit.messageHandlers.native.postMessage({action:'openExternal',url:'file:///etc/passwd'}); return false; }
        catch { return true; }
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(denied, true)
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  func testAppearanceControlsPersistAndFollowNativeAppearanceWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "theme-ui-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let theme = AppThemeStore(defaults: defaults)
    try theme.set("mode", value: "light")
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop, theme: theme)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 760, height: 560))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }

    let interactions =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Theme control did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const root = document.documentElement;
        const initialBackground = getComputedStyle(root).backgroundColor;
        document.querySelector('.tabs [data-page="settings"]').click();
        await waitFor(() => !document.getElementById('settings-content').hidden);
        document.querySelector('[data-section="appearance"]').click();
        const change = async (key, value) => {
          const input = document.querySelector(`[data-theme-setting="${key}"]`);
          await waitFor(() => !input.disabled);
          input.value = value;
          input.dispatchEvent(new Event('input', {bubbles:true}));
          input.dispatchEvent(new Event('change', {bubbles:true}));
          await waitFor(() => !input.disabled);
        };
        await change('mode', 'dark');
        await waitFor(() => root.dataset.theme === 'dark');
        const darkBackground = getComputedStyle(root).backgroundColor;
        await change('accent', '#b43271');
        await change('tone', 'warm');
        await waitFor(() => root.dataset.tone === 'warm');
        const saved = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        document.querySelector('[data-action="resetTheme"]').click();
        await waitFor(() => root.dataset.themeMode === 'system' && root.dataset.tone === 'neutral');
        const reset = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        return {initialBackground, darkBackground, saved:saved.theme, reset:reset.theme};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(interactions?["initialBackground"] as? String, "rgb(255, 255, 255)")
    XCTAssertNotEqual(interactions?["darkBackground"] as? String, "rgb(255, 255, 255)")
    let saved = interactions?["saved"] as? [String: Any]
    XCTAssertEqual(saved?["mode"] as? String, "dark")
    XCTAssertEqual(saved?["accent"] as? String, "#b43271")
    XCTAssertEqual(saved?["tone"] as? String, "warm")
    let reset = interactions?["reset"] as? [String: Any]
    XCTAssertEqual(reset?["mode"] as? String, "system")
    XCTAssertEqual(reset?["tone"] as? String, "neutral")
    XCTAssertEqual(AppThemeStore(defaults: defaults).preferences, theme.preferences)

    // Override only this detached view to simulate live macOS appearance changes.
    // Never change NSApp appearance or the user's global system preference.
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
      web.appearance = NSAppearance(named: appearance)
      let expected = appearance == .darkAqua ? "dark" : "light"
      let resolved =
        try await web.callAsyncJavaScript(
          """
          const deadline = Date.now() + 5000;
          while (document.documentElement.dataset.theme !== expected) {
            if (Date.now() > deadline) throw new Error('System appearance was not followed');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
          return getComputedStyle(document.documentElement).colorScheme;
          """, arguments: ["expected": expected], in: nil, contentWorld: .page) as? String
      XCTAssertEqual(resolved, expected)
    }
    try theme.set("mode", value: "light")
    web.appearance = NSAppearance(named: .darkAqua)
    let override =
      try await web.callAsyncJavaScript(
        """
        const deadline = Date.now() + 5000;
        while (document.documentElement.dataset.themeMode !== 'light'
               || !matchMedia('(prefers-color-scheme: dark)').matches) {
          if (Date.now() > deadline) throw new Error('Appearance override was not applied');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        return document.documentElement.dataset.theme;
        """, arguments: [:], in: nil, contentWorld: .page) as? String
    XCTAssertEqual(override, "light", "Explicit Light must win over a dark native appearance")
    try theme.set("accent", value: "#b43271")
    try theme.set("tone", value: "cool")
    controller.webViewWebContentProcessDidTerminate(web)
    let recoveryDeadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < recoveryDeadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    let recovered =
      try await web.callAsyncJavaScript(
        """
        return {mode:document.documentElement.dataset.theme,
                tone:document.documentElement.dataset.tone,
                accent:getComputedStyle(document.documentElement).getPropertyValue('--accent-base').trim()};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: String]
    XCTAssertEqual(recovered?["mode"], "light")
    XCTAssertEqual(recovered?["tone"], "cool")
    XCTAssertEqual(recovered?["accent"], "#b43271")
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Previous/Next page controls also carry a numeric page, which must not be
  /// treated as a Discover/Installed/Settings navigation value.
  func testWorkshopPaginationDoesNotNavigateWithThePageNumber() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-page-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let navigation = ControlPanelNavigation()
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Workshop pagination did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive(Object.assign({}, snapshot, {
          page: 'discover',
          workshop: Object.assign({}, snapshot.workshop, {
            page: 1, totalPages: 4, loaded: true, loading: false, items: [], error: null
          })
        }));
        const next = document.querySelector('[data-action="workshopPage"][title="Next page"]');
        if (!next) throw new Error('Next page control missing');
        if (next.hasAttribute('data-page')) throw new Error('Pagination must not reuse the main tab data-page attribute');
        if (next.closest('.tabs [data-page]')) throw new Error('Pagination was treated as a main tab');
        next.click();
        await waitFor(() => {
          const banner = document.getElementById('error-banner');
          return (banner && !banner.hidden) || !document.querySelector('[title="Next page"]');
        });
        const banner = document.getElementById('error-banner');
        return {error: banner.hidden ? '' : banner.textContent, workshopPage: next.dataset.workshopPage};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(
      result?["error"] as? String, "",
      "Clicking Next page must request that Workshop page, not navigate with its page number")
    XCTAssertEqual(result?["workshopPage"] as? String, "2")
    XCTAssertNil(controller.actionError)
    XCTAssertEqual(navigation.selection, .wallpaper)
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  func testDownloadSetupCanBeDismissedAndResumedWithoutLosingIntent() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "download-ui-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defaults.set(
      root.appendingPathComponent("missing-steamcmd").path, forKey: "MacWallpaperEngineSteamCMDPath"
    )
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 760, height: 560))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Download interface did not reach expected state');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'requestDownload',id:null});
        window.wallpaperUI.receive(snapshot);
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]'));
        document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]').click();
        const dialog = document.getElementById('download-dialog');
        await waitFor(() => dialog.open);
        const firstStage = dialog.dataset.stage;
        dialog.querySelector('[data-action="dismissDialog"]').click();
        await waitFor(() => !dialog.open);
        const refreshed = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        window.wallpaperUI.receive(refreshed);
        const stayedClosed = !dialog.open;
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]'));
        document.querySelector('[data-action="continueSetup"][data-id="scene-assets"]').click();
        await waitFor(() => dialog.open);
        const resumed = dialog.dataset.stage === firstStage;
        dialog.querySelector('[data-action="dismissDialog"]').click();
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => document.querySelector('[data-action="removeDownloadRequest"][data-id="scene-assets"]'));
        document.querySelector('[data-action="removeDownloadRequest"][data-id="scene-assets"]').click();
        await waitFor(() => !document.querySelector('[data-action="removeDownloadRequest"][data-id="scene-assets"]'));
        const final = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        return {firstStage,stayedClosed,resumed,retained:refreshed.downloadRequests.some(x=>x.id==='scene-assets'),removed:!final.downloadRequests.some(x=>x.id==='scene-assets')};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["firstStage"] as? String, "setup")
    XCTAssertEqual(result?["stayedClosed"] as? Bool, true)
    XCTAssertEqual(result?["retained"] as? Bool, true)
    XCTAssertEqual(result?["resumed"] as? Bool, true)
    XCTAssertEqual(result?["removed"] as? Bool, true)
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Dismissing an error must actually dismiss it: library and download failures
  /// live in persistent native state, so a snapshot that keeps reporting them
  /// makes the close button a no-op.
  func testDismissingAnErrorSuppressesLibraryAndDownloadFailuresUntilTheyRecur() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-errors-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop)

    try? await fixture.store.refreshAllAsync()
    workshop.downloader.installAssets(
      username: "anonymous", executable: root.appendingPathComponent("missing"),
      destination: root.appendingPathComponent("assets"), rememberSession: false, onInstalled: {})
    let downloadFailure = try XCTUnwrap(workshop.downloader.errorMessage)
    XCTAssertNotNil(controller.snapshot()["error"] as? String, "The library failure must surface")
    XCTAssertEqual(controller.snapshot()["downloadError"] as? String, downloadFailure)

    try await controller.perform("dismissError", body: ["action": "dismissError"])
    controller.reconcileDismissedErrors()
    XCTAssertNil(
      controller.snapshot()["error"] as? String, "A dismissed library failure must stay dismissed")
    XCTAssertNil(controller.snapshot()["downloadError"] as? String)

    fixture.bridge.snapshot = BridgeSnapshotBundle(
      app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
      wallpaperOptions: nil, monitorInformation: fixture.store.monitorInformationSnapshot,
      settings: fixture.store.settingsSnapshot)
    try await fixture.store.refreshAllAsync()
    controller.reconcileDismissedErrors()
    fixture.bridge.snapshot = nil
    try? await fixture.store.refreshAllAsync()
    controller.reconcileDismissedErrors()
    XCTAssertNotNil(
      controller.snapshot()["error"] as? String,
      "A failure that happens again after recovery must surface instead of staying hidden")
    await workshop.steamCMDSetup.shutdown()
  }

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

  private func withPanel(_ body: (PanelFixture) async throws -> Void) async throws {
    let fixture = makeStore()
    let panel = try PanelFixture(store: fixture.store, bridge: fixture.bridge)
    do {
      try await panel.start()
      try await body(panel)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testDownloadTelemetryShowsIndeterminateProgressAndNetworkUnitsWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-telemetry-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    let base =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertNotNil(base)
    guard let base else { return }
    controller.stop()

    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Download telemetry did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const job = {
          id: 'telemetry-fixture', wallpaperID: 'telemetry-fixture', title: 'Telemetry fixture',
          status: 'Downloading Workshop files…', preview: null, account: 'fixture',
          progress: null, pending: true, queued: false,
          bytesReceived: null, bytesExpected: null, bytesPerSecond: 600000,
          authenticating: false, cancelled: false, error: null, prompt: null,
          securePrompt: false, challenge: null, warning: null
        };
        const push = extra => window.wallpaperUI.receive(Object.assign({}, base, {
          downloads: [Object.assign({}, job, extra)], downloadRequests: [] }));
        const activity = document.getElementById('activity-bar');
        const queue = document.getElementById('queue-popover');
        push({});
        document.querySelector('#top-actions [data-action="openDownloads"]').click();
        await waitFor(() => !queue.hidden);
        const indeterminate = {
          activityProgress: !!activity.querySelector('progress') && !activity.querySelector('progress').hasAttribute('value'),
          queueProgress: !!queue.querySelector('progress') && !queue.querySelector('progress').hasAttribute('value'),
          rate: activity.textContent.includes('Network speed: 600 KB/s') && queue.textContent.includes('Network speed: 600 KB/s'),
          noPercentOrBytes: !queue.textContent.includes('%') && !queue.textContent.includes(' of ')
        };
        push({bytesPerSecond: 0});
        const zeroRate = activity.textContent.includes('Network speed: 0 B/s');
        push({bytesPerSecond: null});
        const noRate = !activity.textContent.includes('Network speed:') && !queue.textContent.includes('Network speed:');
        push({status: 'Validating and adding to your library…', bytesPerSecond: null});
        const validating = activity.textContent.includes('Validating') && !activity.textContent.includes('Network speed:');
        push({id: 'scene-assets', wallpaperID: null, status: 'Downloading Wallpaper Engine files…', progress: 0.25, bytesReceived: 250, bytesExpected: 1000, bytesPerSecond: null});
        await waitFor(() => !!activity.querySelector('progress') && activity.querySelector('progress').value === 0.25);
        const byteProgress = activity.querySelector('progress').value === 0.25 && activity.textContent.includes('25%');
        return {indeterminate, zeroRate, noRate, validating, byteProgress};
        """, arguments: ["base": base], in: nil, contentWorld: .page) as? [String: Any]
    let indeterminate = result?["indeterminate"] as? [String: Any]
    XCTAssertEqual(
      indeterminate?["activityProgress"] as? Bool, true,
      "Activity bar must render a valueless progress bar while pending")
    XCTAssertEqual(
      indeterminate?["queueProgress"] as? Bool, true,
      "Queue row must render a valueless progress bar while pending")
    XCTAssertEqual(
      indeterminate?["rate"] as? Bool, true, "Both surfaces must show the measured network speed")
    XCTAssertEqual(
      indeterminate?["noPercentOrBytes"] as? Bool, true,
      "Workshop downloads must not report percentage or byte totals")
    XCTAssertEqual(result?["zeroRate"] as? Bool, true, "A measured idle rate must render as 0 B/s")
    XCTAssertEqual(
      result?["noRate"] as? Bool, true, "An unavailable rate must be omitted, not shown as zero")
    XCTAssertEqual(
      result?["validating"] as? Bool, true,
      "The validating phase must show its status without a network speed")
    XCTAssertEqual(
      result?["byteProgress"] as? Bool, true,
      "Explicit app-update bytes may still drive determinate progress")
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  private func makeStore() -> (store: BridgeStore, bridge: LayoutSnapshotBridge) {
    let bridge = LayoutSnapshotBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    store.settingsSnapshot.displays = [
      BridgeDisplaySettingsRow(
        displayId: "primary",
        title: String(
          repeating: "Studio Display — 外接显示器 with a very long display name · ", count: 8),
        enabled: true, mode: .standalone, mirrorTargets: [], selectedMirrorTarget: nil,
        scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60, muted: false, volume: 1
      )
    ]
    return (store, bridge)
  }
}

private final class LayoutSnapshotBridge: WallpaperBridge {
  var snapshot: BridgeSnapshotBundle?
  @MainActor var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
  @MainActor var optionRequests: [String] = []
  @MainActor var failedOptionIDs = Set<String>()
  @MainActor var holdOptions = false
  @MainActor var pendingOptions: [CheckedContinuation<BridgeWallpaperOptionsSnapshot, Error>] = []

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot {
    try await option(wallpaperId)
  }

  @MainActor private func option(_ id: String) async throws -> BridgeWallpaperOptionsSnapshot {
    optionRequests.append(id)
    if holdOptions {
      return try await withCheckedThrowingContinuation { pendingOptions.append($0) }
    }
    guard !failedOptionIDs.contains(id), let value = options[id] else { throw CancellationError() }
    return value
  }

  @MainActor func finishOption(_ value: BridgeWallpaperOptionsSnapshot) {
    pendingOptions.removeFirst().resume(returning: value)
  }

  override func allSnapshots() async throws -> BridgeSnapshotBundle {
    guard let snapshot else { throw CancellationError() }
    return snapshot
  }
}

private struct UnavailableRuntime: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    throw WorkshopFailure(message: "fixture")
  }
  func validateBootstrap(at root: URL) async throws { throw WorkshopFailure(message: "fixture") }
  func prepare(executable: URL, staging: URL) async throws -> URL {
    throw WorkshopFailure(message: "fixture")
  }
  func validate(at root: URL) async throws { throw WorkshopFailure(message: "fixture") }
}

@MainActor
private final class PanelFixture {
  final class Visibility { var visible = false }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-power-\(UUID().uuidString)")
  let store: BridgeStore
  let bridge: LayoutSnapshotBridge
  let navigation = ControlPanelNavigation()
  let visibility = Visibility()
  let defaults: UserDefaults
  let previousHome: String?
  let workshop: WorkshopStore
  let controller: WebPanelController
  var web: WKWebView
  let executable: URL

  init(store: BridgeStore, bridge: LayoutSnapshotBridge) throws {
    self.store = store
    self.bridge = bridge
    defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defaults.set(root.appendingPathComponent("missing").path, forKey: "MacWallpaperEngineSteamCMDPath")
    previousHome = ProcessInfo.processInfo.environment["MAC_WALLPAPER_ENGINE_HOME"]
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    executable = root.appendingPathComponent("steamcmd")
    try Data("""
      #!/bin/sh
      printf 'Password:\\n'
      while [ ! -e "\(root.path)/advance" ]; do /bin/sleep 0.02; done
      printf 'Downloading item 222\\n'
      IFS= read -r hold

      """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    setenv("MAC_WALLPAPER_ENGINE_HOME", root.path, 1)
    let downloader = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("session"), runtimeProvider: PanelRuntime())
    workshop = WorkshopStore(
      downloader: downloader, supportDirectory: root, defaults: defaults,
      runtimeProvider: PanelRuntime(), sceneAssetsAvailable: { false })
    let visibility = self.visibility
    controller = WebPanelController(
      store: store, navigation: navigation, workshop: workshop,
      isPresentationVisible: { visibility.visible })
    web = controller.makeWebView()
    web.setFrameSize(NSSize(width: 960, height: 640))
  }

  func start() async throws {
    try await waitUntil(timeout: 15) { self.controller.isReady && !self.workshop.steamCMDSetup.isBusy }
    try await quiet()
    try await installRecorder()
  }

  func installRecorder() async throws {
    _ = try await js("""
      window.powerProbe = {received:[], active:0, maxActive:0, pending:[], hold:false};
      const receive = window.wallpaperUI.receive;
      window.wallpaperUI.receive = state => {
        const probe = window.powerProbe;
        probe.active++;
        probe.maxActive = Math.max(probe.maxActive, probe.active);
        probe.received.push(state);
        const finish = () => { receive(state); probe.active--; };
        if (probe.hold) return new Promise(resolve => probe.pending.push(() => { finish(); resolve(null); }));
        finish();
        return null;
      };
      """)
  }

  func show() { visibility.visible = true; controller.scheduleUpdate() }
  func hide() { visibility.visible = false; controller.scheduleUpdate() }

  func js(_ script: String) async throws -> Any? {
    XCTAssertNil(web.window, "Every panel behavior check must remain offscreen")
    return try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
  }

  func expectJS<T: Equatable>(
    _ script: String, equals expected: T, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let actual = try await js(script) as? T
    XCTAssertEqual(actual, expected, file: file, line: line)
  }

  func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { throw WorkshopFailure(message: "Panel fixture timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func waitJS(_ condition: String) async throws {
    let deadline = Date().addingTimeInterval(2)
    while try await js("return Boolean(\(condition))") as? Bool != true {
      guard Date() < deadline else { throw WorkshopFailure(message: "Page did not satisfy: \(condition)") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func quiet() async throws { try await Task.sleep(for: .milliseconds(120)) }

  func configureDisplays() {
    store.settingsSnapshot.displays = ["primary", "secondary"].map { id in
      BridgeDisplaySettingsRow(
        displayId: id, title: id, enabled: true, mode: .standalone, mirrorTargets: [],
        selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
        targetFps: 30, maxFps: 60, muted: false, volume: 1)
    }
    store.monitorInformationSnapshot.rows = [
      ("primary", "first"), ("secondary", "second"),
    ].map { display, wallpaper in
      BridgeMonitorInfoRow(
        displayId: display, title: display, wallpaperId: wallpaper, wallpaperTitle: wallpaper,
        mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill",
        targetFps: "30", audioResponse: false)
    }
    for (display, id, fps, volume) in [
      ("primary", "first", UInt32(24), Float(0.2)),
      ("secondary", "second", UInt32(48), Float(0.7)),
    ] {
      bridge.options[id] = BridgeWallpaperOptionsSnapshot(
        wallpaperId: id, title: id, kind: .projectScene, supported: true, dirty: false,
        properties: [], displayConfigurations: [
          BridgeDisplayConfigRow(
            displayId: display, title: display, enabled: true, scalingMode: .fill,
            scalingFactor: 1, targetFps: fps, maxFps: 60, muted: false, volume: volume,
            dirty: false, canRestoreDefaults: false)
        ], audioResponseEnabled: false, muted: false, volume: volume)
    }
    store.wallpaperOptionsSnapshot = bridge.options["first"]
    store.snapshotRevision &+= 1
  }

  func shutdown() async {
    controller.stop()
    _ = try? await js("if (window.powerProbe) while (powerProbe.pending.length) powerProbe.pending.shift()()")
    for pending in bridge.pendingOptions { pending.resume(throwing: CancellationError()) }
    bridge.pendingOptions.removeAll()
    await workshop.downloader.shutdown()
    await workshop.steamCMDSetup.shutdown()
    defaults.removePersistentDomain(forName: root.lastPathComponent)
    if let previousHome { setenv("MAC_WALLPAPER_ENGINE_HOME", previousHome, 1) }
    else { unsetenv("MAC_WALLPAPER_ENGINE_HOME") }
    try? FileManager.default.removeItem(at: root)
  }
}

private struct PanelRuntime: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Missing local fixture")
    }
    return SteamCMDRuntime(rootURL: executable.deletingLastPathComponent(), executableURL: executable)
  }
  func validateBootstrap(at root: URL) async throws {}
  func prepare(executable: URL, staging: URL) async throws -> URL { executable }
  func validate(at root: URL) async throws {}
}
