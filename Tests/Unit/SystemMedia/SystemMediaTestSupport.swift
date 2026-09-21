import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// Stands in for the private framework. No test in this directory loads MediaRemote, calls
/// it, or reads what the machine is actually playing: every answer here is written by the
/// test that asked for it.
@MainActor
final class FakeMediaRemoteSymbols: MediaRemoteSymbols {
    let notificationNames = MediaRemoteNotificationNames(
        infoDidChange: Notification.Name("FakeMediaRemote.infoDidChange"),
        isPlayingDidChange: Notification.Name("FakeMediaRemote.isPlayingDidChange"),
        applicationDidChange: Notification.Name("FakeMediaRemote.applicationDidChange"))

    /// What the framework reports. Nil is the framework answering with nothing.
    var information: [String: Any]? = [:]
    var playing = false
    /// False models a system that never calls the completion back at all, which is what an
    /// entitlement-gated macOS looks like from this side.
    var answers = true

    private(set) var infoRequests = 0
    private(set) var playingRequests = 0
    private(set) var registrations = 0
    private(set) var unregistrations = 0

    func nowPlayingInfo(_ completion: @escaping ([String: Any]?) -> Void) {
        infoRequests += 1
        guard answers else { return }
        completion(information)
    }

    func isPlaying(_ completion: @escaping (Bool) -> Void) {
        playingRequests += 1
        guard answers else { return }
        completion(playing)
    }

    func registerForNotifications() { registrations += 1 }

    func unregisterForNotifications() { unregistrations += 1 }
}

@MainActor
final class FakeMediaRemoteLoader: MediaRemoteLoading {
    private let result: Result<any MediaRemoteSymbols, Error>
    private(set) var loads = 0

    init(_ result: Result<any MediaRemoteSymbols, Error>) { self.result = result }

    func load() throws -> any MediaRemoteSymbols {
        loads += 1
        return try result.get()
    }
}

/// Scheduled work that only runs when a test says so, so the 1 Hz timeline push and the
/// probe timeout are deterministic instead of timed.
@MainActor
final class ManualMediaTimerScheduler: MediaTimerScheduling {
    @MainActor
    final class Token: MediaTimerToken {
        let interval: TimeInterval
        let repeats: Bool
        let handler: () -> Void
        private(set) var isCancelled = false

        init(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) {
            self.interval = interval
            self.repeats = repeats
            self.handler = handler
        }

        func cancel() { isCancelled = true }
    }

    private(set) var tokens: [Token] = []

    var liveDelayed: [Token] { tokens.filter { !$0.repeats && !$0.isCancelled } }
    var liveRepeating: [Token] { tokens.filter { $0.repeats && !$0.isCancelled } }

    func schedule(after seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken {
        let token = Token(interval: seconds, repeats: false, handler: handler)
        tokens.append(token)
        return token
    }

    func schedule(every seconds: TimeInterval, handler: @escaping () -> Void) -> any MediaTimerToken {
        let token = Token(interval: seconds, repeats: true, handler: handler)
        tokens.append(token)
        return token
    }

    /// Fires every pending one-shot timer once.
    func fireDelayed() {
        for token in liveDelayed {
            token.cancel()
            token.handler()
        }
    }

    /// Fires every live repeating timer once.
    func fireRepeating() {
        for token in liveRepeating { token.handler() }
    }
}

/// Wraps the real renderer so a test can see how often decoding actually happened.
@MainActor
final class CountingArtworkRenderer: MediaArtworkRendering {
    private let wrapped = CoreGraphicsArtworkRenderer()
    private(set) var renders = 0

    func render(_ data: Data, maxPixelSize: Int) -> MediaArtworkRaster? {
        renders += 1
        return wrapped.render(data, maxPixelSize: maxPixelSize)
    }
}

/// Builds a PNG in memory, so this suite carries no binary fixtures.
func makeSyntheticPNG(
    width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
) throws -> Data {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let base = try XCTUnwrap(context.data)
    let rowStride = context.bytesPerRow
    for y in 0..<height {
        let row = base.advanced(by: y * rowStride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let (red, green, blue) = pixel(x, y)
            row[x * 4] = red
            row[x * 4 + 1] = green
            row[x * 4 + 2] = blue
            row[x * 4 + 3] = 255
        }
    }
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination), "Could not encode the synthetic cover")
    return output as Data
}

/// A solid cover, the simplest case a palette has to survive.
func makeSolidPNG(_ red: UInt8, _ green: UInt8, _ blue: UInt8, size: Int = 128) throws -> Data {
    try makeSyntheticPNG(width: size, height: size) { _, _ in (red, green, blue) }
}

// MARK: - Independent colour maths

/// Parses `rgb(r, g, b)` back into unit components. Deliberately written here rather than
/// reused from the app: a test that measures contrast with the same code that chose the
/// colour would pass whatever that code did.
func parseCSSColour(_ css: String) throws -> (red: Double, green: Double, blue: Double) {
    let digits = css.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
    let parts = digits.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    XCTAssertEqual(parts.count, 3, "Not a CSS rgb() colour: \(css)")
    let values = try parts.map { try XCTUnwrap(Double($0)) / 255 }
    return (values[0], values[1], values[2])
}

func wcagContrast(_ first: String, _ second: String) throws -> Double {
    func luminance(_ colour: (red: Double, green: Double, blue: Double)) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
    }
    let lhs = luminance(try parseCSSColour(first))
    let rhs = luminance(try parseCSSColour(second))
    return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
}

/// Whichever of black or white contrasts more with `colour`, derived independently of the
/// app's own answer.
func betterOfBlackOrWhite(against colour: String) throws -> String {
    let black = "rgb(0, 0, 0)"
    let white = "rgb(255, 255, 255)"
    return try wcagContrast(white, colour) >= wcagContrast(black, colour) ? white : black
}
