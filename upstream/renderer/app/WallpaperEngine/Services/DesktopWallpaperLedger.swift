import AppKit

struct DesktopPicture: Equatable, Codable {
    var url: URL
    var scaling: Int
    var allowClipping: Bool
    var fill: [Double]

    static func poster(_ url: URL) -> Self {
        // The renderer already applied scaling, cropping, flipping and bars.
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

/// The production implementation is the only code that talks to NSWorkspace.
/// Tests use an in-memory desktop, never the user's wallpaper settings.
@MainActor
protocol DesktopPictureWorkspace {
    func currentPicture(display: String) -> DesktopPicture?
    func setPicture(_ picture: DesktopPicture, display: String) throws
}

@MainActor
final class DesktopWallpaperLedger {
    private struct Entry: Codable {
        var original: DesktopPicture
        var alternate: String
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

    func apply(png: Data, display: String) throws {
        guard let current = workspace.currentPicture(display: display) else { return }
        let owned = entry(for: current.url)
        if owned != nil, (try? Data(contentsOf: current.url)) == png { return }
        // Two alternating files per native desktop invalidate the OS image
        // cache without unbounded frame files. Each Space retains its own
        // original, without private Space IDs or switching Spaces.
        let name = owned?.alternate ?? UUID().uuidString + "-a.png"
        let url = folder.appendingPathComponent(name)
        try png.write(to: url, options: .atomic)
        if owned == nil {
            let alternate = name.replacingOccurrences(of: "-a.png", with: "-b.png")
            entries[name] = Entry(original: current, alternate: alternate)
            entries[alternate] = Entry(original: current, alternate: name)
        }
        // Journal BEFORE changing the OS setting, including crash recovery.
        try save()
        try workspace.setPicture(.poster(url), display: display)
        // Keep both slots for inactive Spaces and system thumbnail caches.
    }

    func restore(display: String) throws {
        guard let current = workspace.currentPicture(display: display),
              let entry = entry(for: current.url) else { return }
        // Do not overwrite a wallpaper the user changed outside this app.
        try workspace.setPicture(entry.original, display: display)
    }

    private func entry(for url: URL) -> Entry? {
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return nil }
        return entries[url.lastPathComponent]
    }

    private func save() throws {
        try JSONEncoder().encode(entries).write(to: journal, options: .atomic)
    }
}
