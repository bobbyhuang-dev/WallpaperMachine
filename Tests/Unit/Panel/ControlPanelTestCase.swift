import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import WallpaperMachine

/// Shared fixture for the offscreen control-panel suites: a `BridgeStore` over a snapshot-only
/// bridge, a `WebPanelController` driven through its real `WKWebView` without a window, and the
/// synthetic GIF frames the Discover previews are tested with.
@MainActor
class ControlPanelTestCase: XCTestCase {
  func makeStore() -> (store: BridgeStore, bridge: LayoutSnapshotBridge) {
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

  func withPanel(
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

  /// `closing`, when given, is the brightness of a last frame shown for a fiftieth of a second
  /// between seconds-long frames of `brightness`.
  static func gif(frames: Int, brightness: Double, closing: Double? = nil) throws -> Data {
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
}

final class LayoutSnapshotBridge: WallpaperBridge {
  var snapshot: BridgeSnapshotBundle?
  @MainActor var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
  @MainActor var optionRequests: [String] = []
  @MainActor var failedOptionIDs = Set<String>()
  @MainActor var holdOptions = false
  @MainActor var pendingOptions: [CheckedContinuation<BridgeWallpaperOptionsSnapshot, Error>] = []
  /// Settings writes the panel commits; a provider stands in for the engine's reply.
  @MainActor var pauseOnBatteryCalls: [Bool] = []
  @MainActor var bundleProvider: (@MainActor () -> BridgeSnapshotBundle)?

  override func setPauseOnBatteryPower(enabled: Bool) async throws -> BridgeSnapshotBundle {
    try await MainActor.run {
      pauseOnBatteryCalls.append(enabled)
      guard let bundle = bundleProvider?() ?? snapshot else { throw CancellationError() }
      return bundle
    }
  }

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

final class PanelUpdateClient: AppUpdateClient, @unchecked Sendable {
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
        string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/tag/v\(version)")!,
      prerelease: false,
      assets: [
        GitHubReleaseAsset(
          name: "WallpaperMachine-\(version)-arm64.zip",
          downloadURL: URL(
            string:
              "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v\(version)/WallpaperMachine-\(version)-arm64.zip"
          )!,
          size: 1_000, digest: nil)
      ])
  }
}

final class PanelUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
  var canInstallInPlace = true
  var installCalls = 0
  func prepareInstallation(archive: URL) throws -> URL { archive }
  func install(extractedApp: URL, replacing destination: URL) throws { installCalls += 1 }
}

struct UnavailableRuntime: SteamCMDRuntimeProviding {
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
final class PanelFixture {
  final class Visibility { var visible = false }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-power-\(UUID().uuidString)")
  let store: BridgeStore
  let bridge: LayoutSnapshotBridge
  let navigation = ControlPanelNavigation()
  let visibility = Visibility()
  let defaults: UserDefaults
  let previousHome: String?
  let workshop: WorkshopStore
  let theme: AppThemeStore
  let controller: WebPanelController
  var web: WKWebView
  let executable: URL

  init(store: BridgeStore, bridge: LayoutSnapshotBridge, displayTitles: DisplayTitleResolver) throws {
    self.store = store
    self.bridge = bridge
    defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defaults.set(root.appendingPathComponent("missing").path, forKey: "WallpaperMachineSteamCMDPath")
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    executable = root.appendingPathComponent("steamcmd")
    // A download prints its password prompt and blocks until `advance` appears; a sign-in-only
    // session (no `+workshop_download_item`) reads the password, records it and signs in.
    try Data("""
      #!/bin/sh
      mode=signin
      for argument in "$@"; do [ "$argument" = +workshop_download_item ] && mode=download; done
      printf 'Password:\\n'
      if [ "$mode" = signin ]; then
        IFS= read -r password
        printf '%s' "$password" > "\(root.path)/password"
        printf 'Waiting for user info...OK\\n'
        exit 0
      fi
      while [ ! -e "\(root.path)/advance" ]; do /bin/sleep 0.02; done
      printf 'Downloading item 222\\n'
      IFS= read -r hold

      """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
    let downloader = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("session"), runtimeProvider: PanelRuntime())
    workshop = WorkshopStore(
      downloader: downloader, supportDirectory: root, defaults: defaults,
      runtimeProvider: PanelRuntime(), sceneAssetsAvailable: { false })
    let visibility = self.visibility
    theme = AppThemeStore(defaults: defaults)
    controller = WebPanelController(
      store: store, navigation: navigation, workshop: workshop,
      isPresentationVisible: { visibility.visible }, theme: theme, displayTitles: displayTitles,
      defaults: defaults, appLanguage: .english())
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

  /// The sign-in-only job once the guide has started it.
  func waitForSignIn() async throws -> WorkshopDownload {
    try await waitUntil(timeout: 5) { self.workshop.downloader.signIn != nil }
    return try XCTUnwrap(workshop.downloader.signIn)
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
    if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
    else { unsetenv("WALLPAPER_MACHINE_HOME") }
    try? FileManager.default.removeItem(at: root)
  }
}

final class PreviewFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
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

struct PanelRuntime: SteamCMDRuntimeProviding {
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
