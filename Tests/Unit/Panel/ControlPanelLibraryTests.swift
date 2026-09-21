import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import MacWallpaperEngine

/// Installed page: sorting, tile marks, filter sidebar, download setup and error dismissal.
@MainActor
final class ControlPanelLibraryTests: ControlPanelTestCase {
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
    XCTAssertEqual(
      installed?["boxes"] as? Int, 5 + 3 + 3 + 25,
      "Installed has Discover's boxes: Show only (plus Favorites and Active), Type, Age rating and Tags; no Resolution or category, which a manifest cannot tell")
    XCTAssertEqual(
      installed?["unchecked"] as? [String], ["Favorite", "Active", "Approved", "Audio responsive", "Customizable"],
      "Only the Show only boxes start unticked: a library hides nothing by default")
    XCTAssertEqual(installed?["selects"] as? Int, 0, "No type menu on Installed either")
    XCTAssertNil(installed?["filterCount"] as? String)
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

  /// Installed's sidebar filters the library with Discover's rules: a ticked Show only box
  /// requires its tag (Favorites and Active on top of Steam's three), an unticked box
  /// excludes wallpapers carrying that tag, the type boxes read the wallpaper's kind, a
  /// wallpaper without a genre counts as Unspecified, and Clear puts every box back.
  func testInstalledFiltersTheLibraryWithDiscoverBoxesWithoutWindow() async throws {
    try await withPanel { panel in
      panel.show()
      try await panel.waitJS("powerProbe.received.length >= 1")
      let result = try await panel.js("""
        const base = window.powerProbe.received.at(-1);
        const wallpaper = (id, kind, tags, approved = false) => ({ id, title: id, kind, tags, approved, preview: null, active: false, supported: true, size: 1, addedAt: 1 });
        const wallpapers = [
          wallpaper('anime', 'Scene', ['anime', 'Everyone', 'Audio responsive'], true),
          wallpaper('nature', 'Video', ['Nature', 'Mature']),
          wallpaper('plain', 'Web', ['Everyone', 'Customizable']),
          wallpaper('bare', 'Unknown', []),
        ];
        const display = Object.assign({}, base.displays[0], { wallpaperID: 'nature' });
        window.wallpaperUI.receive(Object.assign({}, base, { page: 'installed', wallpapers, favorites: ['plain'], displays: [display], targetDisplayID: display.id }));
        const sidebar = document.getElementById('filter-sidebar');
        const titles = () => [...document.querySelectorAll('.tile-title')].map(node => node.textContent);
        const box = value => sidebar.querySelector(`input[value="${value}"]`);
        const tick = (value, on) => { const input = box(value); input.checked = on; input.dispatchEvent(new Event('change', { bubbles: true })); };
        const count = () => document.querySelector('.browser-toolbar .filter-count')?.textContent ?? null;
        const result = { all: titles(), groups: [...sidebar.querySelectorAll('.filter-group summary')].map(node => node.textContent.trim()) };
        tick('Favorite', true); result.favorites = titles(); result.favoritesCount = count();
        tick('Favorite', false); tick('Active', true); result.active = titles();
        tick('Active', false); tick('Approved', true); result.approved = titles();
        tick('Approved', false); tick('Audio responsive', true); result.audio = titles();
        tick('Audio responsive', false); tick('Customizable', true); result.customizable = titles();
        tick('Customizable', false); tick('Anime', false); result.noAnime = titles();
        tick('Unspecified', false); result.noUnspecified = titles(); result.noneCount = count();
        document.querySelector('.filter-heading [data-action="clearInstalled"]').click();
        result.cleared = titles(); result.clearedCount = count();
        tick('Mature', false); result.noMature = titles();
        tick('Video', false); tick('Web', false); result.noVideoWeb = titles();
        sidebar.querySelector('.filter-section[data-key="genre"] [data-action="excludeSection"]').click();
        result.noGenre = titles();
        document.querySelector('.filter-heading [data-action="clearInstalled"]').click();
        document.getElementById('wallpaper-search').value = 'nat';
        document.getElementById('wallpaper-search').dispatchEvent(new Event('input', { bubbles: true }));
        result.searched = titles();
        return result;
        """) as? [String: Any]
      XCTAssertEqual(result?["all"] as? [String], ["anime", "bare", "nature", "plain"], "Nothing is hidden by default")
      XCTAssertEqual(result?["groups"] as? [String], ["Show only", "Type", "Age rating", "Tags"], "Discover's groups minus Resolution")
      XCTAssertEqual(result?["favorites"] as? [String], ["plain"], "Favorites is a Show only box")
      XCTAssertEqual(result?["favoritesCount"] as? String, "1")
      XCTAssertEqual(result?["active"] as? [String], ["nature"], "So is Active on target display")
      XCTAssertEqual(result?["approved"] as? [String], ["anime"], "Approved reads the snapshot's approval")
      XCTAssertEqual(result?["audio"] as? [String], ["anime"], "Audio responsive and Customizable read the manifest tags")
      XCTAssertEqual(result?["customizable"] as? [String], ["plain"])
      XCTAssertEqual(result?["noAnime"] as? [String], ["bare", "nature", "plain"], "Unticking a tag hides wallpapers carrying it, whatever its case")
      XCTAssertEqual(result?["noUnspecified"] as? [String], ["nature"], "A wallpaper without a genre is Unspecified")
      XCTAssertEqual(result?["noneCount"] as? String, "2", "Each unticked box counts as one active filter")
      XCTAssertEqual(result?["cleared"] as? [String], ["anime", "bare", "nature", "plain"], "Clear ticks every box again")
      XCTAssertNil(result?["clearedCount"] as? String)
      XCTAssertEqual(result?["noMature"] as? [String], ["anime", "bare", "plain"], "Age rating reads the manifest's content rating")
      XCTAssertEqual(result?["noVideoWeb"] as? [String], ["anime", "bare"], "Type boxes read the kind; a kind Steam has no box for stays")
      XCTAssertEqual(result?["noGenre"] as? [String], [], "None on Tags hides every wallpaper, Unspecified included")
      XCTAssertEqual(result?["searched"] as? [String], ["nature"], "Search still narrows by title and tags")
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
      defaults: defaults,
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
}
