import Foundation

/// Content a `file` or `directory` wallpaper property accepts.
enum UserAssetFilter: String, Sendable, CaseIterable {
    case image
    case video
    /// The author declared no file-type option. Everything either list allows is
    /// accepted; screening still happens, so a document or executable is refused.
    case any

    /// Lower-cased extensions, matching the sets the official property editor offers.
    var allowedExtensions: Set<String> {
        switch self {
        case .image:
            return Self.imageExtensions
        case .video:
            return Self.videoExtensions
        case .any:
            return Self.imageExtensions.union(Self.videoExtensions)
        }
    }

    private static let imageExtensions: Set<String> = ["jpeg", "jpg", "png", "pnga", "bmp", "gif", "svg", "webp"]
    private static let videoExtensions: Set<String> = ["webm", "ogg", "ogv"]
}

/// One staged asset: where it lives, and the value the page turns into a `file:///` URL.
struct UserAssetImport: Sendable, Equatable {
    var stagedPath: String
    var pageValue: String

    init(stagedPath: String, pageValue: String) {
        self.stagedPath = stagedPath
        self.pageValue = pageValue
    }

    init(stagedPath: String) {
        self.stagedPath = stagedPath
        self.pageValue = Self.pageValue(forPath: stagedPath)
    }

    /// Wallpaper pages build `'file:///' + value`, so an absolute POSIX path arrives
    /// without its leading separator. Only the three characters that would otherwise
    /// terminate or re-scope the URL are escaped: a page that treats the value as a
    /// plain path still receives the literal spaces, `+`, `&` and non-ASCII it expects.
    static func pageValue(forPath path: String) -> String {
        var value = path
        if value.hasPrefix("/") { value.removeFirst() }
        return value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: "?", with: "%3F")
    }
}

/// Why an import could not be staged. The reason is user-readable and always surfaced.
struct UserAssetError: LocalizedError, Equatable {
    enum Code: String, Sendable {
        case projectMissing
        case projectNotWritable
        case invalidPropertyID
        case sourceUnreadable
        case sourceInsideStaging
        case sourceNotAFile
        case sourceNotADirectory
        case unsupportedType
        case stagingFailed
    }

    let code: Code
    let reason: String

    var errorDescription: String? { reason }
}

/// Stages the files a `file` or `directory` property points at so a wallpaper page can read them.
///
/// Everything lands in `<project>/.mwe-user-assets/<propertyId>/`. That location is forced
/// by WebKit: `loadFileURL(_:allowingReadAccessTo:)` only grants access below a root that is
/// an ancestor of the entry file, so a page can never read a file outside its own project
/// folder. Widening the root to a common ancestor would hand every wallpaper the whole
/// application-support tree, and a symlink into the user's file is resolved and refused by
/// WebKit, so the only workable form is a real directory entry inside the project.
///
/// Entries are hard links when the source shares the project's volume and byte copies when it
/// does not. The user's original is never moved, renamed or written to, and no authored
/// wallpaper file is touched: the dot-directory is the single thing this type creates, and
/// `clear(propertyId:)` / `clearAll()` are its deletion route.
@MainActor final class UserAssetStore {
    /// Watcher construction is injected so tests drive directory changes without FSEvents.
    typealias WatcherFactory = @MainActor (URL, @escaping @MainActor () -> Void) -> DirectoryWatching

    /// Upper bound callers should pass to `importDirectory`. Large enough for a real
    /// wallpaper slideshow folder, small enough that a mistaken pick at `/` cannot
    /// stage an unbounded number of links.
    static let defaultDirectoryFileLimit = 4096

    static let stagingDirectoryName = ".mwe-user-assets"

    static func stagingRoot(projectURL: URL) -> URL {
        projectURL.standardizedFileURL.appendingPathComponent(stagingDirectoryName, isDirectory: true)
    }

    var onDirectoryChanged: ((_ propertyId: String, _ added: [UserAssetImport], _ removed: [UserAssetImport]) -> Void)?

