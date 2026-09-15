import XCTest
@testable import MacWallpaperEngine

@MainActor
final class AppUpdateTests: XCTestCase {
    func testSemanticVersionRejectsInvalidAndOrdersStableReleases() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.2"))
        XCTAssertNil(SemanticVersion("v1.2.3-beta"))
        XCTAssertNil(SemanticVersion("01.2.3"))
        XCTAssertEqual(SemanticVersion("v1.2.3")?.display, "1.2.3")
        XCTAssertLessThan(SemanticVersion("0.1.0")!, SemanticVersion("0.1.1")!)
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
        XCTAssertEqual(SemanticVersion("V2.0.0"), SemanticVersion("2.0.0"))
    }

    func testParserReadsStableReleaseAndPrefersArm64Zip() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("latest-mac.yml", "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/download/v1.2.3/latest-mac.yml", 100, nil),
                ("MacWallpaperEngine-1.2.3.dmg", "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/download/v1.2.3/MacWallpaperEngine-1.2.3.dmg", 200, nil),
                ("MacWallpaperEngine-1.2.3-arm64.zip", "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/download/v1.2.3/MacWallpaperEngine-1.2.3-arm64.zip", 300, "sha256:" + String(repeating: "ab", count: 32))
            ]
        ))
        XCTAssertEqual(release.version.display, "1.2.3")
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.name, "MacWallpaperEngine-1.2.3-arm64.zip")
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.digest, "sha256:" + String(repeating: "ab", count: 32))
    }

    func testParserRejectsPrereleaseAndMissingVersion() {
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "v1.2.3", prerelease: true)))
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Data("<html>rate limited</html>".utf8)))
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "nightly")))
    }

    func testMissingAppArchiveBecomesManualFallback() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [("notes.txt", "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/download/v1.2.3/notes.txt", 12, nil)]
        ))
        XCTAssertNil(GitHubReleaseParser.selectAsset(from: release))
    }

    func testDownloadHostAllowlistAndDigestParsing() {
        XCTAssertTrue(GitHubReleaseDownload.isAllowed(URL(string: "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/download/v1/app.zip")!))
        XCTAssertTrue(GitHubReleaseDownload.isAllowed(URL(string: "https://objects.githubusercontent.com/github-production-release-asset/1")!))
        XCTAssertFalse(GitHubReleaseDownload.isAllowed(URL(string: "http://github.com/file")!))
        XCTAssertFalse(GitHubReleaseDownload.isAllowed(URL(string: "https://evil.example/file")!))
        XCTAssertEqual(GitHubReleaseDownload.parseSHA256Hex("SHA256:" + String(repeating: "AA", count: 32)), String(repeating: "aa", count: 32))
        XCTAssertNil(GitHubReleaseDownload.parseSHA256Hex("sha256:deadbeef"))
    }

    func testInstallableLocationsAreApplicationsFolders() {
        XCTAssertTrue(AppUpdateInstaller.isInstallableLocation(URL(fileURLWithPath: "/Applications/MacWallpaperEngine.app")))
        XCTAssertTrue(AppUpdateInstaller.isInstallableLocation(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MacWallpaperEngine.app")))
        XCTAssertFalse(AppUpdateInstaller.isInstallableLocation(URL(fileURLWithPath: "/tmp/MacWallpaperEngine.app")))
    }

    func testInstallerAcceptsOnlyThisAppsBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-validate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("MacWallpaperEngine.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.mac-wallpaper-engine"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/MacWallpaperEngine"))
        XCTAssertEqual(try AppUpdateInstaller.findApplication(in: root).path, app.path)
        try AppUpdateInstaller.validate(app)

        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try AppUpdateInstaller.validate(app))
    }

    func testCheckFindsUpdateWithoutDownloading() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        await expect(fixture.store.checkForUpdates(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(fixture.client.downloadCalls, 0)
    }

    func testCheckReportsUpToDateAndManualRelease() async {
        let current = Fixture()
        current.client.release = current.release(version: "1.0.0")
        await expect(current.store.checkForUpdates(), equals: .upToDate(currentVersion: "1.0.0"))

        let notes = Fixture()
        notes.client.release = notes.release(version: "1.2.0", assets: [])
        await expect(notes.store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.2.0"))
        await expect(notes.store.downloadUpdate(), equals: .error(currentVersion: "1.0.0", operation: .download, code: .configuration, availableVersion: nil))
        XCTAssertEqual(notes.client.downloadCalls, 0)
    }

    func testConcurrentChecksShareOneRequestAndHideDownloadPaths() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.client.fetchGate = Gate()
        async let first = fixture.store.checkForUpdates()
        async let second = fixture.store.checkForUpdates()
        await fixture.client.fetchGate?.waitUntilEntered()
        XCTAssertEqual(fixture.client.fetchCalls, 1)
        fixture.client.fetchGate?.open()
        _ = await (first, second)
        XCTAssertEqual(fixture.store.state, .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))

        await fixture.store.downloadUpdate()
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertFalse("\(fixture.store.state)".contains("private"))
        XCTAssertTrue(fixture.revealed.isEmpty)
    }

    func testDownloadProgressIsClampedAndInstallRequiresReadyState() async {
        XCTAssertEqual(AppUpdateProgress.clamped(transferred: 1_500, total: 1_000, rate: 500).percent, 100)
        XCTAssertEqual(AppUpdateProgress.clamped(transferred: 1_500, total: 1_000, rate: 500).transferred, 1_000)
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.client.progressEvents = [(1_500, 1_000, 500)]
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.store.state, .error(currentVersion: "1.0.0", operation: .install, code: .configuration, availableVersion: nil))
        XCTAssertEqual(fixture.installer.installCalls, 0)

        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 1)
        fixture.scheduled[0]()
        XCTAssertEqual(fixture.installer.installCalls, 1)
        XCTAssertEqual(fixture.terminateCalls, 1)
    }

    func testErrorsAreClassifiedAndDownloadCanBeRetriedAfterCheck() async {
        let fixture = Fixture()
        fixture.client.fetchError = AppUpdateIssue(code: .verification, detail: "sha256 checksum mismatch at /private/update.zip")
        await expect(fixture.store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .verification, availableVersion: nil))
        XCTAssertFalse("\(fixture.store.state)".contains("/private/update.zip"))

        fixture.client.fetchError = nil
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.client.downloadError = URLError(.timedOut)
        await fixture.store.checkForUpdates()
        await expect(fixture.store.downloadUpdate(), equals: .error(currentVersion: "1.0.0", operation: .download, code: .network, availableVersion: nil))

        fixture.client.downloadError = nil
        await fixture.store.checkForUpdates()
        await expect(fixture.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
    }

    func testInstallFailureKeepsDownloadedUpdateForRetry() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.installer.installError = AppUpdateIssue(code: .permission, detail: "EACCES")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()
        XCTAssertEqual(fixture.store.state, .error(currentVersion: "1.0.0", operation: .install, code: .permission, availableVersion: "1.1.0"))

        fixture.installer.installError = nil
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 2)
        fixture.scheduled[1]()
        XCTAssertEqual(fixture.installer.installCalls, 1)
    }

    func testInstallWatchdogFailsIfTheAppNeverQuits() async {
        let fixture = Fixture(installTimeout: .milliseconds(20))
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.store.state, .error(currentVersion: "1.0.0", operation: .install, code: .unknown, availableVersion: "1.1.0"))
    }

    private func expect(_ state: AppUpdateState, equals expected: AppUpdateState) {
        XCTAssertEqual(state, expected)
    }
}

