import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches the bytes of a Workshop preview image; injected so tests never reach the network.
protocol WorkshopThumbnailFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

struct WorkshopThumbnailFailure: LocalizedError, Equatable {
    enum Code: Equatable { case httpStatus(Int), tooLarge, undecodable, notAnimated }
    let code: Code

    var errorDescription: String? {
        switch code {
        case .httpStatus(let status): String(localized: "Steam returned status \(status) for a preview image.")
        case .tooLarge: String(localized: "The preview image is too large to use as a thumbnail.")
        case .undecodable: String(localized: "The preview image could not be decoded.")
        case .notAnimated: String(localized: "The preview image is a single still frame.")
        }
    }
}

struct URLSessionThumbnailFetcher: WorkshopThumbnailFetching {
    // Thumbnails are cached on disk by the owner, so the session keeps no cache of its own and
    // never shares the browse session's connection pool with dozens of image requests.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("MacWallpaperEngine/1.0 (macOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WorkshopThumbnailFailure(code: .httpStatus(http.statusCode))
        }
        return data
    }
}

/// Downloads each Workshop preview once and keeps both halves of it on disk: a small still JPEG
/// for the Discover tile and, when the preview is animated, the bytes Steam sent, so the tile's
/// animation plays from disk without a second request and both survive relaunches.
///
/// The preview is always fetched as Steam published it. Steam's CDN serves that original from
/// its edge in a fraction of a second, whereas a scaled variant (`?imw=…`) makes it re-encode
/// the whole GIF on a cold path, which measured at 2–5 s per tile for a quarter fewer bytes.
actor WorkshopThumbnailCache {
    static let defaultMaxPixelSize = 512
    /// How many frames of an animated preview are measured when choosing its still.
    static let frameSamples = 8
    /// Mean luminance (0...1) below which a sampled frame counts as a black fade-in frame.
    static let darkFrameLuminance = 0.08
    private static let downloadLimit = 24 * 1024 * 1024
    private static let writesPerPrune = 25

    let directory: URL
    let maxPixelSize: Int
    let byteLimit: Int64
    private let fetcher: any WorkshopThumbnailFetching
    private let maxConcurrentFetches: Int
    private let maxConcurrentAnimatedFetches: Int
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var inFlightAnimated: [String: Task<Data, Error>] = [:]
    /// Previews and animation-only refetches queue separately, so refilling evicted animations
    /// never delays the stills of the next page.
    private enum Lane: Hashable { case still, animated }
    private var activeFetches: [Lane: Int] = [:]
    private var waiters: [Lane: [CheckedContinuation<Void, Never>]] = [:]
    private var writesSincePrune = 0
    private var pruned = false

    init(
        directory: URL = ClientPaths.thumbnailCacheURL,
        fetcher: any WorkshopThumbnailFetching = URLSessionThumbnailFetcher(),
        maxPixelSize: Int = WorkshopThumbnailCache.defaultMaxPixelSize,
        maxConcurrentFetches: Int = 8,
        maxConcurrentAnimatedFetches: Int = 2,
        byteLimit: Int64 = 512 * 1024 * 1024
    ) {
        self.directory = directory
        self.fetcher = fetcher
        self.maxPixelSize = max(64, maxPixelSize)
        self.maxConcurrentFetches = max(1, maxConcurrentFetches)
        self.maxConcurrentAnimatedFetches = max(1, maxConcurrentAnimatedFetches)
        self.byteLimit = byteLimit
    }

    /// JPEG bytes for `previewURL`, from disk when present, otherwise fetched once per URL even
    /// under concurrent requests for the same tile.
    func thumbnail(for previewURL: URL) async throws -> Data {
        let file = fileURL(for: previewURL)
        if let cached = Self.cached(file) { return cached }
        let key = file.lastPathComponent
        if let task = inFlight[key] { return try await task.value }
        let fetcher = fetcher
        let maxPixelSize = maxPixelSize
        let task = Task<Data, Error> {
            await acquireSlot(.still)
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try await Self.produce(previewURL: previewURL, into: file, fetcher: fetcher, maxPixelSize: maxPixelSize)
                }.value
                finishFetch(key)
                recordWrite()
                return data
            } catch {
                finishFetch(key)
                throw error
            }
        }
        inFlight[key] = task
        return try await task.value
    }

    /// Starts caching `previewURLs` without waiting for them, in order, so a page's tiles are
    /// already on disk (or at least in flight) by the time the panel asks for them.
    nonisolated func warm(_ previewURLs: [URL]) {
        for previewURL in previewURLs {
            Task(priority: .utility) { _ = try? await self.thumbnail(for: previewURL) }
        }
    }

    /// The preview as Steam serves it, animation intact. The still pass normally left it on disk;
    /// it is fetched again only when that copy was pruned or predates this cache layout. A preview
    /// the still pass found to be a single frame is refused without a request, so the panel keeps
    /// its still instead of loading the same picture at full size.
    func animatedPreview(for previewURL: URL) async throws -> Data {
        let file = fileURL(for: previewURL)
        let key = file.lastPathComponent
        // A still pass under way is already downloading these bytes; wait rather than race it.
        if let task = inFlight[key] { _ = try? await task.value }
        if FileManager.default.fileExists(atPath: Self.stillMarker(for: file).path) {
            throw WorkshopThumbnailFailure(code: .notAnimated)
        }
        let animation = Self.animationFile(for: file)
        if let cached = Self.cached(animation) { return cached }
        if let task = inFlightAnimated[key] { return try await task.value }
        let fetcher = fetcher
        let task = Task<Data, Error> {
            await acquireSlot(.animated)
            defer {
                inFlightAnimated[key] = nil
                release(.animated)
            }
            let data = try await fetcher.fetch(previewURL)
            guard data.count <= Self.downloadLimit else { throw WorkshopThumbnailFailure(code: .tooLarge) }
            guard Self.frameCount(of: data) > 1 else { throw WorkshopThumbnailFailure(code: .notAnimated) }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: animation, options: .atomic)
            recordWrite()
            return data
        }
        inFlightAnimated[key] = task
        return try await task.value
    }

    /// Deletes the oldest entries until the cache fits `byteLimit`.
    func prune() {
        pruned = true
        writesSincePrune = 0
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        var dated = entries.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = dated.reduce(Int64(0)) { $0 + $1.1 }
        dated.sort { $0.2 < $1.2 }
        for (url, size, _) in dated where total > byteLimit {
            try? files.removeItem(at: url)
            total -= size
        }
    }

    func fileURL(for previewURL: URL) -> URL {
        directory.appendingPathComponent(Self.key(for: previewURL)).appendingPathExtension("jpg")
    }

    /// An empty file beside a still recording that its source had one frame, so no animated
    /// relay is attempted for it. Pruning may drop it; that only costs one redundant request.
    nonisolated static func stillMarker(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("still")
    }

    /// The preview's original bytes beside its still, kept only for animated previews.
    nonisolated static func animationFile(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("anim")
    }

    /// A non-empty cache entry. Pruning evicts by modification date, so a hit keeps its entry young.
    private nonisolated static func cached(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    /// The MIME type ImageIO recognises for `data`, for relaying a preview as Steam encoded it.
    nonisolated static func mimeType(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let mime = UTType(type)?.preferredMIMEType else { return "application/octet-stream" }
        return mime
    }

    nonisolated static func frameCount(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    /// Bumped when the still a preview yields changes, so entries made by an older frame choice
    /// are regenerated rather than served; pruning removes the orphans oldest-first.
    private static let keyVersion = "2:"

    nonisolated static func key(for previewURL: URL) -> String {
        let digest = SHA256.hash(data: Data((keyVersion + previewURL.absoluteString).utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(40).description
    }

    /// One still frame of any image ImageIO can read, downscaled to `maxPixelSize` and encoded as
    /// JPEG. Animated previews contribute their representative frame, not necessarily the first.
    nonisolated static func encodeThumbnail(_ data: Data, maxPixelSize: Int = defaultMaxPixelSize) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw WorkshopThumbnailFailure(code: .undecodable)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        let index = representativeFrameIndex(of: source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw WorkshopThumbnailFailure(code: .undecodable)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw WorkshopThumbnailFailure(code: .undecodable)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw WorkshopThumbnailFailure(code: .undecodable)
        }
        return output as Data
    }

    /// Many animated previews fade in from black, so their first frame makes a black tile. The
    /// still is the earliest of `frameSamples` evenly spaced frames that is nearly as bright as the
    /// brightest sample; a preview that is dark throughout, or a still image, keeps frame 0.
    nonisolated static func representativeFrameIndex(of source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return 0 }
        let samples = min(count, frameSamples)
        let indices = (0..<samples).map { $0 * (count - 1) / max(samples - 1, 1) }
        let measured = indices.compactMap { index in luminance(of: source, at: index).map { (index: index, luminance: $0) } }
        guard let brightest = measured.map(\.luminance).max(), brightest >= darkFrameLuminance else { return 0 }
        let floor = max(darkFrameLuminance, brightest * 0.6)
        return measured.first { $0.luminance >= floor }?.index ?? 0
    }

    /// Mean luminance (0...1) of the frame at `index`, measured on a tiny grayscale decode.
    /// Transparent pixels read as black, so an empty first GIF frame is skipped like a dark one.
    private nonisolated static func luminance(of source: CGImageSource, at index: Int) -> Double? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              image.width > 0, image.height > 0,
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let base = context.data else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        for row in 0..<image.height {
            let offset = row * context.bytesPerRow
            for column in 0..<image.width { total += Int(pixels[offset + column]) }
        }
        return Double(total) / Double(image.width * image.height * 255)
    }

    private nonisolated static func produce(
        previewURL: URL, into file: URL, fetcher: any WorkshopThumbnailFetching, maxPixelSize: Int
    ) async throws -> Data {
        let source = try await fetcher.fetch(previewURL)
        guard source.count <= downloadLimit else { throw WorkshopThumbnailFailure(code: .tooLarge) }
        try Task.checkCancellation()
        let thumbnail = try encodeThumbnail(source, maxPixelSize: maxPixelSize)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The animation lands before the still, so a tile that shows its still can always play.
        if frameCount(of: source) > 1 {
            try? source.write(to: animationFile(for: file), options: .atomic)
            try? FileManager.default.removeItem(at: stillMarker(for: file))
        } else {
            try? Data().write(to: stillMarker(for: file), options: .atomic)
        }
        try thumbnail.write(to: file, options: .atomic)
        return thumbnail
    }

    private func limit(_ lane: Lane) -> Int {
        lane == .still ? maxConcurrentFetches : maxConcurrentAnimatedFetches
    }

    private func acquireSlot(_ lane: Lane) async {
        if activeFetches[lane, default: 0] < limit(lane) {
            activeFetches[lane, default: 0] += 1
            return
        }
        await withCheckedContinuation { waiters[lane, default: []].append($0) }
    }

    private func release(_ lane: Lane) {
        if var queue = waiters[lane], !queue.isEmpty {
            queue.removeFirst().resume()
            waiters[lane] = queue
        } else {
            activeFetches[lane, default: 0] -= 1
        }
    }

    private func finishFetch(_ key: String) {
        inFlight[key] = nil
        release(.still)
    }

    private func recordWrite() {
        writesSincePrune += 1
        if !pruned || writesSincePrune >= Self.writesPerPrune { prune() }
    }
}
