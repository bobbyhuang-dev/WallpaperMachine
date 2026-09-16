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
        return {page:state.page, visible:!document.getElementById('settings-content').hidden,
                tabs:[...document.querySelectorAll('.tabs [data-page]')].map(x=>x.textContent.trim())};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(result?["page"] as? String, "settings")
    XCTAssertEqual(result?["visible"] as? Bool, true)
    XCTAssertEqual(navigation.selection, .settings)
    XCTAssertEqual(result?["tabs"] as? [String], ["Discover", "Installed", "Settings"])
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
    XCTAssertEqual(indeterminate?["activityProgress"] as? Bool, true, "Activity bar must render a valueless progress bar while pending")
    XCTAssertEqual(indeterminate?["queueProgress"] as? Bool, true, "Queue row must render a valueless progress bar while pending")
    XCTAssertEqual(indeterminate?["rate"] as? Bool, true, "Both surfaces must show the measured network speed")
    XCTAssertEqual(indeterminate?["noPercentOrBytes"] as? Bool, true, "Workshop downloads must not report percentage or byte totals")
    XCTAssertEqual(result?["zeroRate"] as? Bool, true, "A measured idle rate must render as 0 B/s")
    XCTAssertEqual(result?["noRate"] as? Bool, true, "An unavailable rate must be omitted, not shown as zero")
    XCTAssertEqual(result?["validating"] as? Bool, true, "The validating phase must show its status without a network speed")
    XCTAssertEqual(result?["byteProgress"] as? Bool, true, "Explicit app-update bytes may still drive determinate progress")
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

  override func allSnapshots() async throws -> BridgeSnapshotBundle {
    guard let snapshot else { throw CancellationError() }
    return snapshot
  }
}

private struct UnavailableRuntime: SteamCMDRuntimeProviding {
    func resolve(executable: URL) throws -> SteamCMDRuntime { throw WorkshopFailure(message: "fixture") }
    func validateBootstrap(at root: URL) async throws { throw WorkshopFailure(message: "fixture") }
    func prepare(executable: URL, staging: URL) async throws -> URL { throw WorkshopFailure(message: "fixture") }
    func validate(at root: URL) async throws { throw WorkshopFailure(message: "fixture") }
}
