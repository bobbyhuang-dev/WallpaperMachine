import AppKit
import Darwin
import Foundation

/// WallpaperMachine keeps imports separate from Steam's installation and never edits source wallpapers.
enum ClientPaths {
    static var supportURL: URL {
        if let override = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WallpaperMachine", isDirectory: true)
    }

    static var libraryURL: URL { supportURL.appendingPathComponent("Library", isDirectory: true) }
    static var managedAssetsURL: URL { supportURL.appendingPathComponent("SceneAssets", isDirectory: true) }
    /// Where user-picked `file`/`directory` property assets are kept for good.
    ///
    /// Deliberately not under any directory named `Cache`, not inside `Library/`
    /// (the wallpaper library, which a re-download replaces) and not inside the
    /// Steam workshop tree, so deleting or re-downloading a wallpaper cannot take
    /// the user's imported files with it.
    static var userAssetsURL: URL { supportURL.appendingPathComponent("UserAssets", isDirectory: true) }
    static var assetsURL: URL {
        if let configured = UserDefaults.standard.string(forKey: "WallpaperMachineAssetsPath"), !configured.isEmpty {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            if hasSceneAssets(at: url) { return url }
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets", isDirectory: true)
        let candidates = [managedAssetsURL, installed,
                          supportURL.appendingPathComponent("Steam/steamapps/common/wallpaper_engine/assets")]
        return candidates.first(where: { hasSceneAssets(at: $0) }) ?? managedAssetsURL
    }
    static var managedSteamCMDURL: URL { supportURL.appendingPathComponent("SteamCMD", isDirectory: true) }
    static var thumbnailCacheURL: URL { supportURL.appendingPathComponent("Cache/WorkshopThumbnails", isDirectory: true) }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let starter = libraryURL.appendingPathComponent("starter-aurora", isDirectory: true)
        let starterMarker = supportURL.appendingPathComponent(".starter-installed")
        if !FileManager.default.fileExists(atPath: starterMarker.path),
           !FileManager.default.fileExists(atPath: starter.path),
           let bundled = Bundle.main.url(forResource: "StarterWallpaper", withExtension: nil) {
            let pending = supportURL.appendingPathComponent(".starter-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: pending) }
            try FileManager.default.copyItem(at: bundled, to: pending)
            try FileManager.default.moveItem(at: pending, to: starter)
        }
        // Remember installation so deleting the starter does not restore it on launch.
        if FileManager.default.fileExists(atPath: starter.path),
           !FileManager.default.fileExists(atPath: starterMarker.path) {
            try Data().write(to: starterMarker, options: .atomic)
        }
        setenv("WALLPAPER_MACHINE_SUPPORT_ROOT", supportURL.path, 1)
        setenv("WALLPAPER_MACHINE_LIBRARY_ROOT", libraryURL.path, 1)
        setenv("WALLPAPER_MACHINE_ASSETS_ROOT", assetsURL.path, 1)
        setenv("WALLPAPER_MACHINE_USER_ASSETS_ROOT", userAssetsURL.path, 1)
    }

    static func hasSceneAssets(at url: URL) -> Bool {
        // These are referenced by the renderer's built-in image and effect materials.
        ["shaders/genericimage2.vert", "shaders/genericimage2.frag", "materials/util/effectpassthrough.json"].allSatisfy { path in
            let file = url.appendingPathComponent(path)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
            return FileManager.default.isReadableFile(atPath: file.path)
        }
    }

    static func configureAssetsFolder(at url: URL) throws {
        guard hasSceneAssets(at: url) else {
            throw WorkshopFailure(message: String(localized: "This folder does not contain Wallpaper Engine’s shared shaders and materials. Choose its complete assets folder, or install scene assets through Steam."))
        }
        UserDefaults.standard.set(url.path, forKey: "WallpaperMachineAssetsPath")
        setenv("WALLPAPER_MACHINE_ASSETS_ROOT", url.path, 1)
    }

    static func installSceneAssets(from source: URL, to destination: URL) throws {
        guard hasSceneAssets(at: source) else {
            throw WorkshopFailure(message: String(localized: "Steam did not produce complete scene assets. Confirm this account owns Wallpaper Engine and retry. Existing assets have not been changed."))
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    static func selectAssetsFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate Wallpaper Engine assets")
        panel.message = String(localized: "Choose the assets folder inside your legitimate Wallpaper Engine installation. These shared resources are required by many scenes.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let assets = hasSceneAssets(at: url) ? url : url.appendingPathComponent("assets")
        do {
            try configureAssetsFolder(at: assets)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Assets folder not found")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
        return true
    }
}
