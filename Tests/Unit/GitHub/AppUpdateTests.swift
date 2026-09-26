import XCTest
@testable import WallpaperMachine

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

    func testParserReadsStableReleaseAndPrefersTheArm64DiskImage() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("latest-mac.yml", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/latest-mac.yml", 100, nil),
                ("WallpaperMachine-1.2.3-arm64.zip", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.zip", 150, nil),
                ("WallpaperMachine-1.2.3.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3.dmg", 200, nil),
                ("WallpaperMachine-1.2.3-arm64.dmg.sha256", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.dmg.sha256", 90, nil),
                ("WallpaperMachine-1.2.3-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.dmg", 300, "sha256:" + String(repeating: "ab", count: 32))
            ]
        ))
        XCTAssertEqual(release.version.display, "1.2.3")
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.name, "WallpaperMachine-1.2.3-arm64.dmg")
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.digest, "sha256:" + String(repeating: "ab", count: 32))
    }

    func testParserFallsBackToAnArm64DiskImageThenAnyProductDiskImage() throws {
        let renamed = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("WallpaperMachine-1.2.3.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/plain.dmg", 200, nil),
                ("WallpaperMachine-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/arm64.dmg", 300, nil)
            ]
        ))
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: renamed)?.name, "WallpaperMachine-arm64.dmg")

        let plain = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("Other-1.2.3-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/other.dmg", 100, nil),
                ("WallpaperMachine-1.2.3.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/plain.dmg", 200, nil)
            ]
        ))
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: plain)?.name, "WallpaperMachine-1.2.3.dmg")
    }

    func testZipOnlyReleaseIsLeftToAManualDownload() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [("WallpaperMachine-1.2.3-arm64.zip", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.zip", 300, nil)]
        ))
        XCTAssertNil(GitHubReleaseParser.selectAsset(from: release))
    }

    func testParserRejectsPrereleaseAndMissingVersion() {
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "v1.2.3", prerelease: true)))
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Data("<html>rate limited</html>".utf8)))
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "nightly")))
    }

    func testMissingAppArchiveBecomesManualFallback() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [("notes.txt", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/notes.txt", 12, nil)]
        ))
        XCTAssertNil(GitHubReleaseParser.selectAsset(from: release))
    }

    func testPublishedArchiveNameIsTheOneTheBuildUploads() {
        // scripts/package.py writes this name and .github/workflows/build.yml refuses
        // to publish anything else. Renaming one side without the others silently
        // drops every user back to a manual download.
        XCTAssertEqual(AppUpdateConfiguration.assetName(for: SemanticVersion("1.2.3")!),
                       "WallpaperMachine-1.2.3-arm64.dmg")
    }

    func testParserPrefersTheArchiveNamedForThisVersion() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("WallpaperMachine-1.2.2-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/old.dmg", 100, nil),
                ("WallpaperMachine-1.2.3-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/new.dmg", 300, nil)
            ]
        ))
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.name, "WallpaperMachine-1.2.3-arm64.dmg")
    }

    func testChecksumSidecarIsNeverDownloadedAsAnUpdate() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [("WallpaperMachine-1.2.3-arm64.dmg.sha256", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/sum", 90, nil)]
        ))
        XCTAssertNil(GitHubReleaseParser.selectAsset(from: release))
    }

    func testReleaseNotesReadTheSectionsAndStopAtTheInstallFooter() throws {
        let body = """
        ### New

        - **panel** — Add a filter rail ([`aaa1111`](https://github.com/o/r/commit/aaa1111))

        ### Fixed

        - **scene** — Stop a crash ([`bbb2222`](https://github.com/o/r/commit/bbb2222))

        Plus 3 documentation, test and tooling commits.

        **Full changelog**: https://github.com/o/r/compare/v1.2.2...v1.2.3

        \(ReleaseNotes.boundary)

        ### Install

        1. Open `WallpaperMachine-1.2.3-arm64.dmg` and drag WallpaperMachine to Applications.
        """
        let notes = try XCTUnwrap(ReleaseNotes(version: "1.2.3", body: body))
        XCTAssertEqual(notes.sections.map(\.title), ["New", "Fixed", ""])
        XCTAssertEqual(notes.sections[0].items, ["panel — Add a filter rail"])
        XCTAssertEqual(notes.sections[1].items, ["scene — Stop a crash"])
        XCTAssertEqual(notes.sections[2].items, ["Plus 3 documentation, test and tooling commits."])
    }

    func testAReleaseWithNothingToSayHasNoNotes() {
        XCTAssertNil(ReleaseNotes(version: "1.2.3", body: ""))
        XCTAssertNil(ReleaseNotes(version: "1.2.3",
                                  body: "**Full changelog**: https://github.com/o/r/compare/v1.2.2...v1.2.3"))
    }

    func testCheckPublishesWhatTheNewestReleaseChanged() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0", notes: "### Fixed\n\n- **scene** — Stop a crash\n")
        await fixture.store.checkForUpdates()
        XCTAssertEqual(fixture.store.releaseNotes?.version, "1.1.0")
        XCTAssertEqual(fixture.store.releaseNotes?.sections.first?.items, ["scene — Stop a crash"])
    }

    func testDownloadHostAllowlistAndDigestParsing() {
        XCTAssertTrue(GitHubReleaseDownload.isAllowed(URL(string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1/app.dmg")!))
        XCTAssertTrue(GitHubReleaseDownload.isAllowed(URL(string: "https://objects.githubusercontent.com/github-production-release-asset/1")!))
        XCTAssertFalse(GitHubReleaseDownload.isAllowed(URL(string: "http://github.com/file")!))
        XCTAssertFalse(GitHubReleaseDownload.isAllowed(URL(string: "https://evil.example/file")!))
        XCTAssertEqual(GitHubReleaseDownload.parseSHA256Hex("SHA256:" + String(repeating: "AA", count: 32)), String(repeating: "aa", count: 32))
        XCTAssertNil(GitHubReleaseDownload.parseSHA256Hex("sha256:deadbeef"))
    }

    func testInstallableLocationsAreApplicationsFolders() {
        XCTAssertTrue(AppUpdateInstaller.isInstallableLocation(URL(fileURLWithPath: "/Applications/WallpaperMachine.app")))
        XCTAssertTrue(AppUpdateInstaller.isInstallableLocation(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WallpaperMachine.app")))
        XCTAssertFalse(AppUpdateInstaller.isInstallableLocation(URL(fileURLWithPath: "/tmp/WallpaperMachine.app")))
    }

    func testInstallerAcceptsOnlyThisAppsBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-validate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("WallpaperMachine.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.wallpapermachine"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/WallpaperMachine"))
        XCTAssertEqual(try AppUpdateInstaller.findApplication(in: root).path, app.path)
        try AppUpdateInstaller.validate(app)

        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try AppUpdateInstaller.validate(app))
    }

    func testInstallerCopiesTheAppOutOfTheDiskImageAndDetachesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-dmg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Self.makeDiskImage(in: root, bundleIdentifier: "app.wallpapermachine")
        defer { Self.forceDetach(image) }

        let app = try AppUpdateInstaller().prepareInstallation(archive: image)
        let work = app.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: work) }
        XCTAssertEqual(app.lastPathComponent, "WallpaperMachine.app")
        XCTAssertFalse(app.path.hasPrefix(work.appendingPathComponent("mount").path + "/"))
        XCTAssertFalse(app.path.hasPrefix("/Volumes/"))
        XCTAssertNoThrow(try AppUpdateInstaller.validate(app))
        XCTAssertEqual(try Self.attachedDevices(of: image), [])
    }

    func testInstallerRejectsAForeignAppInTheDiskImageAndDetachesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-dmg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Self.makeDiskImage(in: root, bundleIdentifier: "com.example.other")
        defer { Self.forceDetach(image) }

        XCTAssertThrowsError(try AppUpdateInstaller().prepareInstallation(archive: image)) { error in
            XCTAssertEqual((error as? AppUpdateIssue)?.code, .verification)
        }
        XCTAssertEqual(try Self.attachedDevices(of: image), [])
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
        current.client.release = current.release(version: "0.9.0")
        await expect(current.store.checkForUpdates(), equals: .upToDate(currentVersion: "1.0.0"))

        let notes = Fixture()
        notes.client.release = notes.release(version: "1.2.0", assets: [])
        await expect(notes.store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.2.0"))
        await expect(notes.store.downloadUpdate(), equals: .error(currentVersion: "1.0.0", operation: .download, code: .configuration, availableVersion: nil))
        XCTAssertEqual(notes.client.downloadCalls, 0)
    }

    func testMissingLatestReleaseIsNormalAndDoesNotKeepAnOldUpdate() async {
        let http = UpdateHTTPFixture()
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(
            tag: "v1.1.0", body: "### Fixed\n\n- A fixture update",
            assets: [("WallpaperMachine-1.1.0-arm64.dmg", "https://github.com/o/r/update.dmg", 100, nil)])))
        await expect(store.checkForUpdates(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertNotNil(store.releaseNotes)

        http.respond(latest: .init(status: 404, body: Data()))
        let empty = await store.checkForUpdates()
        let snapshot = WebPanelController.update(empty)
        XCTAssertEqual(snapshot["status"] as? String, "noRelease")
        XCTAssertEqual(snapshot["action"] as? String, "checkForUpdates")
        XCTAssertEqual(snapshot["showsReleases"] as? Bool, false)
        XCTAssertNil(empty.availableVersion)
        XCTAssertNil(store.releaseNotes)
        XCTAssertFalse(empty.isBusy)

        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.2.0")))
        await expect(store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.2.0"))
    }

    func testMissingRepositoryIsNotReportedAsNoUpdate() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 404, body: Data()), repository: .init(status: 404, body: Data()))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .configuration, availableVersion: nil))
    }

    func testRepositoryLookupFailureRemainsANetworkError() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 404, body: Data()), repository: .init(status: 0, body: Data(), error: .timedOut))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .network, availableVersion: nil))
    }

    func testMalformedRepositoryMetadataIsNotReportedAsNoUpdate() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 404, body: Data()), repository: .init(status: 200, body: Data(#"{"message":"unexpected response"}"#.utf8)))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .configuration, availableVersion: nil))
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

    func testDownloadOpensTheDiskImageOnlyWhenItCannotInstallInPlace() async {
        let elsewhere = Fixture()
        elsewhere.installer.canInstallInPlace = false
        elsewhere.client.release = elsewhere.release(version: "1.1.0")
        await elsewhere.store.checkForUpdates()
        await expect(elsewhere.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(elsewhere.opened, [elsewhere.destination])
        XCTAssertTrue(elsewhere.revealed.isEmpty)

        let inPlace = Fixture()
        inPlace.client.release = inPlace.release(version: "1.1.0")
        await inPlace.store.checkForUpdates()
        await expect(inPlace.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertTrue(inPlace.opened.isEmpty)
        XCTAssertTrue(inPlace.revealed.isEmpty)

        inPlace.store.revealDownloadedUpdate()
        XCTAssertEqual(inPlace.revealed, [inPlace.destination])
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
        fixture.client.fetchError = AppUpdateIssue(code: .verification, detail: "sha256 checksum mismatch at /private/update.dmg")
        await expect(fixture.store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .verification, availableVersion: nil))
        XCTAssertFalse("\(fixture.store.state)".contains("/private/update.dmg"))

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
    var opened: [URL] { recorder.opened }
    var terminateCalls: Int { recorder.terminateCalls }
    let destination: URL

    init(installTimeout: Duration = .seconds(45)) {
        destination = FileManager.default.temporaryDirectory.appendingPathComponent("private/mwe-\(UUID().uuidString).dmg")
        let recorder = recorder
        let workspace = AppUpdateWorkspace(
            archiveURL: { [destination] _, _ in destination },
            reveal: { url in recorder.revealed.append(url) },
            open: { url in recorder.opened.append(url) }
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

    func release(version: String, assets: [GitHubReleaseAsset]? = nil, notes: String = "") -> GitHubRelease {
        let defaultAssets = [
            GitHubReleaseAsset(
                name: "WallpaperMachine-\(version)-arm64.dmg",
                downloadURL: URL(string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v\(version)/WallpaperMachine-\(version)-arm64.dmg")!,
                size: 1_000,
                digest: nil
            )
        ]
        return GitHubRelease(
            version: SemanticVersion(version)!,
            htmlURL: URL(string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/tag/v\(version)")!,
            prerelease: false,
            assets: assets ?? defaultAssets,
            notes: notes
        )
    }
}

private final class Recorder: @unchecked Sendable {
    var scheduled: [() -> Void] = []
    var revealed: [URL] = []
    var opened: [URL] = []
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

    func fetchLatestRelease() async throws -> GitHubRelease? {
        fetchCalls += 1
        if let fetchGate { await fetchGate.wait() }
        if let fetchError { throw fetchError }
        return release
    }

    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws {
        downloadCalls += 1
        if let downloadError { throw downloadError }
        for event in progressEvents { progress(event.0, event.1, event.2) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dmg".utf8).write(to: destination)
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

private final class UpdateHTTPFixture {
    let host = "update-\(UUID().uuidString).invalid"
    let session: URLSession
    let client: GitHubReleaseClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHTTPProtocol.self]
        session = GitHubReleaseClient.makeSession(configuration: configuration)
        client = GitHubReleaseClient(session: session, latestURL: URL(string: "https://\(host)/repos/fixture/app/releases/latest")!)
    }

    func respond(latest: UpdateHTTPProtocol.Response,
                 repository: UpdateHTTPProtocol.Response = .init(status: 200, body: Data(#"{"id":1}"#.utf8))) {
        UpdateHTTPProtocol.register(host, latest: latest, repository: repository)
    }

    deinit {
        session.invalidateAndCancel()
        UpdateHTTPProtocol.remove(host)
    }
}

private final class UpdateHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let body: Data
        var error: URLError.Code? = nil
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (latest: Response, repository: Response)] = [:]
    static func register(_ host: String, latest: Response, repository: Response) {
        lock.withLock { responses[host] = (latest, repository) }
    }
    static func remove(_ host: String) { _ = lock.withLock { responses.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let entry = Self.lock.withLock({ Self.responses[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response: Response
        if url.path == "/repos/fixture/app/releases/latest" { response = entry.latest }
        else if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "repos/fixture/app" { response = entry.repository }
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension AppUpdateTests {
    static func releaseJSON(tag: String, prerelease: Bool = false, body: String = "",
                            assets: [(String, String, Int, String?)] = []) -> Data {
        let assetObjects: [[String: Any]] = assets.map { name, url, size, digest in
            var fields: [String: Any] = ["name": name, "browser_download_url": url, "size": size]
            if let digest { fields["digest"] = digest }
            return fields
        }
        let payload: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/tag/\(tag)",
            "prerelease": prerelease,
            "body": body,
            "assets": assetObjects,
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// A compressed HFS+ image shaped like the release: the app plus an `Applications` link.
    static func makeDiskImage(in root: URL, bundleIdentifier: String) throws -> URL {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let app = source.appendingPathComponent("WallpaperMachine.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleIdentifier], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/WallpaperMachine")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        let image = root.appendingPathComponent("WallpaperMachine-1.2.3-arm64.dmg")
        _ = try hdiutil(["create", "-srcfolder", source.path, "-volname", "WallpaperMachine 1.2.3",
                         "-fs", "HFS+", "-format", "UDZO", "-ov", image.path])
        return image
    }

    /// The devices `image` is attached as, according to `hdiutil info`; empty once detached.
    static func attachedDevices(of image: URL) throws -> [String] {
        let output = try hdiutil(["info", "-plist"])
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any])
        let wanted = image.resolvingSymlinksInPath().path
        let images = info["images"] as? [[String: Any]] ?? []
        return images.compactMap { entry in
            guard let path = entry["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted else { return nil }
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            return entities.compactMap { $0["dev-entry"] as? String }.min() ?? path
        }
    }

    /// Leaves nothing attached if an assertion failed before the installer detached.
    static func forceDetach(_ image: URL) {
        for device in (try? attachedDevices(of: image)) ?? [] where device.hasPrefix("/dev/") {
            _ = try? hdiutil(["detach", "-force", device])
        }
    }

    @discardableResult
    static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateIssue(code: .unknown, detail: "hdiutil \(arguments.first ?? "") exited \(process.terminationStatus)")
        }
        return data
    }
}
