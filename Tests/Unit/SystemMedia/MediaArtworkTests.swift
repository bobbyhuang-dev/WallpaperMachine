import XCTest

@testable import MacWallpaperEngine

/// The thumbnail payload handed to author pages: a bounded PNG data URL and a palette
/// whose text colour is actually readable on its background colour.
///
/// Every cover here is generated in the test. Nothing reads the machine's real artwork.
@MainActor
final class MediaArtworkTests: XCTestCase {
    func testTextColourIsReadableOnThePrimaryColourOrFallsBackToBlackOrWhite() throws {
        let twoTone = try makeSyntheticPNG(
            width: 128, height: 128,
            pixel: { _, y in y < 77 ? (20, 24, 60) : (240, 235, 220) })
        let covers: [(name: String, data: Data)] = [
            (name: "near black", data: try makeSolidPNG(14, 16, 22)),
            (name: "near white", data: try makeSolidPNG(245, 243, 238)),
            (name: "mid grey", data: try makeSolidPNG(128, 128, 128)),
            (name: "two tone", data: twoTone),
        ]
        for cover in covers {
            let artwork = MediaArtwork()
            let thumbnail = try XCTUnwrap(artwork.thumbnail(for: cover.data), cover.name)
            let readable = try [thumbnail.secondaryColor, thumbnail.tertiaryColor].first {
                try wcagContrast($0, thumbnail.primaryColor) >= 4.5
            }
            if readable != nil {
                XCTAssertGreaterThanOrEqual(
                    try wcagContrast(thumbnail.textColor, thumbnail.primaryColor), 4.5,
                    "\(cover.name): a cover colour reached AA contrast, so the text colour must too")
            } else {
                XCTAssertEqual(
                    thumbnail.textColor, try betterOfBlackOrWhite(against: thumbnail.primaryColor),
                    "\(cover.name): with no readable cover colour the text must fall back to the stronger of black or white")
            }
        }
    }

    func testHighContrastColourIsBlackOnALightCoverAndWhiteOnADarkCover() throws {
        let artwork = MediaArtwork()
        let light = try XCTUnwrap(artwork.thumbnail(for: try makeSolidPNG(246, 244, 240)))
        XCTAssertEqual(light.highContrastColor, "rgb(0, 0, 0)")

        let dark = try XCTUnwrap(artwork.thumbnail(for: try makeSolidPNG(18, 20, 28)))
        XCTAssertEqual(dark.highContrastColor, "rgb(255, 255, 255)")
    }

    func testTheSameCoverIsEncodedOnlyOnceAndTheCacheStaysBounded() throws {
        let renderer = CountingArtworkRenderer()
        let artwork = MediaArtwork(renderer: renderer, cacheLimit: 1)
        let cover = try makeSolidPNG(90, 30, 140)
        let other = try makeSolidPNG(30, 140, 90)

        let first = try XCTUnwrap(artwork.thumbnail(for: cover))
        let second = try XCTUnwrap(artwork.thumbnail(for: cover))
        XCTAssertEqual(first, second)
        XCTAssertEqual(renderer.renders, 1, "An unchanged cover must not be decoded again")

        _ = try XCTUnwrap(artwork.thumbnail(for: other))
        XCTAssertEqual(renderer.renders, 2)

        _ = try XCTUnwrap(artwork.thumbnail(for: cover))
        XCTAssertEqual(
            renderer.renders, 3,
            "A one-entry cache must evict, otherwise it grows with every track ever played")
    }

    func testACoverOverTheSizeCapIsDownscaledRatherThanDropped() throws {
        // Noise so the encoder cannot compress the cover down to nothing, which would make
        // the cap unreachable and the test vacuous.
        let cover = try makeSyntheticPNG(width: 256, height: 256) { x, y in
            let hash = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663))
            return (
                UInt8(truncatingIfNeeded: hash),
                UInt8(truncatingIfNeeded: hash >> 8),
                UInt8(truncatingIfNeeded: hash >> 16)
            )
        }
        let generous = try XCTUnwrap(
            MediaArtwork(maxDataURLCharacters: 16 * 1024 * 1024).thumbnail(for: cover))
        XCTAssertTrue(generous.pngBase64DataURL.hasPrefix("data:image/png;base64,"))

        let cap = generous.pngBase64DataURL.count / 2
        let bounded = try XCTUnwrap(MediaArtwork(maxDataURLCharacters: cap).thumbnail(for: cover))
        XCTAssertTrue(bounded.pngBase64DataURL.hasPrefix("data:image/png;base64,"))
        XCTAssertLessThan(
            bounded.pngBase64DataURL.count, generous.pngBase64DataURL.count,
            "A cover over the cap must come back smaller, not unchanged")
    }

    func testBytesThatAreNotAnImageYieldNoThumbnail() {
        let artwork = MediaArtwork()
        XCTAssertNil(artwork.thumbnail(for: Data()))
        XCTAssertNil(artwork.thumbnail(for: Data("this is not a cover".utf8)))
    }

    func testDecodedCoverKeepsRowMajorRGBA() throws {
        let cover = try makeSolidPNG(10, 20, 30, size: 8)
        let thumbnail = try XCTUnwrap(MediaArtwork().thumbnail(for: cover))
        XCTAssertEqual(thumbnail.rgba.count, thumbnail.width * thumbnail.height * 4)
        XCTAssertGreaterThan(thumbnail.width, 0)
        XCTAssertGreaterThan(thumbnail.height, 0)
    }
}
