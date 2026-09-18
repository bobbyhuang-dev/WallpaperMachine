import XCTest
@testable import MacWallpaperEngine

/// A wallpaper that refuses to render leaves the engine restoring its previous
/// configuration. The Library must stay usable so another wallpaper can be
/// applied without restarting the app.
@MainActor
final class WallpaperActivationRecoveryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent("Library/failing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A complete web project passes its preflight without decoding media or
        // needing scene assets; this test covers the apply failure, not validation.
        try Data(#"{"type":"web","title":"Failing","file":"index.html"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        try Data("<!doctype html><title>Failing</title>".utf8)
            .write(to: folder.appendingPathComponent("index.html"))
        setenv("MAC_WALLPAPER_ENGINE_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MAC_WALLPAPER_ENGINE_HOME")
        try FileManager.default.removeItem(at: home)
    }

    func testFailedApplyKeepsLibraryActionsAvailable() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))

        XCTAssertFalse(store.activationNeedsRefresh,
                       "A recovered apply failure must not lock the Library behind a manual refresh")
        XCTAssertNil(store.activatingWallpaperID)

        // The user must be able to pick another wallpaper right away.
        bridge.applyError = nil
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
    }

    func testUnrecoverableApplyFailureStillDemandsRefresh() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        bridge.snapshotsFail = true

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))

        XCTAssertTrue(store.activationNeedsRefresh,
                      "Without a trustworthy re-read the app must ask for a full refresh")
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private final class ApplyFailureBridge: WallpaperBridge {
    var applyError: Error? = WallpaperActionError(
        message: "The wallpaper did not render a first frame within 20 seconds.")
    var snapshotsFail = false

    override func allSnapshots() async throws -> BridgeSnapshotBundle {
        if snapshotsFail { throw CancellationError() }
        return bundle
    }

    override func selectWallpaper(id: String) async throws -> BridgeSnapshotBundle { bundle }

    override func setDisplayConfigEnabled(
        wallpaperId: String,
        displayId: String,
        enabled: Bool
    ) async throws -> BridgeWallpaperMutationBundle {
        mutation
    }

    override func wallpaperOptionsSnapshot(
        wallpaperId: String
    ) async throws -> BridgeWallpaperOptionsSnapshot {
        Self.options
    }

    override func applyWallpaperOptions(
        wallpaperId: String
    ) async throws -> BridgeWallpaperMutationBundle {
        if let applyError { throw applyError }
        active = true
        return mutation
    }

    /// Mirrors the engine: the wallpaper only becomes active once an apply succeeds.
    private var active = false

    var bundle: BridgeSnapshotBundle {
        BridgeSnapshotBundle(app: Self.app, library: Self.library, wallpaperOptions: Self.options,
                             monitorInformation: monitors, settings: Self.settings)
    }

    private var mutation: BridgeWallpaperMutationBundle {
        BridgeWallpaperMutationBundle(app: Self.app, library: Self.library,
                                      wallpaperOptions: Self.options,
                                      monitorInformation: monitors, settings: Self.settings)
    }

    private var monitors: BridgeMonitorInformationSnapshot {
        BridgeMonitorInformationSnapshot(rows: [BridgeMonitorInfoRow(
            displayId: "primary", title: "Primary",
            wallpaperId: active ? "failing" : "", wallpaperTitle: active ? "Failing" : "",
            mirrorTargetDisplayId: nil, mirrorTargetTitle: nil,
            scalingMode: "fill", targetFps: "30", audioResponse: false
        )])
    }

    private static let app = BridgeAppSnapshot(
        playbackState: .playing, selectedWallpaperId: "failing",
        activeWallpaperIds: [], errors: [])

    private static let library = BridgeLibrarySnapshot(
        wallpapers: [BridgeWallpaperEntry(id: "failing", title: "Failing", kind: .projectScene,
                                          supported: true, active: false, selected: true,
                                          previewPath: nil)],
        scanStatus: BridgeLibraryScanStatus(scanning: false, done: 1, total: 1),
        sceneCount: 1, videoCount: 0, webpageCount: 0, unknownCount: 0)

    private static let options = BridgeWallpaperOptionsSnapshot(
        wallpaperId: "failing", title: "Failing", kind: .projectScene, supported: true, dirty: false,
        properties: [],
        displayConfigurations: [BridgeDisplayConfigRow(
            displayId: "primary", title: "Primary", enabled: false, scalingMode: .fill,
            scalingFactor: 1, targetFps: 30, maxFps: 60, muted: false, volume: 1,
            dirty: false, canRestoreDefaults: false)],
        audioResponseEnabled: false, muted: false, volume: 1)

    private static let settings = BridgeSnapshotFixtures.settings(
        displays: [BridgeDisplaySettingsRow(
            displayId: "primary", title: "Primary", enabled: true, mode: .standalone,
            mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
            targetFps: 30, maxFps: 60, muted: false, volume: 1)])
}
