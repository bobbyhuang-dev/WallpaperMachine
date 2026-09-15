import AppKit
import SwiftUI

struct LibrarySettingsSection: View {
    @Bindable var workshop: WorkshopStore
    @Environment(BridgeStore.self) private var bridge
    @State private var showAssetsSetup = false

    var body: some View {
        Section("Library & Steam") {
            LabeledContent("Wallpaper library") {
                Button("Show in Finder") { NSWorkspace.shared.open(ClientPaths.libraryURL) }
            }
            Text("Imports are copied into MacWallpaperEngine. Your original files and Steam library are left untouched.")
                .font(.caption).foregroundStyle(.secondary)
            SteamCMDSetupView(setup: workshop.steamCMDSetup)
            LabeledContent("Scene assets") {
                Label(workshop.sceneAssetsReady ? "Ready" : "Not installed",
                      systemImage: workshop.sceneAssetsReady ? "checkmark.circle.fill" : "exclamationmark.circle")
            }
            HStack {
                Button("Locate assets…") {
                    if ClientPaths.selectAssetsFolder() { workshop.refreshSceneAssetsReadiness() }
                }.disabled(workshop.downloader.download(for: nil)?.isPending == true || workshop.steamCMDSetup.isBusy)
                Button(workshop.downloader.download(for: nil)?.isPending == true ? "View scene assets download…" : "Install scene assets…") { showAssetsSetup = true }
                    .disabled(workshop.steamCMDSetup.isBusy)
            }
            Text(ClientPaths.assetsURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Scene wallpapers need shared resources in addition to the Workshop download. Install them once through Steam or choose your purchased installation’s assets folder. Videos do not require it. Scene support is experimental; some effects and scripts may differ from Windows.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Wallpaper Engine on Steam", destination: URL(string: "https://store.steampowered.com/app/431960/Wallpaper_Engine/")!)
        }
        .onAppear { workshop.refreshSceneAssetsReadiness() }
        .sheet(isPresented: $showAssetsSetup, onDismiss: { workshop.refreshSceneAssetsReadiness() }) {
            SceneAssetsSetupView(workshop: workshop).environment(bridge)
        }
    }

}
