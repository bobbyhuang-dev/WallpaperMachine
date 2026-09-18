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

  func testUpdateSnapshotExposesCheckDownloadAndReadyActions() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "update-snap-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let client = PanelUpdateClient()
    client.release = PanelUpdateClient.release(version: "1.1.0")
    let installer = PanelUpdateInstaller()
    let updater = AppUpdateStore(
      currentVersion: "1.0.0", client: client, installer: installer,
      workspace: AppUpdateWorkspace(
        archiveURL: { _, _ in root.appendingPathComponent("update.zip") },
        reveal: { _ in }, open: { _ in }),
      scheduleInstall: { _ in }, terminate: {})
    let navigation = ControlPanelNavigation()
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop, updater: updater)
    let idle = try XCTUnwrap(controller.snapshot()["update"] as? [String: Any])
    XCTAssertEqual(idle["status"] as? String, "idle")
    XCTAssertEqual(idle["action"] as? String, "checkForUpdates")
    XCTAssertEqual(idle["showsAction"] as? Bool, true)

    navigation.revealSettingsSection(.about)
    XCTAssertEqual(controller.snapshot()["settingsSection"] as? String, "about")
    XCTAssertEqual(controller.snapshot()["settingsSectionToken"] as? Int, 1)

    await updater.checkForUpdates()
    let available = try XCTUnwrap(controller.snapshot()["update"] as? [String: Any])
    XCTAssertEqual(available["status"] as? String, "available")
    XCTAssertEqual(available["action"] as? String, "downloadUpdate")

    await updater.downloadUpdate()
    let ready = try XCTUnwrap(controller.snapshot()["update"] as? [String: Any])
    XCTAssertEqual(ready["status"] as? String, "ready")
    XCTAssertEqual(ready["action"] as? String, "installUpdate")
    XCTAssertEqual(ready["showsReveal"] as? Bool, true)

    try await controller.perform("installUpdate", body: ["action": "installUpdate"])
    XCTAssertEqual(
      updater.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"),
      "Install confirmation requires a window, so an offscreen panel must not replace the app")
    XCTAssertEqual(installer.installCalls, 0)
    await workshop.steamCMDSetup.shutdown()
  }

  func testAboutUpdateControlsCheckDownloadAndBlockInstallWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "update-ui-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let client = PanelUpdateClient()
    client.release = PanelUpdateClient.release(version: "1.1.0")
    let installer = PanelUpdateInstaller()
    let updater = AppUpdateStore(
      currentVersion: "1.0.0", client: client, installer: installer,
      workspace: AppUpdateWorkspace(
        archiveURL: { _, _ in root.appendingPathComponent("update.zip") },
        reveal: { _ in }, open: { _ in }),
      scheduleInstall: { _ in }, terminate: {})
    let navigation = ControlPanelNavigation()
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop, updater: updater)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }

    let byTab =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('About updates did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        window.wallpaperUI.receive(await window.webkit.messageHandlers.native.postMessage({action:'ready'}));
        document.querySelector('.tabs [data-page="settings"]').click();
        await waitFor(() => !document.getElementById('settings-content').hidden);
        document.querySelector('[data-section="about"]').click();
        await waitFor(() => !document.getElementById('settings-about').hidden);
        const check = document.querySelector('[data-key="about-updates"] [data-action="checkForUpdates"]');
        if (!check) throw new Error('Check for Updates missing from Settings → About');
        check.click();
        await waitFor(() => document.querySelector('[data-key="about-updates"] [data-action="downloadUpdate"]'));
        document.querySelector('[data-key="about-updates"] [data-action="downloadUpdate"]').click();
        await waitFor(() => document.querySelector('[data-key="about-updates"] [data-action="installUpdate"]'));
        document.querySelector('[data-key="about-updates"] [data-action="installUpdate"]').click();
        const ready = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        document.querySelector('[data-section="general"]').click();
        await waitFor(() => !document.getElementById('settings-general').hidden);
        return {status: ready.update.status, action: ready.update.action, fetchCalls: true};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(byTab?["status"] as? String, "ready")
    XCTAssertEqual(byTab?["action"] as? String, "installUpdate")
    XCTAssertEqual(client.fetchCalls, 1)
    XCTAssertEqual(client.downloadCalls, 1)
    XCTAssertEqual(installer.installCalls, 0)
    XCTAssertEqual(
      updater.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))

    navigation.revealSettingsSection(.about)
    let restored =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('Native About reveal did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        window.wallpaperUI.receive(await window.webkit.messageHandlers.native.postMessage({action:'ready'}));
        await waitFor(() => !document.getElementById('settings-about').hidden
          && !!document.querySelector('[data-key="about-updates"] [data-action="installUpdate"]'));
        return !document.getElementById('settings-about').hidden;
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(restored, true)
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

  /// Discover's filter sidebar collapses to an arrow rail to give the grid its column
  /// back, and the inspector grows with wide windows or follows a dragged edge. Both
  /// choices are stored natively because the page's website data store is not persistent.
  func testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-filters-\(UUID().uuidString)")
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
      store: fixture.store, navigation: navigation, workshop: workshop, defaults: defaults)
    XCTAssertFalse(controller.workshopFiltersCollapsed)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(controller.isReady)
    guard controller.isReady else { return }
    let script = """
      const waitFor = async predicate => {
        const deadline = Date.now() + 5000;
        while (!predicate()) {
          if (Date.now() > deadline) throw new Error('Filter sidebar did not settle');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
      };
      const native = { postMessage: async body => {
        try { return await window.webkit.messageHandlers.native.postMessage(body); }
        catch (error) { throw new Error(`${body.action} failed: ${error?.message || error}`); }
      } };
      const showDiscover = snapshot => window.wallpaperUI.receive(Object.assign({}, snapshot, {
        page: 'discover',
        workshop: Object.assign({}, snapshot.workshop, {
          page: 1, totalPages: 1, loaded: true, loading: false, items: [], error: null
        })
      }));
      const columns = () => getComputedStyle(document.getElementById('library-page')).gridTemplateColumns.split(' ').map(v => Math.round(parseFloat(v)));
      const measure = () => {
        const page = document.getElementById('library-page');
        const toggle = document.querySelector('[data-action="toggleWorkshopFilters"]');
        return {
          hidden: document.getElementById('workshop-filters').hidden,
          collapsed: page.classList.contains('filters-collapsed'),
          expanded: toggle ? toggle.getAttribute('aria-expanded') : null,
          columns: columns()
        };
      };
      showDiscover(await native.postMessage({action:'ready'}));
      const before = measure();
      document.querySelector('[data-action="toggleWorkshopFilters"]').click();
      // The native reply re-renders on its own page (Installed), which hides the sidebar
      // without re-rendering it; either outcome means the round trip completed.
      await waitFor(() => document.getElementById('workshop-filters').hidden
        || document.querySelector('[data-action="toggleWorkshopFilters"]')?.getAttribute('aria-expanded') === 'false');
      const reply = await native.postMessage({action:'ready'});
      showDiscover(reply);
      const after = measure();
      window.wallpaperUI.receive(Object.assign({}, reply, {page: 'installed'}));
      const installed = measure();
      showDiscover(reply);
      // Drag the inspector edge 60px to the left, then double-click it back to the fluid width.
      const resizer = document.getElementById('inspector-resizer');
      const pointer = (type, clientX) => resizer.dispatchEvent(new PointerEvent(type, {bubbles: true, pointerId: 7, button: 0, clientX, clientY: 300}));
      const edge = resizer.getBoundingClientRect().left + 4;
      const dragStart = columns().at(-1);
      pointer('pointerdown', edge);
      pointer('pointermove', edge - 60);
      const duringDrag = columns().at(-1);
      pointer('pointerup', edge - 60);
      const dragged = await native.postMessage({action:'ready'});
      showDiscover(dragged);
      const afterDrag = columns().at(-1);
      resizer.dispatchEvent(new MouseEvent('dblclick', {bubbles: true}));
      const reset = await native.postMessage({action:'ready'});
      showDiscover(reset);
      return {before, after, installed, flag: reply.workshopFiltersCollapsed,
              dragStart, duringDrag, afterDrag, draggedWidth: dragged.inspectorWidth,
              resetWidth: reset.inspectorWidth, afterReset: columns().at(-1)};
      """
    let result =
      try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
      as? [String: Any]
    let before = result?["before"] as? [String: Any]
    XCTAssertEqual(before?["hidden"] as? Bool, false)
    XCTAssertEqual(before?["expanded"] as? String, "true")
    XCTAssertEqual((before?["columns"] as? [Int])?.count, 3, "Discover starts with the sidebar column")
    XCTAssertEqual((before?["columns"] as? [Int])?.last, 260, "Windows under 1040px use the compact 260px inspector")
    let after = result?["after"] as? [String: Any]
    XCTAssertEqual(after?["hidden"] as? Bool, false, "The collapsed sidebar stays as an arrow rail")
    XCTAssertEqual(after?["collapsed"] as? Bool, true)
    XCTAssertEqual(after?["expanded"] as? String, "false")
    XCTAssertEqual((after?["columns"] as? [Int])?.count, 3)
    XCTAssertEqual((after?["columns"] as? [Int])?.first, 30, "Collapsing shrinks the sidebar to its rail")
    XCTAssertEqual(result?["dragStart"] as? Int, 260)
    XCTAssertEqual(result?["duringDrag"] as? Int, 320, "The inspector follows the pointer while dragging")
    XCTAssertEqual(result?["afterDrag"] as? Int, 320, "The dragged width survives a native snapshot")
    XCTAssertEqual(result?["draggedWidth"] as? Double, 320)
    XCTAssertTrue(result?["resetWidth"] is NSNull, "Double-click clears the stored width")
    XCTAssertEqual(result?["afterReset"] as? Int, 260, "Reset returns to the fluid stylesheet width")
    let installed = result?["installed"] as? [String: Any]
    XCTAssertEqual(installed?["collapsed"] as? Bool, false, "Installed never carries the Discover-only class")
    XCTAssertEqual(result?["flag"] as? Bool, true)
    XCTAssertNil(controller.actionError)
    XCTAssertTrue(controller.workshopFiltersCollapsed)
    XCTAssertTrue(defaults.bool(forKey: WebPanelController.workshopFiltersCollapsedKey))
    XCTAssertNil(defaults.object(forKey: WebPanelController.inspectorWidthKey))
    XCTAssertNil(controller.inspectorWidth)
    defaults.set(300.0, forKey: WebPanelController.inspectorWidthKey)
    let relaunched = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults)
    XCTAssertTrue(relaunched.workshopFiltersCollapsed, "The choice must survive a relaunch")
    XCTAssertEqual(relaunched.snapshot()["workshopFiltersCollapsed"] as? Bool, true)
    XCTAssertEqual(relaunched.inspectorWidth, 300, "A stored width must survive a relaunch")
    XCTAssertEqual(relaunched.snapshot()["inspectorWidth"] as? Double, 300)
    defaults.removeObject(forKey: WebPanelController.inspectorWidthKey)

    web.setFrameSize(NSSize(width: 1600, height: 900))
    let wide =
      try await web.callAsyncJavaScript(
        """
        const deadline = Date.now() + 5000;
        const last = () => Math.round(parseFloat(getComputedStyle(document.getElementById('library-page')).gridTemplateColumns.split(' ').pop()));
        while (last() === 280) {
          if (Date.now() > deadline) throw new Error('Inspector did not grow with the window');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        return last();
        """, arguments: [:], in: nil, contentWorld: .page) as? Int
    XCTAssertEqual(wide, 340, "At 1600px the inspector reaches its 340px cap")
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Steam clamps every public query to 1,000 pages of 30, so the panel must let people
  /// jump straight to a page, clamp typed numbers to that range, and explain the cap
  /// instead of pretending millions of results are reachable.
  func testWorkshopPageJumpClampsToSteamsPageLimitAndExplainsTheCap() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-page-jump-\(UUID().uuidString)")
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
        const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
        const sent = [];
        const original = window.webkit.messageHandlers.native.postMessage.bind(window.webkit.messageHandlers.native);
        window.webkit.messageHandlers.native.postMessage = message => { sent.push(message); return original(message); };
        const show = workshop => window.wallpaperUI.receive(Object.assign({}, snapshot, {
          page: 'discover',
          workshop: Object.assign({}, snapshot.workshop, {
            page: 1, totalPages: 1000, totalCount: 2891159, pageSize: 30,
            loaded: true, loading: false, items: [], error: null
          }, workshop)
        }));
        show({});
        const form = document.querySelector('form[data-form="workshopPage"]');
        if (!form) throw new Error('Page jump form missing');
        const input = form.elements.page;
        const note = document.querySelector('.pagination-note')?.textContent || '';
        const max = input.getAttribute('max');
        input.value = '5000';
        form.requestSubmit();
        await new Promise(resolve => setTimeout(resolve, 50));
        const request = sent.find(message => message.action === 'workshopPage');
        show({ totalPages: 1, totalCount: 12 });
        const smallNote = document.querySelector('.pagination-note');
        const single = document.querySelector('form[data-form="workshopPage"] input[name="page"]');
        return { note, requestedPage: request ? request.page : null, max, smallNote: Boolean(smallNote), disabled: Boolean(single && single.disabled) };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["max"] as? String, "1000")
    XCTAssertEqual(result?["requestedPage"] as? Int, 1000, "Typed pages must clamp to Steam's last page")
    let note = try XCTUnwrap(result?["note"] as? String)
    XCTAssertTrue(note.contains("30,000") && note.contains("2,891,159"), "Cap note was: \(note)")
    XCTAssertEqual(result?["smallNote"] as? Bool, false, "A fully reachable result set needs no cap note")
    XCTAssertEqual(result?["disabled"] as? Bool, true, "A single page leaves nothing to jump to")
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }

  /// A Discover page holds exactly the tiles that fit the grid without scrolling: the page
  /// measures its columns and full rows, reports that size, and re-measures after a resize.
  func testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "page-size-\(UUID().uuidString)")
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
    let script = """
      try {
      window.__waitFor = async predicate => {
        const deadline = Date.now() + 5000;
        while (!predicate()) {
          if (Date.now() > deadline) throw new Error('Page size request did not arrive');
          await new Promise(resolve => setTimeout(resolve, 20));
        }
      };
      if (!window.__sent) {
        window.__sent = [];
        const original = window.webkit.messageHandlers.native.postMessage.bind(window.webkit.messageHandlers.native);
        window.webkit.messageHandlers.native.postMessage = message => { window.__sent.push(message); return original(message); };
        window.__snapshot = await original({action:'ready'});
        window.__items = Array.from({ length: 240 }, (_, index) => ({ id: `item-${index}`, title: `Tile ${index}`, kind: 'Scene' }));
      }
      window.__show = workshop => window.wallpaperUI.receive(Object.assign({}, window.__snapshot, {
        page: 'discover',
        workshop: Object.assign({}, window.__snapshot.workshop, {
          page: 1, totalPages: 8, totalCount: 240, reachable: 240, pageSize: 30,
          loaded: true, loading: false, items: window.__items, error: null
        }, workshop)
      }));
      // What fits: the resolved column count and the rows of square tiles the grid's height holds.
      window.__fits = () => {
        const grid = document.getElementById('wallpaper-grid');
        const style = getComputedStyle(grid);
        const columns = style.gridTemplateColumns.split(' ').length;
        const tile = grid.querySelector('.tile-select').getBoundingClientRect().height;
        const gap = parseFloat(style.rowGap);
        const inner = grid.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
        return { columns, rows: Math.floor((inner + gap) / (tile + gap)) };
      };
      const before = window.__sent.filter(message => message.action === 'workshopPageSize').length;
      window.__show({ pageSize: previous || 30, items: previous ? window.__items.slice(0, previous) : window.__items });
      const fits = window.__fits();
      await window.__waitFor(() => window.__sent.filter(message => message.action === 'workshopPageSize').length > before);
      const request = window.__sent.filter(message => message.action === 'workshopPageSize').pop();
      // The native reply re-renders its own (Installed) snapshot; show Discover again with exactly
      // that many tiles at that size: they must fill the grid without a scrollbar.
      await new Promise(resolve => setTimeout(resolve, 300));
      window.__show({ pageSize: request.size, items: window.__items.slice(0, request.size) });
      const grid = document.getElementById('wallpaper-grid');
      const tile = grid.querySelector('.tile-select').getBoundingClientRect().height;
      const count = window.__sent.filter(message => message.action === 'workshopPageSize').length;
      return { size: request.size, expected: fits.columns * fits.rows, columns: fits.columns, rows: fits.rows,
               overflow: grid.scrollHeight - grid.clientHeight, slack: grid.clientHeight - grid.scrollHeight, tile, extra: count - before - 1 };
      } catch (error) { return { error: `${error && error.name}: ${error && error.message} | ${String(error)} | ${error && error.stack}` }; }
      """
    let smallResult = try await web.callAsyncJavaScript(
      script, arguments: ["previous": 0], in: nil, contentWorld: .page)
    let small = smallResult as? [String: Any] ?? [:]
    let smallSize = small["size"] as? Int ?? -1
    XCTAssertNil(small["error"], "Page script failed: \(small)")
    XCTAssertEqual(smallSize, small["expected"] as? Int, "Page size must be columns × full rows: \(small)")
    XCTAssertGreaterThan(smallSize, 1)
    XCTAssertLessThanOrEqual(small["overflow"] as? Double ?? 1, 0, "A full page must not scroll: \(small)")
    XCTAssertLessThan(
      small["slack"] as? Double ?? .infinity, (small["tile"] as? Double ?? 0) + 12,
      "Less than a row must stay empty beneath a full page: \(small)")
    XCTAssertEqual(small["extra"] as? Int, 0, "A page of the reported size must not be re-measured")
    let smallDeadline = Date().addingTimeInterval(3)
    while workshop.pageSize != smallSize && Date() < smallDeadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workshop.pageSize, smallSize)

    web.setFrameSize(NSSize(width: 1400, height: 900))
    let largeResult = try await web.callAsyncJavaScript(
      script, arguments: ["previous": smallSize], in: nil, contentWorld: .page)
    let large = largeResult as? [String: Any] ?? [:]
    let largeSize = large["size"] as? Int ?? -1
    XCTAssertNil(large["error"], "Page script failed: \(large)")
    XCTAssertEqual(largeSize, large["expected"] as? Int, "Page size must follow the resize: \(large)")
    XCTAssertGreaterThan(largeSize, smallSize)
    XCTAssertLessThanOrEqual(large["overflow"] as? Double ?? 1, 0, "A full page must not scroll: \(large)")
    let largeDeadline = Date().addingTimeInterval(3)
    while workshop.pageSize != largeSize && Date() < largeDeadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workshop.pageSize, largeSize)
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }


  /// Square tiles sized by the grid's width rarely divide its height evenly, so a page of whole
  /// rows could leave nearly a row blank (a 1px shortfall costs a whole row). Discover tiles may
  /// stretch or squash by up to 15% so the rows fill the grid; with three or more rows one of the
  /// two candidate row counts always lands inside that tolerance. The native side is stood in for
  /// by a reply that cuts the page to the requested size, as the store does from its cache.
  func testDiscoverPageRowsFillTheGridHeight() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "page-fill-\(UUID().uuidString)")
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
    let setup = """
      const original = window.webkit.messageHandlers.native.postMessage.bind(window.webkit.messageHandlers.native);
      window.__snapshot = await original({action:'ready'});
      window.__items = Array.from({ length: 240 }, (_, index) => ({ id: `item-${index}`, title: `Tile ${index}`, kind: 'Scene' }));
      window.__size = 30;
      window.__make = extra => Object.assign({}, window.__snapshot, { page: 'discover', workshop: Object.assign({}, window.__snapshot.workshop, {
        page: 1, totalPages: 1000, totalCount: 1576662, reachable: 30000, pageSize: window.__size, loaded: true, loading: false,
        items: window.__items.slice(0, window.__size), error: null }, extra) });
      window.webkit.messageHandlers.native.postMessage = message => {
        if (message.action !== 'workshopPageSize') return original(message);
        return new Promise(resolve => setTimeout(() => {
          window.__size = message.size;
          resolve(window.__make({ loading: true, items: [] }));
          setTimeout(() => window.wallpaperUI.receive(window.__make({})), 40);
        }, 30));
      };
      window.wallpaperUI.receive(window.__make({ loading: true, items: [] }));
      await new Promise(resolve => setTimeout(resolve, 200));
      window.wallpaperUI.receive(window.__make({}));
      return true;
      """
    _ = try await web.callAsyncJavaScript(setup, arguments: [:], in: nil, contentWorld: .page)
    let probe = """
      await new Promise(resolve => setTimeout(resolve, 700));
      const grid = document.getElementById('wallpaper-grid');
      const style = getComputedStyle(grid);
      const columns = style.gridTemplateColumns.split(' ').length;
      const box = grid.querySelector('.tile-select').getBoundingClientRect();
      const gap = parseFloat(style.rowGap);
      const inner = grid.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
      const rows = Math.floor((inner + gap) / (box.height + gap));
      return { size: window.__size, expected: columns * rows, rows, overflow: grid.scrollHeight - grid.clientHeight,
               slack: grid.clientHeight - grid.scrollHeight, stretch: Math.abs(box.height - box.width) / box.width };
      """
    // 1229×600 once toggled a scrollbar on and off every frame; 994×737 is the reported window,
    // where four rows miss the grid by about a pixel.
    for (width, height) in [(994, 737), (1229, 600), (1400, 900), (1088, 811), (1547, 1063)] {
      web.setFrameSize(NSSize(width: width, height: height))
      let result = try await web.callAsyncJavaScript(
        probe, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
      let context = "\(width)×\(height): \(result)"
      XCTAssertEqual(result["size"] as? Int, result["expected"] as? Int, "Page size must match the rows shown: \(context)")
      XCTAssertLessThanOrEqual(result["overflow"] as? Double ?? 1, 0, "A full page must not scroll: \(context)")
      XCTAssertLessThanOrEqual(result["stretch"] as? Double ?? 1, 0.15, "Tiles stay within the stretch tolerance: \(context)")
      if (result["rows"] as? Int ?? 0) >= 3 {
        XCTAssertLessThan(
          result["slack"] as? Double ?? .infinity, Double(result["rows"] as? Int ?? 0) + 1,
          "Three or more rows must fill the grid: \(context)")
      }
    }
    XCTAssertNil(controller.actionError)
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

  func testTopBarCentersTheBrandBesideARepositoryLinkAndOwnsTitleBarGesturesWithoutWindow()
    async throws
  {
    try await withPanel { panel in
      // The default window width; narrower panels hide the identity entirely.
      panel.web.setFrameSize(NSSize(width: 1240, height: 640))
      panel.show()
      try await panel.waitJS("document.querySelector('#app-identity [data-action=\"openExternal\"]') !== null")
      let link = try await panel.js("""
        const bar = document.querySelector('.topbar');
        const link = document.querySelector('#app-identity [data-action="openExternal"]');
        const barRect = bar.getBoundingClientRect();
        const identity = document.getElementById('app-identity').getBoundingClientRect();
        return {
          url: link.dataset.url,
          inset: getComputedStyle(document.documentElement).getPropertyValue('--window-controls-inset').trim(),
          offCenter: Math.abs((identity.left + identity.right) / 2 - (barRect.left + barRect.right) / 2),
          title: bar.querySelector('.app-name').textContent,
        };
        """) as? [String: Any]
      let url = try XCTUnwrap(URL(string: link?["url"] as? String ?? ""))
      XCTAssertEqual(url, AppUpdateConfiguration.repositoryURL)
      XCTAssertTrue(
        WebPanelController.allowedExternalURL(url),
        "The repository link must pass the same allowlist as every other external link")
      XCTAssertEqual(link?["inset"] as? String, "0px", "No window means no traffic lights to clear")
      XCTAssertLessThanOrEqual(
        link?["offCenter"] as? Double ?? .infinity, 1,
        "The product name must sit on the window's horizontal center, not after the tabs")
      XCTAssertEqual(link?["title"] as? String, "MacWallpaperEngine")
      XCTAssertEqual(panel.controller.windowControlsInset, 0)
      // Title-bar gestures reply without a snapshot and never fail when there is no window.
      for action in ["dragWindow", "titleDoubleClick"] {
        let reply = try await panel.js(
          "return await window.webkit.messageHandlers.native.postMessage({action:'\(action)'});")
        XCTAssertNil(reply, "\(action) must not push a state snapshot")
      }
      try await panel.expectJS(
        """
        const before = window.powerProbe.received.length;
        document.querySelector('.topbar').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, button: 0}));
        document.querySelector('#app-identity [data-action="openExternal"]').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, button: 0}));
        await new Promise(resolve => setTimeout(resolve, 150));
        return window.powerProbe.received.length - before;
        """, equals: 0)
      XCTAssertNil(panel.controller.actionError)
    }
  }

  private func withPanel(
    displayTitles: DisplayTitleResolver = .renderer, _ body: (PanelFixture) async throws -> Void
  ) async throws {
    let fixture = makeStore()
    let panel = try PanelFixture(
      store: fixture.store, bridge: fixture.bridge, displayTitles: displayTitles)
    do {
      try await panel.start()
      try await body(panel)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testDiscoverTilesCarryDownloadRingsAndOnlySteamRequestsOpenTheDialogWithoutWindow()
    async throws
  {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-rings-\(UUID().uuidString)")
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
            if (Date.now() > deadline) throw new Error('Download ring did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const item = { id: 'ring-fixture', title: 'Ring fixture', creator: 'Test', summary: '', preview: null,
          thumbnail: null, tags: ['Video'], size: 2048, subscriptions: 0, kind: 'Video' };
        const job = { id: 'ring-fixture', wallpaperID: 'ring-fixture', title: 'Ring fixture',
          status: 'Downloading Workshop files…', preview: null, thumbnail: null, account: 'fixture',
          progress: 0.42, pending: true, queued: false, bytesReceived: 860, bytesExpected: 2048,
          bytesPerSecond: 600000, authenticating: false, cancelled: false, error: null, prompt: null,
          securePrompt: false, challenge: null, warning: null };
        const push = (downloads, extra = {}) => window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'discover', workshop: Object.assign({}, base.workshop, { items: [item], loaded: true, selectedID: 'ring-fixture' }),
          downloads, downloadRequests: [], setup: Object.assign({}, base.setup, { ready: true }) }, extra));
        const grid = document.getElementById('wallpaper-grid');
        const dialog = document.getElementById('download-dialog');
        const ring = () => grid.querySelector('.tile-download');
        push([]);
        await waitFor(() => grid.querySelector('.wallpaper-tile'));
        const idle = { noRing: !ring(), noQueueButton: !document.querySelector('#top-actions [data-action="openDownloads"]') };
        push([job]);
        await waitFor(() => ring()?.classList.contains('progress'));
        const progress = {
          percent: ring().querySelector('.ring-label').textContent.trim(),
          speed: ring().querySelector('.ring-speed')?.textContent.trim(),
          cancel: ring().dataset.action === 'downloadCancel' && ring().dataset.id === 'ring-fixture',
          drawn: Number(ring().querySelector('.ring-value').getAttribute('stroke-dashoffset')) > 0,
          queueButton: !!document.querySelector('#top-actions [data-action="openDownloads"]'),
          inspectorCancel: !!document.querySelector('#inspector [data-action="downloadCancel"]'),
          dialogClosed: !dialog.open };
        push([Object.assign({}, job, { progress: null, authenticating: true, status: 'Waiting for Steam authentication…' })]);
        const authenticating = { busy: ring().classList.contains('busy'), speed: ring().querySelector('.ring-speed')?.textContent.trim(), dialogClosed: !dialog.open };
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: 'Steam password', securePrompt: true, status: 'Enter your Steam password below' })]);
        await waitFor(() => dialog.open);
        const prompted = { attention: ring().classList.contains('attention'), passwordField: !!dialog.querySelector('input[type="password"]') };
        dialog.querySelector('[data-action="dismissDialog"]').click();
        await waitFor(() => !dialog.open);
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: 'Steam password', securePrompt: true })]);
        const dismissedStaysClosed = !dialog.open;
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: null, challenge: 'mobileApproval', status: 'Approve the sign-in in the Steam mobile app' })]);
        await waitFor(() => dialog.open);
        push([Object.assign({}, job, { progress: null, authenticating: false, status: 'Downloading Workshop files…' })]);
        await waitFor(() => !dialog.open);
        const resumed = ring().classList.contains('busy');
        push([Object.assign({}, job, { pending: false, progress: null, error: 'Steam denied this download.', status: 'Download could not finish' })]);
        const failed = ring()?.dataset.action === 'downloadRetry' && ring().classList.contains('failed');
        push([], { wallpapers: [{ id: 'ring-fixture', title: 'Ring fixture', kind: 'Video', preview: null, active: false, supported: true, tags: [] }] });
        const installed = { check: !!grid.querySelector('.tile-installed'), noRing: !ring() };
        return { idle, progress, authenticating, prompted, dismissedStaysClosed, resumed, failed, installed };
        """, arguments: ["base": base], in: nil, contentWorld: .page) as? [String: Any]
    let idle = result?["idle"] as? [String: Any]
    XCTAssertEqual(idle?["noRing"] as? Bool, true, "An untouched tile carries no ring")
    XCTAssertEqual(
      idle?["noQueueButton"] as? Bool, true,
      "The top-bar downloads button only appears once there is download activity")
    let progress = result?["progress"] as? [String: Any]
    XCTAssertEqual(progress?["percent"] as? String, "42%", "The ring shows the measured percentage")
    XCTAssertEqual(progress?["speed"] as? String, "600 KB/s", "The ring shows the transfer speed under the percentage")
    XCTAssertEqual(progress?["cancel"] as? Bool, true, "Clicking the ring cancels that download")
    XCTAssertEqual(progress?["drawn"] as? Bool, true, "The ring stroke follows the progress value")
    XCTAssertEqual(progress?["queueButton"] as? Bool, true)
    XCTAssertEqual(
      progress?["inspectorCancel"] as? Bool, true, "The inspector offers Cancel while downloading")
    XCTAssertEqual(
      progress?["dialogClosed"] as? Bool, true, "A running download opens no dialog by itself")
    let authenticating = result?["authenticating"] as? [String: Any]
    XCTAssertEqual(authenticating?["busy"] as? Bool, true, "Sign-in without a prompt spins the ring")
    XCTAssertEqual(
      authenticating?["speed"] as? String, "600 KB/s",
      "Without a percentage the ring still carries the transfer speed")
    XCTAssertEqual(
      authenticating?["dialogClosed"] as? Bool, true,
      "A saved sign-in handoff must not open the dialog")
    let prompted = result?["prompted"] as? [String: Any]
    XCTAssertEqual(prompted?["attention"] as? Bool, true, "A Steam request marks the tile")
    XCTAssertEqual(
      prompted?["passwordField"] as? Bool, true, "A password request opens the dialog by itself")
    XCTAssertEqual(
      result?["dismissedStaysClosed"] as? Bool, true,
      "Not now silences the same request until Steam asks for something else")
    XCTAssertEqual(
      result?["resumed"] as? Bool, true,
      "Once Steam is satisfied the dialog closes and the tile keeps reporting")
    XCTAssertEqual(result?["failed"] as? Bool, true, "A failed download offers retry on its tile")
    let installed = result?["installed"] as? [String: Any]
    XCTAssertEqual(installed?["check"] as? Bool, true, "A wallpaper in the library shows a check")
    XCTAssertEqual(installed?["noRing"] as? Bool, true)
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
      "A Workshop download without measured bytes reports neither percentage nor byte totals")
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

private final class PanelUpdateClient: AppUpdateClient, @unchecked Sendable {
  var release: GitHubRelease?
  var fetchCalls = 0
  var downloadCalls = 0

  func fetchLatestRelease() async throws -> GitHubRelease {
    fetchCalls += 1
    guard let release else {
      throw AppUpdateIssue(code: .configuration, detail: "missing release")
    }
    return release
  }

  func download(
    _ asset: GitHubReleaseAsset, to destination: URL,
    progress: @escaping @Sendable (Int64, Int64, Int64) -> Void
  ) async throws {
    downloadCalls += 1
    progress(asset.size, asset.size, 0)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("zip".utf8).write(to: destination)
  }

  static func release(version: String) -> GitHubRelease {
    GitHubRelease(
      version: SemanticVersion(version)!,
      htmlURL: URL(
        string: "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/tag/v\(version)")!,
      prerelease: false,
      assets: [
        GitHubReleaseAsset(
          name: "MacWallpaperEngine-\(version)-arm64.zip",
          downloadURL: URL(
            string:
              "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/download/v\(version)/MacWallpaperEngine-\(version)-arm64.zip"
          )!,
          size: 1_000, digest: nil)
      ])
  }
}

private final class PanelUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
  var canInstallInPlace = true
  var installCalls = 0
  func prepareInstallation(archive: URL) throws -> URL { archive }
  func install(extractedApp: URL, replacing destination: URL) throws { installCalls += 1 }
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

  init(store: BridgeStore, bridge: LayoutSnapshotBridge, displayTitles: DisplayTitleResolver) throws {
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
      isPresentationVisible: { visibility.visible }, displayTitles: displayTitles)
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
      bridge.options[id] = BridgeSnapshotFixtures.options(
        wallpaperId: id, title: id,
        displayConfigurations: [
          BridgeDisplayConfigRow(
            displayId: display, title: display, enabled: true, scalingMode: .fill,
            scalingFactor: 1, targetFps: fps, maxFps: 60, muted: false, volume: volume,
            dirty: false, canRestoreDefaults: false)
        ], audioResponseEnabled: false, volume: volume)
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
