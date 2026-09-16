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
  private func assertDiskRecovery(restores original: [String: Any]) throws {
    let copy = root.appendingPathComponent("recovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    let copiedStore = copy.appendingPathComponent("Index.plist")
    let copiedJournal = copy.appendingPathComponent("journal.plist")
    try FileManager.default.copyItem(at: store, to: copiedStore)
    try FileManager.default.copyItem(at: journal, to: copiedJournal)
    let recovered = LockScreenWallpaperSelection(
      storeURL: copiedStore, journalURL: copiedJournal, reload: {})
    try recovered.recover()
    let restored = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: copiedStore), format: nil)
        as? [String: Any])
    XCTAssertEqual(restored as NSDictionary, original as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: copiedJournal.path))
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
  func testWallpaperRevisionInvalidatesEverySpaceAndKeepsRestorationOriginals() throws {
    var original = fixture()
    var spaces = try XCTUnwrap(original["Spaces"] as? [String: Any])
    spaces["space-b"] = ["Default": node("default-b"), "Displays": ["one": node("other-space")]]
    original["Spaces"] = spaces
    try write(original)
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 })
    try selection.synchronize(displays: ["one"], revision: "wallpaper-a")
    let first = try readStore()
    try selection.synchronize(displays: ["one"], revision: "wallpaper-b")
    let second = try readStore()
    func configurations(_ root: [String: Any]) throws -> [Data] {
      let displays = try XCTUnwrap(root["Displays"] as? [String: [String: Any]])
      let spaces = try XCTUnwrap(root["Spaces"] as? [String: [String: Any]])
      var nodes = [try XCTUnwrap(displays["one"])]
      for key in spaces.keys.sorted() {
        let perDisplay = try XCTUnwrap(spaces[key]?["Displays"] as? [String: [String: Any]])
        nodes.append(try XCTUnwrap(perDisplay["one"]))
      }
      return try nodes.flatMap { node in
        try ["Desktop", "Idle"].map { key in
          let value = try XCTUnwrap(node[key] as? [String: Any])
          let content = try XCTUnwrap(value["Content"] as? [String: Any])
          let choices = try XCTUnwrap(content["Choices"] as? [[String: Any]])
          return try XCTUnwrap(choices.first?["Configuration"] as? Data)
        }
      }
    }
    let before = try configurations(first)
    let after = try configurations(second)
    for (old, new) in zip(before, after) { XCTAssertNotEqual(old, new) }
    XCTAssertEqual(reloads, 2)
    try selection.synchronize(displays: ["one"], revision: "wallpaper-b")
    XCTAssertEqual(reloads, 2, "Unchanged publication must not reload WallpaperAgent")
    XCTAssertEqual(try readStore() as NSDictionary, second as NSDictionary)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
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

  @MainActor
  func testUnchangedJournalIsNotRewrittenForRepeatedOrRevisionOnlySynchronization() throws {
    let original = fixture()
    try write(original)
    var writes = 0
    var removes = 0
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        if data == nil { removes += 1 } else { writes += 1 }
      })
    try selection.synchronize(displays: ["one"], revision: "first")
    let journalBytes = try Data(contentsOf: journal)
    let firstStore = try Data(contentsOf: store)
    try selection.synchronize(displays: ["one"], revision: "first")
    XCTAssertEqual(try Data(contentsOf: store), firstStore)
    try selection.synchronize(displays: ["one"], revision: "second")
    XCTAssertNotEqual(try Data(contentsOf: store), firstStore)
    XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(reloads, 2)
    try selection.synchronize(displays: [])
    try selection.synchronize(displays: [])
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(removes, 1)
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testExpansionFailureCannotCommitStoreAndRetryKeepsBothOriginals() throws {
    let original = fixture()
    try write(original)
    var failExpansion = false
    var writes = 0
    var reloads = 0
    var storeBeforeCommit = try Data(contentsOf: store)
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: {
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.journal.path))
        XCTAssertNotEqual(try Data(contentsOf: self.store), storeBeforeCommit)
        reloads += 1
      },
      persistJournal: { url, data in
        XCTAssertEqual(try Data(contentsOf: self.store), storeBeforeCommit)
        if failExpansion { throw CocoaError(.fileWriteOutOfSpace) }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        writes += 1
      })
    try selection.synchronize(displays: ["one"])
    storeBeforeCommit = try Data(contentsOf: store)
    let firstJournal = try Data(contentsOf: journal)
    failExpansion = true
    XCTAssertThrowsError(try selection.synchronize(displays: ["one", "two"]))
    XCTAssertEqual(try Data(contentsOf: store), storeBeforeCommit)
    XCTAssertEqual(try Data(contentsOf: journal), firstJournal)
    XCTAssertEqual(reloads, 1)
    try assertDiskRecovery(restores: original)
    failExpansion = false
    try selection.synchronize(displays: ["one", "two"])
    XCTAssertEqual(writes, 2)
    XCTAssertEqual(reloads, 2)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testConcurrentStoreChangeRetainsUnionWithoutOverwritingExternalBytes() throws {
    var external = fixture()
    try write(external)
    external["Unrelated"] = "concurrent external update"
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        try self.write(external)
      })
    XCTAssertThrowsError(try selection.synchronize(displays: ["one"]))
    XCTAssertEqual(reloads, 0)
    XCTAssertEqual(try readStore() as NSDictionary, external as NSDictionary)
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, external as NSDictionary)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testReloadRetryUsesPersistedUnionWithoutRewritingIt() throws {
    let original = fixture()
    try write(original)
    var failReload = true
    var writes = 0
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal,
      reload: {
        reloads += 1
        if failReload { throw CocoaError(.executableRuntimeMismatch) }
      },
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        writes += 1
      })
    XCTAssertThrowsError(try selection.synchronize(displays: ["one"]))
    let committedStore = try Data(contentsOf: store)
    let committedJournal = try Data(contentsOf: journal)
    try assertDiskRecovery(restores: original)
    failReload = false
    try selection.synchronize(displays: ["one"])
    XCTAssertEqual(reloads, 2)
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(try Data(contentsOf: store), committedStore)
    XCTAssertEqual(try Data(contentsOf: journal), committedJournal)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testPruneFailureKeepsRecoveryUnionOnDisk() throws {
    let original = fixture()
    try write(original)
    var failPrune = false
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        if failPrune {
          XCTAssertEqual(reloads, 2, "Prune must follow the successful store reload")
          throw CocoaError(.fileWriteOutOfSpace)
        }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
      })
    try selection.synchronize(displays: ["one", "two"])
    let union = try Data(contentsOf: journal)
    failPrune = true
    XCTAssertThrowsError(try selection.synchronize(displays: ["two"]))
    XCTAssertEqual(try Data(contentsOf: journal), union)
    let displays = try XCTUnwrap(try readStore()["Displays"] as? [String: [String: Any]])
    XCTAssertEqual(provider(try XCTUnwrap(displays["one"]), key: "Idle"), "display-one-idle")
    XCTAssertEqual(
      provider(try XCTUnwrap(displays["two"]), key: "Idle"),
      LockScreenConfiguration.extensionIdentifier)
    let recovered = LockScreenWallpaperSelection(storeURL: store, journalURL: journal, reload: {})
    try recovered.recover()
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
  }

  @MainActor
  func testRemoveFailureRetainsMemoryAndDiskUntilRetrySucceeds() throws {
    let original = fixture()
    try write(original)
    var failRemove = true
    var removeAttempts = 0
    var reloads = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: { reloads += 1 },
      persistJournal: { url, data in
        if data == nil {
          removeAttempts += 1
          XCTAssertEqual(try self.readStore() as NSDictionary, original as NSDictionary)
          if failRemove { throw CocoaError(.fileWriteNoPermission) }
        }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
      })
    try selection.synchronize(displays: ["one"])
    let union = try Data(contentsOf: journal)
    XCTAssertThrowsError(try selection.synchronize(displays: []))
    XCTAssertEqual(try Data(contentsOf: journal), union)
    XCTAssertEqual(try readStore() as NSDictionary, original as NSDictionary)
    try assertDiskRecovery(restores: original)
    failRemove = false
    try selection.synchronize(displays: [])
    XCTAssertEqual(removeAttempts, 2)
    XCTAssertEqual(reloads, 2, "Retrying journal removal alone must not reload the store")
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testNewAndDisappearingSpacesAreReconciledWithUnchangedInputs() throws {
    try write(fixture())
    var writes = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {},
      persistJournal: { url, data in
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
        if data != nil { writes += 1 }
      })
    try selection.synchronize(displays: ["one"], revision: "same")
    var changed = try readStore()
    var spaces = try XCTUnwrap(changed["Spaces"] as? [String: Any])
    spaces["space-b"] = ["Default": node("new-default"), "Displays": [String: Any]()]
    changed["Spaces"] = spaces
    try write(changed)
    try selection.synchronize(displays: ["one"], revision: "same")
    XCTAssertEqual(writes, 2)
    var selected = try readStore()
    var selectedSpaces = try XCTUnwrap(selected["Spaces"] as? [String: [String: Any]])
    let newDisplays = try XCTUnwrap(selectedSpaces["space-b"]?["Displays"] as? [String: [String: Any]])
    XCTAssertEqual(
      provider(try XCTUnwrap(newDisplays["one"]), key: "Idle"),
      LockScreenConfiguration.extensionIdentifier)
    selectedSpaces.removeValue(forKey: "space-a")
    selected["Spaces"] = selectedSpaces
    try write(selected)
    try selection.synchronize(displays: ["one"], revision: "same")
    try selection.synchronize(displays: [])
    let restoredSpaces = try XCTUnwrap(try readStore()["Spaces"] as? [String: [String: Any]])
    XCTAssertNil(restoredSpaces["space-a"])
    XCTAssertEqual(
      restoredSpaces["space-b"]?["Default"] as? NSDictionary, node("new-default") as NSDictionary)
    XCTAssertTrue(
      try XCTUnwrap(restoredSpaces["space-b"]?["Displays"] as? [String: Any]).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
  }

  @MainActor
  func testDecodedEmptyJournalIsRemovedAndMalformedJournalIsPreserved() throws {
    try write(fixture())
    try PropertyListEncoder().encode([String]()).write(to: journal)
    var removes = 0
    let selection = LockScreenWallpaperSelection(
      storeURL: store, journalURL: journal, reload: {},
      persistJournal: { url, data in
        if data == nil { removes += 1 }
        try LockScreenWallpaperSelection.persistJournalFile(url, data)
      })
    try selection.recover()
    XCTAssertEqual(removes, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    let malformed = Data("not a property list".utf8)
    try malformed.write(to: journal)
    XCTAssertThrowsError(try selection.recover())
    XCTAssertEqual(try Data(contentsOf: journal), malformed)
    XCTAssertEqual(removes, 1)
  }

}
