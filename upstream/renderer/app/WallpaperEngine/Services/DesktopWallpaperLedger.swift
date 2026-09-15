import AppKit
import CryptoKit

struct DesktopPicture: Equatable, Codable {
    var url: URL
    var scaling: Int
    var allowClipping: Bool
    var fill: [Double]
    // Preserve the complete native per-Space configuration (including dynamic
    // wallpaper/slideshow options) rather than reconstructing it on restore.
    var nativeOptions: Data? = nil

    static func poster(_ url: URL) -> Self {
        Self(url: url, scaling: Int(NSImageScaling.scaleAxesIndependently.rawValue),
             allowClipping: false, fill: [0, 0, 0, 1])
    }

    var options: [NSWorkspace.DesktopImageOptionKey: Any] {
        var result: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: scaling, .allowClipping: allowClipping
        ]
        if fill.count == 4 {
            result[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
        }
        return result
    }
}

/// Tests use an in-memory workspace; no test changes the user's wallpaper.
@MainActor
protocol DesktopPictureWorkspace {
    func targets() throws -> [DesktopPictureTarget]
    func currentPicture(target: DesktopPictureTarget) throws -> DesktopPicture?
    func setPicture(_ picture: DesktopPicture, target: DesktopPictureTarget) throws
}

@MainActor
final class DesktopWallpaperLedger {
    private struct Entry: Codable {
        var original: DesktopPicture
        // nil for the previous alternating-file journal, which remains readable.
        var display: String?
    }
    private var entries: [String: Entry]
    private let folder: URL
    private let journal: URL
    private let workspace: any DesktopPictureWorkspace

    init(folder: URL, workspace: any DesktopPictureWorkspace) throws {
        self.folder = folder
        self.journal = folder.appendingPathComponent("originals.json")
        self.workspace = workspace
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: journal.path) {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: journal))
        } else {
            entries = [:]
        }
    }

    /// Submit a fresh frame to EVERY desktop on its display, without a Space
    /// change event. A loading renderer keeps the previous poster until ready.
    func synchronize(posters: [String: Data], liveDisplays: Set<String>) throws {
        let targets = try workspace.targets()
        var firstError: Error?
        // Cache only within this pass: external edits/missing files must still
        // be detected on the next refresh. Retain no extra image buffers.
        var comparisons: [URL: Bool] = [:]
        let digests = posters.mapValues { Data(SHA256.hash(data: $0)) }
        for target in targets {
            do {
                if let png = posters[target.display], liveDisplays.contains(target.display) {
                    try apply(png: png, digest: digests[target.display]!, target: target,
                              comparisons: &comparisons)
                } else if !liveDisplays.contains(target.display) {
                    try restore(target: target)
                }
            } catch { if firstError == nil { firstError = error } }
        }
        // Keep updating sibling Spaces/displays even when one native call fails.
        if let firstError { throw firstError }
        try removeUnreferencedPosters(targets: targets)
    }

    func restoreAll() throws { try synchronize(posters: [:], liveDisplays: []) }

    func apply(png: Data, target: DesktopPictureTarget) throws {
        var comparisons: [URL: Bool] = [:]
        try apply(png: png, digest: Data(SHA256.hash(data: png)), target: target, comparisons: &comparisons)
    }

    private func apply(png: Data, digest: Data, target: DesktopPictureTarget,
                       comparisons: inout [URL: Bool]) throws {
        guard let current = try workspace.currentPicture(target: target) else {
            throw NSError(domain: "DesktopWallpaperSync", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read the original wallpaper for display \(target.display), desktop \(target.space ?? "current"); poster synchronization was not applied."
            ])
        }
        let owned = entry(for: current.url)
        if let owned, owned.display == target.display {
            let matches: Bool
            if let cached = comparisons[current.url] { matches = cached }
            else {
                matches = (try? Data(contentsOf: current.url)) == png
                comparisons[current.url] = matches
            }
            if matches { return }
        } else if owned != nil, (try? Data(contentsOf: current.url)) == png { return }
        let original = owned?.original ?? current
        // Never reuse a filename for different pixels: WallpaperAgent can cache
        // inactive-Space thumbnails by URL even after the file is overwritten.
        // Identical originals/frames may share an immutable file safely.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hash = SHA256()
        hash.update(data: Data(target.display.utf8))
        hash.update(data: try encoder.encode(original))
        // Hash large pixels once per display, not once per Space.
        hash.update(data: digest)
        let name = "poster-" + hash.finalize().map { String(format: "%02x", $0) }.joined() + ".png"
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try png.write(to: url, options: .atomic)
        }
        if entries[name] == nil {
            entries[name] = Entry(original: original, display: target.display)
            // Journal BEFORE the native call, including crash/relaunch recovery.
            // Shared immutable files already have a durable entry.
            do { try save() }
            catch {
                entries.removeValue(forKey: name)
                throw error
            }
        }
        comparisons[url] = true
        try workspace.setPicture(.poster(url), target: target)
    }

    func restore(target: DesktopPictureTarget) throws {
        guard let current = try workspace.currentPicture(target: target),
              let entry = entry(for: current.url) else { return }
        // Do not overwrite a wallpaper the user changed outside this app.
        try workspace.setPicture(entry.original, target: target)
    }

    private func entry(for url: URL) -> Entry? {
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return nil }
        return entries[url.lastPathComponent]
    }

    private func removeUnreferencedPosters(targets: [DesktopPictureTarget]) throws {
        // Only prune displays for which ALL native Space targets are available.
        // A public-API fallback cannot see inactive Spaces, so must keep files.
        let completeDisplays = Set(targets.filter { $0.space != nil }.map(\.display))
            .subtracting(targets.filter { $0.space == nil }.map(\.display))
        var referenced = Set<String>()
        for target in targets {
            guard let current = try workspace.currentPicture(target: target) else { return }
            if entry(for: current.url) != nil { referenced.insert(current.url.lastPathComponent) }
        }
        let obsolete = entries.filter {
            guard let display = $0.value.display else { return false }
            return completeDisplays.contains(display) && !referenced.contains($0.key)
        }.map(\.key)
        for name in obsolete {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            entries.removeValue(forKey: name)
        }
        if !obsolete.isEmpty { try save() }
    }

    private func save() throws { try JSONEncoder().encode(entries).write(to: journal, options: .atomic) }
}
