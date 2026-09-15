import AppKit
import Darwin

struct DesktopPictureTarget: Hashable, Codable {
    var display: String
    // nil is the public-API fallback, scoped to the currently visible Space.
    var space: String?
}

/// Native ABI references:
/// https://github.com/cameron-simpson/css/blob/main/lib/python/cs/app/osx/objc.py
/// https://gist.github.com/RhetTbull/86394ac9c2cc1096e510775dee14ae08
/// These optional HIServices/CoreGraphics APIs target an inactive Space directly.
/// Do not replace them with Space switching, plist edits, or process restarts.
@MainActor
final class DesktopSpaceWallpaperAPI {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyPicture = @convention(c) (UInt32, Int32, CFString) -> Unmanaged<CFDictionary>?
    private typealias SetPicture = @convention(c) (UInt32, CFDictionary, Int32, Int32, CFString) -> Void
    private let connection: Connection
    private let copySpaces: CopySpaces
    private let copyPicture: CopyPicture
    private let setPicture: SetPicture

    init?() {
        guard let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let hi = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY),
              let connection = dlsym(cg, "_CGSDefaultConnection"),
              let copySpaces = dlsym(cg, "CGSCopyManagedDisplaySpaces"),
              let copyPicture = dlsym(hi, "DesktopPictureCopyDisplayForSpace"),
              let setPicture = dlsym(hi, "DesktopPictureSetDisplayForSpace") else { return nil }
        self.connection = unsafeBitCast(connection, to: Connection.self)
        self.copySpaces = unsafeBitCast(copySpaces, to: CopySpaces.self)
        self.copyPicture = unsafeBitCast(copyPicture, to: CopyPicture.self)
        self.setPicture = unsafeBitCast(setPicture, to: SetPicture.self)
        // Framework handles deliberately remain loaded for these function pointers.
    }

    func targets(displays: [String: String]) -> [DesktopPictureTarget] {
        guard let groups = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Self.targets(groups: groups, displays: displays)
    }

    /// Pure topology decoding, also exercised without a WindowServer in tests.
    static func targets(groups: [[String: Any]], displays: [String: String]) -> [DesktopPictureTarget] {
        var result: [DesktopPictureTarget] = []
        for group in groups {
            guard let identifier = group["Display Identifier"] as? String,
                  let spaces = group["Spaces"] as? [[String: Any]] else { continue }
            let matching = displays.filter {
                identifier == "Main" || $0.value.caseInsensitiveCompare(identifier) == .orderedSame
            }.keys.sorted()
            for space in spaces {
                // Fullscreen app Spaces are not desktop thumbnails.
                guard (space["type"] as? NSNumber)?.intValue == 0,
                      let uuid = space["uuid"] as? String, !uuid.isEmpty else { continue }
                for display in matching {
                    let target = DesktopPictureTarget(display: display, space: uuid)
                    if !result.contains(target) { result.append(target) }
                }
            }
        }
        return result
    }

    func picture(target: DesktopPictureTarget) throws -> DesktopPicture? {
        guard let display = UInt32(target.display), let space = target.space,
              let config = copyPicture(display, 0, space as CFString)?.takeRetainedValue() as? [String: Any] else {
            throw CocoaError(.fileReadUnknown)
        }
        return try Self.decodePicture(config)
    }

    /// An empty dictionary is a real native selection (inherited/default), not
    /// an unavailable display. Keep it verbatim so restoration does not flatten
    /// a linked/dynamic wallpaper into a guessed DefaultDesktop.heic image.
    static func decodePicture(_ config: [String: Any]) throws -> DesktopPicture {
        let data = try PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
        let path = config["ImageFilePath"] as? String
        let url = path.flatMap { $0.isEmpty ? nil : imageURL($0) }
            ?? URL(string: "mwe-native-selection://inherited")!
        return DesktopPicture(url: url,
                              scaling: Int(NSImageScaling.scaleAxesIndependently.rawValue),
                              allowClipping: false, fill: [0, 0, 0, 1], nativeOptions: data)
    }

    func set(_ picture: DesktopPicture, target: DesktopPictureTarget) throws {
        guard let display = UInt32(target.display), let space = target.space else { return }
        let config = try Self.configuration(picture)
        setPicture(display, config as CFDictionary, 0, 0, space as CFString)
        // The setter returns void. Detect rejected/stale writes instead of
        // silently declaring success; the coordinator retries transient failures.
        guard let actual = copyPicture(display, 0, space as CFString)?.takeRetainedValue() as? [String: Any],
              Self.acknowledges(actual, expected: config) else {
            throw NSError(domain: "DesktopWallpaperSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "macOS has not accepted the wallpaper for desktop \(space)."
            ])
        }
    }

    static func acknowledges(_ actual: [String: Any], expected: [String: Any]) -> Bool {
        if let path = expected["ImageFilePath"] as? String, !path.isEmpty {
            guard let received = actual["ImageFilePath"] as? String, !received.isEmpty else { return false }
            return imageURL(received).standardizedFileURL == imageURL(path).standardizedFileURL
        }
        // A pathless selection must be restored as native configuration, not
        // acknowledged merely because both reads lack an image URL.
        return NSDictionary(dictionary: actual).isEqual(to: expected)
    }

    static func imageURL(_ path: String) -> URL {
        if path.hasPrefix("file:"), let url = URL(string: path), url.isFileURL { return url }
        let expanded = (path.hasPrefix("/~") ? String(path.dropFirst()) : path) as NSString
        let absolute = expanded.expandingTildeInPath
        return URL(fileURLWithPath: absolute.hasPrefix("/") ? absolute : "/" + absolute)
    }

    static func configuration(_ picture: DesktopPicture) throws -> [String: Any] {
        var config: [String: Any]
        if let data = picture.nativeOptions {
            guard let original = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            config = original
        } else {
            // A poster already has the display's exact aspect ratio. FillScreen
            // therefore preserves the final renderer crop/bars without rescaling
            // the source content a second time.
            let placement: String
            if picture.scaling == Int(NSImageScaling.scaleNone.rawValue) { placement = "Centered" }
            else if picture.scaling == Int(NSImageScaling.scaleAxesIndependently.rawValue) { placement = "FillScreen" }
            else { placement = picture.allowClipping ? "Crop" : "SizeToFit" }
            config = ["ImageFilePath": picture.url.path, "Placement": placement,
                      "BackgroundColor": Array(picture.fill.prefix(3))]
        }
        // Sonoma+ mis-expands absolute home paths into /~ in this legacy API.
        // Root-relative filesystem paths are accepted and read back as absolute.
        for key in ["ImageFilePath", "NewImageFilePath", "ChangePath", "NewChangePath"] {
            if let path = config[key] as? String, !path.isEmpty {
                config[key] = String(imageURL(path).path.dropFirst())
            }
        }
        return config
    }
}

