import Darwin
import XCTest
@testable import WallpaperMachine

/// Staging for `file` and `directory` wallpaper properties.
///
/// The contract under test is what a wallpaper page and the control panel observe: the
/// bytes reachable through `pageValue`, the entries `randomFile` may return, the folder
/// left on disk, and the error raised when the project cannot be written to.
@MainActor
final class UserAssetStoreTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var previousHome: String?

    private var managedRoot: URL { ClientPaths.userAssetsURL }
    private var staging: URL { UserAssetStore.stagingRoot(projectURL: project) }

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-assets-tests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        setenv("WALLPAPER_MACHINE_HOME", root.appendingPathComponent("home").path, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome {
            setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
        } else {
            unsetenv("WALLPAPER_MACHINE_HOME")
        }
        // A read-only project directory would otherwise survive the run.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeStore(
        wallpaperId: String = "2001", watcher: UserAssetStore.WatcherFactory? = nil
    ) -> UserAssetStore {
        UserAssetStore(
            projectURL: project, wallpaperId: wallpaperId,
            watcherFactory: watcher ?? { url, onChange in
                ManualDirectoryWatcher(url: url, trigger: onChange)
            })
    }

    @discardableResult
    private func writeSource(_ name: String, bytes: String = "asset-bytes", in directory: URL? = nil) throws -> URL {
        let parent = directory ?? root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    /// The page does `'file:///' + value`; this is the inverse of that plus the three
    /// escapes the store applies, so a match proves the value names the staged file.
    private func path(fromPageValue value: String) -> String {
        "/" + value
            .replacingOccurrences(of: "%3F", with: "?")
            .replacingOccurrences(of: "%23", with: "#")
            .replacingOccurrences(of: "%25", with: "%")
    }

    private func inode(_ path: String) throws -> UInt64 {
        var status = stat()
        guard stat(path, &status) == 0 else {
            throw XCTSkip("stat failed for \(path)")
        }
        return UInt64(status.st_ino)
    }

    /// Every regular file the managed store holds for a property, ordered by name.
    /// Read straight off disk rather than through the store, so a test cannot pass by
    /// agreeing with the implementation about where the bytes went.
    private func storedFiles(wallpaperId: String, propertyId: String) -> [URL] {
        let directory = managedRoot
            .appendingPathComponent(wallpaperId, isDirectory: true)
            .appendingPathComponent(propertyId, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func manifest(wallpaperId: String = "2001") -> UserAssetManifest {
        ManagedUserAssetStore().manifest(wallpaperId: wallpaperId)
    }

    private func assertFails(
        _ expected: UserAssetError.Code, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            try body()
            XCTFail("expected \(expected.rawValue)", file: file, line: line)
        } catch let error as UserAssetError {
            XCTAssertEqual(error.code, expected, file: file, line: line)
            XCTAssertFalse(
                error.localizedDescription.isEmpty, "the failure must carry a reason",
                file: file, line: line)
        } catch {
            XCTFail("expected UserAssetError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Single file

    func testImportedFileIsReadableThroughItsPageValueWithoutASecondCopyOfTheBytes() throws {
        let source = try writeSource("clouds.png", bytes: "original-bytes")
        let store = makeStore()
        let asset = try store.importFile(at: source, propertyId: "background", filter: .image)

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path(fromPageValue: asset.pageValue))),
            Data("original-bytes".utf8))
        XCTAssertTrue(asset.stagedPath.hasPrefix(staging.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the user's own file is copied from, never moved")

        // The bridge entry is a hard link onto the app's managed copy, not onto the
        // user's file and not a second set of bytes: importing costs one copy, and the
        // user deleting their original cannot take the staged bytes with it.
        let stored = try XCTUnwrap(storedFiles(wallpaperId: "2001", propertyId: "background").first)
        XCTAssertEqual(try inode(stored.path), try inode(asset.stagedPath))
        XCTAssertNotEqual(try inode(source.path), try inode(stored.path))
        XCTAssertTrue(store.isManaged(propertyId: "background"))
    }

    func testPageValueSurvivesSpacesCJKAndURLPunctuation() throws {
        let name = "a b#c?d%e 壁纸+x&y'z.png"
        let source = try writeSource(name, bytes: "punctuated")
        let asset = try makeStore().importFile(at: source, propertyId: "background", filter: .image)

        XCTAssertEqual(path(fromPageValue: asset.pageValue), asset.stagedPath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path(fromPageValue: asset.pageValue))),
            Data("punctuated".utf8))
        // Only the three URL-significant characters are escaped: a page that uses the
        // value as a plain path must still see the rest literally.
        XCTAssertTrue(asset.pageValue.contains("a b%23c%3Fd%25e 壁纸+x&y'z.png"))
        XCTAssertFalse(asset.pageValue.hasPrefix("/"))
    }

    func testExtensionOutsideTheFilterIsNotStaged() throws {
        let store = makeStore()
        let video = try writeSource("clip.webm")
        assertFails(.unsupportedType) { try store.importFile(at: video, propertyId: "background", filter: .image) }
        XCTAssertNil(store.randomFile(propertyId: "background"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("background/clip.webm").path))
    }

    func testFilterMatchingIgnoresExtensionCase() throws {
        let source = try writeSource("Clouds.PNG")
        let asset = try makeStore().importFile(at: source, propertyId: "background", filter: .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.stagedPath))
    }

    func testUnrestrictedPropertyTakesImagesAndVideosButNothingElse() throws {
        let folder = root.appendingPathComponent("mixed", isDirectory: true)
        try writeSource("still.png", in: folder)
        try writeSource("clip.webm", in: folder)
        try writeSource("notes.txt", in: folder)
        try writeSource("tool.sh", in: folder)

        let assets = try makeStore().importDirectory(
            at: folder, propertyId: "asset", filter: .any, limit: 100)

        XCTAssertEqual(assets.map { URL(fileURLWithPath: $0.stagedPath).lastPathComponent },
                       ["clip.webm", "still.png"])
    }

    func testReadOnlyProjectDirectoryFailsWithAReason() throws {
        let source = try writeSource("clouds.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: project.path)
        let store = makeStore()
        assertFails(.projectNotWritable) { try store.importFile(at: source, propertyId: "background", filter: .image) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testSourceInsideTheStagingRootIsRefused() throws {
        let store = makeStore()
        let first = try writeSource("clouds.png")
        let staged = try store.importFile(at: first, propertyId: "background", filter: .image)
        assertFails(.sourceInsideStaging) {
            try store.importFile(at: URL(fileURLWithPath: staged.stagedPath), propertyId: "second", filter: .image)
        }
    }

    func testReimportingAPropertyDropsTheAssetItReplaces() throws {
        let store = makeStore()
        let first = try store.importFile(at: try writeSource("first.png"), propertyId: "background", filter: .image)
        let second = try store.importFile(at: try writeSource("second.png"), propertyId: "background", filter: .image)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.stagedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.stagedPath))
        XCTAssertEqual(store.stagedFiles(propertyId: "background"), [second])
    }

    // MARK: - Directory

    func testDirectoryImportStagesOnlyMatchingFilesAtOneLevel() throws {
        let folder = root.appendingPathComponent("gallery", isDirectory: true)
        try writeSource("a.png", in: folder)
        try writeSource("b.jpg", in: folder)
        try writeSource("notes.txt", in: folder)
        try writeSource("nested.png", in: folder.appendingPathComponent("inner", isDirectory: true))

        let assets = try makeStore().importDirectory(
            at: folder, propertyId: "gallery", filter: .image, limit: 100)

        XCTAssertEqual(assets.map { URL(fileURLWithPath: $0.stagedPath).lastPathComponent }, ["a.png", "b.jpg"])
    }

    func testFileCountLimitTruncatesAndSaysSo() throws {
        let folder = root.appendingPathComponent("gallery", isDirectory: true)
        for index in 0..<5 { try writeSource("image-\(index).png", in: folder) }
        let store = makeStore()

        let capped = try store.importDirectory(at: folder, propertyId: "gallery", filter: .image, limit: 3)
        XCTAssertEqual(capped.count, 3)
        XCTAssertTrue(store.isTruncated(propertyId: "gallery"))

        let complete = try store.importDirectory(at: folder, propertyId: "gallery", filter: .image, limit: 10)
        XCTAssertEqual(complete.count, 5)
        XCTAssertFalse(store.isTruncated(propertyId: "gallery"))
    }

    func testDirectoryChangeBurstProducesOneCoalescedDiff() throws {
        let folder = root.appendingPathComponent("gallery", isDirectory: true)
        try writeSource("keep.png", in: folder)
        let removedSource = try writeSource("gone.png", in: folder)
        var watcher: ManualDirectoryWatcher?
        let store = makeStore(watcher: { url, onChange in
            let made = ManualDirectoryWatcher(url: url, trigger: onChange)
            watcher = made
            return made
        })
        var diffs: [(added: [UserAssetImport], removed: [UserAssetImport])] = []
        store.onDirectoryChanged = { _, added, removed in diffs.append((added, removed)) }
        try store.importDirectory(at: folder, propertyId: "gallery", filter: .image, limit: 100)

        try writeSource("added-1.png", in: folder)
        try writeSource("added-2.png", in: folder)
        try FileManager.default.removeItem(at: removedSource)
        try XCTUnwrap(watcher).fire()

        XCTAssertEqual(diffs.count, 1, "a settled burst must report one diff, not one per file")
        let diff = try XCTUnwrap(diffs.first)
        XCTAssertEqual(diff.added.map { URL(fileURLWithPath: $0.stagedPath).lastPathComponent },
                       ["added-1.png", "added-2.png"])
        XCTAssertEqual(diff.removed.map { URL(fileURLWithPath: $0.stagedPath).lastPathComponent }, ["gone.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(diff.removed.first).stagedPath))
        XCTAssertEqual(store.stagedFiles(propertyId: "gallery").count, 3)
    }

    func testUnchangedDirectoryReportsNoDiff() throws {
        let folder = root.appendingPathComponent("gallery", isDirectory: true)
        try writeSource("a.png", in: folder)
        var watcher: ManualDirectoryWatcher?
        let store = makeStore(watcher: { url, onChange in
            let made = ManualDirectoryWatcher(url: url, trigger: onChange)
            watcher = made
            return made
        })
        var diffs = 0
        store.onDirectoryChanged = { _, _, _ in diffs += 1 }
        try store.importDirectory(at: folder, propertyId: "gallery", filter: .image, limit: 100)

        try XCTUnwrap(watcher).fire()
        XCTAssertEqual(diffs, 0)
    }

    func testReplacedFileIsRestagedSoTheStagedBytesFollowTheSource() throws {
        let folder = root.appendingPathComponent("gallery", isDirectory: true)
        let source = try writeSource("a.png", bytes: "before", in: folder)
        var watcher: ManualDirectoryWatcher?
        let store = makeStore(watcher: { url, onChange in
            let made = ManualDirectoryWatcher(url: url, trigger: onChange)
            watcher = made
            return made
        })
        let staged = try XCTUnwrap(
            try store.importDirectory(at: folder, propertyId: "gallery", filter: .image, limit: 100).first)

        // A replace, not an in-place write: the staged hard link would otherwise still
        // point at the old inode.
        try FileManager.default.removeItem(at: source)
        try Data("after-the-replacement".utf8).write(to: source)
        try XCTUnwrap(watcher).fire()

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staged.stagedPath)),
                       Data("after-the-replacement".utf8))
    }

    // MARK: - Random selection

    func testRandomFileIsNilWithoutStagedEntries() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let store = makeStore()

        XCTAssertNil(store.randomFile(propertyId: "gallery"))
        try store.importDirectory(at: empty, propertyId: "gallery", filter: .image, limit: 100)
        XCTAssertNil(store.randomFile(propertyId: "gallery"))
    }

    func testRandomFileOnlyReturnsStagedEntriesAndDoesNotRescan() throws {
        let folder = root.appendingPathComponent("gallery", isDirectory: true)
        for index in 0..<3 { try writeSource("image-\(index).png", in: folder) }
        let store = makeStore()
        let staged = Set(try store.importDirectory(
            at: folder, propertyId: "gallery", filter: .image, limit: 100).map(\.stagedPath))

        // Added without a change notification: an implementation that walked the folder on
        // every call would start handing this one out.
        try writeSource("unnoticed.png", in: folder)

        var seen = Set<String>()
        for _ in 0..<60 {
            let pick = try XCTUnwrap(store.randomFile(propertyId: "gallery"))
            XCTAssertTrue(staged.contains(pick.stagedPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: pick.stagedPath))
            seen.insert(pick.stagedPath)
        }
        XCTAssertEqual(seen, staged, "selection must be able to reach every staged entry")
    }

    // MARK: - Removal

    func testClearingAPropertyRemovesItsStagingAndStopsWatching() throws {
        let folder = root.appendingPathComponent("gallery", isDirectory: true)
        let source = try writeSource("a.png", in: folder)
        var watcher: ManualDirectoryWatcher?
        let store = makeStore(watcher: { url, onChange in
            let made = ManualDirectoryWatcher(url: url, trigger: onChange)
            watcher = made
            return made
        })
        try store.importDirectory(at: folder, propertyId: "gallery", filter: .image, limit: 100)
        try store.importFile(at: try writeSource("solo.png"), propertyId: "background", filter: .image)

        store.clear(propertyId: "gallery")

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("gallery").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("background").path))
        XCTAssertTrue(try XCTUnwrap(watcher).isStopped)
        XCTAssertNil(store.randomFile(propertyId: "gallery"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the user's own file must survive")
    }

    func testClearAllRemovesTheWholeStagingDirectoryAndNothingElse() throws {
        let store = makeStore()
        let authored = project.appendingPathComponent("index.html")
        try Data("<html></html>".utf8).write(to: authored)
        try store.importFile(at: try writeSource("clouds.png"), propertyId: "background", filter: .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        store.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: authored.path))
        XCTAssertNil(store.randomFile(propertyId: "background"))
    }

    // MARK: - Managed storage

    /// The bridge inside the project is derived. Wiping all of it must cost nothing but
    /// the work of relinking, because the bytes live in the managed store — which the
    /// user's own file being gone as well is what actually proves.
    func testDeletingTheWholeBridgeLosesNothing() throws {
        let source = try writeSource("clouds.png", bytes: "survives-the-bridge")
        let first = try makeStore().importFile(at: source, propertyId: "background", filter: .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.stagedPath))

        try FileManager.default.removeItem(at: staging)
        try FileManager.default.removeItem(at: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.stagedPath))

        let rebuilt = try makeStore().importFile(at: source, propertyId: "background", filter: .image)
        XCTAssertEqual(rebuilt.stagedPath, first.stagedPath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: rebuilt.stagedPath)),
            Data("survives-the-bridge".utf8))
    }

    /// Deleting the wallpaper and downloading it again replaces the whole project
    /// folder. The property's asset is keyed on the stable wallpaper id, so it comes
    /// back — and it comes back even though the user's own file is gone too.
    func testStoreSurvivesDeletingAndRecreatingTheProject() throws {
        let source = try writeSource("clouds.png", bytes: "survives-redownload")
        try makeStore().importFile(at: source, propertyId: "background", filter: .image)

        try FileManager.default.removeItem(at: project)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let store = makeStore()
        let restored = try store.importFile(at: source, propertyId: "background", filter: .image)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: restored.stagedPath)),
            Data("survives-redownload".utf8))
        XCTAssertTrue(store.isSourceMissing(propertyId: "background"),
                      "the user's own file is gone, and the panel has to be able to say so")
        XCTAssertTrue(store.isManaged(propertyId: "background"))
    }

    /// A second wallpaper id is a different wallpaper. A bridge this build wrote names
    /// its owner, so the other id cannot mistake it for a round-6 staging directory and
    /// adopt files that are not its own.
    func testAnotherWallpaperIdDoesNotInheritTheStoredAsset() throws {
        let source = try writeSource("clouds.png")
        try makeStore(wallpaperId: "2001").importFile(at: source, propertyId: "background", filter: .image)
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(
            try Data(contentsOf: staging.appendingPathComponent(UserAssetStore.ownerMarkerName)),
            Data("2001".utf8), "the bridge has to say whose it is")
        assertFails(.sourceUnreadable) {
            try makeStore(wallpaperId: "3002").importFile(
                at: source, propertyId: "background", filter: .image)
        }
        XCTAssertTrue(
            manifest(wallpaperId: "3002").properties.isEmpty,
            "nothing may be recorded for a wallpaper that owns none of this")
        XCTAssertNoThrow(
            try makeStore(wallpaperId: "2001").importFile(
                at: source, propertyId: "background", filter: .image),
            "the same wallpaper id still recovers its own asset")
    }

    /// An unchanged selection must not be re-copied on every launch. The stored file's
    /// inode is the proof: a fresh copy would be a new one.
    func testReimportingAnUnchangedSelectionCopiesNothing() throws {
        let source = try writeSource("clouds.png", bytes: "stable")
        try makeStore().importFile(at: source, propertyId: "background", filter: .image)
        let stored = try XCTUnwrap(storedFiles(wallpaperId: "2001", propertyId: "background").first)
        let before = try inode(stored.path)

        for _ in 0..<3 {
            try makeStore().importFile(at: source, propertyId: "background", filter: .image)
        }

        let after = storedFiles(wallpaperId: "2001", propertyId: "background")
        XCTAssertEqual(after.count, 1, "a second copy of an unchanged file is a leak")
        XCTAssertEqual(try inode(XCTUnwrap(after.first).path), before)
    }

    /// An asset present in neither the user's folder nor the store is missing, and the
    /// property has to fail loudly rather than come back silently empty.
    func testAnAssetMissingFromBothPlacesIsReportedRatherThanCleared() throws {
        let source = try writeSource("clouds.png")
        let store = makeStore()
        try store.importFile(at: source, propertyId: "background", filter: .image)

        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(
            at: managedRoot.appendingPathComponent("2001/background", isDirectory: true))

        assertFails(.sourceUnreadable) {
            try makeStore().importFile(at: source, propertyId: "background", filter: .image)
        }
    }

    /// A round-6 project still holds hard links into the user's file and nothing in the
    /// store. Absorbing them must not touch the old location, and must happen once.
    func testALegacyStagingDirectoryIsMigratedOnceWithoutBeingDeleted() throws {
        let legacy = staging.appendingPathComponent("background", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let original = try writeSource("clouds.png", bytes: "round-six-bytes")
        let staged = legacy.appendingPathComponent("clouds.png")
        try FileManager.default.linkItem(at: original, to: staged)
        try FileManager.default.removeItem(at: original)

        let restored = try makeStore().importFile(at: original, propertyId: "background", filter: .image)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: restored.stagedPath)),
            Data("round-six-bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path),
                      "migration publishes into the store; it never deletes the old location")
        let record = try XCTUnwrap(manifest().properties["background"])
        XCTAssertEqual(record.migratedLegacyPaths, [legacy.path])
        XCTAssertEqual(record.sourcePath, original.path,
                       "the path recorded is the user's original, not the staged link")

        let stored = try XCTUnwrap(storedFiles(wallpaperId: "2001", propertyId: "background").first)
        let before = try inode(stored.path)
        try makeStore().importFile(at: original, propertyId: "background", filter: .image)
        XCTAssertEqual(storedFiles(wallpaperId: "2001", propertyId: "background").count, 1)
        XCTAssertEqual(try inode(XCTUnwrap(storedFiles(wallpaperId: "2001", propertyId: "background").first).path),
                       before, "migration is recorded, so a second launch copies nothing")
    }

    // MARK: - Purging

    func testPurgeKeepsEveryAssetTheManifestStillListsAndReclaimsTheRest() throws {
        let store = makeStore()
        try store.importFile(at: try writeSource("kept.png", bytes: "keep-me"), propertyId: "background", filter: .image)
        let kept = try XCTUnwrap(storedFiles(wallpaperId: "2001", propertyId: "background").first)

        // An orphan of exactly the shape a crash between copying and recording leaves.
        let orphan = managedRoot
            .appendingPathComponent("2001/background/deadbeefdeadbeefdeadbeefdeadbeef", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(String(repeating: "x", count: 512).utf8).write(to: orphan.appendingPathComponent("orphan.png"))
        // A whole wallpaper folder nothing recorded.
        let strayWallpaper = managedRoot.appendingPathComponent("9999/gallery", isDirectory: true)
        try FileManager.default.createDirectory(at: strayWallpaper, withIntermediateDirectories: true)
        try Data(String(repeating: "y", count: 256).utf8).write(to: strayWallpaper.appendingPathComponent("stray.png"))

        let released = try UserAssetStorage.purgeUnreferencedDerivedCaches()

        XCTAssertEqual(released, 768, "only the two unreferenced files can be reclaimed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path),
                      "a referenced asset is never a purge candidate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("9999").path))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: store.stagedFiles(propertyId: "background")[0].stagedPath)),
            Data("keep-me".utf8))
    }

    /// A property whose source has gone missing is exactly the case where the store's
    /// copy is the only copy. Purging must not be what finally loses it.
    func testPurgeKeepsTheStoredCopyOfAnAssetWhoseSourceIsGone() throws {
        let source = try writeSource("clouds.png", bytes: "last-copy")
        try makeStore().importFile(at: source, propertyId: "background", filter: .image)
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(try UserAssetStorage.purgeUnreferencedDerivedCaches(), 0)

        let store = makeStore()
        let restored = try store.importFile(at: source, propertyId: "background", filter: .image)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: restored.stagedPath)), Data("last-copy".utf8))
    }
}

/// Stands in for `DirectoryWatcher` so the store's diffing is exercised without FSEvents
/// timing. `DirectoryWatcherTests` covers the real stream.
private final class ManualDirectoryWatcher: DirectoryWatching {
    let url: URL
    private let trigger: @MainActor () -> Void
    private(set) var isStopped = false

    init(url: URL, trigger: @escaping @MainActor () -> Void) {
        self.url = url
        self.trigger = trigger
    }

    @MainActor func fire() { trigger() }

    func stop() { isStopped = true }
}
