import Darwin
import XCTest
@testable import MacWallpaperEngine

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

    private var staging: URL { UserAssetStore.stagingRoot(projectURL: project) }

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["MAC_WALLPAPER_ENGINE_HOME"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-assets-tests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        setenv("MAC_WALLPAPER_ENGINE_HOME", root.appendingPathComponent("home").path, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome {
            setenv("MAC_WALLPAPER_ENGINE_HOME", previousHome, 1)
        } else {
            unsetenv("MAC_WALLPAPER_ENGINE_HOME")
        }
        // A read-only project directory would otherwise survive the run.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeStore(watcher: UserAssetStore.WatcherFactory? = nil) -> UserAssetStore {
        if let watcher {
            return UserAssetStore(projectURL: project, watcherFactory: watcher)
        }
        return UserAssetStore(projectURL: project, watcherFactory: { url, onChange in
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

    func testImportedFileIsAHardLinkReachableThroughItsPageValue() throws {
        let source = try writeSource("clouds.png", bytes: "original-bytes")
        let asset = try makeStore().importFile(at: source, propertyId: "background", filter: .image)

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path(fromPageValue: asset.pageValue))),
            Data("original-bytes".utf8))
        XCTAssertEqual(try inode(source.path), try inode(asset.stagedPath),
                       "the staged entry must share the original's inode, not copy it")
        XCTAssertTrue(asset.stagedPath.hasPrefix(staging.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
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
