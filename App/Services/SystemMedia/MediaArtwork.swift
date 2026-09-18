import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A colour in the sRGB unit cube, the working form of everything in this file.
struct MediaArtworkRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = MediaArtworkRGB(red: 0, green: 0, blue: 0)
    static let white = MediaArtworkRGB(red: 1, green: 1, blue: 1)

    var css: String {
        func channel(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgb(\(channel(red)), \(channel(green)), \(channel(blue)))"
    }
}

/// Decoded, downscaled artwork: the PNG bytes handed to the page, and the pixels the
/// palette is clustered from.
struct MediaArtworkRaster {
    var png: Data
    /// Row-major RGBA8 with premultiplied alpha, `width * height * 4` bytes.
    var rgba: [UInt8]
    var width: Int
    var height: Int
}

/// Decodes and downscales cover art. Injected so tests can count how often the
/// expensive step actually runs.
@MainActor
protocol MediaArtworkRendering: AnyObject {
    func render(_ data: Data, maxPixelSize: Int) -> MediaArtworkRaster?
}

/// Turns now-playing cover art into a `wallpaperRegisterMediaThumbnailListener` payload:
/// a bounded PNG data URL plus a palette clustered from the cover itself.
///
/// The bound matters more than fidelity here. The bytes cross into a web view as a
/// base64 string on every track change, so a full-resolution cover would be megabytes of
/// text; a wallpaper never renders one larger than a few hundred pixels.
@MainActor
final class MediaArtwork {
    /// Longest edge of the encoded cover.
    nonisolated static let maxPixelSize = 256
    /// Ceiling on the data URL length, in characters.
    nonisolated static let maxDataURLCharacters = 192 * 1024
    /// Minimum contrast a colour taken from the cover must reach to be used for text.
    nonisolated static let minimumTextContrast = 4.5

    private struct Identity: Equatable {
        var byteCount: Int
        var digest: String
    }

    private let renderer: any MediaArtworkRendering
    private let maxPixelSize: Int
    private let maxDataURLCharacters: Int
    private let cacheLimit: Int
    /// Most recently used first. A cover repeats across every event of a track and
    /// across a whole album, so a handful of entries removes nearly all re-encoding.
    private var cache: [(identity: Identity, thumbnail: SystemMediaThumbnail)] = []

    // `renderer` defaults to nil rather than to a `CoreGraphicsArtworkRenderer()`
    // expression: a default argument is evaluated outside the main actor, where a
    // main-actor type cannot be constructed.
    init(
        renderer: (any MediaArtworkRendering)? = nil,
        maxPixelSize: Int = MediaArtwork.maxPixelSize,
        maxDataURLCharacters: Int = MediaArtwork.maxDataURLCharacters,
        cacheLimit: Int = 4
    ) {
        self.renderer = renderer ?? CoreGraphicsArtworkRenderer()
        self.maxPixelSize = maxPixelSize
        self.maxDataURLCharacters = maxDataURLCharacters
        self.cacheLimit = max(cacheLimit, 1)
    }

    /// Thumbnail for `data`, or nil when the bytes are empty or not a decodable image.
    func thumbnail(for data: Data) -> SystemMediaThumbnail? {
        guard !data.isEmpty else { return nil }
        let identity = Identity(byteCount: data.count, digest: Self.digest(data))
        if let index = cache.firstIndex(where: { $0.identity == identity }) {
            let entry = cache.remove(at: index)
            cache.insert(entry, at: 0)
            return entry.thumbnail
        }
        guard let thumbnail = encode(data) else { return nil }
        cache.insert((identity: identity, thumbnail: thumbnail), at: 0)
        if cache.count > cacheLimit { cache.removeLast(cache.count - cacheLimit) }
        return thumbnail
    }

    private func encode(_ data: Data) -> SystemMediaThumbnail? {
        var smallest: (raster: MediaArtworkRaster, url: String)?
        for size in Self.sizeLadder(from: maxPixelSize) {
            guard let raster = renderer.render(data, maxPixelSize: size) else { break }
            let url = Self.dataURL(raster.png)
            smallest = (raster, url)
            if url.count <= maxDataURLCharacters { break }
        }
        // A cover that stays over the cap at the smallest rung is still shown: a page
        // that asked for cover art is better served by a coarse one than by none.
        guard let chosen = smallest else { return nil }
        return Self.thumbnail(raster: chosen.raster, dataURL: chosen.url)
    }

    private static func sizeLadder(from maxPixelSize: Int) -> [Int] {
        var sizes: [Int] = []
        var size = max(maxPixelSize, 32)
        while size >= 32 {
            sizes.append(size)
            size /= 2
        }
        return sizes
    }

