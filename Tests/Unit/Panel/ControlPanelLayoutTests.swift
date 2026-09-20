import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
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
      store: fixture.store, navigation: navigation, workshop: workshop, appLanguage: .english())
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

  func testPanelRendersInTheControllerLanguage() async throws {
    XCTAssertEqual(WebPanelController.pageLanguage("zh-Hans"), "zh-Hans")
    XCTAssertEqual(WebPanelController.pageLanguage(nil), "en")
    XCTAssertEqual(
      WebPanelController.pageLanguage("en';alert(1);//"), "en",
      "Only a plain language tag may be spliced into the user script")
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-panel-language-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    var rendered: [String: [String: Any]] = [:]
    for language in ["en", "zh-Hans"] {
      let controller = WebPanelController(
        store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
        appLanguage: AppLanguageStore(defaults: defaults, systemLanguages: [language]))
      let web = controller.makeWebView()
      defer { controller.stop() }
      web.setFrameSize(NSSize(width: 960, height: 640))
      let deadline = Date().addingTimeInterval(15)
      while !controller.isReady && Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      guard controller.isReady else { return XCTFail("\(language): panel did not become ready") }
      rendered[language] =
        try await web.callAsyncJavaScript(
          """
          const bridge = window.webkit.messageHandlers.native;
          window.wallpaperUI.receive(await bridge.postMessage({action:'navigate',page:'installed'}));
          const summary = document.getElementById('browser-summary').textContent;
          window.wallpaperUI.receive(await bridge.postMessage({action:'navigate',page:'settings'}));
          return {
            lang: document.documentElement.lang,
            tab: document.querySelector('.tabs [data-page="discover"]').textContent,
            navLabel: document.querySelector('.tabs').getAttribute('aria-label'),
            section: document.querySelector('#settings-tab-general').textContent,
            summary,
          };
          """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
      let contracts = try await web.callAsyncJavaScript(
        """
        const {t, setLanguage} = await import('./i18n.js');
        const cases = [['zh-CN','zh-Hans'], ['zh-Hans-TW','zh-Hans'], ['zh','zh-Hans'],
          ['zh-TW','en'], ['zh-Hant','en'], ['zh-Hant-CN','en'], ['en-CN','en'], ['en-GB','en'],
          ['fr','en'], ['zhgarbage','en'], ['','en'], [undefined,'en']];
        const resolved = cases.every(([tag, expected]) => setLanguage(tag) === expected);
        setLanguage('zh-Hans');
        const payload = '<img src=x onerror=alert(1)> {count} $&';
        const interpolated = t('Select: {title}', {title: payload});
        const safeSubstitution = interpolated.includes(payload);
        const fallback = t('Uncatalogued {value}', {value: 'value'}) === 'Uncatalogued value';
        const missing = t('Select: {title}').includes('{title}');
        setLanguage(window.__appLanguage);
        return resolved && safeSubstitution && fallback && missing;
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
      XCTAssertEqual(contracts, true, "Language fallback and literal interpolation must stay predictable")
      XCTAssertNil(web.window, "This regression must not open a desktop window")
    }
    let english = try XCTUnwrap(rendered["en"])
    let chinese = try XCTUnwrap(rendered["zh-Hans"])
    XCTAssertEqual(english["lang"] as? String, "en")
    XCTAssertEqual(chinese["lang"] as? String, "zh-Hans")
    for key in ["tab", "navLabel", "section", "summary"] {
      let en = try XCTUnwrap(english[key] as? String, key)
      let zh = try XCTUnwrap(chinese[key] as? String, key)
      XCTAssertFalse(en.isEmpty, key)
      XCTAssertNotEqual(en, zh, "\(key): the page must render the controller's language, not English")
      XCTAssertTrue(
        zh.unicodeScalars.contains { $0.properties.isIdeographic },
        "\(key): expected Han text, got \(zh)")
    }
    await workshop.steamCMDSetup.shutdown()
  }

  func testLanguageSettingSwitchesThePanelInPlaceAndOffersEveryShippedLanguage() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-panel-language-switch-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let languages = AppLanguageStore(defaults: defaults, systemLanguages: ["en"])
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      appLanguage: languages)
    let web = controller.makeWebView()
    defer { controller.stop() }
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard controller.isReady else { return XCTFail("panel did not become ready") }
    let probe = """
      const bridge = window.webkit.messageHandlers.native;
      window.wallpaperUI.receive(await bridge.postMessage({action:'navigate',page:'settings'}));
      const reply = await bridge.postMessage({action:'languageSetting', value});
      window.wallpaperUI.receive(reply);
      const select = document.querySelector('[data-language-setting]');
      return {
        lang: document.documentElement.lang,
        tab: document.querySelector('.tabs [data-page="discover"]').textContent,
        navLabel: document.querySelector('.tabs').getAttribute('aria-label'),
        section: document.querySelector('#settings-tab-general').textContent,
        selected: select.value,
        options: Array.from(select.options).map(option => [option.value, option.textContent]),
        effective: reply.language.effective,
      };
      """
    let chineseReply = try await web.callAsyncJavaScript(
      probe, arguments: ["value": "zh-Hans"], in: nil, contentWorld: .page)
    let chinese = try XCTUnwrap(chineseReply as? [String: Any])
    XCTAssertEqual(chinese["lang"] as? String, "zh-Hans")
    XCTAssertEqual(chinese["selected"] as? String, "zh-Hans")
    XCTAssertEqual(chinese["effective"] as? String, "zh-Hans")
    XCTAssertEqual(languages.preference, "zh-Hans")
    XCTAssertEqual(controller.language, "zh-Hans")
    for key in ["tab", "navLabel", "section"] {
      let text = try XCTUnwrap(chinese[key] as? String, key)
      XCTAssertTrue(
        text.unicodeScalars.contains { $0.properties.isIdeographic },
        "\(key): the page must switch without a reload, got \(text)")
    }
    let options = try XCTUnwrap(chinese["options"] as? [[String]])
    XCTAssertEqual(options.first?.first, "system")
    XCTAssertEqual(
      options.dropFirst().map { $0[0] }, AppLanguage.supported.map(\.tag),
      "Every shipped language is offered after System")
    for language in AppLanguage.supported {
      XCTAssertTrue(
        options.contains { $0[0] == language.tag && $0[1] == language.name },
        "\(language.tag) is listed under its own name in any interface language")
    }

    let englishReply = try await web.callAsyncJavaScript(
      probe, arguments: ["value": "system"], in: nil, contentWorld: .page)
    let english = try XCTUnwrap(englishReply as? [String: Any])
    XCTAssertEqual(english["lang"] as? String, "en")
    XCTAssertEqual(english["selected"] as? String, "system")
    XCTAssertEqual(languages.preference, AppLanguageStore.systemChoice)
    for key in ["tab", "navLabel", "section"] {
      let text = try XCTUnwrap(english[key] as? String, key)
      XCTAssertNotEqual(text, chinese[key] as? String, key)
      XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isIdeographic }, key)
    }

    let refused =
      try await web.callAsyncJavaScript(
        """
        try { await window.webkit.messageHandlers.native.postMessage({action:'languageSetting', value:'zh-TW'}); return false; }
        catch { return document.documentElement.lang === 'en'; }
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
    XCTAssertEqual(refused, true, "A language the app does not ship is refused and changes nothing")
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
      store: fixture.store, navigation: navigation, workshop: workshop, updater: updater,
      appLanguage: .english())
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
      store: fixture.store, navigation: navigation, workshop: workshop, updater: updater,
      appLanguage: .english())
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
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop, theme: theme,
      appLanguage: .english())
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
      store: fixture.store, navigation: navigation, workshop: workshop, appLanguage: .english())
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

  /// Both library pages share one right-hand filter sidebar whose only switch is the
  /// toolbar's Filter button: no rail, no collapse control inside the sidebar, and no
  /// popover on Installed. Each page remembers its own choice natively because the
  /// page's website data store is not persistent. The inspector's width is a function of
  /// the window width alone: there is no drag handle, nothing is stored, and a width
  /// left behind by an earlier build is discarded rather than applied.
  func testFilterSidebarTogglesFromTheToolbarPerPageAndInspectorFollowsWindowWidth() async throws {
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
    // A width dragged in an earlier build must neither be applied nor kept.
    defaults.set(320.0, forKey: WebPanelController.legacyInspectorWidthKey)
    let controller = WebPanelController(
      store: fixture.store, navigation: navigation, workshop: workshop, defaults: defaults,
      appLanguage: .english())
    XCTAssertEqual(controller.filtersCollapsed, ["discover": false, "installed": false])
    XCTAssertNil(
      defaults.object(forKey: WebPanelController.legacyInspectorWidthKey),
      "A stored inspector width from an earlier build is cleared on launch")
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
      const toggle = () => document.querySelector('.browser-toolbar [data-action="toggleFilters"]');
      const measure = () => {
        const sidebar = document.getElementById('filter-sidebar');
        const bar = document.querySelector('.browser-toolbar').getBoundingClientRect();
        const button = toggle();
        const rect = button.getBoundingClientRect();
        return {
          hidden: sidebar.hidden,
          expanded: button.getAttribute('aria-expanded'),
          label: button.querySelector('.button-label')?.textContent,
          glyph: !!button.querySelector('svg'),
          filled: getComputedStyle(button).backgroundColor,
          // The button leads the toolbar and sits beside the sidebar it opens.
          first: Math.round(rect.left - bar.left) <= 17,
          besideSidebar: sidebar.hidden ? null : Math.round(sidebar.getBoundingClientRect().right) <= Math.round(rect.left),
          sidebarLeftOfGrid: sidebar.hidden ? null : sidebar.getBoundingClientRect().right <= document.querySelector('.browser-column').getBoundingClientRect().left + 1,
          sidebarAtLeftEdge: sidebar.hidden ? null : Math.round(sidebar.getBoundingClientRect().left) === 0,
          insideToggles: sidebar.querySelectorAll('[data-action="toggleFilters"], .filter-rail, .filter-toggle').length,
          popover: document.querySelectorAll('.installed-filter, .filter-popover').length,
          sortOptions: [...document.querySelectorAll('#browser-sort option')].map(option => option.textContent),
          sortValue: document.getElementById('browser-sort')?.value,
          direction: !!document.querySelector('.browser-toolbar [data-action="toggleSortDirection"]'),
          // Discover's boxes: which start unticked, and that no type menu remains.
          unchecked: [...sidebar.querySelectorAll('input[type="checkbox"]:not(:checked)')].map(input => input.value),
          boxes: sidebar.querySelectorAll('input[type="checkbox"]').length,
          selects: sidebar.querySelectorAll('select').length,
          filterCount: document.querySelector('.browser-toolbar .filter-count')?.textContent ?? null,
          columns: columns()
        };
      };
      showDiscover(await native.postMessage({action:'ready'}));
      const before = measure();
      toggle().click();
      // The native reply re-renders on its own page (Installed, whose sidebar is still
      // open), so the round trip is complete once native reports Discover's choice.
      let reply;
      const settle = Date.now() + 5000;
      while (!(reply = await native.postMessage({action:'ready'})).filtersCollapsed?.discover) {
        if (Date.now() > settle) throw new Error('Filter choice did not reach native');
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      showDiscover(reply);
      const after = measure();
      window.wallpaperUI.receive(Object.assign({}, reply, {page: 'installed'}));
      const installed = measure();
      showDiscover(reply);
      const inspector = document.getElementById('inspector');
      return {before, after, installed, flags: reply.filtersCollapsed,
              separators: document.querySelectorAll('[role="separator"], [class*="resizer"]').length,
              snapshotWidth: 'inspectorWidth' in reply,
              inspectorWidth: Math.round(inspector.getBoundingClientRect().width),
              inspectorCursor: getComputedStyle(inspector).cursor};
      """
    let result =
      try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
      as? [String: Any]
    let before = result?["before"] as? [String: Any]
    XCTAssertEqual(before?["hidden"] as? Bool, false)
    XCTAssertEqual(before?["expanded"] as? String, "true")
    XCTAssertEqual(before?["label"] as? String, "Filter", "The switch is a button that says Filter")
    XCTAssertEqual(before?["glyph"] as? Bool, true, "…with a filter glyph beside the label")
    XCTAssertEqual(before?["first"] as? Bool, true, "…leading the toolbar, beside the sidebar")
    XCTAssertEqual(before?["besideSidebar"] as? Bool, true)
    XCTAssertEqual(before?["sidebarLeftOfGrid"] as? Bool, true, "The sidebar is on the left of the grid")
    XCTAssertEqual(before?["sidebarAtLeftEdge"] as? Bool, true, "…at the window's left edge; the inspector keeps the right")
    XCTAssertEqual(before?["insideToggles"] as? Int, 0, "The sidebar carries no collapse control of its own")
    XCTAssertNotEqual(before?["filled"] as? String, "rgba(0, 0, 0, 0)", "The Filter button is filled, not a quiet control")
    XCTAssertEqual((before?["columns"] as? [Int])?.count, 3, "Discover starts with the sidebar column")
    XCTAssertEqual((before?["columns"] as? [Int])?.first, 160, "The sidebar is the first column (160px below 1040px)")
    XCTAssertEqual((before?["columns"] as? [Int])?.last, 290, "A 960px window gets a 290px inspector (15vw + 146px)")
    let after = result?["after"] as? [String: Any]
    XCTAssertEqual(after?["hidden"] as? Bool, true, "Closing removes the sidebar entirely; no rail remains")
    XCTAssertEqual(after?["expanded"] as? String, "false")
    XCTAssertEqual(after?["first"] as? Bool, true, "The Filter button stays where it was so it can reopen the sidebar")
    XCTAssertEqual((after?["columns"] as? [Int])?.count, 2, "Closed, the grid takes the sidebar's column")
    XCTAssertEqual(result?["separators"] as? Int, 0, "The inspector edge is not a drag handle")
    XCTAssertEqual(result?["snapshotWidth"] as? Bool, false, "The snapshot carries no inspector width")
    XCTAssertEqual(result?["inspectorWidth"] as? Int, 290, "The grid column and the rendered inspector agree")
    XCTAssertEqual(result?["inspectorCursor"] as? String, "auto", "Nothing invites resizing")
    let installed = result?["installed"] as? [String: Any]
    XCTAssertEqual(installed?["hidden"] as? Bool, false, "Installed has its own sidebar, still open after Discover's was closed")
    XCTAssertEqual(installed?["expanded"] as? String, "true")
    XCTAssertEqual(installed?["label"] as? String, "Filter", "Installed uses the same Filter button")
    XCTAssertEqual(installed?["first"] as? Bool, true)
    XCTAssertEqual(installed?["popover"] as? Int, 0, "The old Filters popover is gone")
    XCTAssertEqual(installed?["insideToggles"] as? Int, 0)
    XCTAssertEqual((installed?["columns"] as? [Int])?.count, 3)
    XCTAssertEqual(
      installed?["sortOptions"] as? [String], ["Name", "Type", "Favorites", "File size", "Date added"],
      "Installed keeps its sort menu, with the new keys")
    XCTAssertEqual(installed?["direction"] as? Bool, true, "…and a direction switch beside it")
    XCTAssertEqual(before?["direction"] as? Bool, false, "Discover's Steam sorts have no direction")
    XCTAssertEqual(before?["sortValue"] as? String, "trend-year", "Discover opens on this year's most popular")
    XCTAssertEqual(
      before?["unchecked"] as? [String],
      ["Approved", "Audio responsive", "Customizable", "Questionable", "Mature", "Unspecified"],
      "Wallpaper Engine's defaults: nothing in Show only, Everyone-only, genre-less hidden; every other box ticked")
    XCTAssertEqual(before?["boxes"] as? Int, 3 + 5 + 3 + 25 + 25, "Show only, Type, Age rating, Resolution and Tags")
    XCTAssertEqual(before?["selects"] as? Int, 0, "No type menu: types are boxes like Wallpaper Engine's")
    XCTAssertNil(before?["filterCount"] as? String, "Defaults count as no active filter")
    XCTAssertEqual(result?["flags"] as? [String: Bool], ["discover": true, "installed": false])
    XCTAssertNil(controller.actionError)
    XCTAssertEqual(controller.filtersCollapsed, ["discover": true, "installed": false])
    XCTAssertTrue(defaults.bool(forKey: WebPanelController.filtersCollapsedKeys["discover"]!))
    XCTAssertFalse(defaults.bool(forKey: WebPanelController.filtersCollapsedKeys["installed"]!))
    XCTAssertNil(defaults.object(forKey: WebPanelController.legacyInspectorWidthKey))
    let relaunched = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      defaults: defaults, appLanguage: .english())
    XCTAssertEqual(
      relaunched.filtersCollapsed, ["discover": true, "installed": false],
      "The choice must survive a relaunch, page by page")
    XCTAssertEqual(relaunched.snapshot()["filtersCollapsed"] as? [String: Bool], ["discover": true, "installed": false])
    XCTAssertNil(relaunched.snapshot()["inspectorWidth"], "No inspector width is published")

    // The width is the same function of the window on both pages: 260px at the 760px
    // minimum, 15vw + 146px in between, 420px from about 1830px on. The window is
    // widened and narrowed in turn so the value cannot be an artefact of the order.
    let expectations: [(width: Double, page: String, inspector: Int)] = [
      (1600, "discover", 386), (760, "discover", 260), (760, "installed", 260),
      (2000, "installed", 420), (1040, "installed", 302), (1040, "discover", 302),
    ]
    for expectation in expectations {
      web.setFrameSize(NSSize(width: expectation.width, height: 900))
      let measured =
        try await web.callAsyncJavaScript(
          """
          const snapshot = await window.webkit.messageHandlers.native.postMessage({action:'ready'});
          window.wallpaperUI.receive(Object.assign({}, snapshot, {
            page, workshop: Object.assign({}, snapshot.workshop, {page: 1, totalPages: 1, loaded: true, loading: false, items: [], error: null})
          }));
          const deadline = Date.now() + 5000;
          while (Math.round(document.documentElement.clientWidth) !== expected) {
            if (Date.now() > deadline) throw new Error(`Viewport did not reach ${expected}px`);
            await new Promise(resolve => setTimeout(resolve, 20));
          }
          const columns = getComputedStyle(document.getElementById('library-page')).gridTemplateColumns.split(' ').map(v => Math.round(parseFloat(v)));
          return {inspector: Math.round(document.getElementById('inspector').getBoundingClientRect().width),
                  last: columns.at(-1), sum: columns.reduce((a, b) => a + b, 0)};
          """, arguments: ["page": expectation.page, "expected": expectation.width], in: nil,
          contentWorld: .page) as? [String: Any]
      XCTAssertEqual(
        measured?["inspector"] as? Int, expectation.inspector,
        "At \(Int(expectation.width))px on \(expectation.page) the inspector is \(expectation.inspector)px wide")
      XCTAssertEqual(measured?["last"] as? Int, expectation.inspector, "The grid column matches the inspector")
      XCTAssertEqual(
        measured?["sum"] as? Int, Int(expectation.width),
        "The columns fill the window exactly at \(Int(expectation.width))px on \(expectation.page)")
    }
    XCTAssertNil(web.window)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Installed sorts by name, type, favorites, folder size or date added, in either
  /// direction: picking a key starts in the direction people ask for it (names A→Z,
  /// the rest largest / newest / starred first), the direction button flips it, names
  /// break ties, and wallpapers whose folder has not been measured yet sort last.
  func testInstalledSortsByEveryKeyInBothDirectionsWithoutWindow() async throws {
    try await withPanel { panel in
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let order = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, title, kind, size, addedAt) => ({ id, title, kind, size, addedAt, preview: null, active: false, supported: true, tags: [] });
        const wallpapers = [
          wallpaper('b', 'Beta', 'Video', 300, 3000), wallpaper('a', 'alpha', 'Scene', 100, null),
          wallpaper('c', 'Gamma', 'Scene', null, 1000), wallpaper('d', 'Delta', 'Web', 200, 2000),
        ];
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, favorites: ['c', 'a'] }));
        const titles = () => [...document.querySelectorAll('.tile-title')].map(node => node.textContent);
        const sort = document.getElementById('browser-sort');
        const pick = value => { sort.value = value; sort.dispatchEvent(new Event('change', { bubbles: true })); };
        const flip = () => document.querySelector('[data-action="toggleSortDirection"]').click();
        const result = { initial: titles() };
        for (const key of ['type', 'favorites', 'size', 'added', 'title']) {
          pick(key);
          result[key] = titles();
          flip();
          result[`${key}Flipped`] = titles();
        }
        result.direction = document.querySelector('[data-action="toggleSortDirection"]').getAttribute('title');
        return result;
        """) as? [String: Any]
      XCTAssertEqual(order?["initial"] as? [String], ["alpha", "Beta", "Delta", "Gamma"], "Names A→Z by default, case-insensitively")
      XCTAssertEqual(order?["type"] as? [String], ["alpha", "Gamma", "Beta", "Delta"], "Type, names breaking ties")
      XCTAssertEqual(order?["typeFlipped"] as? [String], ["Delta", "Beta", "alpha", "Gamma"])
      XCTAssertEqual(order?["favorites"] as? [String], ["alpha", "Gamma", "Beta", "Delta"], "Favorites first")
      XCTAssertEqual(order?["favoritesFlipped"] as? [String], ["Beta", "Delta", "alpha", "Gamma"])
      XCTAssertEqual(order?["size"] as? [String], ["Beta", "Delta", "alpha", "Gamma"], "Largest first; an unmeasured folder sorts last")
      XCTAssertEqual(order?["sizeFlipped"] as? [String], ["alpha", "Delta", "Beta", "Gamma"], "…in both directions")
      XCTAssertEqual(order?["added"] as? [String], ["Beta", "Delta", "Gamma", "alpha"], "Newest first; no date sorts last")
      XCTAssertEqual(order?["addedFlipped"] as? [String], ["Gamma", "Delta", "Beta", "alpha"])
      XCTAssertEqual(order?["title"] as? [String], ["alpha", "Beta", "Delta", "Gamma"], "Choosing a key resets to its natural direction")
      XCTAssertEqual(order?["titleFlipped"] as? [String], ["Gamma", "Delta", "Beta", "alpha"])
      XCTAssertEqual(order?["direction"] as? String, "Name, descending. Click to sort ascending")
    }
  }

  /// Tiles wear Wallpaper Engine's corner marks: a green trophy for a staff-approved
  /// wallpaper and a heart for a favorite, on Installed and Discover alike, plus the
  /// library check on Discover. The marks step aside with the Active badge while the
  /// select check is showing, and the favorite toggle itself no longer stays lit.
  func testTilesWearApprovedAndFavoriteMarksWithoutWindow() async throws {
    try await withPanel { panel in
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, title, approved) => ({ id, title, kind: 'Scene', approved, preview: null, active: false, supported: true, tags: [], size: 1, addedAt: 1 });
        const wallpapers = [wallpaper('a', 'Approved', true), wallpaper('b', 'Loved', false), wallpaper('c', 'Both', true), wallpaper('d', 'Plain', false)];
        const display = Object.assign({}, base.displays[0], { wallpaperID: 'c' });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, favorites: ['b', 'c'], displays: [display], targetDisplayID: display.id }));
        const tile = id => document.querySelector(`.wallpaper-tile [data-id="${id}"]`).closest('.wallpaper-tile');
        const marks = id => [...tile(id).querySelectorAll('.tile-mark')].map(node => node.className.replace('tile-mark', '').trim());
        const left = node => Math.round(node.getBoundingClientRect().left - node.closest('.wallpaper-tile').getBoundingClientRect().left);
        const installed = {
          a: marks('a'), b: marks('b'), c: marks('c'), d: marks('d'),
          announced: tile('c').querySelector('.tile-select').getAttribute('aria-label').split(', ').length - tile('d').querySelector('.tile-select').getAttribute('aria-label').split(', ').length,
          toggleHidden: getComputedStyle(tile('b').querySelector('.tile-favorite')).opacity === '0',
          trophyGreen: getComputedStyle(tile('a').querySelector('.tile-mark.approved')).color !== getComputedStyle(tile('a').querySelector('.tile-mark')).backgroundColor,
          badgeAfterMarks: left(tile('c').querySelector('.active-badge')) > left(tile('c').querySelector('.tile-marks')) + 20,
          marksAtCorner: left(tile('c').querySelector('.tile-marks')),
        };
        tile('c').querySelector('.tile-check').click();
        await new Promise(resolve => setTimeout(resolve, 50));
        // The marks slide into place (`transition: left`), and an offscreen web view never
        // services a transition, so the measured position would stay at its start value.
        document.getAnimations().forEach(animation => animation.finish());
        const checked = { marksMoved: left(tile('c').querySelector('.tile-marks')), badgeMoved: left(tile('c').querySelector('.active-badge')) };
        const item = (id, tags) => ({ id, title: id, creator: 'Test', summary: '', preview: null, thumbnail: null, tags, size: 1, subscriptions: 0, kind: 'Scene', approved: tags.includes('Approved') });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'discover', wallpapers, favorites: ['b', 'c'], downloads: [], downloadRequests: [],
          workshop: Object.assign({}, base.workshop, { items: [item('c', ['Approved', 'Scene']), item('x', ['Approved']), item('y', ['Scene'])], loaded: true }) }));
        const discover = { c: marks('c'), x: marks('x'), y: marks('y'), noCheck: !tile('x').querySelector('.tile-check') };
        return { installed, checked, discover };
        """) as? [String: Any]
      let installed = result?["installed"] as? [String: Any]
      XCTAssertEqual(installed?["a"] as? [String], ["approved"], "An approved wallpaper wears the trophy")
      XCTAssertEqual(installed?["b"] as? [String], ["favorite"], "A favorite wears the heart")
      XCTAssertEqual(installed?["c"] as? [String], ["approved", "favorite"], "Both stack, trophy first")
      XCTAssertEqual(installed?["d"] as? [String], [], "A plain wallpaper wears nothing")
      XCTAssertEqual(installed?["announced"] as? Int, 2, "Screen readers hear both marks on the tile's own label")
      XCTAssertEqual(installed?["toggleHidden"] as? Bool, true, "The favorite toggle waits for hover; the heart mark carries the state")
      XCTAssertEqual(installed?["trophyGreen"] as? Bool, true)
      XCTAssertEqual(installed?["marksAtCorner"] as? Int, 6, "Marks sit in the corner while the select check is hidden")
      XCTAssertEqual(installed?["badgeAfterMarks"] as? Bool, true, "The Active badge sits after the marks")
      let checked = result?["checked"] as? [String: Any]
      XCTAssertEqual(checked?["marksMoved"] as? Int, 35, "Ticking the tile moves the marks past the select check")
      XCTAssertEqual(checked?["badgeMoved"] as? Int, 59, "…and the Active badge past the marks")
      let discover = result?["discover"] as? [String: Any]
      XCTAssertEqual(discover?["c"] as? [String], ["installed", "approved", "favorite"], "Discover adds the library check ahead of the marks")
      XCTAssertEqual(discover?["x"] as? [String], ["approved"], "Steam's Approved tag marks a Discover tile")
      XCTAssertEqual(discover?["y"] as? [String], [])
      XCTAssertEqual(discover?["noCheck"] as? Bool, true, "Discover tiles have no select check to step past")
    }
  }

  /// Steam clamps every public query to 1,000 pages of 30, so the panel must let people
  /// jump straight to a page and clamp typed numbers to that range instead of pretending
  /// millions of results are reachable.
  func testWorkshopPageJumpClampsToSteamsPageLimit() async throws {
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
      store: fixture.store, navigation: navigation, workshop: workshop, appLanguage: .english())
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
        const max = input.getAttribute('max');
        input.value = '5000';
        form.requestSubmit();
        await new Promise(resolve => setTimeout(resolve, 50));
        const request = sent.find(message => message.action === 'workshopPage');
        show({ totalPages: 1, totalCount: 12 });
        const single = document.querySelector('form[data-form="workshopPage"] input[name="page"]');
        return { requestedPage: request ? request.page : null, max, disabled: Boolean(single && single.disabled) };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["max"] as? String, "1000")
    XCTAssertEqual(result?["requestedPage"] as? Int, 1000, "Typed pages must clamp to Steam's last page")
    XCTAssertEqual(result?["disabled"] as? Bool, true, "A single page leaves nothing to jump to")
    XCTAssertNil(controller.actionError)
    await workshop.steamCMDSetup.shutdown()
  }

  /// Discover tiles are exactly square, never fewer than three to a row (even at the 760px
  /// window minimum with the filter sidebar open), and gain columns as the window widens.
  /// A page is a fixed 30 tiles that scroll, so the panel never reports a page size, and the
  /// column count settles at once after a resize instead of flapping.
  func testDiscoverGridKeepsSquareTilesInAtLeastThreeStableColumns() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "grid-columns-\(UUID().uuidString)")
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
      store: fixture.store, navigation: navigation, workshop: workshop, appLanguage: .english())
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
      window.__sent = [];
      window.webkit.messageHandlers.native.postMessage = message => { window.__sent.push(message); return original(message); };
      window.__snapshot = await original({action:'ready'});
      window.__items = Array.from({ length: 30 }, (_, index) => ({ id: `item-${index}`, title: `Tile ${index}`, kind: 'Scene' }));
      window.__show = page => window.wallpaperUI.receive(Object.assign({}, window.__snapshot, { page,
        wallpapers: window.__items.map(item => Object.assign({ preview: null, active: false, supported: true, tags: [] }, item)),
        workshop: Object.assign({}, window.__snapshot.workshop, {
        page: 1, totalPages: 1000, totalCount: 1576662, reachable: 30000, pageSize: 30, maxPages: 1000,
        loaded: true, loading: false, items: window.__items, error: null }) }));
      window.__show('discover');
      return window.__snapshot.workshop.pageSize;
      """
    let pageSize = try await web.callAsyncJavaScript(
      setup, arguments: [:], in: nil, contentWorld: .page) as? Int
    XCTAssertEqual(pageSize, WorkshopStore.pageSize, "A page is one Steam page of 30")
    let probe = """
      const deadline = Date.now() + 5000;
      while (Math.round(document.documentElement.clientWidth) !== expected) {
        if (Date.now() > deadline) throw new Error(`Viewport did not reach ${expected}px`);
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      window.__show(page);
      const grid = document.getElementById('wallpaper-grid');
      const columnsNow = () => getComputedStyle(grid).gridTemplateColumns.split(' ').length;
      // Sample the column count over a few hundred milliseconds: it must not flap after a resize.
      const samples = [];
      for (let index = 0; index < 8; index += 1) {
        samples.push(columnsNow());
        await new Promise(resolve => setTimeout(resolve, 40));
      }
      const tiles = [...grid.querySelectorAll('.tile-select')].map(tile => tile.getBoundingClientRect());
      const first = tiles[0];
      const widths = new Set(tiles.map(tile => Math.round(tile.width)));
      return { columns: samples[0], stable: samples.every(count => count === samples[0]), tiles: tiles.length,
               square: Math.abs(first.height - first.width), uniform: widths.size === 1,
               pageSizeRequests: window.__sent.filter(message => message.action === 'workshopPageSize').length,
               scrolls: grid.scrollHeight > grid.clientHeight, gridWidth: grid.clientWidth };
      """
    var previous = 0
    for (page, width, height, minimum) in [
      ("discover", 760, 560, 3), ("installed", 760, 560, 3), ("discover", 960, 640, 3),
      ("discover", 1400, 900, 5), ("discover", 1900, 1000, 6),
    ] {
      web.setFrameSize(NSSize(width: width, height: height))
      let result = try await web.callAsyncJavaScript(
        probe, arguments: ["page": page, "expected": width], in: nil, contentWorld: .page)
        as? [String: Any] ?? [:]
      let context = "\(page) at \(width)×\(height): \(result)"
      let columns = result["columns"] as? Int ?? 0
      XCTAssertGreaterThanOrEqual(columns, minimum, "At least \(minimum) columns: \(context)")
      XCTAssertEqual(result["stable"] as? Bool, true, "Columns must not flap: \(context)")
      XCTAssertLessThanOrEqual(result["square"] as? Double ?? 1, 0.5, "Tiles must be square: \(context)")
      XCTAssertEqual(result["uniform"] as? Bool, true, "Every tile shares one width: \(context)")
      XCTAssertEqual(result["pageSizeRequests"] as? Int, 0, "The grid never negotiates a page size: \(context)")
      if page == "discover" {
        XCTAssertEqual(result["tiles"] as? Int, 30, "A page shows all 30 tiles: \(context)")
        XCTAssertGreaterThanOrEqual(columns, previous, "Columns never drop as the window widens: \(context)")
        previous = columns
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
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      appLanguage: .english())
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
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      appLanguage: .english())

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

  func testTopBarKeepsTheRepositoryLinkAndNeverOverlapsAtTheMinimumWindowWidth() async throws {
    try await withPanel { panel in
      panel.show()
      try await panel.waitJS("document.querySelector('#app-identity [data-action=\"openExternal\"]') !== null")
      // From the minimum content width up to the default, with a download in flight so the queue button is present too.
      let widths: [Double] = [760, 840, 900, 1040, 1240]
      for width in widths {
        panel.web.setFrameSize(NSSize(width: width, height: 640))
        let layout = try await panel.js("""
          const base = window.powerProbe.received.at(-1);
          const job = { id: 'bar-fixture', wallpaperID: 'bar-fixture', title: 'Bar fixture',
            status: 'Downloading Workshop files…', preview: null, thumbnail: null, account: 'fixture',
            progress: 0.5, pending: true, queued: false, bytesReceived: 1, bytesExpected: 2,
            bytesPerSecond: 1, authenticating: false, cancelled: false, error: null, prompt: null,
            securePrompt: false, challenge: null, warning: null };
          // A real window clears its traffic lights with the same inset the app reports.
          window.wallpaperUI.receive(Object.assign({}, base, { downloads: [job], downloadRequests: [], windowControlsInset: 70 }));
          const bar = document.querySelector('.topbar');
          const barRect = bar.getBoundingClientRect();
          const rect = element => element.getBoundingClientRect();
          const controls = [...bar.querySelectorAll('button, select')].filter(element => element.getClientRects().length);
          const overlaps = [];
          for (let i = 0; i < controls.length; i += 1) for (let j = i + 1; j < controls.length; j += 1) {
            const a = rect(controls[i]), b = rect(controls[j]);
            if (a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5)
              overlaps.push(`${controls[i].textContent || controls[i].getAttribute('aria-label')} × ${controls[j].textContent || controls[j].getAttribute('aria-label')}`);
          }
          const outside = controls.filter(element => rect(element).left < barRect.left - 0.5 || rect(element).right > barRect.right + 0.5)
            .map(element => element.textContent || element.getAttribute('aria-label'));
          const name = document.querySelector('.app-name');
          return {
            width: barRect.width,
            overlaps, outside,
            github: !!document.querySelector('#app-identity [data-action="openExternal"]')?.getClientRects().length,
            queue: !!document.querySelector('#top-actions [data-action="openDownloads"]')?.getClientRects().length,
            nameVisible: !!name && name.getClientRects().length > 0,
          };
          """) as? [String: Any]
        XCTAssertEqual(layout?["width"] as? Double, width, "Top bar must span the panel at \(width)px")
        XCTAssertEqual(layout?["overlaps"] as? [String], [], "Top bar controls must not overlap at \(width)px")
        XCTAssertEqual(layout?["outside"] as? [String], [], "Top bar controls must stay inside the bar at \(width)px")
        XCTAssertEqual(layout?["github"] as? Bool, true, "The repository link stays available at \(width)px")
        XCTAssertEqual(layout?["queue"] as? Bool, true, "The downloads button stays available at \(width)px")
        XCTAssertEqual(
          layout?["nameVisible"] as? Bool, width > 840,
          "Only the repository button stays in the middle of a narrow window; the name returns once there is room (\(width)px)")
      }
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
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      appLanguage: .english())
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
        const prompted = { attention: ring().classList.contains('attention'), passwordField: !!dialog.querySelector('input[type="password"]'),
          guide: !!dialog.querySelector('.dialog-guide') };
        dialog.querySelector('[data-action="dismissDialog"]').click();
        await waitFor(() => !dialog.open);
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: 'Steam password', securePrompt: true })]);
        const dismissedStaysClosed = !dialog.open;
        push([Object.assign({}, job, { progress: null, authenticating: true, prompt: null, challenge: 'mobileApproval', status: 'Approve the sign-in in the Steam mobile app' })]);
        await waitFor(() => dialog.open);
        const guided = { steps: dialog.querySelectorAll('.dialog-steps li').length, icon: !!dialog.querySelector('.dialog-guide-icon svg'),
          noField: !dialog.querySelector('input'), stage: dialog.dataset.stage };
        push([Object.assign({}, job, { progress: null, authenticating: false, status: 'Downloading Workshop files…' })]);
        await waitFor(() => dialog.dataset.stage === 'started');
        const handoff = { open: dialog.open, progress: !!dialog.querySelector('.dialog-guide progress'), status: dialog.querySelector('.dialog-guide [role="status"]')?.textContent.includes('Ring fixture'),
          done: !!dialog.querySelector('.dialog-actions .primary[data-action="dismissDialog"]'), ringBusy: ring().classList.contains('busy') };
        push([Object.assign({}, job, { progress: 0.1, authenticating: false, status: 'Downloading Workshop files…' })]);
        const handoffStays = dialog.open && dialog.dataset.stage === 'started' && Number(dialog.querySelector('.dialog-guide progress').value) > 0;
        dialog.querySelector('.dialog-actions .primary[data-action="dismissDialog"]').click();
        await waitFor(() => !dialog.open);
        push([Object.assign({}, job, { progress: 0.2, authenticating: false, status: 'Downloading Workshop files…' })]);
        const resumed = ring().classList.contains('progress') && !dialog.open;
        push([Object.assign({}, job, { pending: false, progress: null, error: 'Steam denied this download.', status: 'Download could not finish' })]);
        const failed = ring()?.dataset.action === 'downloadRetry' && ring().classList.contains('failed');
        push([], { wallpapers: [{ id: 'ring-fixture', title: 'Ring fixture', kind: 'Video', preview: null, active: false, supported: true, tags: [] }] });
        const installed = { check: !!grid.querySelector('.tile-mark.installed'), noRing: !ring() };
        return { idle, progress, authenticating, prompted, dismissedStaysClosed, guided, handoff, handoffStays, resumed, failed, installed };
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
      prompted?["guide"] as? Bool, false, "A password request shows only the field, no guide card")
    let guided = result?["guided"] as? [String: Any]
    XCTAssertEqual(guided?["stage"] as? String, "auth")
    XCTAssertGreaterThanOrEqual(
      guided?["steps"] as? Int ?? 0, 3,
      "Mobile approval lists the phone steps, including what to answer Steam")
    XCTAssertEqual(guided?["icon"] as? Bool, true)
    XCTAssertEqual(guided?["noField"] as? Bool, true, "Mobile approval asks for nothing to type")
    let handoff = result?["handoff"] as? [String: Any]
    XCTAssertEqual(
      handoff?["open"] as? Bool, true,
      "Once Steam is satisfied the dialog confirms the download instead of vanishing")
    XCTAssertEqual(handoff?["progress"] as? Bool, true, "The confirmation carries live progress")
    XCTAssertEqual(handoff?["status"] as? Bool, true, "The confirmation names the wallpaper")
    XCTAssertEqual(handoff?["done"] as? Bool, true, "Done is the primary way out")
    XCTAssertEqual(handoff?["ringBusy"] as? Bool, true, "The tile reports meanwhile")
    XCTAssertEqual(
      result?["handoffStays"] as? Bool, true,
      "Later progress updates the confirmation instead of closing it")
    XCTAssertEqual(
      result?["resumed"] as? Bool, true,
      "After Done the dialog stays closed and the tile keeps reporting")
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
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      appLanguage: .english())
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

  func testDiscoverTilesRevealTheAnimatedPreviewOnlyWhileItIsBrightWithoutWindow() async throws {
    let fixture = makeStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-live-\(UUID().uuidString)")
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer {
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
    let bright = try Self.gif(frames: 3, brightness: 0.9)
    let black = try Self.gif(frames: 9, brightness: 0, closing: 0.9)
    let still = try Self.gif(frames: 1, brightness: 0.9)
    // One download yields both the still and the animation. `b` is black but for one brief
    // closing frame, which the still pass picks: a bright still over an animation that reads black. `c`'s still arrives last; no animation may start before it.
    let fetcher = PreviewFetcher(delay: { $0.path.contains("/c/") ? .milliseconds(400) : .zero }) { url in
      if url.path.contains("/c/") { return still }
      if url.path.contains("/b/") { return black }
      return bright
    }
    let assets = WebPanelAssets(
      thumbnailCache: WorkshopThumbnailCache(
        directory: root.appendingPathComponent("thumbs"), fetcher: fetcher))
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = WebPanelController(
      store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop,
      assets: assets, appLanguage: .english())
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
    assets.thumbnails = [
      "a": try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/a/preview/")),
      "b": try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/b/preview/")),
      "c": try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/c/preview/")),
    ]

    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async (predicate, what) => {
          const deadline = Date.now() + 10000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error(`Timed out: ${what}`);
            await new Promise(resolve => setTimeout(resolve, 25));
          }
        };
        const item = id => ({ id, title: `Tile ${id}`, creator: 'Test', summary: '', preview: `https://images.steamusercontent.com/ugc/${id}/preview/`,
          thumbnail: `mwe-ui://thumbnail/${id}`, animated: `mwe-ui://animated/${id}`, tags: ['Scene'], size: 1, subscriptions: 0, kind: 'Scene' });
        const grid = document.getElementById('wallpaper-grid');
        // Records, for every animation layer the moment it is inserted, whether every still on the page had settled.
        const insertions = [];
        new MutationObserver(records => { for (const record of records) for (const node of record.addedNodes) {
          for (const live of node.nodeType === 1 ? [...(node.matches('img.tile-live') ? [node] : node.querySelectorAll('img.tile-live'))] : []) {
            const stills = [...grid.querySelectorAll('img.tile-still')];
            insertions.push(stills.length === 3 && stills.every(still => still.complete && still.naturalWidth > 0));
          } } }).observe(grid, { childList: true, subtree: true });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'discover',
          workshop: Object.assign({}, base.workshop, { items: [item('a'), item('b'), item('c')], loaded: true }), downloads: [], downloadRequests: [] }));
        const tile = id => grid.querySelector(`.wallpaper-tile[data-key="${id}"]`);
        const stillOf = id => tile(id)?.querySelector('img.tile-still');
        const liveOf = id => tile(id)?.querySelector('img.tile-live');
        const diagnose = () => ['a', 'b', 'c'].map(id => `${id}: still=${stillOf(id)?.complete}/${stillOf(id)?.naturalWidth} live=${!!liveOf(id)}/${liveOf(id)?.complete}/${liveOf(id)?.naturalWidth} playing=${tile(id)?.classList.contains('playing')}`).join('; ');
        try {
          await waitFor(() => ['a', 'b', 'c'].every(id => stillOf(id)?.complete && stillOf(id).naturalWidth > 0), 'stills to load');
          await waitFor(() => tile('a')?.classList.contains('playing'), 'the bright animation to play');
          await waitFor(() => liveOf('b')?.complete && liveOf('b').naturalWidth > 0, 'the black animation to arrive');
        } catch (error) { return { error: `${error.message} — ${diagnose()}` }; }
        await new Promise(resolve => setTimeout(resolve, 700));
        return {
          stillsFirst: insertions.length >= 2 && insertions.every(Boolean),
          eagerStills: ['a', 'b', 'c'].every(id => stillOf(id).loading !== 'lazy'),
          aPlaying: tile('a').classList.contains('playing'), aStillKept: !!stillOf('a'),
          bLoaded: !!liveOf('b'), bPlaying: tile('b').classList.contains('playing'),
          cLive: !!liveOf('c'), cStill: !!stillOf('c'),
        };
        """, arguments: ["base": base], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertNil(result?["error"], (result?["error"] as? String) ?? "")
    XCTAssertEqual(
      result?["stillsFirst"] as? Bool, true,
      "No animation starts before every still on the page has arrived")
    XCTAssertEqual(result?["eagerStills"] as? Bool, true, "Discover stills are not lazy-loaded")
    XCTAssertEqual(result?["aPlaying"] as? Bool, true, "A bright animation replaces its still")
    XCTAssertEqual(result?["aStillKept"] as? Bool, true, "The still stays underneath for the dark loops")
    XCTAssertEqual(result?["bLoaded"] as? Bool, true, "The black animation loads beneath its still")
    XCTAssertEqual(
      result?["bPlaying"] as? Bool, false, "A black animation never replaces a bright still")
    XCTAssertEqual(result?["cLive"] as? Bool, false, "A single-frame preview gets no animation layer")
    XCTAssertEqual(result?["cStill"] as? Bool, true)
    XCTAssertEqual(
      Set(fetcher.requests).count, fetcher.requests.count,
      "Each preview is downloaded once: its still and its animation share the bytes")
    XCTAssertEqual(fetcher.requests.count, 3)
    XCTAssertNil(web.window, "This regression must not open a desktop window")
    await workshop.steamCMDSetup.shutdown()
  }

  /// `closing`, when given, is the brightness of a last frame shown for a fiftieth of a second
  /// between seconds-long frames of `brightness`.
  private static func gif(frames: Int, brightness: Double, closing: Double? = nil) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames, nil))
    for frame in 0..<frames {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(gray: frame == frames - 1 ? closing ?? brightness : brightness, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      let delay = closing == nil ? 0.1 : frame == frames - 1 ? 0.02 : 1.0
      let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
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
      isPresentationVisible: { visibility.visible }, displayTitles: displayTitles,
      appLanguage: .english())
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

private final class PreviewFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
  private let lock = NSLock()
  private let respond: @Sendable (URL) throws -> Data
  private let delay: @Sendable (URL) -> Duration
  private var recorded: [URL] = []
  var requests: [URL] { lock.withLock { recorded } }

  init(
    delay: @escaping @Sendable (URL) -> Duration = { _ in .zero },
    respond: @escaping @Sendable (URL) throws -> Data
  ) {
    self.delay = delay
    self.respond = respond
  }

  func fetch(_ url: URL) async throws -> Data {
    lock.withLock { recorded.append(url) }
    let wait = delay(url)
    if wait > .zero { try await Task.sleep(for: wait) }
    return try respond(url)
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
