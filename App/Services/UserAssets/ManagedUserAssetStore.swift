import CryptoKit
import Darwin
import Foundation

/// One file the app owns a copy of, on behalf of a `file` or `directory` property.
///
/// `assetId` is derived from the content digest, so re-picking a byte-identical
/// file lands on the entry that is already stored instead of making a second copy.
struct ManagedUserAsset: Codable, Equatable, Sendable {
    var assetId: String
    var fileName: String
    /// The user's own path, kept for display and for re-scanning a watched folder.
    /// Never used to serve bytes: the store's copy is the one that is read.
    var sourcePath: String
    var size: Int64
    var modified: Date
    /// SHA-256 of the file's bytes, lower-case hex.
    var digest: String
}

/// What one property imported, and where it came from.
struct ManagedUserAssetProperty: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case directory
    }

    var kind: Kind
    /// The file or folder the user picked.
    var sourcePath: String
    /// Stored files, ordered by file name.
    var assets: [ManagedUserAsset]
    /// True when the source folder held more matching files than the limit allowed.
    var truncated: Bool
    /// Legacy in-project staging directories already absorbed, so migration runs once.
    var migratedLegacyPaths: [String]

    init(
        kind: Kind, sourcePath: String, assets: [ManagedUserAsset] = [], truncated: Bool = false,
        migratedLegacyPaths: [String] = []
    ) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.assets = assets
        self.truncated = truncated
        self.migratedLegacyPaths = migratedLegacyPaths
    }
}

/// The system of record for one wallpaper's imported assets.
///
/// Written next to the stored bytes rather than into the wallpaper package: a
/// Workshop update replaces the package, and the manifest has to survive that.
struct UserAssetManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileName = "manifest.json"

    var version: Int = currentVersion
    var wallpaperId: String
    var properties: [String: ManagedUserAssetProperty] = [:]
}

/// Keeps the user's imported `file`/`directory` property assets in application
/// support, keyed by the stable wallpaper id rather than by display name or by
/// entry file name, so a Workshop update or a delete-and-re-download does not
/// lose them.
///
/// Layout: `UserAssets/<wallpaperId>/<propertyId>/<assetId>/<fileName>`, with
/// `UserAssets/<wallpaperId>/manifest.json` recording what each property holds.
///
/// Importing copies the user's file in — cloned with `clonefile` where the
/// filesystem supports it, so an APFS import costs no space until one side is
/// written. The user's original is never moved, renamed or written to.
final class ManagedUserAssetStore {
    let root: URL
    private let fileManager: FileManager

