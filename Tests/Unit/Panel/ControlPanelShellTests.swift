import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import WallpaperMachine

/// Window sizing, bundled asset routing, language, appearance, About/update and the top bar.
@MainActor
final class ControlPanelShellTests: ControlPanelTestCase {
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
    let defaultsName = "ControlPanelShellTests.\(UUID().uuidString)"
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
      store: fixture.store, navigation: navigation, workshop: workshop,
      defaults: defaults, appLanguage: .english())
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
      defaults: defaults,
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
      defaults: defaults,
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
      defaults: defaults,
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
      defaults: defaults,
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
      XCTAssertEqual(link?["title"] as? String, "WallpaperMachine")
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
        // The frame change reaches the page asynchronously. Measuring straight
        // after setting it reads the previous layout, which is why this only
        // ever failed on a busy machine and always by a whole reflow.
        try await panel.waitJS("Math.round(window.innerWidth) === \(Int(width))")
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

  /// The first-run guide covers the whole window and walks five pages: language and appearance
  /// (applied at once, put back by Skip), Steam sign-in (a real sign-in-only session whose
  /// password prompt is answered from the form), preferences (drafts committed by Continue),
  /// tips with the GitHub links, and the closing choice. It is shown on its own once per Mac and
  /// again from Settings.
  func testFirstRunGuideCoversTheWindowWalksFivePagesAndReturnsFromSettings() async throws {
    try await withPanel { panel in
      XCTAssertFalse(panel.controller.welcomeSeen, "A fresh install has not seen the guide")
      XCTAssertEqual(panel.controller.snapshot()["welcomeSeen"] as? Bool, false)
      panel.show()
      try await panel.waitJS("!document.getElementById('welcome').hidden && !!document.querySelector('#welcome .welcome-page')")
      let first = try await panel.js("""
        const region = document.getElementById('welcome');
        const rect = region.getBoundingClientRect();
        const style = getComputedStyle(region);
        return {
          step: region.querySelector('.welcome-page').dataset.step,
          covers: style.position === 'fixed' && rect.width === window.innerWidth && rect.height === window.innerHeight,
          background: style.backgroundColor,
          theme: document.documentElement.dataset.theme,
          title: region.querySelector('#welcome-title').textContent,
          languages: [...region.querySelectorAll('[data-action="language"]')].map(b => b.dataset.value),
          themes: [...region.querySelectorAll('[data-action="theme"]')].map(b => b.dataset.value),
          checked: [...region.querySelectorAll('[aria-checked="true"]')].map(b => `${b.dataset.action}:${b.dataset.value}`),
          steps: region.querySelectorAll('.welcome-progress li').length,
          modal: document.querySelectorAll('dialog[open]').length,
          focusedTitle: document.activeElement === region.querySelector('#welcome-title'),
        };
        """) as? [String: Any]
      XCTAssertEqual(first?["step"] as? String, "language")
      XCTAssertEqual(first?["covers"] as? Bool, true, "The guide covers the whole window, top bar included")
      XCTAssertEqual(
        first?["background"] as? String, first?["theme"] as? String == "dark" ? "rgb(0, 0, 0)" : "rgb(255, 255, 255)",
        "Black or white by the resolved appearance, never translucent")
      XCTAssertEqual(first?["title"] as? String, "Welcome to WallpaperMachine")
      XCTAssertEqual(first?["languages"] as? [String], ["system"] + AppLanguage.supported.map(\.tag))
      XCTAssertEqual(first?["themes"] as? [String], ["system", "light", "dark"])
      XCTAssertEqual(first?["checked"] as? [String], ["language:system", "theme:system"], "Defaults are selected")
      XCTAssertEqual(first?["steps"] as? Int, 5)
      XCTAssertEqual(first?["modal"] as? Int, 0, "The guide is a page, not a modal dialog")
      XCTAssertEqual(first?["focusedTitle"] as? Bool, true, "Focus lands on the page title")

      // A choice applies at once; Skip puts the opening values back and moves on.
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"theme\"][data-value=\"dark\"]').click();")
      try await panel.waitUntil { panel.theme.preferences.mode == .dark }
      try await panel.waitJS("document.documentElement.dataset.themeMode === 'dark' && document.querySelector('#welcome [data-action=\"theme\"][data-value=\"dark\"]').getAttribute('aria-checked') === 'true'")
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"skipLanguage\"]').click();")
      try await panel.waitUntil { panel.theme.preferences.mode == .system }
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'steam'")

      // Steam: the two links the requirement implies, plain validation, then a real sign-in.
      //
      // Settle first. The count below is latched and then read 50 ms later, so
      // a snapshot already in flight when it was latched lands inside that
      // window and is indistinguishable from one the submit caused — which is
      // what made this assertion fail whenever the machine was busy enough to
      // delay an unrelated push into it.
      try await panel.quiet()
      let steam = try await panel.js("""
        const region = document.getElementById('welcome');
        const links = [...region.querySelectorAll('.welcome-steam-links [data-action="openExternal"]')].map(link => link.dataset.url);
        const before = window.powerProbe.received.length;
        region.querySelector('form[data-form="signIn"]').requestSubmit();
        await new Promise(resolve => setTimeout(resolve, 50));
        return {
          links,
          fields: ['welcome-account', 'welcome-password'].map(id => document.getElementById(id)?.type),
          remember: region.querySelector('input[name="remember"]').checked,
          error: region.querySelector('form .notice.error')?.textContent || '',
          snapshots: window.powerProbe.received.length - before,
          skip: !!region.querySelector('[data-action="skipSteam"]'),
        };
        """) as? [String: Any]
      let links = try XCTUnwrap(steam?["links"] as? [String])
      XCTAssertEqual(links.count, 2, "Register and buy: the two links the Steam requirement implies")
      for link in links {
        let url = try XCTUnwrap(URL(string: link))
        XCTAssertTrue(WebPanelController.allowedExternalURL(url), "\(link) must pass the external allowlist")
      }
      XCTAssertTrue(links.contains { $0.contains("/join") }, "One link registers a Steam account")
      XCTAssertTrue(links.contains { $0.contains("/app/431960") }, "One link buys Wallpaper Engine")
      XCTAssertEqual(steam?["fields"] as? [String], ["text", "password"])
      XCTAssertEqual(steam?["remember"] as? Bool, true, "Keep me signed in is on by default")
      XCTAssertFalse((steam?["error"] as? String ?? "").isEmpty, "An empty account is refused before anything reaches native")
      XCTAssertEqual(steam?["snapshots"] as? Int, 0)
      XCTAssertEqual(steam?["skip"] as? Bool, true, "Signing in is optional")

      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil(timeout: 5) { panel.workshop.steamCMDSetup.selectedRuntime != nil }
      try await panel.waitJS("document.querySelector('#welcome form[data-form=\"signIn\"] button[type=\"submit\"] .button-label')?.textContent === 'Sign in'")
      _ = try await panel.js("""
        const region = document.getElementById('welcome');
        const account = region.querySelector('#welcome-account');
        account.value = 'LocalTest';
        account.dispatchEvent(new Event('input', { bubbles: true }));
        region.querySelector('#welcome-password').value = 'hunter2-secret';
        region.querySelector('form[data-form="signIn"]').requestSubmit();
        """)
      let job = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 10) { !job.isPending }
      XCTAssertNil(job.errorMessage, "The sign-in-only session succeeds")
      XCTAssertEqual(
        try String(contentsOf: panel.root.appendingPathComponent("password"), encoding: .utf8), "hunter2-secret",
        "The password typed into the guide answers Steam's own prompt")
      try await panel.waitJS("!!document.querySelector('#welcome .welcome-status.success')")
      let signedIn = try await panel.js("""
        const region = document.getElementById('welcome');
        return {
          title: region.querySelector('.welcome-status.success .welcome-status-title').textContent,
          dialog: document.querySelectorAll('dialog[open]').length,
          passwordField: !!document.getElementById('welcome-password'),
          continueLabel: region.querySelector('.welcome-footer .primary .button-label')?.textContent,
          queue: !!document.querySelector('#top-actions [data-action="openDownloads"]'),
        };
        """) as? [String: Any]
      XCTAssertEqual(signedIn?["title"] as? String, "Signed in as localtest")
      XCTAssertEqual(signedIn?["dialog"] as? Int, 0, "The guide answers the prompt itself; the download dialog stays closed")
      XCTAssertEqual(signedIn?["passwordField"] as? Bool, false, "The password field is gone with the form")
      XCTAssertEqual(signedIn?["continueLabel"] as? String, "Continue")
      XCTAssertEqual(signedIn?["queue"] as? Bool, false, "A finished sign-in is not listed as a download")

      // Preferences are drafts: nothing reaches native until Continue.
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"continue\"]').click();")
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'preferences'")
      panel.bridge.bundleProvider = {
        BridgeSnapshotBundle(
          app: panel.store.appSnapshot, library: panel.store.librarySnapshot, wallpaperOptions: nil,
          monitorInformation: panel.store.monitorInformationSnapshot, settings: panel.store.settingsSnapshot)
      }
      let preferences = try await panel.js("""
        const region = document.getElementById('welcome');
        region.querySelector('input[data-pref="pauseOnBattery"]').click();
        await new Promise(resolve => setTimeout(resolve, 30));
        return { prefs: region.querySelectorAll('input[data-pref]').length, checked: region.querySelector('input[data-pref="pauseOnBattery"]').checked };
        """) as? [String: Any]
      XCTAssertEqual(preferences?["prefs"] as? Int, 4)
      XCTAssertEqual(preferences?["checked"] as? Bool, true)
      XCTAssertEqual(panel.bridge.pauseOnBatteryCalls, [], "Toggling a switch is a draft")
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"savePreferences\"]').click();")
      try await panel.waitUntil { panel.bridge.pauseOnBatteryCalls == [true] }
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'tips'")

      // Tips point at GitHub through the same allowlist as every other link.
      let tips = try await panel.js("""
        const region = document.getElementById('welcome');
        const github = [...region.querySelectorAll('.welcome-github [data-action="openExternal"]')].map(link => link.dataset.url);
        return { tips: region.querySelectorAll('.welcome-tips li').length, github };
        """) as? [String: Any]
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"continue\"]').click();")
      try await panel.waitJS("document.querySelector('#welcome .welcome-page')?.dataset.step === 'start'")
      let start = try await panel.js("""
        const region = document.getElementById('welcome');
        return { step: region.querySelector('.welcome-page').dataset.step, recap: [...region.querySelectorAll('.welcome-recap dd')].map(node => node.textContent) };
        """) as? [String: Any]
      XCTAssertEqual(tips?["tips"] as? Int, 5)
      let github = try XCTUnwrap(tips?["github"] as? [String])
      XCTAssertEqual(github.count, 2, "Repository and issue tracker")
      for link in github {
        let url = try XCTUnwrap(URL(string: link))
        XCTAssertEqual(url.host, "github.com", link)
        XCTAssertTrue(WebPanelController.allowedExternalURL(url), "\(link) must pass the external allowlist")
      }
      XCTAssertEqual(start?["step"] as? String, "start")
      XCTAssertEqual(start?["recap"] as? [String], ["System (Auto)", "System (Auto)", "Signed in as localtest"])

      // The closing choice puts the guide away, tells native, and lands on Discover.
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"browse\"]').click();")
      try await panel.waitUntil { panel.controller.welcomeSeen && panel.navigation.selection == .workshop }
      XCTAssertTrue(panel.defaults.bool(forKey: WebPanelController.welcomeSeenKey), "The choice is stored")
      try await panel.waitJS("document.getElementById('welcome').hidden")
      try await panel.quiet()
      try await panel.expectJS(
        """
        const base = window.powerProbe.received.at(-1);
        window.wallpaperUI.receive(Object.assign({}, base, { welcomeSeen: true }));
        return document.getElementById('welcome').hidden;
        """, equals: true)
      XCTAssertNil(panel.controller.actionError)

      // A relaunch with the same defaults never shows it on its own again.
      let relaunched = WebPanelController(
        store: panel.store, navigation: ControlPanelNavigation(), workshop: panel.workshop,
        theme: panel.theme, defaults: panel.defaults, appLanguage: .english())
      XCTAssertTrue(relaunched.welcomeSeen)
      XCTAssertEqual(relaunched.snapshot()["welcomeSeen"] as? Bool, true)

      // Settings → Library & Steam brings it back from the first page; finishing it then asks native nothing.
      let replay = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'settings', welcomeSeen: true }));
        document.querySelector('#settings-content [data-section="library"]').click();
        const button = document.querySelector('#settings-content [data-action="openWelcome"]');
        button.click();
        const region = document.getElementById('welcome');
        const reopened = !region.hidden && region.querySelector('.welcome-page').dataset.step === 'language';
        const before = window.powerProbe.received.length;
        region.querySelector('[data-action="go"][data-step="4"]').click();
        const last = region.querySelector('.welcome-page').dataset.step;
        region.querySelector('[data-action="finish"]').click();
        await new Promise(resolve => setTimeout(resolve, 150));
        return { hasButton: !!button, reopened, last, closed: region.hidden, snapshots: window.powerProbe.received.length - before };
        """) as? [String: Any]
      XCTAssertEqual(replay?["hasButton"] as? Bool, true, "Library & Steam offers the guide again")
      XCTAssertEqual(replay?["reopened"] as? Bool, true)
      XCTAssertEqual(replay?["last"] as? String, "start", "The step indicator jumps between pages")
      XCTAssertEqual(replay?["closed"] as? Bool, true)
      XCTAssertEqual(replay?["snapshots"] as? Int, 0, "An already-seen guide closes without another round trip")
    }
  }

}
