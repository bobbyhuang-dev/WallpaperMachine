import CoreGraphics
import Darwin
import Foundation
import XCTest

@testable import WallpaperMachine

final class LockScreenWallpaperServiceTests: XCTestCase {
  private var root: URL!
  private var defaults: UserDefaults!
  private var defaultsSuite: String!
  private var timers: [Timer] = []
  private let preference = "WallpaperMachineAnimateLockScreen"
  private var store: URL { root.appendingPathComponent("Index.plist") }
  private var journal: URL { root.appendingPathComponent("journal.plist") }
  private var documents: URL { root.appendingPathComponent("Documents") }
  private var project: URL { root.appendingPathComponent("Project") }
  private var home: URL { root.appendingPathComponent("Home") }
  private var previousHome: String?

  override func setUpWithError() throws {
    defaultsSuite = "lock-screen-service-tests-" + UUID().uuidString
    defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    // Asset snapshots derive relative paths from a resolved enumeration root;
    // the temporary directory is under /var, a symlink that enumeration
    // resolves but standardizedFileURL restores, so stage under Caches instead.
    root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/lock-screen-service-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    // The managed user-asset store lives under the support root; every test that
    // publishes one has to land in a throwaway home, not the user's own.
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    try Data(#"{"type":"video","title":"t","file":"a.mp4"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    try Data([0x00]).write(to: project.appendingPathComponent("a.mp4"))
    try write(fixture())
  }
  override func tearDownWithError() throws {
    timers.forEach { $0.invalidate() }
    timers.removeAll()
    defaults.removePersistentDomain(forName: defaultsSuite)
    try FileManager.default.removeItem(at: root)
    if let previousHome {
      setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
    } else {
      unsetenv("WALLPAPER_MACHINE_HOME")
    }
  }

  @MainActor
  private func scheduleMonitor(_ callback: @escaping @MainActor () -> Void) -> Timer {
    // A real Timer, deliberately never registered with a run loop.
    let timer = Timer(timeInterval: 2, repeats: true) { _ in
      MainActor.assumeIsolated { callback() }
    }
    timers.append(timer)
    return timer
  }

  private func choice(_ name: String) -> [String: Any] {
    [
      "Content": [
        "Choices": [["Provider": name, "Configuration": Data(name.utf8), "Files": [String]()]],
        "Shuffle": "$null",
      ], "LastSet": Date(timeIntervalSince1970: 1),
    ]
  }
  private func node(_ name: String) -> [String: Any] {
    [
      "Desktop": choice(name + "-desktop"), "Idle": choice(name + "-idle"), "Type": "individual",
      "Unrelated": name,
    ]
  }
  private func fixture() -> [String: Any] {
    [
      "AllSpacesAndDisplays": node("global"), "SystemDefault": node("system"),
      "Displays": ["one": node("display-one"), "two": node("display-two")],
      "Spaces": [
        "space-a": [
          "Default": node("default-a"),
          "Displays": ["one": node("space-one"), "two": node("space-two")],
        ]
      ],
      "Unrelated": "keep",
    ]
  }
  private func write(_ value: [String: Any]) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(
      to: store, options: .atomic)
  }

  private func scene(propertiesJSON: String? = nil) -> BridgeLockScreenScene {
    BridgeLockScreenScene(
      displayId: CGMainDisplayID(), wallpaperId: "2001", title: "t",
      projectPath: project.appendingPathComponent("project.json").path,
      assetsPath: project.path, fps: 30, scalingMode: .fill, scalingFactor: 1,
      propertiesJson: propertiesJSON, paused: false)
  }

