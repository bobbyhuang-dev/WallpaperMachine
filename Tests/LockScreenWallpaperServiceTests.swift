import CoreGraphics
import Foundation
import XCTest

@testable import MacWallpaperEngine

final class LockScreenWallpaperServiceTests: XCTestCase {
  private var root: URL!
  private var previousPreference: Any?
  private var store: URL { root.appendingPathComponent("Index.plist") }
  private var journal: URL { root.appendingPathComponent("journal.plist") }
  private var documents: URL { root.appendingPathComponent("Documents") }
  private var project: URL { root.appendingPathComponent("Project") }

  override func setUpWithError() throws {
    // setEnabled writes the real app preference; preserve the user's value.
    previousPreference = UserDefaults.standard.object(
      forKey: "MacWallpaperEngineAnimateLockScreen")
    // Asset snapshots derive relative paths from a resolved enumeration root;
    // the temporary directory is under /var, a symlink that enumeration
    // resolves but standardizedFileURL restores, so stage under Caches instead.
    root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/lock-screen-service-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try Data(#"{"type":"video","title":"t","file":"a.mp4"}"#.utf8).write(
      to: project.appendingPathComponent("project.json"))
    try Data([0x00]).write(to: project.appendingPathComponent("a.mp4"))
    try write(fixture())
  }
  override func tearDownWithError() throws {
    if let previousPreference {
      UserDefaults.standard.set(
        previousPreference, forKey: "MacWallpaperEngineAnimateLockScreen")
    } else {
      UserDefaults.standard.removeObject(forKey: "MacWallpaperEngineAnimateLockScreen")
    }
    try FileManager.default.removeItem(at: root)
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

  private func scene() -> BridgeLockScreenScene {
    BridgeLockScreenScene(
      displayId: CGMainDisplayID(), title: "t",
      projectPath: project.appendingPathComponent("project.json").path,
      assetsPath: project.path, fps: 30, scalingMode: .fill, scalingFactor: 1,
      propertiesJson: nil, paused: false)
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
      documents: documents)
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
      documents: documents)
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
      documents: documents)
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
}