@MainActor
final class SystemDesktopPictureWorkspace: DesktopPictureWorkspace {
    private let spaces = DesktopSpaceWallpaperAPI()
    private var reportedFallback = false

    static func id(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }

    func targets() throws -> [DesktopPictureTarget] {
        var displays: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let id = Self.id(screen), let number = UInt32(id),
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { continue }
            displays[id] = CFUUIDCreateString(nil, uuid) as String
        }
        var targets = spaces?.targets(displays: displays) ?? []
        for screen in NSScreen.screens {
            guard let id = Self.id(screen), !targets.contains(where: { $0.display == id }) else { continue }
            targets.append(DesktopPictureTarget(display: id, space: nil))
            if !reportedFallback {
                NSLog("[WE] All-Space wallpaper API unavailable; only the current desktop can be synchronized.")
                reportedFallback = true
            }
        }
        return targets
    }

    private func screen(_ display: String) -> NSScreen? { NSScreen.screens.first { Self.id($0) == display } }

    func currentPicture(target: DesktopPictureTarget) throws -> DesktopPicture? {
        if target.space != nil { return try spaces?.picture(target: target) }
        guard let screen = screen(target.display), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return DesktopPicture(url: url,
                              scaling: (options[.imageScaling] as? NSNumber)?.intValue ?? Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                              allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true,
                              fill: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent])
    }

    func setPicture(_ picture: DesktopPicture, target: DesktopPictureTarget) throws {
        if target.space != nil {
            guard let spaces else { throw CocoaError(.featureUnsupported) }
            try spaces.set(picture, target: target)
        } else if let screen = screen(target.display) {
            try NSWorkspace.shared.setDesktopImageURL(picture.url, for: screen, options: picture.options)
        }
    }
}