  /// The managed store as the app writes it, isolated per test through
  /// `WALLPAPER_MACHINE_HOME`.
  @discardableResult
  private func writeManagedAsset(
    propertyId: String, fileName: String, bytes: String, kind: String = "file"
  ) throws -> URL {
    let store = ClientPaths.userAssetsURL.appendingPathComponent("2001", isDirectory: true)
    let digest = "d" + String(bytes.hashValue, radix: 16, uppercase: false)
    let directory = store.appendingPathComponent("\(propertyId)/\(digest)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(fileName)
    try Data(bytes.utf8).write(to: file)
    let manifest = """
      {"version":1,"wallpaperId":"2001","properties":{"\(propertyId)":{"kind":"\(kind)",\
      "sourcePath":"/Users/someone/\(fileName)","truncated":false,"migratedLegacyPaths":[],\
      "assets":[{"assetId":"\(digest)","fileName":"\(fileName)",\
      "sourcePath":"/Users/someone/\(fileName)","size":\(bytes.utf8.count),\
      "modified":"2024-01-01T00:00:00Z","digest":"\(digest)"}]}}}
      """
    try Data(manifest.utf8).write(to: store.appendingPathComponent("manifest.json"))
    return file
  }

  @MainActor
  private func waitFor(
    _ description: String, timeout: TimeInterval = 10,
    condition: @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for \(description)")
  }

  /// Answers the extension's readiness files like the real lock-screen renderer.
  private func readinessResponder() -> Task<Void, Never> {
    let documents = self.documents
    return Task.detached {
      while !Task.isCancelled {
        let file = documents.appendingPathComponent(LockScreenConfiguration.fileName)
        if let data = try? Data(contentsOf: file),
          let configuration = try? JSONDecoder().decode(LockScreenConfiguration.self, from: data)
        {
          for scene in configuration.scenes {
            let readiness = LockScreenReadiness(
              revision: configuration.revision, displayID: scene.displayID, error: nil)
            try? JSONEncoder().encode(readiness).write(
              to: documents.appendingPathComponent("ready-\(scene.displayID).json"),
              options: .atomic)
          }
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  @MainActor
  func testActivationFailureAlwaysHandsDesktopBackToPosterProvider() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    let service = LockScreenWallpaperService(
      scenes: { [self.scene()] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal,
        reload: { throw LockScreenWallpaperFailure(message: "agent missing") }),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    var before = 0
    var after = 0
    service.beforeActivation = { before += 1 }
    service.afterDeactivation = { after += 1 }
    service.setEnabled(true)
    await waitFor("the failed activation to settle") { !service.isBusy }
    XCTAssertEqual(before, 1)
    XCTAssertEqual(after, 1)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertFalse(service.isEnabled)
    XCTAssertTrue(service.errorMessage?.contains("Restoration also failed") == true)
  }

  @MainActor
  func testDisableWithFailedRestorationStillHandsDesktopBack() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var failReload = false
    let service = LockScreenWallpaperService(
      scenes: { [self.scene()] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal,
        reload: {
          if failReload { throw LockScreenWallpaperFailure(message: "agent missing") }
        }),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    var before = 0
    var after = 0
    service.beforeActivation = { before += 1 }
    service.afterDeactivation = { after += 1 }
    let responder = readinessResponder()
    defer { responder.cancel() }
    service.setEnabled(true)
    await waitFor("the lock screen provider to enable") { service.isEnabled }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    XCTAssertEqual(before, 1)
    failReload = true
    service.setEnabled(false)
    await waitFor("deactivation to finish") { !service.isBusy }
    XCTAssertEqual(after, 1)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNotNil(service.errorMessage)
  }

  @MainActor
  func testNoAppliedWallpaperReleasesDesktopProvider() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var scenes = [scene()]
    let service = LockScreenWallpaperService(
      scenes: { scenes },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    var after = 0
    service.beforeActivation = {}
    service.afterDeactivation = { after += 1 }
    let responder = readinessResponder()
    defer { responder.cancel() }
    service.setEnabled(true)
    await waitFor("the lock screen provider to enable") { service.isEnabled }
    XCTAssertTrue(service.isEnabled)
    XCTAssertTrue(service.ownsDesktopProvider)
    scenes = []
    service.refresh()
    await waitFor("the provider release to settle") { !service.isBusy }
    XCTAssertEqual(after, 1)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertNil(service.errorMessage)
  }

  @MainActor
  func testMonitorExistsOnlyWhileRequestedAndDoesNotRescheduleWhileBusy() async throws {
    var calls = 0
    var pending: CheckedContinuation<[BridgeLockScreenScene], Never>?
    var suspend = false
    let service = LockScreenWallpaperService(
      scenes: {
        calls += 1
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return []
      },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    XCTAssertTrue(timers.isEmpty)
    service.refresh()
    await waitFor("off refresh") { !service.isBusy }
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(timers.isEmpty)
    service.setEnabled(true)
    await waitFor("requested empty scene refresh") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertEqual(timers.count, 1, "Empty scenes still need monitoring for a future wallpaper")
    let timer = try XCTUnwrap(timers.first)
    XCTAssertTrue(timer.isValid)
    suspend = true
    timer.fire()
    await waitFor("suspended scene request") { pending != nil }
    let busyCalls = calls
    timer.fire()
    XCTAssertEqual(calls, busyCalls)
    XCTAssertEqual(timers.count, 1)
    suspend = false
    pending?.resume(returning: [])
    pending = nil
    await waitFor("busy refresh") { !service.isBusy }
    service.refresh()
    await waitFor("explicit refresh") { !service.isBusy }
    XCTAssertEqual(timers.count, 1)
    service.setEnabled(false)
    XCTAssertFalse(timer.isValid, "Disable must stop monitoring before asynchronous restoration")
    await waitFor("disable") { !service.isBusy }
    XCTAssertFalse(defaults.bool(forKey: preference))
    service.setEnabled(true)
    await waitFor("reenable empty scenes") { !service.isBusy }
    XCTAssertEqual(timers.count, 2)
    try await service.shutdown()
    XCTAssertTrue(timers.allSatisfy { !$0.isValid })
    service.setEnabled(true)
    XCTAssertEqual(timers.count, 2)
  }

  @MainActor
  func testPersistedRequestStartsOneMonitorAndErrorsRequireExplicitRetry() async throws {
    defaults.set(true, forKey: preference)
    var fail = true
    var calls = 0
    let service = LockScreenWallpaperService(
      scenes: {
        calls += 1
        if fail { throw LockScreenWallpaperFailure(message: "scene lookup failed") }
        return []
      },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    XCTAssertTrue(service.isRequested)
    XCTAssertEqual(timers.count, 1)
    let first = try XCTUnwrap(timers.first)
    first.fire()
    await waitFor("failed polling refresh") { !service.isBusy }
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(first.isValid)
    XCTAssertEqual(calls, 1)
    fail = false
    service.refresh()
    await waitFor("explicit retry") { !service.isBusy }
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(timers.count, 2)
    XCTAssertTrue(try XCTUnwrap(timers.last).isValid)
    try await service.shutdown()
    XCTAssertTrue(timers.allSatisfy { !$0.isValid })
  }

  @MainActor
  func testRecoveryFailureDoesNotStartMonitorAndRefreshCanRecover() async throws {
    defaults.set(true, forKey: preference)
    try Data("invalid journal".utf8).write(to: journal)
    let service = LockScreenWallpaperService(
      scenes: { [] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    XCTAssertThrowsError(try service.start())
    XCTAssertTrue(timers.isEmpty)
    XCTAssertNotNil(service.errorMessage)
    try FileManager.default.removeItem(at: journal)
    service.refresh()
    await waitFor("successful recovery retry") { !service.isBusy }
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(timers.count, 1)
    try await service.shutdown()
  }

  @MainActor
  func testDisableCancelsReadinessBeforeEnabledPreferenceCanCommit() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    let service = LockScreenWallpaperService(
      scenes: { [self.scene()] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    service.setEnabled(true)
    await waitFor("published scene awaiting readiness") {
      service.ownsDesktopProvider && FileManager.default.fileExists(atPath: self.journal.path)
    }
    XCTAssertTrue(service.isBusy)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(defaults.bool(forKey: preference))
    let timer = try XCTUnwrap(timers.last)
    service.setEnabled(false)
    XCTAssertFalse(timer.isValid)
    try answerPublishedReadiness()
    await waitFor("cancelled readiness and restoration") { !service.isBusy }
    XCTAssertFalse(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertFalse(defaults.bool(forKey: preference))
    XCTAssertNil(service.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testNewGenerationCannotCommitPreviousReadiness() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var records = [scene()]
    let service = LockScreenWallpaperService(
      scenes: { records },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    service.setEnabled(true)
    await waitFor("first generation awaiting readiness") {
      service.ownsDesktopProvider && FileManager.default.fileExists(atPath: self.journal.path)
    }
    records = []
    service.refresh()
    try answerPublishedReadiness()
    await waitFor("replacement generation") { !service.isBusy }
    XCTAssertTrue(service.isRequested)
    XCTAssertFalse(service.isEnabled)
    XCTAssertFalse(service.ownsDesktopProvider)
    XCTAssertFalse(defaults.bool(forKey: preference))
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(timers.count, 1)
    try await service.shutdown()
  }

  @MainActor
  func testShutdownStopsMonitorBeforeWaitingAndKeepsItStoppedOnFailure() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    var failReload = false
    let service = LockScreenWallpaperService(
      scenes: { [self.scene()] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal,
        reload: {
          if failReload { throw LockScreenWallpaperFailure(message: "restoration failed") }
        }),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    service.setEnabled(true)
    await waitFor("activation waiting for readiness") {
      service.ownsDesktopProvider && FileManager.default.fileExists(atPath: self.journal.path)
    }
    let timer = try XCTUnwrap(timers.last)
    failReload = true
    let shutdown = Task { try await service.shutdown() }
    await waitFor("shutdown monitor cancellation") { !timer.isValid }
    do {
      try await shutdown.value
      XCTFail("Expected failed restoration")
    } catch {
      XCTAssertNotNil(service.errorMessage)
    }
    XCTAssertFalse(timer.isValid)
    XCTAssertFalse(service.isBusy)
    XCTAssertEqual(timers.count, 1)
    XCTAssertFalse(defaults.bool(forKey: preference))
    failReload = false
    service.setEnabled(false)
    await waitFor("explicit restoration retry") { !service.isBusy }
    XCTAssertNil(service.errorMessage)
    XCTAssertTrue(timers.allSatisfy { !$0.isValid })
  }

  // MARK: - Managed user assets

  /// The extension can only read its own container, so a property pointing at the
  /// app's managed store has to be republished into the container and the value
  /// rewritten. Only the assets this wallpaper references may travel.
  @MainActor
  func testReferencedUserAssetsArePublishedIntoTheContainerAndNothingElseIs() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    try writeManagedAsset(propertyId: "cover", fileName: "a b+c.png", bytes: "cover-bytes")
    // A second wallpaper's import, which this one must not carry into the container.
    let other = ClientPaths.userAssetsURL.appendingPathComponent(
      "9999/cover/abc", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("other-wallpaper".utf8).write(to: other.appendingPathComponent("other.png"))

    let service = LockScreenWallpaperService(
      scenes: { [self.scene(propertiesJSON: #"{"cover":"/Users/someone/a b+c.png"}"#)] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("enabled with published assets") { service.isEnabled }

    let configuration = try JSONDecoder().decode(
      LockScreenConfiguration.self,
      from: Data(contentsOf: documents.appendingPathComponent(LockScreenConfiguration.fileName)))
    let json = try XCTUnwrap(XCTUnwrap(configuration.scenes.first).propertiesJSON)
    let root = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
    let value = try XCTUnwrap(root["cover"] as? String)

    XCTAssertTrue(
      value.hasPrefix(documents.path + "/revisions/"),
      "the extension cannot read the app's own store, so the value must name the container copy")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: value)), Data("cover-bytes".utf8))
    let published = try FileManager.default.subpathsOfDirectory(atPath: documents.path)
    XCTAssertFalse(
      published.contains { $0.hasSuffix("other.png") },
      "another wallpaper's imports are not this wallpaper's to publish")

    try await service.shutdown()
  }

  /// Republishing the same selection must not copy it again, and must not leave the
  /// revision it replaced behind for good — there was no collection at all before.
  @MainActor
  func testRepublishingReusesTheRevisionAndCollectsOnlyUnreferencedOnes() async throws {
    try XCTSkipIf(CGDisplayIsOnline(CGMainDisplayID()) == 0, "No online main display")
    try writeManagedAsset(propertyId: "cover", fileName: "first.png", bytes: "first-bytes")
    var properties = #"{"cover":"/Users/someone/first.png"}"#
    let service = LockScreenWallpaperService(
      scenes: { [self.scene(propertiesJSON: properties)] },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    let responder = readinessResponder()
    defer { responder.cancel() }
    try service.start()
    service.setEnabled(true)
    await waitFor("first publication") { service.isEnabled }

    let revisions = documents.appendingPathComponent("revisions", isDirectory: true)
    let firstNames = try Set(FileManager.default.contentsOfDirectory(atPath: revisions.path))
    let assetRevision = try XCTUnwrap(
      publishedAssetRevision(), "the first publication must name an asset revision")
    let inode = try XCTUnwrap(try? FileManager.default.attributesOfItem(
      atPath: assetRevision.path)[.systemFileNumber] as? NSNumber)

    // A stale revision of exactly the shape earlier activations left behind.
    let orphan = revisions.appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: orphan.appendingPathComponent("stale.png"))

    // Off and on again republishes the same selection from scratch, which is the
    // path that would copy the assets a second time if the fingerprint were unstable.
    service.setEnabled(false)
    await waitFor("deactivated") { !service.isBusy && !service.isEnabled }
    service.setEnabled(true)
    await waitFor("second publication") { service.isEnabled && !service.isBusy }

    XCTAssertEqual(
      try XCTUnwrap(try? FileManager.default.attributesOfItem(
        atPath: assetRevision.path)[.systemFileNumber] as? NSNumber), inode,
      "an unchanged selection must reuse its revision rather than copy it again")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: orphan.path),
      "an unreferenced revision is a leak; there was no collection before this")
    let afterNames = try Set(FileManager.default.contentsOfDirectory(atPath: revisions.path))
    XCTAssertTrue(
      firstNames.isSubset(of: afterNames),
      "a revision the published configuration still names must never be collected")

    // Now change the selection: the old asset revision becomes unreferenced.
    try writeManagedAsset(propertyId: "cover", fileName: "second.png", bytes: "second-bytes")
    properties = #"{"cover":"/Users/someone/second.png"}"#
    service.refresh()
    await waitFor("third publication") { service.isEnabled && !service.isBusy }

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: assetRevision.path),
      "the replaced asset revision is unreferenced and must be collected")
    let replacement = try XCTUnwrap(publishedAssetRevision())
    XCTAssertEqual(
      try Data(contentsOf: replacement.appendingPathComponent("cover/second.png")),
      Data("second-bytes".utf8))

    try await service.shutdown()
  }

  /// A web wallpaper has no lock-screen renderer. That combination is not applicable,
  /// and must never be reported as a failure or as something still being waited for.
  @MainActor
  func testAWebOnlyDesktopIsReportedAsNotApplicableRatherThanFailed() async throws {
    let service = LockScreenWallpaperService(
      scenes: { [] }, webWallpapersApplied: { true },
      selection: LockScreenWallpaperSelection(
        storeURL: store, journalURL: journal, reload: {}),
      documents: documents, defaults: defaults, scheduleMonitor: scheduleMonitor)
    try service.start()
    service.setEnabled(true)
    await waitFor("settled status") { !service.isBusy }

    XCTAssertTrue(
      service.status.lowercased().contains("not applicable"),
      "web plus lock screen is unsupported, not failed: got “\(service.status)”")
    XCTAssertFalse(service.status.lowercased().contains("failed"))
    XCTAssertNil(service.errorMessage)
    XCTAssertFalse(service.isEnabled)

    try await service.shutdown()
  }

  /// The asset revision is the one holding a `cover` directory; the project payload
  /// revision holds `project.json`.
  private func publishedAssetRevision() throws -> URL? {
    let revisions = documents.appendingPathComponent("revisions", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: revisions.path)) ?? []
    return names.map { revisions.appendingPathComponent($0, isDirectory: true) }
      .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cover").path) }
  }

  private func answerPublishedReadiness() throws {
    let configuration = try JSONDecoder().decode(
      LockScreenConfiguration.self,
      from: Data(contentsOf: documents.appendingPathComponent(LockScreenConfiguration.fileName)))
    for scene in configuration.scenes {
      let readiness = LockScreenReadiness(
        revision: configuration.revision, displayID: scene.displayID, error: nil)
      try JSONEncoder().encode(readiness).write(
        to: documents.appendingPathComponent("ready-\(scene.displayID).json"), options: .atomic)
    }
  }
}
