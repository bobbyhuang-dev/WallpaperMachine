import CryptoKit
import Foundation

protocol AppUpdateClient: Sendable {
    func fetchLatestRelease() async throws -> GitHubRelease
    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws
}

struct DisabledAppUpdateClient: AppUpdateClient {
    func fetchLatestRelease() async throws -> GitHubRelease {
        throw AppUpdateIssue(code: .configuration, detail: String(localized: "The GitHub Release update metadata is unavailable."))
    }

    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws {
        throw AppUpdateIssue(code: .configuration, detail: String(localized: "No update is available to download."))
    }
}

struct GitHubReleaseClient: AppUpdateClient {
    private let session: URLSession
    private let latestURL: URL

    init(session: URLSession = GitHubReleaseClient.makeSession(),
         latestURL: URL = AppUpdateConfiguration.latestReleaseURL) {
        self.session = session
        self.latestURL = latestURL
    }

    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestURL)
        request.setValue("MacWallpaperEngine", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppUpdateIssue(code: AppUpdateErrorClassifier.classify(error), detail: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw AppUpdateIssue(code: .configuration, detail: String(localized: "The GitHub Release update metadata is unavailable."))
            }
            throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
        }
        return try GitHubReleaseParser.decode(data)
    }

    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let transfer = GitHubReleaseDownload(source: asset.downloadURL, destination: destination,
                                             expectedSize: asset.size > 0 ? asset.size : nil,
                                             digest: asset.digest, progress: progress)
        try await transfer.start()
    }
}

/// Streams a GitHub Release asset to disk. Redirects stay on GitHub HTTPS hosts.
final class GitHubReleaseDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let allowedHosts: Set<String> = [
        "github.com", "api.github.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"
    ]

    private let source: URL
    private let destination: URL
    private let expectedSize: Int64?
    private let digest: String?
    private let progress: @Sendable (Int64, Int64, Int64) -> Void
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: Error?
    private var hasher = SHA256()
    private var lastProgressAt = ContinuousClock.now
    private var lastProgressBytes: Int64 = 0

    init(source: URL, destination: URL, expectedSize: Int64?, digest: String?,
         configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) {
        self.source = source
        self.destination = destination
        self.expectedSize = expectedSize
        self.digest = digest
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.progress = progress
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    guard Self.isAllowed(source) else {
                        throw AppUpdateIssue(code: .network, detail: String(localized: "The update download redirected outside GitHub."))
                    }
                    let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    self.continuation = continuation
                    configuration.httpCookieStorage = nil
                    configuration.httpShouldSetCookies = false
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.timeoutIntervalForRequest = 300
                    configuration.timeoutIntervalForResource = 1800
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    var request = URLRequest(url: source)
                    request.setValue("MacWallpaperEngine", forHTTPHeaderField: "User-Agent")
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    let task = session.dataTask(with: request)
                    lock.withLock {
                        self.task = task
                        task.resume()
                        if cancelled { task.cancel() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true; self.task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.isAllowed(url) else {
            failure = AppUpdateIssue(code: .network, detail: String(localized: "The update download redirected outside GitHub."))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = response.url, Self.isAllowed(url) else {
            failure = AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
            completionHandler(.cancel)
            return
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
        expected = expectedSize ?? length
        if let expected, expected > AppUpdateConfiguration.maximumDownloadBytes {
            failure = AppUpdateIssue(code: .verification, detail: String(localized: "The update archive exceeds the allowed size."))
            completionHandler(.cancel)
            return
        }
        lastProgressAt = .now
        lastProgressBytes = 0
        progress(0, expected ?? 0, 0)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= AppUpdateConfiguration.maximumDownloadBytes - received else {
            failure = AppUpdateIssue(code: .verification, detail: String(localized: "The update archive exceeds the allowed size."))
            dataTask.cancel()
            return
        }
        do {
            try file?.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(data.count)
            let elapsed = lastProgressAt.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            let rate: Int64
            if seconds >= 0.25 {
                rate = Int64(Double(received - lastProgressBytes) / max(seconds, 0.001))
                lastProgressAt = .now
                lastProgressBytes = received
            } else {
                rate = 0
            }
            progress(received, expected ?? 0, max(0, rate))
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try file?.close() } catch { if failure == nil { failure = error } }
        file = nil
        let wasCancelled = lock.withLock { self.task = nil; return cancelled }
        let completion = continuation
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if wasCancelled {
            completion?.resume(throwing: CancellationError())
            return
        }
        if let failure {
            completion?.resume(throwing: failure)
            return
        }
        if let error {
            let code: AppUpdateErrorCode = (error as? URLError)?.code == .timedOut ? .network : AppUpdateErrorClassifier.classify(error)
            completion?.resume(throwing: AppUpdateIssue(code: code, detail: error.localizedDescription))
            return
        }
        if received == 0 || expected.map({ $0 != received }) == true {
            completion?.resume(throwing: AppUpdateIssue(code: .verification, detail: String(localized: "The update download is empty or truncated.")))
            return
        }
        if let digest, let expectedHash = Self.parseSHA256Hex(digest) {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedHash else {
                completion?.resume(throwing: AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed.")))
                return
            }
        }
        completion?.resume()
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host, allowedHosts.contains(host.lowercased()) else { return false }
        return url.port == nil || url.port == 443
    }

    static func parseSHA256Hex(_ digest: String) -> String? {
        let value = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = value.lowercased().hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
        let normalized = hex.lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }
}
