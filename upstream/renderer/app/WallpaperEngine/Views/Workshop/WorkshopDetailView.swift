import AppKit
import SwiftUI

struct WorkshopDetailView: View {
    let item: WorkshopItem
    @Bindable var workshop: WorkshopStore
    @Environment(BridgeStore.self) private var bridge
    @EnvironmentObject private var navigation: ControlPanelNavigation
    @State private var activationMessage: String?
    @State private var activationItemID: String?
    @State private var activationFailed = false
    @State private var showAssetsSetup = false
    private var downloader: WorkshopDownloader { workshop.downloader }
    private var isInstalled: Bool {
        bridge.librarySnapshot.wallpapers.contains { $0.id == item.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    WorkshopPreview(url: item.previewURL)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("By \(item.creator)").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Label("\(item.subscriptions.formatted()) subscribers", systemImage: "person.2")
                            if item.size > 0 { Label(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file), systemImage: "internaldrive") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Label(item.kind.compatibility, systemImage: item.kind == .application || item.kind == .web ? "exclamationmark.triangle" : "info.circle")
                        .font(.callout.weight(.medium)).foregroundStyle(item.kind == .application || item.kind == .web ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.kind == .scene {
                        Text("Scene support is experimental. Some effects, scripts, and audio features may differ from Windows. Shared scene assets are installed separately from Workshop wallpapers.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.summary.isEmpty {
                        Text(item.summary).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("View full description, creator, and requirements on Steam", destination: item.pageURL)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    if isInstalled {
                        Label("Available in your local library", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if let warning = downloader.sessionWarning {
                            Label(warning, systemImage: "exclamationmark.shield")
                                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if item.kind == .scene && !workshop.sceneAssetsReady {
                            Label("Scene assets still need setup", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text("The wallpaper download is complete. Install Wallpaper Engine’s shared resources once, or locate your purchased installation’s assets folder.").font(.callout).foregroundStyle(.secondary)
                            Button("Install scene assets…") { showAssetsSetup = true }.buttonStyle(.borderedProminent)
                        }
                        Button("Show in Library") {
                            let id = item.id
                            let revision = bridge.latestBridgeErrorRevision
                            Task {
                                do { try await navigation.revealWallpaper(id: id, store: bridge) }
                                catch {
                                    if revision == bridge.latestBridgeErrorRevision {
                                        activationItemID = id
                                        activationMessage = error.localizedDescription
                                        activationFailed = true
                                    }
                                }
                            }
                        }.disabled(bridge.activatingWallpaperID != nil || bridge.applyingWallpaperID != nil)
                        WallpaperTargetPicker()
                        Button {
                            let itemID = item.id
                            let targetID = navigation.targetDisplayID
                            let title = bridge.settingsSnapshot.displays.first { $0.displayId == targetID }?.title ?? targetID
                            let revision = bridge.latestBridgeErrorRevision
                            activationMessage = nil
                            Task {
                                do {
                                    try await bridge.activateWallpaperAsync(id: itemID, displayId: targetID)
                                    activationItemID = itemID
                                    activationFailed = false
                                    activationMessage = String(localized: "Applied to \(title)")
                                } catch {
                                    if bridge.latestBridgeErrorRevision == revision {
                                        activationItemID = itemID
                                        activationFailed = true
                                        activationMessage = error.localizedDescription
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                if bridge.activatingWallpaperID == item.id { ProgressView().controlSize(.small) }
                                Text("Apply to \(bridge.settingsSnapshot.displays.first { $0.displayId == navigation.targetDisplayID }?.title ?? navigation.targetDisplayID)")
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(minWidth: 0, maxWidth: .infinity)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                            .help(String(localized: "Apply to \(bridge.settingsSnapshot.displays.first { $0.displayId == navigation.targetDisplayID }?.title ?? navigation.targetDisplayID)"))
                            .disabled(bridge.activatingWallpaperID != nil || bridge.applyingWallpaperID != nil || bridge.activationNeedsRefresh)
                        if activationItemID == item.id, let activationMessage {
                            Text(activationMessage).foregroundStyle(activationFailed ? Color.red : Color.secondary)
                                .textSelection(.enabled).accessibilityIdentifier("wallpaper.activationStatus")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if item.kind == .application {
                        Text("Application wallpapers contain Windows executables. MacWallpaperEngine will not download or run them. Choose a Scene wallpaper instead.").foregroundStyle(.secondary)
                    } else {
                        SteamDownloadControls(item: item, workshop: workshop)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
            }
        }
        .onAppear { workshop.refreshSceneAssetsReadiness() }
        .sheet(isPresented: $showAssetsSetup, onDismiss: { workshop.refreshSceneAssetsReadiness() }) {
            SceneAssetsSetupView(workshop: workshop).environment(bridge)
        }
    }

}


struct SceneAssetsSetupView: View {
    @Bindable var workshop: WorkshopStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Set up scene assets").font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if workshop.sceneAssetsReady {
                        Label("Scene assets are ready", systemImage: "checkmark.circle")
                        Text(ClientPaths.assetsURL.path).font(.caption).textSelection(.enabled)
                        Text("Close this setup and apply your wallpaper. No restart or wallpaper re-download is needed.")
                    } else {
                        Text("Workshop downloads do not include Wallpaper Engine’s shared shaders and materials. Install them with a Steam account that owns Wallpaper Engine, or use an existing installation.")
                        Button("Locate assets…") {
                            if ClientPaths.selectAssetsFolder() { workshop.refreshSceneAssetsReadiness() }
                        }.disabled(workshop.downloader.isRunning || workshop.steamCMDSetup.isBusy)
                        Divider()
                        SteamDownloadControls(item: nil, workshop: workshop)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24)
            .frame(minWidth: 440, idealWidth: 590, maxWidth: 640, minHeight: 360, idealHeight: 500, maxHeight: 640)
            .onAppear { workshop.refreshSceneAssetsReadiness() }
    }
}

struct WorkshopSetupView: View {
    let workshop: WorkshopStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connect to Steam Workshop").font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                SteamCMDSetupView(setup: workshop.steamCMDSetup)
                WorkshopSetupInstructions().padding(.top, 16)
            }
        }.padding(24)
            .frame(minWidth: 440, idealWidth: 570, maxWidth: 640, minHeight: 360, idealHeight: 500, maxHeight: 640)
    }
}

struct SteamGuardInstructions: View {
    var challenge: WorkshopDownloader.SteamGuardChallenge?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Steam Guard · approve your sign-in", systemImage: "checkmark.shield")
                .font(.callout.weight(.semibold)).foregroundStyle(.primary)
            if challenge == nil || challenge == .mobileApproval {
                Text("Mobile approval: open the Steam mobile app, select the same account in the Steam Guard shield tab, and approve the request you just started. If no notification appears, open Steam Guard directly. Only approve a sign-in you recognize.")
            }
            if challenge == nil || challenge == .authenticatorCode {
                Text("Authenticator code: in the Steam mobile app, open Steam Guard for this account and show its current code. Enter it in the Steam Guard code field here and press Submit before it changes. Check that your phone’s date and time are set automatically if codes are rejected.")
            }
            if challenge == nil || challenge == .emailCode {
                Text("Email code: check the email address registered to this Steam account, including spam, then enter the latest Steam Guard code here and press Submit. Delivery can be delayed; if this login expires, use Retry Steam sign-in and use the new code.")
            }
            Text("Do not disable Steam Guard or share passwords, codes, or recovery codes. If you denied this request or it expired, wait for this attempt to finish and choose Retry Steam sign-in. Steam decides which verification method is available; retrying does not bypass approval.")
            Link("Steam Guard help", destination: URL(string: "https://help.steampowered.com/en/wizard/HelpWithSteamIssue/?issueid=808")!)
        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct WorkshopSetupInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Browsing is public and needs no API key. Downloads require Valve’s SteamCMD and a Steam account that legitimately owns Wallpaper Engine.")
            Text("Install SteamCMD here, or locate a complete existing macOS installation. Installation does not require a Steam login. On Apple silicon, follow Apple’s Rosetta instructions if setup reports that it is needed.")
            Text("Choose a wallpaper, enter your Steam account login name, and confirm ownership on first use or when switching accounts. Enter your password or Steam Guard code only when prompted; mobile approval is supported.")
            Text("MacWallpaperEngine runs a private copy of SteamCMD and removes temporary download staging. Keep me signed in on this Mac saves Steam-issued sign-in cache in private app support storage, never submitted passwords or Steam Guard codes. Turn it off or choose Forget saved Steam sign-in to remove the local cache; other Steam devices stay signed in. Steam can request fresh authentication after expiry, revocation, or security checks. Downloads can take longer on first launch while SteamCMD updates.")
            Text("Scene wallpapers need shared resources in addition to the Workshop download. Use Install scene assets… in Settings or the wallpaper details, or locate the assets folder from your purchased installation. Setup downloads the Windows installation but keeps only assets and never runs Windows programs. Application wallpapers are unsupported; Web wallpapers cannot be applied by this renderer.")
            VStack(alignment: .leading, spacing: 8) {
                Link("Wallpaper Engine on Steam", destination: URL(string: "https://store.steampowered.com/app/431960/Wallpaper_Engine/")!)
                Link("Steam Guard help", destination: URL(string: "https://help.steampowered.com/en/wizard/HelpWithSteamIssue/?issueid=808")!)
            }
        }.font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