    private let projectURL: URL
    private let fileManager: FileManager
    private let makeWatcher: WatcherFactory
    private var properties: [String: PropertyState] = [:]

    init(
        projectURL: URL,
        fileManager: FileManager = .default,
        watcherFactory: @escaping WatcherFactory = { url, onChange in
            DirectoryWatcher(url: url, onChange: onChange)
        }
    ) {
        self.projectURL = projectURL
        self.fileManager = fileManager
        self.makeWatcher = watcherFactory
    }

    deinit {
        // FSEvents holds the stream's callback reference, so a watcher outlives its owner
        // unless it is stopped explicitly.
        for state in properties.values { state.watcher?.stop() }
    }

    // MARK: - Import

    /// Stages a single file. Replaces whatever the property staged before.
    @discardableResult
    func importFile(at url: URL, propertyId: String, filter: UserAssetFilter) throws -> UserAssetImport {
        let source = try canonicalSource(url)
        guard try !isDirectory(source) else {
            throw UserAssetError(code: .sourceNotAFile, reason: String(
                localized: "Choose a file, not a folder."))
        }
        guard filter.allowedExtensions.contains(source.pathExtension.lowercased()) else {
            throw UserAssetError(code: .unsupportedType, reason: unsupportedReason(filter))
        }
        let directory = try resetPropertyDirectory(propertyId)
        let staged = directory.appendingPathComponent(source.lastPathComponent)
        try stage(source, at: staged)
        let asset = UserAssetImport(stagedPath: staged.path)
        var state = PropertyState(filter: filter, limit: 1)
        state.entries[source.lastPathComponent] = StagedEntry(asset: asset, stamp: stamp(of: source))
        properties[propertyId] = state
        return asset
    }

    /// Stages up to `limit` matching files from the first level of `url` and watches it for
    /// changes. Returns the staged assets ordered by file name.
    @discardableResult
    func importDirectory(
        at url: URL, propertyId: String, filter: UserAssetFilter, limit: Int
    ) throws -> [UserAssetImport] {
        let source = try canonicalSource(url)
        guard try isDirectory(source) else {
            throw UserAssetError(code: .sourceNotADirectory, reason: String(
                localized: "Choose a folder, not a file."))
        }
        let directory = try resetPropertyDirectory(propertyId)
        let scan = scanSource(source, filter: filter, limit: limit)
        var state = PropertyState(filter: filter, limit: limit)
        state.sourceDirectory = source
        state.truncated = scan.truncated
        for candidate in scan.files {
            let staged = directory.appendingPathComponent(candidate.name)
            do {
                try stage(candidate.url, at: staged)
            } catch {
                // One unreadable entry must not cost the user the rest of the folder.
                AppLog.warn("user assets \(propertyId): skipped \(candidate.name): \(error.localizedDescription)")
                continue
            }
            state.entries[candidate.name] = StagedEntry(
                asset: UserAssetImport(stagedPath: staged.path), stamp: candidate.stamp)
        }
        if scan.truncated {
            AppLog.warn("user assets \(propertyId): folder exceeds \(limit) files; staged the first \(state.entries.count)")
        }
        state.watcher = makeWatcher(source) { [weak self] in
            self?.directoryDidChange(propertyId: propertyId)
        }
        properties[propertyId] = state
        return orderedAssets(state)
    }

    // MARK: - Query

    /// A uniformly chosen staged file, or nil when nothing is staged for the property.
    /// Reads the in-memory index; it never walks the source folder.
    func randomFile(propertyId: String) -> UserAssetImport? {
        properties[propertyId]?.entries.values.randomElement()?.asset
    }

    /// Staged assets for a property, ordered by file name.
    func stagedFiles(propertyId: String) -> [UserAssetImport] {
        guard let state = properties[propertyId] else { return [] }
        return orderedAssets(state)
    }

