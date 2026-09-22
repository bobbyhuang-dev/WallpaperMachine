import AppKit
import WebKit
import XCTest

@testable import WallpaperMachine

/// Authored labels retain presentation without gaining panel privileges. Plain
/// names remain available to native pickers and unnamed controls never expose ids.
@MainActor
final class WebPanelPropertyLabelTests: XCTestCase {
  func testAuthorMarkupIsReducedToTheWordsItCarries() throws {
    let context = try Context()
    defer { context.tearDown() }
    let labels = [
      "tinted": "<font color=red>图1自定义",
      "linked":
        "<center><big><b>Bilibili<br/><a href='https://space.bilibili.com/676093670'>和仓贤一的个人主页 (点击跳转)</a><big></p>",
      "padded": "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp镜头位置X（默认0）<br/>",
      "escaped": "&amp;lt;b&amp;gt; stays text",
      "strip":
        "<img src=\"http://photogz.photo.store.qq.com/psc?/V12uhwIt3z28yp/bqQ!/b&bo=HgEIAA!&rf=viewer_4\" width=\"2000\" height=\"1\">",
      "rule": "<hr>",
      "scheme": "ui_browse_properties_scheme_color",
    ]
    context.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "scene-1", kind: .projectScene,
      properties: labels.keys.sorted().map { Self.property(id: $0, labelHtml: labels[$0] ?? "") })

    let rows = try XCTUnwrap(
      (context.controller.snapshot()["options"] as? [String: Any])?["properties"]
        as? [[String: Any]])
    let label = { (id: String) in rows.first { $0["id"] as? String == id }?["label"] as? String }

