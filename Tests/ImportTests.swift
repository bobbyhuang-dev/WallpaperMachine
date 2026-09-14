import XCTest
@testable import MacWallpaperEngine

final class ImportTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("managed/Library") }
    private let importer = WallpaperImportService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-wallpaper-engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func project(_ id: String, file: String = "movie.mp4", type: String = "video") throws -> URL {
        let url = root.appendingPathComponent("sources/\(id)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("video-content".utf8).write(to: url.appendingPathComponent("movie.mp4"))
        try JSONSerialization.data(withJSONObject: ["title": "Test \(id)", "type": type, "file": file])
            .write(to: url.appendingPathComponent("project.json"))
        return url
    }
    private func importOne(_ url: URL, policy: WallpaperImportService.DuplicatePolicy = .skip) async throws -> WallpaperImportService.Report {
        try await importer.importItems([url], into: library, duplicates: policy, progress: { _ in })
    }

    func testImportPreservesOriginalAndCompleteContent() async throws {
        let source = try project("123456")
        let report = try await importOne(source)
        XCTAssertEqual(report.importedIDs, ["123456"])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")),
                       try Data(contentsOf: library.appendingPathComponent("123456/movie.mp4")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("123456/project.json").path))
    }
    func testDuplicatesNeverOverwriteExistingWallpaper() async throws {
        let source = try project("123456")
        _ = try await importOne(source)
        try Data("different-content".utf8).write(to: source.appendingPathComponent("movie.mp4"))
        let skipped = try await importOne(source)
        XCTAssertEqual(skipped.skipped, ["123456"])
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("123456/movie.mp4"), encoding: .utf8), "video-content")
        let kept = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(kept.importedIDs.count, 1)
        XCTAssertNotEqual(kept.importedIDs.first, "123456")
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("\(try XCTUnwrap(kept.importedIDs.first))/movie.mp4"), encoding: .utf8), "different-content")
    }
    func testTraversalProjectIsRejectedWithoutLibraryEntry() async throws {
        let source = try project("escape", file: "../movie.mp4")
        let report = try await importOne(source)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("escape").path))
    }
    func testSymlinkContentIsRejectedWithoutPartialCommit() async throws {
        let source = try project("link")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: root)
        let report = try await importOne(source)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("link").path))
    }
    func testInvalidProjectDoesNotPreventValidSiblingImport() async throws {
        let invalid = try project("invalid", file: "missing.mp4")
        let valid = try project("valid")
        let result = try await importer.importItems([invalid, valid], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(result.importedIDs, ["valid"])
        XCTAssertEqual(result.failures.count, 1)
    }
    func testImportFromManagedLibraryRejected() async throws {
        let source = try project("123")
        _ = try await importOne(source)
        let result = try await importOne(library.appendingPathComponent("123"), policy: .keepBoth)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }
    func testCancellationNeverCommitsIncompleteProject() async throws {
        let source = try project("cancelled")
        let task = Task {
            try await importer.importItems([source], into: library, duplicates: .skip, progress: { _ in })
        }
        task.cancel()
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("cancelled").path))
    }
    func testStandaloneVideoProducesPlayableManifest() async throws {
        let video = root.appendingPathComponent("My Video.mp4")
        try Data("video-content".utf8).write(to: video)
        let result = try await importOne(video)
        let id = try XCTUnwrap(result.importedIDs.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: library.appendingPathComponent("\(id)/project.json"))) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "video")
        XCTAssertEqual(json["file"] as? String, "My Video.mp4")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("\(id)/My Video.mp4")), try Data(contentsOf: video))
    }

    func testInvalidExistingDestinationIsNotReportedInstalled() async throws {
        let source = try project("123")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("not a wallpaper".utf8).write(to: library.appendingPathComponent("123"))
        let result = try await importOne(source)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testByteOrderMarkedManifestIsRejectedBeforeCommit() async throws {
        let source = try project("bom")
        let manifest = source.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifest)
        try (Data([0xEF, 0xBB, 0xBF]) + original).write(to: manifest)
        let result = try await importOne(source)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("bom").path))
    }
}