    private static func dataURL(_ png: Data) -> String {
        "data:image/png;base64,\(png.base64EncodedString())"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func thumbnail(raster: MediaArtworkRaster, dataURL: String) -> SystemMediaThumbnail {
        let palette = palette(of: raster)
        return SystemMediaThumbnail(
            pngBase64DataURL: dataURL,
            primaryColor: palette.primary.css,
            secondaryColor: palette.secondary.css,
            tertiaryColor: palette.tertiary.css,
            textColor: textColor(primary: palette.primary, candidates: [palette.secondary, palette.tertiary]).css,
            highContrastColor: highContrastColor(against: palette.primary).css)
    }

    // MARK: - Palette

    /// Three colours drawn from the cover, ordered by how much of it they cover.
    ///
    /// Pixels are bucketed four bits per channel and the largest buckets win. That is
    /// coarse on purpose: the page uses these as background and accent tints, where a
    /// stable answer matters far more than an exact one, and exact k-means on every
    /// track change would cost far more than the result is worth.
    private static func palette(
        of raster: MediaArtworkRaster
    ) -> (primary: MediaArtworkRGB, secondary: MediaArtworkRGB, tertiary: MediaArtworkRGB) {
        let bucketCount = 16 * 16 * 16
        var counts = [Int](repeating: 0, count: bucketCount)
        var sums = [Double](repeating: 0, count: bucketCount * 3)
        let pixels = raster.rgba
        for base in stride(from: 0, to: pixels.count - 3, by: 4) {
            let alpha = Double(pixels[base + 3]) / 255
            // Near-transparent pixels carry no colour worth clustering, and dividing by
            // a tiny alpha to undo premultiplication would amplify their noise.
            guard alpha >= 0.0625 else { continue }
            let red = min(Double(pixels[base]) / 255 / alpha, 1)
            let green = min(Double(pixels[base + 1]) / 255 / alpha, 1)
            let blue = min(Double(pixels[base + 2]) / 255 / alpha, 1)
            let bucket =
                (Int(red * 255) >> 4) << 8 | (Int(green * 255) >> 4) << 4 | (Int(blue * 255) >> 4)
            counts[bucket] += 1
            sums[bucket * 3] += red
            sums[bucket * 3 + 1] += green
            sums[bucket * 3 + 2] += blue
        }

        func mean(_ bucket: Int) -> MediaArtworkRGB {
            let total = Double(counts[bucket])
            return MediaArtworkRGB(
                red: sums[bucket * 3] / total,
                green: sums[bucket * 3 + 1] / total,
                blue: sums[bucket * 3 + 2] / total)
        }

        let occupied = (0..<bucketCount).filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }
        guard let first = occupied.first else {
            // Fully transparent artwork: a neutral pair keeps the page's text readable.
            return (.black, .white, MediaArtworkRGB(red: 0.5, green: 0.5, blue: 0.5))
        }
        let primary = mean(first)
        let separation = 0.22
        let secondary =
            occupied.dropFirst().first { distance(mean($0), primary) >= separation }.map(mean)
            ?? derived(from: primary, shift: 0.62)
        let tertiary =
            occupied.dropFirst().first {
                let colour = mean($0)
                return distance(colour, primary) >= separation && distance(colour, secondary) >= separation
            }.map(mean) ?? derived(from: primary, shift: 0.34)
        return (primary, secondary, tertiary)
    }

    private static func distance(_ lhs: MediaArtworkRGB, _ rhs: MediaArtworkRGB) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return (red * red + green * green + blue * blue).squareRoot()
    }

    /// A companion tone for a cover that has no second colour of its own: a flat cover
    /// still has to yield a palette the page can put text on.
    private static func derived(from colour: MediaArtworkRGB, shift: Double) -> MediaArtworkRGB {
        let target: Double = relativeLuminance(colour) < 0.5 ? 1 : 0
        return MediaArtworkRGB(
            red: colour.red + (target - colour.red) * shift,
            green: colour.green + (target - colour.green) * shift,
            blue: colour.blue + (target - colour.blue) * shift)
    }

    // MARK: - Contrast

    /// The first cover colour readable on `primary`, or plain black/white when the cover
    /// offers nothing that reaches the WCAG AA ratio for body text.
    private static func textColor(primary: MediaArtworkRGB, candidates: [MediaArtworkRGB]) -> MediaArtworkRGB {
        if let readable = candidates.first(where: { contrastRatio($0, primary) >= minimumTextContrast }) {
            return readable
        }
        return highContrastColor(against: primary)
    }

    private static func highContrastColor(against colour: MediaArtworkRGB) -> MediaArtworkRGB {
        contrastRatio(.white, colour) >= contrastRatio(.black, colour) ? .white : .black
    }

    /// WCAG 2.1 contrast ratio, 1…21.
    private static func contrastRatio(_ lhs: MediaArtworkRGB, _ rhs: MediaArtworkRGB) -> Double {
        let first = relativeLuminance(lhs)
        let second = relativeLuminance(rhs)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// WCAG 2.1 relative luminance.
    private static func relativeLuminance(_ colour: MediaArtworkRGB) -> Double {
        func linear(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.04045 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
    }
}

/// Decodes artwork through ImageIO and hands back both the PNG and its pixels, so the
/// palette is clustered from exactly the image the page receives.
@MainActor
final class CoreGraphicsArtworkRenderer: MediaArtworkRendering {
    func render(_ data: Data, maxPixelSize: Int) -> MediaArtworkRaster? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            image.width > 0, image.height > 0
        else { return nil }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }

        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let base = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let rowBytes = width * 4
        let sourceStride = context.bytesPerRow
        var rgba = [UInt8](repeating: 0, count: rowBytes * height)
        rgba.withUnsafeMutableBytes { destination in
            guard let start = destination.baseAddress else { return }
            for row in 0..<height {
                start.advanced(by: row * rowBytes)
                    .copyMemory(from: base.advanced(by: row * sourceStride), byteCount: rowBytes)
            }
        }
        return MediaArtworkRaster(png: output as Data, rgba: rgba, width: width, height: height)
    }
}