    XCTAssertEqual(label("tinted"), "图1自定义", "A colour tag is styling, not part of the name")
    XCTAssertEqual(
      label("linked"), "Bilibili 和仓贤一的个人主页 (点击跳转)",
      "A line break separates words rather than gluing them into one run")
    XCTAssertEqual(
      label("padded"), "镜头位置X（默认0）",
      "Indent entities — with or without the semicolon the author forgot — are whitespace")
    XCTAssertEqual(
      label("escaped"), "&lt;b&gt; stays text",
      "An escaped ampersand is decoded once, so escaped markup cannot come back as markup")
    XCTAssertEqual(
      label("strip"), "", "An image strip is decoration: it carries no word to show")
    XCTAssertEqual(label("rule"), "", "Nor does a rule")
    XCTAssertNotEqual(
      label("scheme"), "ui_browse_properties_scheme_color",
      "The editor's own token for the scheme colour must never reach the user")
    XCTAssertFalse(label("scheme")?.isEmpty ?? true)
  }

  func testPagePreservesPresentationAndRejectsAuthorControls() async throws {
    let context = try Context()
    defer { context.tearDown() }
    let web = context.controller.makeWebView()
    web.setFrameSize(NSSize(width: 960, height: 640))
    let deadline = Date().addingTimeInterval(15)
    while !context.controller.isReady && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(context.controller.isReady)
    guard context.controller.isReady else { return }
    let ready =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    let payload = try XCTUnwrap(ready)
    context.controller.stop()

    // The id an author ends up with when the editor slugs an image tag into a key.
    let slug = "imgsrchttpphotogzphotostoreqqcompscv12uhwit3z28ypviewer_4width2000height51"
    let result =
      try await web.callAsyncJavaScript(
        """
        const waitFor = async predicate => {
          const deadline = Date.now() + 5000;
          while (!predicate()) {
            if (Date.now() > deadline) throw new Error('The inspector did not settle');
            await new Promise(resolve => setTimeout(resolve, 20));
          }
        };
        const property = (id, kind, label) => ({
          id, kind, label, value: kind === 'boolean' ? true : '', defaultValue: null,
          enabled: true, dirty: false, min: 0, max: 1, step: 0.01, options: [] });
        const show = properties => window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'installed', selectedID: 'scene-1',
          wallpapers: [{ id: 'scene-1', title: 'Scene one', kind: 'Scene', preview: null, active: false, supported: true, tags: [] }],
          options: { id: 'scene-1', kind: 'Scene', supported: true, dirty: false, volume: 1, muted: false,
            audioResponseEnabled: true, mediaIntegrationEnabled: false, displays: [], properties } }));
        const field = id => document.querySelector(`#inspector [data-key="${id}"]`);
        const section = () => [...document.querySelectorAll('#inspector summary')]
          .some(node => node.textContent.includes('Wallpaper properties'));

        show([property(slug, 'boolean', ''), property('deco', 'text', ''), property('real', 'slider', 'Character size')]);
        await waitFor(() => field('real'));
        const named = field(slug).querySelector('.field-title label');
        const mixed = {
          unnamedText: named.textContent,
          unnamedMentionsSlug: field(slug).textContent.includes(slug),
          unnamedControls: named.getAttribute('for') === field(slug).querySelector('input').id,
          wordlessTextRow: field('deco') !== null,
          namedRow: field('real').querySelector('.field-title label').textContent,
          section: section(),
        };

        show([property('deco', 'text', '')]);
        await waitFor(() => !field('real'));
        const decorationOnlySection = section();
        const rich = property('rich', 'boolean', 'Character');
        rich.labelHTML = '<h3>人物<br>Character</h3><font color="red">Tint</font><script>window.injected = true</script><input data-action="delete"><img src="https://evil.test/x" onerror="window.injected = true"><svg onload="window.injected = true"></svg><a href="javascript:alert(1)">Unsafe</a>';
        const art = property('art', 'text', '');
        art.labelHTML = '<center><a href="https://space.bilibili.com/111174060/"><img src="https://i.ibb.co/example/image.gif" width="105%" onerror="alert(1)"></a></center><hr>';
        art.labelImages = { 'https://i.ibb.co/example/image.gif': 'mwe-ui://property-image/' + 'a'.repeat(64) };
        const escaped = property('escaped', 'text', '<img src=x onerror=alert(1)>');
        const heading = property('heading', 'text', 'Effect settings');
        heading.labelHTML = '<h3>Effect settings</h3><a><h5>Instructions</h5></a>';
        show([rich, art, escaped, heading]);
        await waitFor(() => field('rich'));
        const label = field('rich').querySelector('.property-label');
        const image = field('art').querySelector('img');
        const link = field('art').querySelector('[data-action="openExternal"]');
        return Object.assign(mixed, {
          decorationOnlySection,
          heading: label.querySelector('h3')?.textContent,
          lineBreaks: label.querySelectorAll('br').length,
          color: label.querySelector('font')?.getAttribute('color'),
          injected: Boolean(window.injected),
          unsafeElements: label.querySelectorAll('script, input, svg, [onerror], [data-action]').length,
          escapedText: field('escaped').textContent,
          escapedImages: field('escaped').querySelectorAll('img').length,
          imageSource: image?.getAttribute('src'),
          imageWidth: image?.getAttribute('width'),
          authorRule: Boolean(field('art').querySelector('hr')),
          authorLink: link?.dataset.url,
          linkIsKeyboardControl: link?.tagName === 'BUTTON' && link.type === 'button',
          descriptionHeading: field('heading').querySelector('h3')?.textContent,
        });
        """, arguments: ["base": payload, "slug": slug], in: nil, contentWorld: .page)
      as? [String: Any]
    let page = try XCTUnwrap(result)

    XCTAssertEqual(
      page["unnamedText"] as? String, "Unnamed option",
      "A control whose label was pure decoration still needs a name a person can read")
    XCTAssertEqual(
      page["unnamedMentionsSlug"] as? Bool, false,
      "…and the editor's slug of the markup is not that name")
    XCTAssertEqual(
      page["unnamedControls"] as? Bool, true, "The stand-in name still labels the control")
    XCTAssertEqual(
      page["wordlessTextRow"] as? Bool, false,
      "A text property is only its label, so one with no words is left out")
    XCTAssertEqual(page["namedRow"] as? String, "Character size", "A real label is untouched")
    XCTAssertEqual(page["section"] as? Bool, true)
    XCTAssertEqual(
      page["decorationOnlySection"] as? Bool, false,
      "With every property left out, the empty disclosure goes too")
    XCTAssertEqual(page["heading"] as? String, "人物Character")
    XCTAssertEqual(page["lineBreaks"] as? Int, 1)
    XCTAssertEqual(page["color"] as? String, "red")
    XCTAssertEqual(page["injected"] as? Bool, false)
    XCTAssertEqual(page["unsafeElements"] as? Int, 0)
    XCTAssertEqual(page["escapedText"] as? String, "<img src=x onerror=alert(1)>")
    XCTAssertEqual(page["escapedImages"] as? Int, 0)
    XCTAssertEqual(page["imageSource"] as? String, "mwe-ui://property-image/" + String(repeating: "a", count: 64))
    XCTAssertEqual(page["imageWidth"] as? String, "100%")
    XCTAssertEqual(page["authorRule"] as? Bool, true)
    XCTAssertEqual(page["authorLink"] as? String, "https://space.bilibili.com/111174060/")
    XCTAssertEqual(page["linkIsKeyboardControl"] as? Bool, true)
    XCTAssertEqual(page["descriptionHeading"] as? String, "Effect settings")
  }

  static func property(id: String, labelHtml: String) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: .text, labelHtml: labelHtml, value: .empty, defaultValue: .empty, slider: nil,
      comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false,
      canRestoreDefaults: false, enabled: true, assetManaged: false, assetMissing: false,
      assetSourcePath: nil)
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-labels-\(UUID().uuidString)")
    let bridge = LayoutSnapshotBridge(noPointer: .init())
    let store: BridgeStore
    let defaults: UserDefaults
    let workshop: WorkshopStore
    let controller: WebPanelController

    init() throws {
      store = BridgeStore(bridge: bridge)
      defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
      workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
        defaults: defaults)
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english())
      store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      store.librarySnapshot = BridgeLibrarySnapshot(
        wallpapers: [
          BridgeWallpaperEntry(
            id: "scene-1", title: "Scene one", kind: .projectScene, supported: true, active: false,
            selected: true, previewPath: nil)
        ],
        scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 1,
        videoCount: 0, webpageCount: 0, unknownCount: 0)
    }

    func tearDown() {
      controller.stop()
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
