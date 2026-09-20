import AppKit
import WebKit
import XCTest

@testable import MacWallpaperEngine

/// Covers the `file` and `directory` property editors: what the panel sends to the
/// engine, what the page is given to render, and what it does with a value that
/// contains markup. A `texture` property moved out of the old directory bucket, so
/// it is held to the control it has always had.
@MainActor
final class WebPanelAssetPropertiesTests: XCTestCase {
  func testClearingAPathSendsNil() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform(
      "clearPropertyPath", body: ["id": "web-1", "propertyID": "cover"])

    XCTAssertEqual(context.bridge.paths.count, 1)
    let call = try XCTUnwrap(context.bridge.paths.first)
    XCTAssertEqual(call.wallpaperId, "web-1")
    XCTAssertEqual(call.propertyId, "cover")
    XCTAssertNil(
      call.path, "Clearing must send nil, not an empty string the engine would store as a path")
  }

  func testChoosingWithoutAWindowSendsNoPath() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform(
      "choosePropertyPath", body: ["id": "web-1", "propertyID": "cover"])

    XCTAssertTrue(
      context.bridge.paths.isEmpty,
      "A picker that was never presented must not commit a path")
  }

  func testATexturePropertyIsRefusedByThePathEditor() async throws {
    let context = try Context()
    defer { context.tearDown() }

    for action in ["choosePropertyPath", "clearPropertyPath"] {
      do {
        try await context.controller.perform(
          action, body: ["id": "web-1", "propertyID": "backdrop"])
        XCTFail("\(action) must not accept a scene texture")
      } catch {}
    }
    XCTAssertTrue(context.bridge.paths.isEmpty)
  }

  func testSnapshotDescribesAnUnsetPathAndAChosenFolder() throws {
    let context = try Context()
    defer { context.tearDown() }
    let folder = context.root.appendingPathComponent("slides")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["a.png", "b.jpg", "notes.txt"] {
      try Data().write(to: folder.appendingPathComponent(name))
    }
    // A folder whose name ends in an accepted extension, and a dotfile: both are
    // screened out by the importer, so neither may be counted as a file it would take.
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("photos.png"), withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent(".hidden.png"))
    context.bridge.options = Self.options(properties: [
      Self.property(id: "cover", kind: .file, value: .empty, filter: .image),
      Self.property(
        id: "album", kind: .directory, value: .string(value: folder.path), filter: .image,
        mode: .fetchAll),
    ])
    context.store.wallpaperOptionsSnapshot = context.bridge.options

    let properties = try XCTUnwrap(
      (context.controller.snapshot()["options"] as? [String: Any])?["properties"]
        as? [[String: Any]])
    let cover = try XCTUnwrap(properties.first { $0["id"] as? String == "cover" })
    let album = try XCTUnwrap(properties.first { $0["id"] as? String == "album" })

    XCTAssertEqual(cover["kind"] as? String, "file")
    XCTAssertTrue(
      cover["fileName"] is NSNull, "An unset path has no display name to show")
    XCTAssertEqual(
      cover["fileTypes"] as? [String], UserAssetFilter.image.allowedExtensions.sorted(),
      "The page states the accepted types, taken from the property's own filter")

    XCTAssertEqual(album["kind"] as? String, "directory")
    XCTAssertEqual(album["fileName"] as? String, "slides")
    XCTAssertEqual(
      album["fileCount"] as? Int, 2, "Only files the importer would take are counted")
    XCTAssertEqual(album["truncated"] as? Bool, false)
    XCTAssertEqual(album["directoryMode"] as? String, "fetchAll")
    XCTAssertEqual(album["fileLimit"] as? Int, UserAssetStore.defaultDirectoryFileLimit)
  }

  func testAnUnreadableFolderIsReportedAsUnknownRatherThanEmpty() throws {
    let context = try Context()
    defer { context.tearDown() }
    let missing = context.root.appendingPathComponent("gone")
    context.bridge.options = Self.options(properties: [
      Self.property(
        id: "album", kind: .directory, value: .string(value: missing.path), mode: .onDemand)
    ])
    context.store.wallpaperOptionsSnapshot = context.bridge.options

    let properties = try XCTUnwrap(
      (context.controller.snapshot()["options"] as? [String: Any])?["properties"]
        as? [[String: Any]])
    let album = try XCTUnwrap(properties.first)

    XCTAssertEqual(album["fileName"] as? String, "gone")
    XCTAssertTrue(
      album["fileCount"] is NSNull,
      "A folder that could not be read must not be published as holding zero files")
    XCTAssertEqual(album["directoryMode"] as? String, "onDemand")
  }

  func testPageRendersAssetControlsAndEscapesPathsCarryingMarkup() async throws {
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
    let base =
      try await web.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.native.postMessage({action:'ready'})",
        arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    let payload = try XCTUnwrap(base)
    context.controller.stop()

    let hostile = "<img src=x onerror=alert(1)> \"quoted\" & 'single'"
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
        const property = (id, kind, extra) => Object.assign({
          id, kind, label: id, value: '', defaultValue: null, enabled: true, dirty: false,
          min: 0, max: 1, step: 0.01, options: [] }, extra);
        window.wallpaperUI.receive(Object.assign({}, base, {
          page: 'installed', selectedID: 'web-1',
          wallpapers: [{ id: 'web-1', title: 'Web one', kind: 'Web', preview: null, active: false, supported: true, tags: [] }],
          options: { id: 'web-1', kind: 'Web', supported: true, dirty: false, volume: 0.5, muted: false,
            audioResponseEnabled: true, mediaIntegrationEnabled: false, displays: [],
            properties: [
              property('cover', 'file', { fileName: null, fileTypes: ['jpg', 'png'], error: null }),
              property('album', 'directory', { fileName: hostile, fileTypes: ['png'], fileCount: 3,
                fileLimit: 4096, truncated: false, directoryMode: 'fetchAll', error: hostile }),
              property('backdrop', 'texture', { value: hostile }),
            ] } }));
        await waitFor(() => document.querySelector('#inspector [data-key="cover"]'));
        const field = id => document.querySelector(`#inspector [data-key="${id}"]`);
        const control = (id, action) => field(id).querySelector(`[data-action="${action}"]`);
        const cover = field('cover');
        const album = field('album');
        const backdrop = field('backdrop');
        return {
          emptyValue: cover.querySelector('input[readonly]').value,
          emptyLabelled: document.querySelector(`label[for="${cover.querySelector('input[readonly]').id}"]`) !== null,
          emptyClearDisabled: control('cover', 'clearPropertyPath').disabled,
          emptyChooseEnabled: !control('cover', 'choosePropertyPath').disabled,
          chosenValue: album.querySelector('input[readonly]').value,
          chosenClearEnabled: !control('album', 'clearPropertyPath').disabled,
          injectedElements: album.querySelectorAll('img').length + backdrop.querySelectorAll('img').length,
          errorText: album.querySelector('[role="alert"]').textContent,
          markupCarriedIntoAlbum: album.innerHTML.includes('<img'),
          textureValue: backdrop.querySelector('.file-value').textContent,
          textureChoosesImage: control('backdrop', 'choosePropertyFile') !== null,
          textureUsesPathEditor: control('backdrop', 'choosePropertyPath') !== null,
          mediaToggle: document.querySelector('#inspector [data-setting="mediaIntegrationEnabled"]') !== null,
          mediaChecked: document.querySelector('#inspector [data-setting="mediaIntegrationEnabled"]').checked,
          audioStatuses: document.querySelectorAll('#inspector [role="status"]').length,
        };
        """, arguments: ["base": payload, "hostile": hostile], in: nil, contentWorld: .page)
      as? [String: Any]
    let page = try XCTUnwrap(result)

    XCTAssertFalse(
      (page["emptyValue"] as? String ?? "").isEmpty,
      "An unset path still reads as something, not as a blank field")
    XCTAssertEqual(
      page["emptyLabelled"] as? Bool, true, "The field carries the property's own label")
    XCTAssertEqual(page["emptyClearDisabled"] as? Bool, true)
    XCTAssertEqual(page["emptyChooseEnabled"] as? Bool, true)
    XCTAssertEqual(
      page["chosenValue"] as? String, hostile,
      "The display name is shown as text, exactly as given")
    XCTAssertEqual(page["chosenClearEnabled"] as? Bool, true)
    XCTAssertEqual(
      page["injectedElements"] as? Int, 0, "A file name must not become an element")
    XCTAssertEqual(page["markupCarriedIntoAlbum"] as? Bool, false)
    XCTAssertEqual(page["errorText"] as? String, hostile, "A failure reason is escaped too")
    XCTAssertEqual(
      page["textureValue"] as? String, hostile,
      "A texture keeps rendering its value in the control it always had")
    XCTAssertEqual(page["textureChoosesImage"] as? Bool, true)
    XCTAssertEqual(
      page["textureUsesPathEditor"] as? Bool, false,
      "A texture must not be offered the user-asset picker")
    XCTAssertEqual(page["mediaToggle"] as? Bool, true)
    XCTAssertEqual(page["mediaChecked"] as? Bool, false, "Media integration ships off")
    XCTAssertGreaterThanOrEqual(
      page["audioStatuses"] as? Int ?? 0, 2,
      "Audio and media each report their own state, separately from the switch")
    XCTAssertNil(web.window, "This check must stay offscreen")
    await context.workshop.steamCMDSetup.shutdown()
  }

  static func property(
    id: String, kind: BridgePropertyKind, value: BridgePropertyValue = .empty,
    filter: BridgeFileFilter? = nil, mode: BridgeDirectoryMode? = nil,
    assetManaged: Bool = false, assetMissing: Bool = false, assetSourcePath: String? = nil
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: id, value: value, defaultValue: .empty, slider: nil,
      comboOptions: [], fileFilter: filter, directoryMode: mode, dirty: false,
      canRestoreDefaults: false, enabled: true, assetManaged: assetManaged,
      assetMissing: assetMissing, assetSourcePath: assetSourcePath)
  }

  static func options(properties: [BridgePropertyDescriptor]) -> BridgeWallpaperOptionsSnapshot {
    BridgeWallpaperOptionsSnapshot(
      wallpaperId: "web-1", title: "Web one", kind: .webpage, supported: true, dirty: false,
      properties: properties, displayConfigurations: [], audioResponseEnabled: true,
      mediaIntegrationEnabled: false, muted: false, volume: 0.5)
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-assets-\(UUID().uuidString)")
    let bridge = AssetBridge(noPointer: .init())
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
            id: "web-1", title: "Web one", kind: .webpage, supported: true, active: false,
            selected: true, previewPath: nil)
        ],
        scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
        videoCount: 0, webpageCount: 1, unknownCount: 0)
      bridge.options = WebPanelAssetPropertiesTests.options(properties: [
        WebPanelAssetPropertiesTests.property(id: "cover", kind: .file, filter: .image),
        WebPanelAssetPropertiesTests.property(id: "backdrop", kind: .texture),
      ])
      bridge.snapshots = { [store, bridge] in
        BridgeWallpaperMutationBundle(
          app: store.appSnapshot, library: store.librarySnapshot,
          wallpaperOptions: bridge.options,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
    }

    func tearDown() {
      controller.stop()
      defaults.removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private final class AssetBridge: WallpaperBridge {
  struct Path {
    let wallpaperId: String
    let propertyId: String
    let path: String?
  }

  @MainActor var snapshots: (() -> BridgeWallpaperMutationBundle)?
  @MainActor var options = BridgeWallpaperOptionsSnapshot(
    wallpaperId: "web-1", title: "Web one", kind: .webpage, supported: true, dirty: false,
    properties: [], displayConfigurations: [], audioResponseEnabled: true,
    mediaIntegrationEnabled: false, muted: false, volume: 0.5)
  @MainActor var paths: [Path] = []

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws
    -> BridgeWallpaperOptionsSnapshot
  {
    await currentOptions()
  }

  override func setPropertyPath(wallpaperId: String, propertyId: String, path: String?)
    async throws -> BridgeWallpaperMutationBundle
  {
    await record(Path(wallpaperId: wallpaperId, propertyId: propertyId, path: path))
  }

  @MainActor private func currentOptions() -> BridgeWallpaperOptionsSnapshot { options }

  @MainActor private func record(_ call: Path) -> BridgeWallpaperMutationBundle {
    paths.append(call)
    guard let snapshots else { fatalError("The fixture must publish a snapshot") }
    return snapshots()
  }
}
