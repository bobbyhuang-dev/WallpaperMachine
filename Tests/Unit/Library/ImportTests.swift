import Darwin
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

    private func downloadedProject(_ id: String, staging: URL) throws -> URL {
        let source = try project(id)
        let destination = staging.appendingPathComponent("steamapps/workshop/content/431960/\(id)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private func assertDownloadRejected(_ id: String, staging: URL, library destination: URL? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await importer.importDownloadedItem(id, from: staging, into: destination ?? library)
            XCTFail("Unsafe or incomplete download was accepted", file: file, line: line)
        } catch {}
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

    func testDownloadedProjectMovesCompleteTreeWithoutCopying() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        let nested = source.appendingPathComponent("assets/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("texture.bin")
        try Data("nested-content".utf8).write(to: payload)
        let originalIdentity = try FileManager.default.attributesOfItem(atPath: payload.path)[.systemFileNumber] as? NSNumber
        try await importer.importDownloadedItem("123", from: staging, into: library)
        let installed = library.appendingPathComponent("123/assets/nested/texture.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: installed), Data("nested-content".utf8))
        XCTAssertEqual(try XCTUnwrap(originalIdentity),
                       try XCTUnwrap(FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? NSNumber))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedUnsafeTreesNeverPublishPartialItems() async throws {
        for (id, specialFile) in [("123", false), ("124", true)] {
            let staging = root.appendingPathComponent("download-\(id)")
            let source = try downloadedProject(id, staging: staging)
            let nested = source.appendingPathComponent(".hidden/nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let unsafe = nested.appendingPathComponent("unsafe")
            if specialFile {
                XCTAssertEqual(unsafe.withUnsafeFileSystemRepresentation { mkfifo($0!, mode_t(0o600)) }, 0)
            } else {
                try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: root.appendingPathComponent("missing"))
            }
            await assertDownloadRejected(id, staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("movie.mp4").path))
        }
    }

    func testDownloadedFixedAncestorsCannotTraverseSymbolicLinks() async throws {
        for component in ["", "steamapps", "steamapps/workshop", "steamapps/workshop/content", "steamapps/workshop/content/431960", "steamapps/workshop/content/431960/123"] {
            let staging = root.appendingPathComponent(UUID().uuidString)
            _ = try downloadedProject("123", staging: staging)
            let ancestor = component.isEmpty ? staging : staging.appendingPathComponent(component)
            let original = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: ancestor, to: original)
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: original)
            await assertDownloadRejected("123", staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        }
    }

    func testDownloadedIncompleteContentNeverPublishes() async throws {
        for (id, damage) in [("123", "manifest"), ("124", "missing"), ("125", "empty")] {
            let staging = root.appendingPathComponent("download-\(id)")
            let source = try downloadedProject(id, staging: staging)
            switch damage {
            case "manifest":
                try Data("{\"type\":".utf8).write(to: source.appendingPathComponent("project.json"))
            case "missing":
                try FileManager.default.removeItem(at: source.appendingPathComponent("movie.mp4"))
            default:
                try Data().write(to: source.appendingPathComponent("movie.mp4"))
            }
            await assertDownloadRejected(id, staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testDownloadedCancellationPreservesStagedContent() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        let importer = self.importer
        let library = self.library
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await importer.importDownloadedItem("123", from: staging, into: library)
        }
        do {
            try await task.value
            XCTFail("Cancelled download was published")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedDuplicatePreservesExistingAndStagedContent() async throws {
        let source = try project("123")
        _ = try await importOne(source)
        try FileManager.default.removeItem(at: source)
        let staging = root.appendingPathComponent("download")
        let downloaded = try downloadedProject("123", staging: staging)
        try Data("replacement".utf8).write(to: downloaded.appendingPathComponent("movie.mp4"))
        try await importer.importDownloadedItem("123", from: staging, into: library)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("video-content".utf8))
        XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("movie.mp4")), Data("replacement".utf8))
    }

    func testDownloadedInvalidOrLinkedExistingDestinationIsRejected() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = library.appendingPathComponent("123")
        try Data("existing-invalid".utf8).write(to: destination)
        await assertDownloadRejected("123", staging: staging)
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing-invalid".utf8))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        await assertDownloadRejected("123", staging: staging)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.path)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedInvalidIDsAndOverlappingRootsAreRejected() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        for invalid in ["../123", "+123", "0", "１２３", "18446744073709551616"] {
            await assertDownloadRejected(invalid, staging: staging)
        }
        await assertDownloadRejected("123", staging: staging, library: staging)
        await assertDownloadRejected("123", staging: staging, library: staging.appendingPathComponent("managed"))
        await assertDownloadRejected("123", staging: staging, library: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testConcurrentDownloadedPublicationsKeepOneWholeProject() async throws {
        let firstStaging = root.appendingPathComponent("download-first")
        let secondStaging = root.appendingPathComponent("download-second")
        let first = try downloadedProject("123", staging: firstStaging)
        let second = try downloadedProject("123", staging: secondStaging)
        try Data("second-content".utf8).write(to: second.appendingPathComponent("movie.mp4"))
        try Data("first".utf8).write(to: first.appendingPathComponent("marker"))
        try Data("second".utf8).write(to: second.appendingPathComponent("marker"))
        let otherImporter = WallpaperImportService()
        async let firstImport: Void = importer.importDownloadedItem("123", from: firstStaging, into: library)
        async let secondImport: Void = otherImporter.importDownloadedItem("123", from: secondStaging, into: library)
        _ = try await (firstImport, secondImport)
        let firstRemains = FileManager.default.fileExists(atPath: first.path)
        let secondRemains = FileManager.default.fileExists(atPath: second.path)
        XCTAssertNotEqual(firstRemains, secondRemains)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")),
                       Data((firstRemains ? "second-content" : "video-content").utf8))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/marker")),
                       Data((firstRemains ? "second" : "first").utf8))
    }
}
