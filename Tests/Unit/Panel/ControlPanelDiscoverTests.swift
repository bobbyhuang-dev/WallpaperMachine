import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import MacWallpaperEngine

/// Discover page: pagination, grid columns, download rings, telemetry and animated previews.
@MainActor
final class ControlPanelDiscoverTests: ControlPanelTestCase {
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
        push([Object.assign({}, job, { progress: null, bytesPerSecond: null, authenticating: true, phase: 'signingIn', status: 'Waiting for Steam authentication…' })]);
        const phased = { busy: ring().classList.contains('busy'), word: ring().querySelector('.ring-label.ring-phase')?.textContent.trim(), phase: ring().dataset.phase, noSpeed: !ring().querySelector('.ring-speed') };
        push([Object.assign({}, job, { progress: 1, bytesPerSecond: null, authenticating: false, phase: 'finishing', status: 'Validating and adding to your library…' })]);
        const finishing = { progress: ring().classList.contains('progress'), word: ring().querySelector('.ring-label').textContent.trim(), full: Number(ring().querySelector('.ring-value').getAttribute('stroke-dashoffset')) === 0 };
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
        return { idle, progress, authenticating, phased, finishing, prompted, dismissedStaysClosed, guided, handoff, handoffStays, resumed, failed, installed };
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
    let phased = result?["phased"] as? [String: Any]
    XCTAssertEqual(phased?["busy"] as? Bool, true)
    XCTAssertEqual(
      phased?["word"] as? String, "Signing in",
      "Before bytes move the ring names the SteamCMD step instead of spinning empty")
    XCTAssertEqual(phased?["phase"] as? String, "signingIn")
    XCTAssertEqual(phased?["noSpeed"] as? Bool, true)
    let finishing = result?["finishing"] as? [String: Any]
    XCTAssertEqual(finishing?["progress"] as? Bool, true)
    XCTAssertEqual(finishing?["full"] as? Bool, true, "The ring stays full while the files are validated")
    XCTAssertEqual(
      finishing?["word"] as? String, "Finishing",
      "Validation and import read as a step, not a frozen 100%")
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
}