@MainActor
private final class Fixture {
    let client = FakeAppUpdateClient()
    let installer = FakeInstaller()
    let store: AppUpdateStore
    let recorder = Recorder()
    var scheduled: [() -> Void] { recorder.scheduled }
    var revealed: [URL] { recorder.revealed }
    var terminateCalls: Int { recorder.terminateCalls }
    let destination: URL

    init(installTimeout: Duration = .seconds(45)) {
        destination = FileManager.default.temporaryDirectory.appendingPathComponent("private/mwe-\(UUID().uuidString).zip")
        let recorder = recorder
        let workspace = AppUpdateWorkspace(
            archiveURL: { [destination] _, _ in destination },
            reveal: { url in recorder.revealed.append(url) },
            open: { _ in }
        )
        store = AppUpdateStore(
            currentVersion: "1.0.0",
            client: client,
            installer: installer,
            workspace: workspace,
            scheduleInstall: { work in recorder.scheduled.append(work) },
            terminate: { recorder.terminateCalls += 1 },
            installTimeout: installTimeout
        )
    }

    func release(version: String, assets: [GitHubReleaseAsset]? = nil) -> GitHubRelease {
        let defaultAssets = [
            GitHubReleaseAsset(
                name: "MacWallpaperEngine-\(version)-arm64.zip",
                downloadURL: URL(string: "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/download/v\(version)/MacWallpaperEngine-\(version)-arm64.zip")!,
                size: 1_000,
                digest: nil
            )
        ]
        return GitHubRelease(
            version: SemanticVersion(version)!,
            htmlURL: URL(string: "https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/tag/v\(version)")!,
            prerelease: false,
            assets: assets ?? defaultAssets
        )
    }
}

private final class Recorder: @unchecked Sendable {
    var scheduled: [() -> Void] = []
    var revealed: [URL] = []
    var terminateCalls = 0
}

private final class FakeAppUpdateClient: AppUpdateClient, @unchecked Sendable {
    var release: GitHubRelease?
    var fetchError: Error?
    var downloadError: Error?
    var fetchGate: Gate?
    var progressEvents: [(Int64, Int64, Int64)] = []
    var fetchCalls = 0
    var downloadCalls = 0

    func fetchLatestRelease() async throws -> GitHubRelease {
        fetchCalls += 1
        if let fetchGate { await fetchGate.wait() }
        if let fetchError { throw fetchError }
        guard let release else {
            throw AppUpdateIssue(code: .configuration, detail: "missing release")
        }
        return release
    }

    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws {
        downloadCalls += 1
        if let downloadError { throw downloadError }
        for event in progressEvents { progress(event.0, event.1, event.2) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: destination)
    }
}

private final class FakeInstaller: AppUpdateInstalling, @unchecked Sendable {
    var canInstallInPlace = true
    var installCalls = 0
    var installError: Error?

    func prepareInstallation(archive: URL) throws -> URL { archive }

    func install(extractedApp: URL, replacing destination: URL) throws {
        if let installError { throw installError }
        installCalls += 1
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            entered += 1
            let enteredWaiters = self.enteredWaiters
            self.enteredWaiters = []
            if opened {
                lock.unlock()
                enteredWaiters.forEach { $0.resume() }
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
                enteredWaiters.forEach { $0.resume() }
            }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

private extension AppUpdateTests {
    static func releaseJSON(tag: String, prerelease: Bool = false,
                            assets: [(String, String, Int, String?)] = []) -> Data {
        let assetJSON = assets.map { name, url, size, digest in
            var fields = """
            "name":"\(name)","browser_download_url":"\(url)","size":\(size)
            """
            if let digest {
                fields += ",\"digest\":\"\(digest)\""
            }
            return "{\(fields)}"
        }.joined(separator: ",")
        return Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/bobbyhuang-dev/mac-wallpaper-engine/releases/tag/\(tag)","prerelease":\(prerelease),"assets":[\(assetJSON)]}
        """.utf8)
    }
}
