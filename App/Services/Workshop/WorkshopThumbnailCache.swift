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
    enum Code: Equatable { case httpStatus(Int), tooLarge, undecodable }
    let code: Code

    var errorDescription: String? {
        switch code {
        case .httpStatus(let status): String(localized: "Steam returned status \(status) for a preview image.")
        case .tooLarge: String(localized: "The preview image is too large to use as a thumbnail.")
        case .undecodable: String(localized: "The preview image could not be decoded.")
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
        configuration.httpMaximumConnectionsPerHost = 4
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

/// Turns Steam's full-size (often animated) preview images into small still JPEG thumbnails
/// kept on disk, so the Discover grid costs kilobytes per tile instead of megabytes and
/// survives relaunches. Steam's CDN scales JPEG/PNG previews on request; GIFs it only
/// re-encodes, so the first frame is extracted locally.
actor WorkshopThumbnailCache {
    static let defaultMaxPixelSize = 512
    static let resizableHosts: Set<String> = ["images.steamusercontent.com", "steamuserimages-a.akamaihd.net"]
    private static let sizeParameters: Set<String> = ["imw", "imh", "ima", "impolicy", "imcolor", "letterbox"]
    private static let downloadLimit = 24 * 1024 * 1024
    private static let writesPerPrune = 25

    let directory: URL
    let maxPixelSize: Int
    let byteLimit: Int64
    private let fetcher: any WorkshopThumbnailFetching
    private let maxConcurrentFetches: Int
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var writesSincePrune = 0
    private var pruned = false

    init(
        directory: URL = ClientPaths.thumbnailCacheURL,
        fetcher: any WorkshopThumbnailFetching = URLSessionThumbnailFetcher(),
        maxPixelSize: Int = WorkshopThumbnailCache.defaultMaxPixelSize,
        maxConcurrentFetches: Int = 4,
        byteLimit: Int64 = 128 * 1024 * 1024
    ) {
        self.directory = directory
        self.fetcher = fetcher
        self.maxPixelSize = max(64, maxPixelSize)
        self.maxConcurrentFetches = max(1, maxConcurrentFetches)
        self.byteLimit = byteLimit
    }

    /// JPEG bytes for `previewURL`, from disk when present, otherwise fetched once per URL even
    /// under concurrent requests for the same tile.
    func thumbnail(for previewURL: URL) async throws -> Data {
        let file = fileURL(for: previewURL)
        if let cached = try? Data(contentsOf: file), !cached.isEmpty {
            // Pruning evicts by modification date, so a hit keeps its entry young.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return cached
        }
        let key = file.lastPathComponent
        if let task = inFlight[key] { return try await task.value }
        let fetcher = fetcher
        let maxPixelSize = maxPixelSize
        let task = Task<Data, Error> {
            await acquireSlot()
            do {
                let data = try await Task.detached(priority: .utility) {
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

    nonisolated static func key(for previewURL: URL) -> String {
        let digest = SHA256.hash(data: Data(previewURL.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(40).description
    }

    /// Steam's image CDN scales previews when asked; other hosts get the URL unchanged.
    nonisolated static func scaledPreviewURL(_ url: URL, maxPixelSize: Int = defaultMaxPixelSize) -> URL {
        guard let host = url.host?.lowercased(), resizableHosts.contains(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { !sizeParameters.contains($0.name.lowercased()) }
        let size = String(maxPixelSize)
        items += [
            URLQueryItem(name: "imw", value: size), URLQueryItem(name: "imh", value: size),
            URLQueryItem(name: "ima", value: "fit"), URLQueryItem(name: "impolicy", value: "Letterbox"),
            URLQueryItem(name: "letterbox", value: "false"),
        ]
        components.queryItems = items
        return components.url ?? url
    }

    /// First frame of any image ImageIO can read, downscaled to `maxPixelSize` and encoded as JPEG.
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
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
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

    private nonisolated static func produce(
        previewURL: URL, into file: URL, fetcher: any WorkshopThumbnailFetching, maxPixelSize: Int
    ) async throws -> Data {
        let scaled = scaledPreviewURL(previewURL, maxPixelSize: maxPixelSize)
        var source: Data
        do {
            source = try await fetcher.fetch(scaled)
        } catch let failure as WorkshopThumbnailFailure where scaled != previewURL {
            // The CDN refused the scaling query; the original still yields a usable first frame.
            guard case .httpStatus = failure.code else { throw failure }
            source = try await fetcher.fetch(previewURL)
        }
        guard source.count <= downloadLimit else { throw WorkshopThumbnailFailure(code: .tooLarge) }
        try Task.checkCancellation()
        let thumbnail = try encodeThumbnail(source, maxPixelSize: maxPixelSize)
        source = Data()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try thumbnail.write(to: file, options: .atomic)
        return thumbnail
    }

    private func acquireSlot() async {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func finishFetch(_ key: String) {
        inFlight[key] = nil
        if waiters.isEmpty {
            activeFetches -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func recordWrite() {
        writesSincePrune += 1
        if !pruned || writesSincePrune >= Self.writesPerPrune { prune() }
    }
}
