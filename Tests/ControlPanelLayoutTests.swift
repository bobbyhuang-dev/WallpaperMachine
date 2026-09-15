import AppKit
import SwiftUI
import XCTest
@testable import MacWallpaperEngine

@MainActor
final class ControlPanelLayoutTests: XCTestCase {
    func testControlPanelAcceptsSmallWindowProposalsWithLongDisplayTitle() async throws {
        let fixture = makeStore()
        fixture.bridge.snapshot = BridgeSnapshotBundle(
            app: fixture.store.appSnapshot, library: fixture.store.librarySnapshot,
            wallpaperOptions: nil, monitorInformation: fixture.store.monitorInformationSnapshot,
            settings: fixture.store.settingsSnapshot
        )
        try await fixture.store.refreshAllAsync()
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: session) }
        let defaultsName = "ControlPanelLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let workshop = WorkshopStore(downloader: WorkshopDownloadManager(sessionDirectory: session),
                                     supportDirectory: session, defaults: defaults)
        let updater = AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient())

        for language in ["en", "zh-Hans"] {
            let controller = NSHostingController(rootView:
                ControlPanelView(store: fixture.store, navigation: ControlPanelNavigation(), workshop: workshop, updater: updater)
                    .environment(\.locale, Locale(identifier: language))
                    .defaultAppStorage(defaults)
            )
            controller.sizingOptions = []
            for size in [NSSize(width: 760, height: 560), NSSize(width: 960, height: 640), NSSize(width: 1240, height: 800)] {
                controller.view.setFrameSize(size)
                controller.view.layoutSubtreeIfNeeded()
                let measured = controller.sizeThatFits(in: size)
                XCTAssertEqual(measured.width, size.width, accuracy: 1, "\(language): the root must accept the window width")
                XCTAssertLessThanOrEqual(measured.height, size.height + 1, "\(language): content must not force a taller window")
                XCTAssertNil(controller.view.window, "Layout measurement must stay offscreen")
            }
        }
    }

    func testDisplayMenuDoesNotAdoptLongestChoiceAsItsMinimumWidth() {
        let fixture = makeStore()
        let controller = NSHostingController(rootView:
            WallpaperTargetPicker()
                .environment(fixture.store)
                .environmentObject(ControlPanelNavigation())
        )
        let measured = controller.sizeThatFits(in: NSSize(width: 256, height: 1000))
        XCTAssertLessThanOrEqual(measured.width, 257, "Display names belong in the menu, not in the inspector's minimum width")
        XCTAssertNil(controller.view.window)
    }

    func testInspectorEmptyCopyReflowsAtNarrowWidthsInBothLanguages() {
        for language in ["en", "zh-Hans"] {
            let controller = NSHostingController(rootView:
                ControlPanelEmptyState("Select a wallpaper", systemImage: "sidebar.right",
                    description: Text("Click a wallpaper to apply it to the selected display and show its settings. Use Select & Customize in its context menu to inspect without applying.")) {}
                    .environment(\.locale, Locale(identifier: language))
            )
            let narrow = controller.sizeThatFits(in: NSSize(width: 256, height: 1000))
            let wide = controller.sizeThatFits(in: NSSize(width: 396, height: 1000))
            XCTAssertLessThanOrEqual(narrow.width, 257)
            XCTAssertGreaterThan(narrow.height, wide.height, "\(language): narrow empty-state copy must wrap rather than overflow or disappear")
            XCTAssertNil(controller.view.window)
        }
    }

    func testDownloadDetailsSheetCarriesTheEnvironmentItsContentReads() async throws {
        // The activity bar sends people here to finish Steam Guard. Sheet content does not inherit
        // the environment applied inside ControlPanelView, and WorkshopDetailView resolves
        // BridgeStore and ControlPanelNavigation before its body runs, so an uninjected copy traps.
        let fixture = makeStore()
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: session) }
        let defaultsName = "ControlPanelLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = WorkshopDownloadManager(sessionDirectory: session, runtimeProvider: UnavailableRuntime())
        let workshop = WorkshopStore(downloader: manager, supportDirectory: session, defaults: defaults)
        let item = WorkshopItem(id: "3770867059", title: "Steam Guard", creator: "Test", summary: "",
                                previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
        manager.start(item: item, username: "tester", executable: session.appendingPathComponent("steamcmd"),
                      library: session, rememberSession: false, onImported: {})
        let download = try XCTUnwrap(manager.downloads.first)
        workshop.showDownload(download)
        XCTAssertTrue(workshop.showsDownloadDetails, "The activity bar opens this sheet for Steam Guard")
        XCTAssertNotNil(workshop.selectedDownload?.item, "The sheet must reach the per-item detail view")

        let controller = NSHostingController(rootView:
            ControlPanelView.downloadDetails(store: fixture.store, workshop: workshop,
                                             navigation: ControlPanelNavigation())
                .defaultAppStorage(defaults)
        )
        controller.sizingOptions = []
        controller.view.setFrameSize(NSSize(width: 700, height: 560))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.view.subviews.count, 0, "The sheet content must render")
        XCTAssertNil(controller.view.window, "Rendering the sheet content must stay offscreen")
        manager.cancel(download)
    }

    private func makeStore() -> (store: BridgeStore, bridge: LayoutSnapshotBridge) {
        let bridge = LayoutSnapshotBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        store.settingsSnapshot.displays = [BridgeDisplaySettingsRow(
            displayId: "primary",
            title: String(repeating: "Studio Display — 外接显示器 with a very long display name · ", count: 8),
            enabled: true, mode: .standalone, mirrorTargets: [], selectedMirrorTarget: nil,
            scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60, muted: false, volume: 1
        )]
        return (store, bridge)
    }
}

private final class LayoutSnapshotBridge: WallpaperBridge {
    var snapshot: BridgeSnapshotBundle?

    override func allSnapshots() async throws -> BridgeSnapshotBundle {
        guard let snapshot else { throw CancellationError() }
        return snapshot
    }
}

private struct UnavailableRuntime: SteamCMDRuntimeProviding {
    func resolve(executable: URL) throws -> SteamCMDRuntime { throw WorkshopFailure(message: "fixture") }
    func validateBootstrap(at root: URL) async throws { throw WorkshopFailure(message: "fixture") }
    func prepare(executable: URL, staging: URL) async throws -> URL { throw WorkshopFailure(message: "fixture") }
    func validate(at root: URL) async throws { throw WorkshopFailure(message: "fixture") }
}
