import AppKit
import ImageIO
import XCTest
@testable import MacWallpaperEngine

@MainActor
private final class MemoryDesktopWorkspace: DesktopPictureWorkspace {
    var space = "one"
    var pictures: [String: DesktopPicture] = [:]
    var writes = 0
    var failWrites = false

    func currentPicture(display: String) -> DesktopPicture? { pictures[space + ":" + display] }
    func setPicture(_ picture: DesktopPicture, display: String) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        pictures[space + ":" + display] = picture
        writes += 1
    }
}

final class DesktopWallpaperTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-poster-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func original(_ name: String) -> DesktopPicture {
        DesktopPicture(url: root.appendingPathComponent(name + ".heic"),
                       scaling: Int(NSImageScaling.scaleProportionallyDown.rawValue),
                       allowClipping: true, fill: [0.1, 0.2, 0.3, 1])
    }

    @MainActor
    func testPosterPreservesPerSpaceOriginalsAndRestoresScaling() throws {
        let workspace = MemoryDesktopWorkspace()
        let one = original("one"), two = original("two")
        workspace.pictures = ["one:1": one, "two:1": two]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(png: Data([1]), display: "1")
        let first = try XCTUnwrap(workspace.currentPicture(display: "1"))
        XCTAssertEqual(first.scaling, Int(NSImageScaling.scaleAxesIndependently.rawValue))
        XCTAssertFalse(first.allowClipping)
        workspace.space = "two"
        try ledger.apply(png: Data([1]), display: "1")
        XCTAssertNotEqual(workspace.currentPicture(display: "1")?.url, first.url)
        try ledger.restore(display: "1")
        XCTAssertEqual(workspace.currentPicture(display: "1"), two)
        workspace.space = "one"
        try ledger.restore(display: "1")
        XCTAssertEqual(workspace.currentPicture(display: "1"), one)
    }

    @MainActor
    func testMultipleDisplaysKeepTheirOwnRenderedFrames() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = ["one:1": original("primary"), "one:2": original("external")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(png: Data([1, 2]), display: "1")
        try ledger.apply(png: Data([3, 4]), display: "2")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.currentPicture(display: "1")?.url)), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(workspace.currentPicture(display: "2")?.url)), Data([3, 4]))
        try ledger.restore(display: "2")
        XCTAssertEqual(workspace.currentPicture(display: "2"), original("external"))
        XCTAssertNotEqual(workspace.currentPicture(display: "1"), original("primary"))
    }

    @MainActor
    func testFrameUpdatesUseBoundedAlternatingURLsAndDoNotReplaceOriginal() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = ["one:1": original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        var urls: Set<URL> = []
        for value in UInt8(0)..<20 {
            try ledger.apply(png: Data([value]), display: "1")
            urls.insert(try XCTUnwrap(workspace.currentPicture(display: "1")?.url))
        }
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.count, 2)
        try ledger.restore(display: "1")
        XCTAssertEqual(workspace.currentPicture(display: "1"), original("before"))
    }

    @MainActor
    func testIdenticalFramesDoNotRewriteNativeWallpaper() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = ["one:1": original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(png: Data([1]), display: "1")
        try ledger.apply(png: Data([1]), display: "1")
        XCTAssertEqual(workspace.writes, 1)
        // The same image must still be applied to a newly visited Space.
        workspace.space = "two"
        workspace.pictures["two:1"] = original("other")
        try ledger.apply(png: Data([1]), display: "1")
        XCTAssertEqual(workspace.writes, 2)
    }

    @MainActor
    func testRestorationSurvivesRelaunchAndInactiveSpace() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = ["one:1": original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(png: Data([1]), display: "1")
        let reloaded = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        workspace.space = "two"
        try reloaded.restore(display: "1")
        XCTAssertEqual(workspace.writes, 1)
        workspace.space = "one"
        try reloaded.restore(display: "1")
        XCTAssertEqual(workspace.currentPicture(display: "1"), original("before"))
    }

    @MainActor
    func testUserWallpaperChangeIsNotOverwrittenOnRestore() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = ["one:1": original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(png: Data([1]), display: "1")
        workspace.pictures["one:1"] = original("user-change")
        try ledger.restore(display: "1")
        XCTAssertEqual(workspace.currentPicture(display: "1"), original("user-change"))
        try ledger.apply(png: Data([2]), display: "1")
        try ledger.restore(display: "1")
        XCTAssertEqual(workspace.currentPicture(display: "1"), original("user-change"))
    }

    @MainActor
    func testFailedNativeUpdateLeavesOriginalAndCanRetry() throws {
        let workspace = MemoryDesktopWorkspace()
        workspace.pictures = ["one:1": original("before")]
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        workspace.failWrites = true
        XCTAssertThrowsError(try ledger.apply(png: Data([1]), display: "1"))
        XCTAssertEqual(workspace.currentPicture(display: "1"), original("before"))
        workspace.failWrites = false
        try ledger.apply(png: Data([2]), display: "1")
        try ledger.restore(display: "1")
        XCTAssertEqual(workspace.currentPicture(display: "1"), original("before"))
    }

    @MainActor
    func testMissingDisplayAndCorruptJournalNeverWriteWallpaper() throws {
        let workspace = MemoryDesktopWorkspace()
        let ledger = try DesktopWallpaperLedger(folder: root, workspace: workspace)
        try ledger.apply(png: Data([1]), display: "missing")
        try ledger.restore(display: "missing")
        XCTAssertEqual(workspace.writes, 0)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("originals.json"))
        XCTAssertThrowsError(try DesktopWallpaperLedger(folder: root, workspace: workspace))
        XCTAssertEqual(workspace.writes, 0)
    }

    func testRendererPixelsKeepChannelsOrientationAndDimensions() throws {
        // Asymmetric 2x2 pattern: catches red/blue swaps and vertical flipping.
        let rgba = Data([255, 0, 0, 255, 0, 255, 0, 255,
                         0, 0, 255, 255, 255, 255, 255, 255])
        let bgra = Data([0, 0, 255, 255, 0, 255, 0, 255,
                         255, 0, 0, 255, 255, 255, 255, 255])
        for (pixels, blueFirst) in [(rgba, false), (bgra, true)] {
            let png = try DesktopPosterEncoder.png(pixels: pixels, width: 2, height: 2, bgra: blueFirst)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(bitmap.pixelsWide, 2)
            XCTAssertEqual(bitmap.pixelsHigh, 2)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
            // Inspect encoded samples directly. NSColor conversion would route
            // device RGB through the test machine's display profile instead.
            for (x, y, expected) in [(0, 0, [255, 0, 0]), (1, 0, [0, 255, 0]),
                                     (0, 1, [0, 0, 255]), (1, 1, [255, 255, 255])] {
                var samples = [Int](repeating: 0, count: 4)
                bitmap.getPixel(&samples, atX: x, y: y)
                XCTAssertEqual(Array(samples.prefix(3)), expected)
            }
        }
    }

    func testEncoderRejectsInvalidSizesAndTruncatedPixels() {
        for (width, height, bytes) in [(0, 2, 0), (-1, 2, 0), (2, 2, 15), (2, 2, 17), (Int.max, 1, 0), (16_384, 16_384, 0)] {
            XCTAssertThrowsError(try DesktopPosterEncoder.png(pixels: Data(count: bytes), width: width, height: height, bgra: false))
        }
    }
}