    init(root: URL = ClientPaths.userAssetsURL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    // MARK: - Locations
    func wallpaperRoot(_ wallpaperId: String) throws -> URL {
        guard let component = Self.safeComponent(wallpaperId) else {
            throw UserAssetError(code: .invalidWallpaperID, reason: String(
                localized: "This wallpaper has an identifier that cannot be used as a folder."))
        }
        return root.appendingPathComponent(component, isDirectory: true)
    }

    func propertyRoot(wallpaperId: String, propertyId: String) throws -> URL {
        guard let component = Self.safeComponent(propertyId) else {
            throw UserAssetError(code: .invalidPropertyID, reason: String(
                localized: "This wallpaper property has a name that cannot be used as a folder."))
        }
        return try wallpaperRoot(wallpaperId).appendingPathComponent(component, isDirectory: true)
    }

    func storedURL(wallpaperId: String, propertyId: String, asset: ManagedUserAsset) throws -> URL {
        try propertyRoot(wallpaperId: wallpaperId, propertyId: propertyId)
            .appendingPathComponent(asset.assetId, isDirectory: true)
            .appendingPathComponent(asset.fileName)
    }

    /// A path component that cannot escape the store or collide with `.` / `..`.
    /// Wallpaper ids are numeric in practice; anything else is refused rather
    /// than sanitised into a different wallpaper's folder.
    private static func safeComponent(_ raw: String) -> String? {
        guard !raw.isEmpty, raw != ".", raw != "..",
              !raw.contains("/"), !raw.contains(":"), !raw.contains("\0"),
              !raw.hasPrefix(".") else { return nil }
        return raw
    }

    // MARK: - Manifest

    func manifest(wallpaperId: String) -> UserAssetManifest {
        // ISO-8601 both ways: the encoder writes it, and a decoder left on the default
        // numeric strategy silently fails to read its own output, which reads back as
        // "this wallpaper has no managed assets".
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let url = try? wallpaperRoot(wallpaperId).appendingPathComponent(UserAssetManifest.fileName),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(UserAssetManifest.self, from: data),
              decoded.version == UserAssetManifest.currentVersion
        else { return UserAssetManifest(wallpaperId: wallpaperId) }
        return decoded
    }

    /// Written whole and atomically: a crash mid-write must not leave a manifest
    /// that lists half a property's files.
    func write(_ manifest: UserAssetManifest) throws {
        let directory = try wallpaperRoot(manifest.wallpaperId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(UserAssetManifest.fileName), options: .atomic)
    }

    // MARK: - Import

    /// Copies the bytes at `readingFrom` into the store unless an entry with the
    /// same content is already there, and records `sourcePath` as where the user's
    /// own copy lives.
    ///
    /// The two are the same for an ordinary import. They differ when a round-6
    /// in-project staging directory is migrated: the bytes are read from the staged
    /// link, while the path recorded is the original the property still names.
    ///
    /// `known` is the property's current manifest entry for this file name, which
    /// lets an unchanged file skip both the digest and the copy.
    func adopt(
        readingFrom source: URL, fileName: String, sourcePath: String,
        wallpaperId: String, propertyId: String, known: ManagedUserAsset?
    ) throws -> ManagedUserAsset {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate ?? .distantPast

        if let known, known.fileName == fileName, known.size == size,
           known.modified == modified, known.sourcePath == sourcePath,
           fileManager.fileExists(atPath: (try? storedURL(
               wallpaperId: wallpaperId, propertyId: propertyId, asset: known))?.path ?? "") {
            // Same bytes by every cheap measure, already stored: no digest, no copy.
            return known
        }

        let digest = try Self.digest(of: source)
        let asset = ManagedUserAsset(
            assetId: String(digest.prefix(32)), fileName: fileName, sourcePath: sourcePath,
            size: size, modified: modified, digest: digest)
        let destination = try storedURL(wallpaperId: wallpaperId, propertyId: propertyId, asset: asset)
        if fileManager.fileExists(atPath: destination.path) {
            // Content-addressed: the same digest under the same name is the same file,
            // so re-picking a file the store already holds copies nothing.
            return asset
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Self.copy(source, to: destination, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw UserAssetError(code: .stagingFailed, reason: String(
                localized: "\(fileName) could not be copied into the app's asset folder."))
        }
        return asset
    }

    /// Drops the stored directories a property no longer lists. Called after the
    /// manifest has been rewritten, so a failure here costs disk space and never
    /// a reference.
    func pruneUnlisted(wallpaperId: String, propertyId: String, keeping assets: [ManagedUserAsset]) {
        guard let directory = try? propertyRoot(wallpaperId: wallpaperId, propertyId: propertyId),
              let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return }
        let live = Set(assets.map(\.assetId))
        for entry in entries where !live.contains(entry.lastPathComponent) {
            try? fileManager.removeItem(at: entry)
        }
    }

    func removeProperty(wallpaperId: String, propertyId: String) {
        guard let directory = try? propertyRoot(wallpaperId: wallpaperId, propertyId: propertyId) else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Bytes

    /// Streams the file so a large video is never held in memory.
    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `clonefile` first: on APFS an import costs metadata rather than the file's
    /// bytes, and the clone is a real independent file, so deleting the user's
    /// original still leaves the store's copy readable.
    static func copy(_ source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try fileManager.copyItem(at: source, to: destination)
    }
}
