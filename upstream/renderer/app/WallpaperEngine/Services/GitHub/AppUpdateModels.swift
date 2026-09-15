import Foundation

enum AppUpdateConfiguration {
    static let repository = "bobbyhuang-dev/mac-wallpaper-engine"
    static let bundleIdentifier = "app.mac-wallpaper-engine"
    static let applicationName = "MacWallpaperEngine.app"
    static let maximumDownloadBytes: Int64 = 1_073_741_824

    static var releasesURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }
}

enum AppUpdateErrorCode: String, Equatable, Sendable {
    case network, configuration, verification, permission, unknown
}

enum AppUpdateOperation: String, Equatable, Sendable {
    case check, download, install
}

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) && ($0 == "0" || !$0.hasPrefix("0")) }),
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var display: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct GitHubReleaseAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let size: Int64
    let digest: String?
    var isZip: Bool { name.lowercased().hasSuffix(".zip") }
    var isDiskImage: Bool { name.lowercased().hasSuffix(".dmg") }
}

struct GitHubRelease: Equatable, Sendable {
    let version: SemanticVersion
    let htmlURL: URL
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]
}

enum AppUpdateState: Equatable, Sendable {
    case unsupported(currentVersion: String)
    case idle(currentVersion: String)
    case checking(currentVersion: String)
    case upToDate(currentVersion: String)
    case available(currentVersion: String, availableVersion: String)
    case manual(currentVersion: String, availableVersion: String)
    case downloading(currentVersion: String, availableVersion: String, percent: Double, transferred: Int64, total: Int64, bytesPerSecond: Int64)
    case ready(currentVersion: String, availableVersion: String)
    case error(currentVersion: String, operation: AppUpdateOperation, code: AppUpdateErrorCode, availableVersion: String?)

    var currentVersion: String {
        switch self {
        case .unsupported(let version), .idle(let version), .checking(let version), .upToDate(let version),
             .available(let version, _), .manual(let version, _), .downloading(let version, _, _, _, _, _),
             .ready(let version, _), .error(let version, _, _, _):
            return version
        }
    }

    var availableVersion: String? {
        switch self {
        case .available(_, let version), .manual(_, let version), .downloading(_, let version, _, _, _, _),
             .ready(_, let version):
            return version
        case .error(_, _, _, let version):
            return version
        case .unsupported, .idle, .checking, .upToDate:
            return nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading: true
        default: false
        }
    }
}

struct AppUpdateIssue: Error, Equatable {
    let code: AppUpdateErrorCode
    let detail: String
}

enum AppUpdateProgress {
    static func clamped(transferred: Int64, total: Int64, rate: Int64) -> (percent: Double, transferred: Int64, total: Int64, rate: Int64) {
        let boundedTotal = max(0, total)
        let boundedTransferred = boundedTotal > 0 ? min(max(0, transferred), boundedTotal) : max(0, transferred)
        let rawPercent = boundedTotal > 0 ? Double(boundedTransferred) / Double(boundedTotal) * 100 : 0
        let percent = (min(100, max(0, rawPercent)) * 10).rounded() / 10
        return (percent, boundedTransferred, boundedTotal, max(0, rate))
    }
}

enum AppUpdateErrorClassifier {
    static func classify(_ error: Error) -> AppUpdateErrorCode {
        if let issue = error as? AppUpdateIssue { return issue.code }
        if error is CancellationError { return .unknown }
        let message = error.localizedDescription
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .unknown
            case .userAuthenticationRequired, .noPermissionsToReadFile: return .permission
            default: return .network
            }
        }
        if posixPermission(error) { return .permission }
        if message.range(of: #"sha-?256|sha-?512|checksum|digest|signature|could not be verified|zip|archive"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .verification
        }
        if message.range(of: #"eacces|eperm|permission|not permitted|access denied"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .permission
        }
        if message.range(of: #"release metadata|no published|feed url|configuration unavailable|no downloadable"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .configuration
        }
        if message.range(of: #"enotfound|econn|etimedout|network|net::|socket|timeout|http(?:s)? request|status code"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .network
        }
        return .unknown
    }

    private static func posixPermission(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return false }
        return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
    }
}

enum GitHubReleaseParser {
    static func decode(_ data: Data) throws -> GitHubRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AppUpdateIssue(code: .configuration, detail: String(localized: "GitHub did not return a successful update response."))
        }
        guard !payload.prerelease,
              let version = SemanticVersion(payload.tagName),
              let htmlURL = URL(string: payload.htmlURL)
        else {
            throw AppUpdateIssue(code: .configuration, detail: String(localized: "GitHub did not return a successful update response."))
        }
        let assets = payload.assets.compactMap { asset -> GitHubReleaseAsset? in
            guard let url = URL(string: asset.browserDownloadURL) else { return nil }
            return GitHubReleaseAsset(name: asset.name, downloadURL: url, size: asset.size, digest: asset.digest)
        }
        return GitHubRelease(version: version, htmlURL: htmlURL, prerelease: payload.prerelease, assets: assets)
    }

    static func selectAsset(from release: GitHubRelease) -> GitHubReleaseAsset? {
        let candidates = release.assets.filter { asset in
            let name = asset.name.lowercased()
            guard asset.isZip || asset.isDiskImage else { return false }
            if name.contains("blockmap") || name.contains(".yml") { return false }
            return name.contains("macwallpaperengine") || name.contains("mac-wallpaper-engine")
        }
        return candidates.first { $0.isZip && $0.name.lowercased().contains("arm64") }
            ?? candidates.first { $0.isZip }
            ?? candidates.first { $0.isDiskImage }
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case prerelease, assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            let size: Int64
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}
