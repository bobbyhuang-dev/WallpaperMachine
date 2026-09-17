import Foundation

/// Only removes direct children of the app-managed library, never import sources.
enum WallpaperDeletionService {
    static func wallpaperURL(id: String, library: URL) throws -> URL {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw failure("Invalid wallpaper ID. Nothing was deleted.")
        }
        let root = library.resolvingSymlinksInPath().standardizedFileURL
        let item = root.appendingPathComponent(id, isDirectory: true)
        let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
              item.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == root else {
            throw failure("This wallpaper is not a folder in the managed library. Nothing was deleted.")
        }
        return item
    }

    static func moveToTrash(id: String, library: URL,
                            recycle: (URL) throws -> Void = { url in
                                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                            }) throws {
        try recycle(wallpaperURL(id: id, library: library))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MacWallpaperEngine.Deletion", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Outcome of a batch deletion; ids keep the order they were requested in.
struct WallpaperDeletionReport {
    var deleted: [String] = []
    var failures: [(id: String, error: Error)] = []
}
