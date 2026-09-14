import Foundation

/// Copies user-selected content into the managed library, never modifying the source.
actor WallpaperImportService {
    enum DuplicatePolicy: String, CaseIterable, Identifiable, Sendable {
        case skip = "Skip existing"
        case keepBoth = "Keep both copies"
        var id: String { rawValue }
    }

    struct Report: Sendable {
        var importedIDs: [String] = []
        var skipped: [String] = []
        var failures: [String] = []
        var cancelled = false
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi"]
    static let webExtensions: Set<String> = ["html", "htm"]

    func importItems(
        _ sources: [URL], into library: URL, duplicates: DuplicatePolicy,
        progress: @Sendable (String) async -> Void
    ) async throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let managedRoot = library.resolvingSymlinksInPath().standardizedFileURL
        // A sibling staging directory is on the same volume but invisible to the library scanner.
        let staging = managedRoot.deletingLastPathComponent()
            .appendingPathComponent(".mac-wallpaper-engine-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var report = Report()
        var seen = Set<String>()

        for source in sources {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                try Task.checkCancellation()
                let candidates = try discover(source)
                for candidate in candidates {
                    try Task.checkCancellation()
                    let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
                    guard seen.insert(canonical.path).inserted else { continue }
                    await progress("Importing \(candidate.lastPathComponent)…")
                    do {
                        guard !isWithin(canonical, managedRoot), !isWithin(managedRoot, canonical) else {
                            throw ImportError(message: "Choose a source outside MacWallpaperEngine’s managed library.")
                        }
                        let isDirectory = try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                        let preferredID = isDirectory ? candidate.lastPathComponent : "local-" + candidate.lastPathComponent
                        guard isSafeRelativePath(preferredID), !preferredID.contains("/") else {
                            throw ImportError(message: "The folder name cannot be used as a library identifier.")
                        }
                        var id = preferredID
                        var destination = managedRoot.appendingPathComponent(id, isDirectory: true)
                        if fm.fileExists(atPath: destination.path) {
                            if duplicates == .skip {
                                try validateProject(at: destination)
                                report.skipped.append(candidate.lastPathComponent)
                                continue
                            }
                            id += "-" + UUID().uuidString
                            destination = managedRoot.appendingPathComponent(id, isDirectory: true)
                        }
                        let staged = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        defer { try? fm.removeItem(at: staged) }
                        if isDirectory {
                            try validateProject(at: candidate)
                            try copySafely(candidate, to: staged)
                        } else {
                            let ext = candidate.pathExtension.lowercased()
                            guard Self.videoExtensions.contains(ext) || Self.webExtensions.contains(ext) else {
                                throw ImportError(message: "Choose a video, HTML file, or Wallpaper Engine project folder. Standalone images are not supported by this renderer.")
                            }
                            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
                            try copySafely(candidate, to: staged.appendingPathComponent(candidate.lastPathComponent))
                            let manifest: [String: Any] = [
                                "title": candidate.deletingPathExtension().lastPathComponent,
                                "type": Self.videoExtensions.contains(ext) ? "video" : "web",
                                "file": candidate.lastPathComponent,
                                "general": ["properties": [String: String]()]
                            ]
                            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                            try data.write(to: staged.appendingPathComponent("project.json"), options: .atomic)
                        }
                        try validateProject(at: staged)
                        try Task.checkCancellation()
                        // moveItem never overwrites a concurrently created destination.
                        try fm.moveItem(at: staged, to: destination)
                        report.importedIDs.append(id)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        report.failures.append("\(candidate.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                report.cancelled = true
                break
            } catch {
                report.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    private func discover(_ source: URL) throws -> [URL] {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ImportError(message: "Symbolic links are not imported. Choose the original folder or file instead.")
        }
        guard values.isDirectory == true else { return [source] }
        if fm.fileExists(atPath: source.appendingPathComponent("project.json").path) { return [source] }
        let relativeRoots = ["", "steamapps/workshop/content/431960", "workshop/content/431960", "content/431960", "431960"]
        var projects: [URL] = []
        for relative in relativeRoots {
            try Task.checkCancellation()
            let root = relative.isEmpty ? source : source.appendingPathComponent(relative, isDirectory: true)
            guard fm.fileExists(atPath: root.path) else { continue }
            guard isWithin(root.resolvingSymlinksInPath().standardizedFileURL,
                           source.resolvingSymlinksInPath().standardizedFileURL) else { continue }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for child in children where fm.fileExists(atPath: child.appendingPathComponent("project.json").path) {
                projects.append(child)
            }
        }
        guard !projects.isEmpty else {
            throw ImportError(message: "No project.json found. Choose a wallpaper project, a folder containing projects, or a Steam library with steamapps/workshop/content/431960.")
        }
        return projects.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func validateProject(at root: URL) throws {
        let manifestURL = root.appendingPathComponent("project.json")
        let metadata = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              (metadata.fileSize ?? 0) <= 16 * 1024 * 1024 else {
            throw ImportError(message: "project.json must be a regular JSON file smaller than 16 MB.")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard String(data: manifestData, encoding: .utf8) != nil, !manifestData.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw ImportError(message: "project.json must use UTF-8 encoding without a byte-order mark. Convert the manifest and import it again.")
        }
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let type = (manifest["type"] as? String)?.lowercased(), ["scene", "video", "web"].contains(type) else {
            throw ImportError(message: "project.json must describe a scene, video, or web wallpaper.")
        }
        if let value = manifest["file"], !(value is String) {
            throw ImportError(message: "The project’s file field must be a relative filename.")
        }
        let file = (manifest["file"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (type == "scene" ? "scene.json" : "")
        guard isSafeRelativePath(file) else {
            throw ImportError(message: "The project’s file field must point inside its own folder (no absolute paths or parent traversal).")
        }
        let entry = root.appendingPathComponent(file)
        let package = entry.deletingPathExtension().appendingPathExtension("pkg")
        let entryValues = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let packageValues = type == "scene" ? (try? package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])) : nil
        let exists = (entryValues?.isRegularFile == true && entryValues?.isSymbolicLink != true)
            || (packageValues?.isRegularFile == true && packageValues?.isSymbolicLink != true)
        guard exists else {
            throw ImportError(message: "Missing project content: \(file). Copy the complete wallpaper folder, not just project.json.")
        }
        if let preview = manifest["preview"] as? String, !preview.isEmpty, !isSafeRelativePath(preview) {
            throw ImportError(message: "The preview path must remain inside the wallpaper folder.")
        }
        if let dependencies = manifest["dependencies"] as? [String], dependencies.contains(where: { !isSafeRelativePath($0) }) {
            throw ImportError(message: "Project dependency paths may not escape their folder.")
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func isWithin(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }

    private func copySafely(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else {
            throw ImportError(message: "Symbolic links are not imported: \(source.lastPathComponent). Copy the original content into the project folder first.")
        }
        if values.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            for child in children {
                try copySafely(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else if values.isRegularFile == true {
            guard fm.createFile(atPath: destination.path, contents: nil) else {
                throw ImportError(message: "Could not create \(destination.lastPathComponent). Check available disk space and folder permissions.")
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } else {
            throw ImportError(message: "Unsupported special file: \(source.lastPathComponent). Only regular files and folders can be imported.")
        }
    }
}
