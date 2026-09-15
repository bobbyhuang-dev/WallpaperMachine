import Foundation
import XCTest

@testable import MacWallpaperEngine

final class LockScreenWallpaperTests: XCTestCase {
  private var root: URL!
  private var store: URL { root.appendingPathComponent("Index.plist") }
  private var journal: URL { root.appendingPathComponent("journal.plist") }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lock-wallpaper-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

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
  private func readStore() throws -> [String: Any] {
    try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: store), format: nil)
        as? [String: Any])
  }
  private func provider(_ node: [String: Any], key: String) -> String? {
    let content = (node[key] as? [String: Any])?["Content"] as? [String: Any]
    return (content?["Choices"] as? [[String: Any]])?.first?["Provider"] as? String
  }

  @MainActor
  func testNativeSelectionTargetsOnlyOwnedDisplaysAndRestoresIndependentOriginals() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(displays: ["one"])
    let selected = try readStore()
    let displays = try XCTUnwrap(selected["Displays"] as? [String: [String: Any]])
    XCTAssertEqual(
      provider(try XCTUnwrap(displays["one"]), key: "Desktop"),
      LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(
      provider(try XCTUnwrap(displays["one"]), key: "Idle"),
      LockScreenConfiguration.extensionIdentifier)
    XCTAssertEqual(
      displays["two"] as NSDictionary?,
      (original["Displays"] as? [String: Any])?["two"] as? NSDictionary)
    XCTAssertEqual(
      selected["AllSpacesAndDisplays"] as? NSDictionary,
      original["AllSpacesAndDisplays"] as? NSDictionary)
    try selection.synchronize(displays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testExternalDesktopEditSurvivesWhileOwnedIdleSelectionRestores() throws {
    try write(fixture())
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(displays: ["one"])
    var external = try readStore()
    var displays = try XCTUnwrap(external["Displays"] as? [String: [String: Any]])
    displays["one"]?["Desktop"] = choice("user-selected")
    displays["one"]?["Unrelated"] = "new-user-value"
    external["Displays"] = displays
    try write(external)
    XCTAssertThrowsError(try selection.synchronize(displays: ["one"]))
    try selection.synchronize(displays: [])
    let restored = try XCTUnwrap((try readStore()["Displays"] as? [String: [String: Any]])?["one"])
    XCTAssertEqual(provider(restored, key: "Desktop"), "user-selected")
    XCTAssertEqual(provider(restored, key: "Idle"), "display-one-idle")
    XCTAssertEqual(restored["Unrelated"] as? String, "new-user-value")
  }

  @MainActor
  func testReloadFailureLeavesRecoverableJournalInsteadOfLosingOriginals() throws {
    let original = fixture()
    try write(original)
    let failing = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { throw CocoaError(.executableRuntimeMismatch) }
    )
    XCTAssertThrowsError(try failing.synchronize(displays: ["one"]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testNewSpaceInheritedSelectionIsRemovedRatherThanInventingAnOriginal() throws {
    var original = fixture()
    original["Spaces"] = ["space-a": ["Default": node("default-a"), "Displays": [String: Any]()]]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(displays: ["one"])
    try selection.synchronize(displays: [])
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }
  @MainActor
  func testSystemCopiedFallbackIsRestoredWithoutOverwritingOtherAppGlobalChoice() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(displays: ["one"])
    var systemChanged = try readStore()
    let owned = try XCTUnwrap((systemChanged["Displays"] as? [String: [String: Any]])?["one"])
    var copied = try XCTUnwrap(systemChanged["SystemDefault"] as? [String: Any])
    copied["Desktop"] = owned["Desktop"]
    copied["Idle"] = owned["Idle"]
    systemChanged["SystemDefault"] = copied
    systemChanged["AllSpacesAndDisplays"] = ["Linked": choice("another-app"), "Type": "linked"]
    try write(systemChanged)
    try selection.synchronize(displays: [])
    let restored = try readStore()
    XCTAssertEqual(
      restored["SystemDefault"] as? NSDictionary, original["SystemDefault"] as? NSDictionary)
    XCTAssertEqual(
      restored["AllSpacesAndDisplays"] as? NSDictionary,
      systemChanged["AllSpacesAndDisplays"] as? NSDictionary)
  }

  @MainActor
  func testConflictingGlobalLinkedWallpaperIsRejectedWithoutChangingStore() throws {
    var original = fixture()
    original["AllSpacesAndDisplays"] = ["Linked": choice("another-app"), "Type": "linked"]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    XCTAssertThrowsError(try selection.checkCompatibility())
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testOrphanedSpaceIdleRecoversFromDisplayAndPreservesDesktop() throws {
    var original = fixture()
    var spaces = try XCTUnwrap(original["Spaces"] as? [String: [String: Any]])
    var space = try XCTUnwrap(spaces["space-a"])
    var displays = try XCTUnwrap(space["Displays"] as? [String: [String: Any]])
    displays["one"]?["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    var fallback = node("default-a")
    fallback["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    space["Default"] = fallback
    space["Displays"] = displays
    spaces["space-a"] = space
    original["Spaces"] = spaces
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(displays: ["one"])
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    let restoredSpaces = try XCTUnwrap(try readStore()["Spaces"] as? [String: [String: Any]])
    let restored = try XCTUnwrap(restoredSpaces["space-a"])
    let restoredDisplays = try XCTUnwrap(restored["Displays"] as? [String: [String: Any]])
    let display = try XCTUnwrap(restoredDisplays["one"])
    XCTAssertEqual(provider(display, key: "Desktop"), "space-one-desktop")
    XCTAssertEqual(provider(display, key: "Idle"), "display-one-idle")
    let restoredFallback = try XCTUnwrap(restored["Default"] as? [String: Any])
    XCTAssertEqual(provider(restoredFallback, key: "Desktop"), "default-a-desktop")
    XCTAssertEqual(provider(restoredFallback, key: "Idle"), "system-idle")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testSystemCopiedSpaceDefaultRestoresAcrossRelaunch() throws {
    let original = fixture()
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try selection.synchronize(displays: ["one"])
    var copied = try readStore()
    var spaces = try XCTUnwrap(copied["Spaces"] as? [String: [String: Any]])
    var fallback = node("default-a")
    fallback["Desktop"] = choice(LockScreenConfiguration.extensionIdentifier)
    fallback["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    spaces["space-a"]?["Default"] = fallback
    copied["Spaces"] = spaces
    try write(copied)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testOrphanWithoutNativeFallbackDoesNotChangeStore() throws {
    var original = fixture()
    original["SystemDefault"] = [:] as [String: Any]
    original["AllSpacesAndDisplays"] = [:] as [String: Any]
    original["Spaces"] = [:] as [String: Any]
    var display = node("display-one")
    display["Idle"] = choice(LockScreenConfiguration.extensionIdentifier)
    original["Displays"] = ["one": display]
    try write(original)
    let selection = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    XCTAssertThrowsError(try selection.synchronize(displays: ["one"]))
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

}