    /// True when the property's source folder held more matching files than the limit
    /// allowed, so only a prefix of it is staged.
    func isTruncated(propertyId: String) -> Bool {
        properties[propertyId]?.truncated ?? false
    }

    // MARK: - Removal

    func clear(propertyId: String) {
        properties.removeValue(forKey: propertyId)?.watcher?.stop()
        guard let directory = try? propertyDirectory(propertyId) else { return }
        try? fileManager.removeItem(at: directory)
    }

    func clearAll() {
        for state in properties.values { state.watcher?.stop() }
        properties.removeAll()
        try? fileManager.removeItem(at: Self.stagingRoot(projectURL: projectURL))
    }

    // MARK: - Directory changes

    private func directoryDidChange(propertyId: String) {
        guard var state = properties[propertyId], let source = state.sourceDirectory else { return }
        guard let directory = try? propertyDirectory(propertyId) else { return }
        let scan = scanSource(source, filter: state.filter, limit: state.limit)
        if scan.truncated != state.truncated {
            AppLog.warn("user assets \(propertyId): folder \(scan.truncated ? "now exceeds" : "no longer exceeds") \(state.limit) files")
        }
        state.truncated = scan.truncated

        var added: [UserAssetImport] = []
        var surviving = Set<String>()
        for candidate in scan.files {
            surviving.insert(candidate.name)
            if let existing = state.entries[candidate.name], existing.stamp == candidate.stamp { continue }
            let staged = directory.appendingPathComponent(candidate.name)
            do {
                try stage(candidate.url, at: staged)
            } catch {
                AppLog.warn("user assets \(propertyId): skipped \(candidate.name): \(error.localizedDescription)")
                continue
            }
            let asset = UserAssetImport(stagedPath: staged.path)
            state.entries[candidate.name] = StagedEntry(asset: asset, stamp: candidate.stamp)
            added.append(asset)
        }

        var removed: [UserAssetImport] = []
        for (name, entry) in state.entries where !surviving.contains(name) {
            try? fileManager.removeItem(atPath: entry.asset.stagedPath)
            state.entries[name] = nil
            removed.append(entry.asset)
        }

        properties[propertyId] = state
        guard !added.isEmpty || !removed.isEmpty else { return }
        onDirectoryChanged?(
            propertyId,
            added.sorted { $0.stagedPath < $1.stagedPath },
            removed.sorted { $0.stagedPath < $1.stagedPath })
    }

    // MARK: - Staging

    private func propertyDirectory(_ propertyId: String) throws -> URL {
        guard !propertyId.isEmpty, propertyId != ".", propertyId != "..",
              !propertyId.contains("/"), !propertyId.contains(":"), !propertyId.contains("\0") else {
            throw UserAssetError(code: .invalidPropertyID, reason: String(
                localized: "This wallpaper property has a name that cannot be used as a folder."))
        }
        return Self.stagingRoot(projectURL: projectURL)
            .appendingPathComponent(propertyId, isDirectory: true)
    }

    /// Empties and recreates a property's staging directory so a new pick never inherits
    /// leftovers from the previous one.
    private func resetPropertyDirectory(_ propertyId: String) throws -> URL {
        let directory = try propertyDirectory(propertyId)
        try requireWritableProject()
        properties.removeValue(forKey: propertyId)?.watcher?.stop()
        try? fileManager.removeItem(at: directory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UserAssetError(code: .projectNotWritable, reason: notWritableReason(error))
        }
        return directory
    }

