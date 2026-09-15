import SwiftUI

struct WallpaperInspectorView: View {
    @Environment(BridgeStore.self) private var store
    @Environment(WorkshopStore.self) private var workshop
    @EnvironmentObject private var navigation: ControlPanelNavigation
    @State private var showSceneAssetsSetup = false
    @State private var loadingWallpaperID: String?
    @State private var errorWallpaperID: String?
    @State private var errorMessage: String?

    private var selectedWallpaper: BridgeWallpaperEntry? {
        guard let id = store.appSnapshot.selectedWallpaperId else { return nil }
        return store.librarySnapshot.wallpapers.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let wallpaper = selectedWallpaper {
                    identity(wallpaper)
                    Divider()
                }

                WallpaperTargetPicker()

                if let wallpaper = selectedWallpaper {
                    playbackStatus(wallpaper)
                    readiness(wallpaper)
                    Divider()

                    if let errorMessage, errorWallpaperID == wallpaper.id {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let options = store.wallpaperOptionsSnapshot, options.wallpaperId == wallpaper.id {
                        WallpaperOptionsEditorView(
                            options: options,
                            displayIdFilter: navigation.targetDisplayID,
                            displayRowsAreCollapsible: false,
                            showsTitle: false,
                            scrollsContent: false,
                            onError: { presentError($0, wallpaperID: wallpaper.id) },
                            onApply: { _ in
                                if errorWallpaperID == wallpaper.id { errorMessage = nil }
                            }
                        )
                        .disabled(store.activatingWallpaperID != nil || !options.supported)
                    } else if loadingWallpaperID == wallpaper.id || store.activatingWallpaperID == wallpaper.id {
                        ProgressView("Loading wallpaper settings…").controlSize(.small)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wallpaper settings are unavailable.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Retry") { loadOptions(wallpaper) }
                                .disabled(loadingWallpaperID != nil || store.activatingWallpaperID != nil)
                        }
                    }
                } else {
                    Divider()
                    ControlPanelEmptyState("Select a wallpaper", systemImage: "sidebar.right",
                        description: Text("Click a wallpaper to apply it to the selected display and show its settings. Use Select & Customize in its context menu to inspect without applying.")) {}
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
        }
        .onAppear { workshop.refreshSceneAssetsReadiness() }
        .sheet(isPresented: $showSceneAssetsSetup, onDismiss: workshop.refreshSceneAssetsReadiness) {
            SceneAssetsSetupView(workshop: workshop)
                .environment(store)
                .environment(workshop)
                .environmentObject(navigation)
        }
    }

    private func identity(_ wallpaper: BridgeWallpaperEntry) -> some View {
        let kind = WallpaperKindFilter(kind: wallpaper.kind)
        return VStack(alignment: .leading, spacing: 8) {
            WallpaperPreviewView(wallpaper: wallpaper)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(kind.kindTitle, systemImage: kind.systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func playbackStatus(_ wallpaper: BridgeWallpaperEntry) -> some View {
        if store.isWallpaperActive(id: wallpaper.id, displayId: navigation.targetDisplayID) {
            Label("Active on selected display", systemImage: "display.badge.checkmark")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if wallpaper.active {
            Label("Active on another display", systemImage: "display.2")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Not active", systemImage: "stop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func readiness(_ wallpaper: BridgeWallpaperEntry) -> some View {
        if !wallpaper.supported {
            VStack(alignment: .leading, spacing: 8) {
                Label("Not playable", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                Text(wallpaper.kind == .webpage
                    ? String(localized: "Web projects can be saved to your library, but this renderer cannot play them.")
                    : String(localized: "This wallpaper type cannot be played on macOS. You can still inspect or remove it from your library."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if wallpaper.kind == .projectScene {
            if workshop.sceneAssetsReady {
                Label("Scene assets are ready", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Shared scene assets required", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    Text("Scene wallpapers need Wallpaper Engine’s shared shaders and materials before they can play.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Scene Assets…") { showSceneAssetsSetup = true }
                        .disabled(store.activatingWallpaperID != nil)
                }
            }
        }
    }

    private func loadOptions(_ wallpaper: BridgeWallpaperEntry) {
        guard loadingWallpaperID == nil, store.activatingWallpaperID == nil else { return }
        loadingWallpaperID = wallpaper.id
        let errorRevision = store.latestBridgeErrorRevision
        Task {
            defer { loadingWallpaperID = nil }
            do {
                try await store.selectWallpaperAsync(id: wallpaper.id)
                if errorWallpaperID == wallpaper.id { errorMessage = nil }
            } catch {
                if store.latestBridgeErrorRevision == errorRevision { presentError(error, wallpaperID: wallpaper.id) }
            }
        }
    }

    private func presentError(_ error: Error, wallpaperID: String) {
        errorWallpaperID = wallpaperID
        errorMessage = error.localizedDescription
    }
}

