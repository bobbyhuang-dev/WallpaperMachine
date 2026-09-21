import XCTest
@testable import WallpaperMachine

final class DeletionTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("Library") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testMovesOnlyManagedCopyAndPreservesSource() throws {
        let source = root.appendingPathComponent("source")
        let copy = library.appendingPathComponent("123")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("video.mp4"))
        try FileManager.default.copyItem(at: source, to: copy)
        let trash = root.appendingPathComponent("TestTrash")
        try WallpaperDeletionService.moveToTrash(id: "123", library: library) { url in
            XCTAssertEqual(url.standardizedFileURL, copy.resolvingSymlinksInPath().standardizedFileURL)
            try FileManager.default.moveItem(at: url, to: trash)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("video.mp4")),
                       try Data(contentsOf: trash.appendingPathComponent("video.mp4")))
    }

    func testRejectsTraversalMissingFoldersAndSymlinks() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("link"), withDestinationURL: outside)
        for id in ["", ".", "..", "../outside", "/tmp", "nested/item", "missing", "link"] {
            XCTAssertThrowsError(try WallpaperDeletionService.moveToTrash(id: id, library: library) { _ in
                XCTFail("Must not recycle invalid ID: \(id)")
            })
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testTrashFailureLeavesWallpaperInLibrary() throws {
        let copy = library.appendingPathComponent("123")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WallpaperDeletionService.moveToTrash(id: "123", library: library) { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }
}
