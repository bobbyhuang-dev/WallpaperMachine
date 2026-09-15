import AppKit
import SwiftUI

struct LibrarySettingsSection: View {
    @Bindable var workshop: WorkshopStore
    @Environment(BridgeStore.self) private var bridge
    @State private var showAssetsSetup = false
    @State private var assetsPath = ClientPaths.assetsURL.path
    @State private var steamcmdPath = ClientPaths.steamcmdURL?.path

    var body: some View {
        Section("Library & Steam") {
            LabeledContent("Wallpaper library") {
                Button("Show in Finder") { NSWorkspace.shared.open(ClientPaths.libraryURL) }
            }
            Text("Imports are copied into MacWallpaperEngine. Your original files and Steam library are left untouched.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("SteamCMD") {
                Label(steamcmdPath == nil ? "Not installed" : "Ready", systemImage: steamcmdPath == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(steamcmdPath == nil ? Color.orange : Color.green)
            }
            HStack {
                Text("Used to download wallpapers you own through Steam.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Locate…") { chooseSteamCMD() }
            }
            LabeledContent("Scene assets") {
                Label(ClientPaths.hasSceneAssets(at: URL(fileURLWithPath: assetsPath)) ? "Ready" : "Not installed",
                      systemImage: ClientPaths.hasSceneAssets(at: URL(fileURLWithPath: assetsPath)) ? "checkmark.circle.fill" : "exclamationmark.circle")
            }
            HStack {
                Button("Locate assets…") {
                    if ClientPaths.selectAssetsFolder() { assetsPath = ClientPaths.assetsURL.path }
                }.disabled(workshop.downloader.download(for: nil)?.isPending == true)
                Button(workshop.downloader.download(for: nil)?.isPending == true ? "View scene assets download…" : "Install scene assets…") { showAssetsSetup = true }
            }
            Text(assetsPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Scene wallpapers need shared resources in addition to the Workshop download. Install them once through Steam or choose your purchased installation’s assets folder. Videos do not require it. Scene support is experimental; some effects and scripts may differ from Windows.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Wallpaper Engine on Steam", destination: URL(string: "https://store.steampowered.com/app/431960/Wallpaper_Engine/")!)
        }
        .onAppear { assetsPath = ClientPaths.assetsURL.path }
        .sheet(isPresented: $showAssetsSetup, onDismiss: { assetsPath = ClientPaths.assetsURL.path }) {
            SceneAssetsSetupView(workshop: workshop).environment(bridge)
        }
    }

    private func chooseSteamCMD() {
        let panel = NSOpenPanel()
        panel.title = "Locate SteamCMD"
        panel.message = "Choose the steamcmd executable or steamcmd.sh script."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "Choose an executable file"
            alert.informativeText = "The selected file cannot be executed. Select the installed SteamCMD executable."
            alert.runModal()
            return
        }
        UserDefaults.standard.set(url.path, forKey: "MacWallpaperEngineSteamCMDPath")
        steamcmdPath = url.path
    }
}
