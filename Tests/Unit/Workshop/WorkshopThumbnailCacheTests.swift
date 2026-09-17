import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacWallpaperEngine

final class WorkshopThumbnailCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-thumbnails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScaledPreviewURLOnlyAsksSteamImageHostsForSmallerImages() throws {
        let steam = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/1/ABC/?imw=5000&x=1"))
        let scaled = WorkshopThumbnailCache.scaledPreviewURL(steam, maxPixelSize: 320)
        let items = try XCTUnwrap(URLComponents(url: scaled, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(scaled.host, steam.host)
        XCTAssertEqual(scaled.path, steam.path)
        XCTAssertEqual(items.filter { $0.name == "imw" }.map(\.value), ["320"])
        XCTAssertEqual(items.first { $0.name == "imh" }?.value, "320")
        XCTAssertEqual(items.first { $0.name == "x" }?.value, "1")

        let other = try XCTUnwrap(URL(string: "https://example.com/preview.gif"))
        XCTAssertEqual(WorkshopThumbnailCache.scaledPreviewURL(other), other)
    }

    func testEncodeThumbnailKeepsOneScaledFrameOfAnAnimatedPreview() throws {
        let gif = try Self.image(type: .gif, width: 1024, height: 640, frames: 3)
        let jpeg = try WorkshopThumbnailCache.encodeThumbnail(gif, maxPixelSize: 512)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 320)
        XCTAssertThrowsError(try WorkshopThumbnailCache.encodeThumbnail(Data("not an image".utf8)))
    }

    func testThumbnailIsFetchedOnceThenServedFromDiskAcrossInstances() async throws {
        let png = try Self.image(type: .png, width: 900, height: 900, frames: 1)
        let fetcher = RecordingFetcher { _ in png }
        let preview = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/2/DEF/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)

        async let first = cache.thumbnail(for: preview)
        async let second = cache.thumbnail(for: preview)
        async let third = cache.thumbnail(for: preview)
        let results = try await [first, second, third]
        XCTAssertEqual(Set(results.map(\.count)).count, 1)
        XCTAssertEqual(fetcher.requests.count, 1)
        XCTAssertEqual(fetcher.requests.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "imw" }?.value }, "512")

        let relaunched = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        let again = try await relaunched.thumbnail(for: preview)
        XCTAssertEqual(again, results[0])
        XCTAssertEqual(fetcher.requests.count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(files.count, 1)
    }

    func testRefusedScalingFallsBackToTheOriginalPreview() async throws {
        let png = try Self.image(type: .png, width: 300, height: 200, frames: 1)
        let fetcher = RecordingFetcher { url in
            guard url.query == nil else { throw WorkshopThumbnailFailure(code: .httpStatus(400)) }
            return png
        }
        let preview = try XCTUnwrap(URL(string: "https://steamuserimages-a.akamaihd.net/ugc/3/GHI/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        let data = try await cache.thumbnail(for: preview)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(fetcher.requests.map { $0.query == nil }, [false, true])
    }

    func testFailedFetchLeavesNothingCachedAndRetriesLater() async throws {
        let png = try Self.image(type: .png, width: 300, height: 200, frames: 1)
        let fetcher = RecordingFetcher { _ in png }
        fetcher.failNext = URLError(.notConnectedToInternet)
        let preview = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/4/JKL/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        do {
            _ = try await cache.thumbnail(for: preview)
            XCTFail("expected the transport failure to surface")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }.isEmpty)
        let data = try await cache.thumbnail(for: preview)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(fetcher.requests.count, 2)
    }

    func testFetchesRunAtMostTheConfiguredNumberAtOnce() async throws {
        let png = try Self.image(type: .png, width: 200, height: 200, frames: 1)
        let fetcher = RecordingFetcher(delay: .milliseconds(40)) { _ in png }
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher, maxConcurrentFetches: 2)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<6 {
                let url = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/\(index)/X/"))
                group.addTask { try await cache.thumbnail(for: url) }
            }
            for try await _ in group {}
        }
        XCTAssertEqual(fetcher.requests.count, 6)
        XCTAssertLessThanOrEqual(fetcher.peakConcurrency, 2)
    }

    func testPruneRemovesTheOldestEntriesUntilTheCacheFits() async throws {
        let cache = WorkshopThumbnailCache(directory: root, fetcher: RecordingFetcher { _ in Data() }, byteLimit: 2_500)
        let files = FileManager.default
        for (index, age) in [400.0, 300, 200, 100].enumerated() {
            let file = root.appendingPathComponent("entry-\(index).jpg")
            try Data(repeating: 0, count: 1_000).write(to: file)
            try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
        }
        await cache.prune()
        let remaining = try files.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(remaining, ["entry-2.jpg", "entry-3.jpg"])
    }

    private static func image(type: UTType, width: Int, height: Int, frames: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil))
        let space = CGColorSpaceCreateDeviceRGB()
        for frame in 0..<frames {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(frame) / CGFloat(max(frames, 2)), green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Noise keeps the encoder from collapsing the frame to a few bytes.
            for y in stride(from: 0, to: height, by: 16) {
                context.setFillColor(CGColor(red: CGFloat(y % 97) / 97, green: CGFloat(y % 53) / 53, blue: 0.2, alpha: 1))
                context.fill(CGRect(x: (y * 7) % width, y: y, width: 40, height: 8))
            }
            let image = try XCTUnwrap(context.makeImage())
            let properties: [CFString: Any] = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] : [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private final class RecordingFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let respond: @Sendable (URL) throws -> Data
    private let delay: Duration
    private var active = 0
    private(set) var requests: [URL] = []
    private(set) var peakConcurrency = 0
    var failNext: Error?

    init(delay: Duration = .zero, respond: @escaping @Sendable (URL) throws -> Data) {
        self.delay = delay
        self.respond = respond
    }

    func fetch(_ url: URL) async throws -> Data {
        lock.lock()
        requests.append(url)
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        let failure = failNext
        failNext = nil
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return try respond(url)
    }
}
