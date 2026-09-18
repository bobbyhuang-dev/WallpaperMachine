import XCTest

@testable import MacWallpaperEngine

/// Covers the validation the panel performs on quality settings before they reach
/// the engine, and the snapshot keys the settings page reads back.
@MainActor
final class WebPanelPerformanceSettingsTests: XCTestCase {
  func testRenderScaleFromAStalePageIsClampedToTheSupportedRange() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform("setting", body: ["key": "renderScale", "value": 5.0])
    try await context.controller.perform("setting", body: ["key": "renderScale", "value": 0.01])

    XCTAssertEqual(
      context.bridge.renderScales, [1, 0.25],
      "A scale outside 0.25...1 must reach the engine clamped, not refused or passed through")
  }

  func testNonNumericRenderScaleIsRefused() async {
    guard let context = try? Context() else { return XCTFail("fixture") }
    defer { context.tearDown() }

    do {
      try await context.controller.perform("setting", body: ["key": "renderScale", "value": "0.5"])
      XCTFail("A string render scale must not be accepted")
    } catch {}
    XCTAssertTrue(context.bridge.renderScales.isEmpty)
  }

  func testUnknownVideoBackendIsRefusedInsteadOfSilentlyDefaulting() async throws {
    let context = try Context()
    defer { context.tearDown() }

    do {
      try await context.controller.perform("setting", body: ["key": "videoBackend", "value": "native"])
      XCTFail("An unrecognised backend name must not be applied")
    } catch {}
    XCTAssertTrue(
      context.bridge.videoBackends.isEmpty,
      "A rejected backend must not fall back to Compatibility behind the user's back")

    try await context.controller.perform(
      "setting", body: ["key": "videoBackend", "value": "native_preferred"])
    XCTAssertEqual(context.bridge.videoBackends, ["native_preferred"])
  }

  func testBatteryFrameRateIsClampedAndTheUnchangedProfileFieldsAreKept() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot.batteryProfileEnabled = true
    context.store.settingsSnapshot.batteryRenderScale = 0.5

    try await context.controller.perform("setting", body: ["key": "batteryTargetFps", "value": 1000])

    let profile = try XCTUnwrap(context.bridge.batteryProfiles.first)
    XCTAssertEqual(profile.targetFps, 240, "Frame rate must be clamped to 1...240")
    XCTAssertTrue(profile.enabled, "Changing one field must not turn the profile off")
    XCTAssertEqual(profile.renderScale, 0.5, "Changing one field must not reset the other")
  }

  func testSceneOptimizationDefaultsOnAndRoundTripsThroughTheEngine() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings()

    let shipped = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      shipped["sceneOptimization"] as? Bool, true,
      "Scene optimisation ships on; a page that renders it off would invert the default")

    try await context.controller.perform(
      "setting", body: ["key": "sceneOptimization", "value": false])

    XCTAssertEqual(context.bridge.sceneOptimization, [false])
    let off = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      off["sceneOptimization"] as? Bool, false,
      "The page must re-render from the snapshot the engine returned, not from the click")

    try await context.controller.perform(
      "setting", body: ["key": "sceneOptimization", "value": true])

    XCTAssertEqual(context.bridge.sceneOptimization, [false, true])
    let on = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(on["sceneOptimization"] as? Bool, true)
  }

  func testNonBooleanSceneOptimizationValueIsRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }

    do {
      try await context.controller.perform(
        "setting", body: ["key": "sceneOptimization", "value": 1])
      XCTFail("A numeric value must not be accepted for a switch")
    } catch {}
    XCTAssertTrue(context.bridge.sceneOptimization.isEmpty)
  }

  func testSnapshotPublishesPerformanceSettingsUnderTheDocumentedKeys() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot.videoBackend = "native_preferred"
    context.store.settingsSnapshot.videoBackends = [
      BridgeVideoBackendReport(
        displayId: 2, displayName: "Display 2", wallpaperId: "beach", wallpaperTitle: "Beach",
        backend: "legacy", fallbackReason: "29.97 fps is below the 30 fps target")
    ]
    context.store.settingsSnapshot.contentPacingEnabled = true
    context.store.settingsSnapshot.sharedVideoDecodeEnabled = true
    context.store.settingsSnapshot.sharedVideoDecodeSessions = 1
    context.store.settingsSnapshot.sharedVideoDecodeConsumers = 3
    context.store.settingsSnapshot.renderScale = 0.75
    context.store.settingsSnapshot.preferredRenderScale = 1
    context.store.settingsSnapshot.renderScaleSupported = true
    context.store.settingsSnapshot.batteryProfileEnabled = true
    context.store.settingsSnapshot.batteryRenderScale = 0.75
    context.store.settingsSnapshot.batteryTargetFps = 30
    context.store.settingsSnapshot.onBatteryPower = true

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])

    XCTAssertEqual(settings["videoBackend"] as? String, "native_preferred")
    XCTAssertEqual(settings["contentPacing"] as? Bool, true)
    XCTAssertEqual(settings["sharedVideoDecode"] as? Bool, true)
    XCTAssertEqual(settings["sharedVideoDecodeSessions"] as? Int, 1)
    XCTAssertEqual(settings["sharedVideoDecodeConsumers"] as? Int, 3)
    XCTAssertEqual(settings["renderScale"] as? Double, 0.75)
    XCTAssertEqual(settings["preferredRenderScale"] as? Double, 1)
    XCTAssertEqual(settings["renderScaleSupported"] as? Bool, true)
    XCTAssertEqual(settings["batteryProfileEnabled"] as? Bool, true)
    XCTAssertEqual(settings["batteryRenderScale"] as? Double, 0.75)
    XCTAssertEqual(settings["batteryTargetFps"] as? Int, 30)
    XCTAssertEqual(settings["onBatteryPower"] as? Bool, true)

    let reports = try XCTUnwrap(settings["videoBackends"] as? [[String: Any]])
    XCTAssertEqual(reports.count, 1)
    XCTAssertEqual(reports[0]["displayId"] as? Int, 2)
    XCTAssertEqual(reports[0]["displayName"] as? String, "Display 2")
    XCTAssertEqual(reports[0]["wallpaperId"] as? String, "beach")
    XCTAssertEqual(reports[0]["wallpaperTitle"] as? String, "Beach")
    XCTAssertEqual(reports[0]["backend"] as? String, "legacy")
    XCTAssertEqual(
      reports[0]["fallbackReason"] as? String, "29.97 fps is below the 30 fps target")

    context.store.settingsSnapshot.videoBackends = []
    let empty = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual((empty["videoBackends"] as? [[String: Any]])?.isEmpty, true)
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-performance-\(UUID().uuidString)")
    let bridge = RecordingBridge(noPointer: .init())
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
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults)
      bridge.snapshots = { [store] in
        BridgeSnapshotBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
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

private final class RecordingBridge: WallpaperBridge {
  struct Profile {
    let enabled: Bool
    let renderScale: Float
    let targetFps: UInt32
  }

  @MainActor var snapshots: (() -> BridgeSnapshotBundle)?
  @MainActor var renderScales: [Float] = []
  @MainActor var videoBackends: [String] = []
  @MainActor var batteryProfiles: [Profile] = []
  @MainActor var sceneOptimization: [Bool] = []

  override func setRenderScale(scale: Float) async throws -> BridgeSnapshotBundle {
    await record { $0.renderScales.append(scale) }
  }

  override func setVideoBackend(mode: String) async throws -> BridgeSnapshotBundle {
    await record { $0.videoBackends.append(mode) }
  }

  /// Returns the setting applied, the way the engine does: the page re-renders from
  /// this, so a test that returned the old value could not tell acceptance from a
  /// silently dropped click.
  override func setSceneOptimizationEnabled(enabled: Bool) async throws -> BridgeSnapshotBundle {
    var bundle = await record { $0.sceneOptimization.append(enabled) }
    bundle.settings.sceneOptimizationEnabled = enabled
    return bundle
  }

  override func setBatteryQualityProfile(
    enabled: Bool, renderScale: Float, targetFps: UInt32
  ) async throws -> BridgeSnapshotBundle {
    await record {
      $0.batteryProfiles.append(
        Profile(enabled: enabled, renderScale: renderScale, targetFps: targetFps))
    }
  }

  @MainActor private func record(_ note: @MainActor (RecordingBridge) -> Void)
    -> BridgeSnapshotBundle
  {
    note(self)
    guard let snapshots else { fatalError("The fixture must publish a snapshot") }
    return snapshots()
  }
}