    private func requireWritableProject() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UserAssetError(code: .projectMissing, reason: String(
                localized: "The wallpaper folder is missing, so the chosen file cannot be prepared."))
        }
        let root = Self.stagingRoot(projectURL: projectURL)
        let parent = fileManager.fileExists(atPath: root.path) ? root : projectURL
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UserAssetError(code: .projectNotWritable, reason: notWritableReason(nil))
        }
    }

    private func stage(_ source: URL, at destination: URL) throws {
        try? fileManager.removeItem(at: destination)
        do {
            // A hard link keeps the original untouched and costs no space. WebKit refuses a
            // symlink that leaves the read-access root, and resolves it before checking, so a
            // link is the only zero-copy form a page can actually load.
            try fileManager.linkItem(at: source, to: destination)
        } catch {
            do {
                // Hard links cannot cross volumes; an external disk needs a real copy.
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw UserAssetError(code: .stagingFailed, reason: String(
                    localized: "\(source.lastPathComponent) could not be prepared for this wallpaper."))
            }
        }
    }

    // MARK: - Source inspection

    private func canonicalSource(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let staging = Self.stagingRoot(projectURL: projectURL).resolvingSymlinksInPath().standardizedFileURL
        guard !Self.isWithin(resolved, staging), resolved != staging else {
            throw UserAssetError(code: .sourceInsideStaging, reason: String(
                localized: "Choose a file outside the wallpaper’s own prepared assets."))
        }
        guard fileManager.isReadableFile(atPath: resolved.path) else {
            throw UserAssetError(code: .sourceUnreadable, reason: String(
                localized: "\(url.lastPathComponent) cannot be read."))
        }
        return resolved
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        var flag: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &flag) else {
            throw UserAssetError(code: .sourceUnreadable, reason: String(
                localized: "\(url.lastPathComponent) cannot be read."))
        }
        return flag.boolValue
    }

    /// One level of `directory`, filtered and capped. Only metadata is read; file contents
    /// are never loaded, however many entries the folder holds.
    private func scanSource(
        _ directory: URL, filter: UserAssetFilter, limit: Int
    ) -> (files: [Candidate], truncated: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            return ([], false)
        }
        let allowed = filter.allowedExtensions
        var candidates: [Candidate] = []
        var truncated = false
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard allowed.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            guard fileManager.isReadableFile(atPath: url.path) else { continue }
            guard candidates.count < max(0, limit) else {
                truncated = true
                break
            }
            candidates.append(Candidate(
                url: url, name: name,
                stamp: Stamp(size: values.fileSize ?? -1, modified: values.contentModificationDate)))
        }
        return (candidates, truncated)
    }

    private func stamp(of url: URL) -> Stamp {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Stamp(size: values?.fileSize ?? -1, modified: values?.contentModificationDate)
    }

    private func orderedAssets(_ state: PropertyState) -> [UserAssetImport] {
        state.entries.keys.sorted().compactMap { state.entries[$0]?.asset }
    }

    private func unsupportedReason(_ filter: UserAssetFilter) -> String {
        let extensions = filter.allowedExtensions.sorted().joined(separator: ", ")
        switch filter {
        case .image:
            return String(localized: "This wallpaper property takes an image: \(extensions).")
        case .video:
            return String(localized: "This wallpaper property takes a video: \(extensions).")
        case .any:
            return String(localized: "This wallpaper property takes one of: \(extensions).")
        }
    }

    private func notWritableReason(_ error: Error?) -> String {
        if let error {
            return String(localized: "The wallpaper folder cannot be written to: \(error.localizedDescription)")
        }
        return String(localized: "The wallpaper folder is read-only, so the chosen file cannot be prepared.")
    }

    private static func isWithin(_ url: URL, _ root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard components.count > rootComponents.count else { return false }
        return Array(components.prefix(rootComponents.count)) == rootComponents
    }

    // MARK: - State

    private struct Stamp: Equatable {
        var size: Int
        var modified: Date?
    }

    private struct Candidate {
        var url: URL
        var name: String
        var stamp: Stamp
    }

    private struct StagedEntry {
        var asset: UserAssetImport
        var stamp: Stamp
    }

    private struct PropertyState {
        var filter: UserAssetFilter
        var limit: Int
        var sourceDirectory: URL?
        var entries: [String: StagedEntry] = [:]
        var truncated = false
        var watcher: DirectoryWatching?
    }
}
