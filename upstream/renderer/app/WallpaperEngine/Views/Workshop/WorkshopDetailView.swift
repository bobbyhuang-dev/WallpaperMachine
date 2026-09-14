import AppKit
import SwiftUI

struct WorkshopDetailView: View {
    let item: WorkshopItem
    @Bindable var workshop: WorkshopStore
    let installed: Bool
    @Environment(BridgeStore.self) private var bridge
    @Environment(\.dismiss) private var dismiss
    @State private var showAssetsSetup = false
    @State private var assetsReady = ClientPaths.hasSceneAssets(at: ClientPaths.assetsURL)
    private var downloader: WorkshopDownloader { workshop.downloader }
    private var isInstalled: Bool {
        installed || downloader.downloadedID == item.id || bridge.librarySnapshot.wallpapers.contains { $0.id == item.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workshop wallpaper").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(downloader.isRunning)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkshopPreview(url: item.previewURL).frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Text("By \(item.creator)").foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Label(item.subscriptions.formatted() + " subscribers", systemImage: "person.2")
                            if item.size > 0 { Label(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file), systemImage: "internaldrive") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Label(item.kind.compatibility, systemImage: item.kind == .application || item.kind == .web ? "exclamationmark.triangle" : "info.circle")
                        .font(.callout.weight(.medium)).foregroundStyle(item.kind == .application || item.kind == .web ? Color.orange : Color.secondary)
                    if item.kind == .scene {
                        Text("Scene support is experimental. Some effects, scripts, and audio features may differ from Windows. Shared scene assets are installed separately from Workshop wallpapers.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !item.summary.isEmpty { Text(item.summary).font(.callout).textSelection(.enabled) }
                    Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Link("View full description, creator, and requirements on Steam", destination: item.pageURL)
                    Divider()
                    if isInstalled {
                        Label("Available in your local library", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if let warning = downloader.sessionWarning {
                            Label(warning, systemImage: "exclamationmark.shield")
                                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if item.kind == .scene && !assetsReady {
                            Label("Scene assets still need setup", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text("The wallpaper download is complete. Install Wallpaper Engine’s shared resources once, or locate your purchased installation’s assets folder.").font(.callout).foregroundStyle(.secondary)
                            Button("Install scene assets…") { showAssetsSetup = true }.buttonStyle(.borderedProminent)
                        }
                        Text("Apply uses your primary display. Display targets and wallpaper properties are available in Library.").font(.callout).foregroundStyle(.secondary)
                        Button {
                            workshop.apply(id: item.id, bridge: bridge)
                        } label: {
                            HStack { if workshop.applyingID == item.id { ProgressView().controlSize(.small) }; Text("Apply to primary display") }
                        }.buttonStyle(.borderedProminent).disabled(workshop.applyingID != nil || item.kind == .application || item.kind == .web || (item.kind == .scene && !assetsReady))
                        if let message = workshop.applyMessage { Text(message).foregroundStyle(.green) }
                        if let error = workshop.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    } else if item.kind == .application {
                        Text("Application wallpapers contain Windows executables. MacWallpaperEngine will not download or run them. Choose a Scene wallpaper instead.").foregroundStyle(.secondary)
                    } else {
                        SteamDownloadControls(item: item, workshop: workshop)
                    }
                }.padding(24)
            }
        }.frame(width: 680, height: 780)
            .interactiveDismissDisabled(downloader.isRunning)
            .onAppear { assetsReady = ClientPaths.hasSceneAssets(at: ClientPaths.assetsURL) }
            .sheet(isPresented: $showAssetsSetup, onDismiss: {
                assetsReady = ClientPaths.hasSceneAssets(at: ClientPaths.assetsURL)
                if assetsReady { workshop.errorMessage = nil }
            }) {
                SceneAssetsSetupView(workshop: workshop).environment(bridge)
            }
    }

}

private struct SteamDownloadControls: View {
    let item: WorkshopItem?
    @Bindable var workshop: WorkshopStore
    @Environment(BridgeStore.self) private var bridge
    @AppStorage("MacWallpaperEngine.rememberSteamSession") private var rememberSession = true
    @State private var username = ""
    @State private var secret = ""
    @State private var ownsWallpaperEngine = false
    @State private var executable: URL? = ClientPaths.steamcmdURL
    @State private var setupExpanded = false
    @State private var guardHelpExpanded = false

    private var downloader: WorkshopDownloader { workshop.downloader }
    private var matchesSavedAccount: Bool {
        guard rememberSession, let savedAccount = downloader.savedAccount else { return false }
        return normalizedAccount(username) == normalizedAccount(savedAccount)
    }
    private var canStartDownload: Bool {
        executable != nil && !normalizedAccount(username).isEmpty && (ownsWallpaperEngine || matchesSavedAccount)
    }
    private var canRetrySignIn: Bool {
        downloader.currentItemID == item?.id && downloader.canRetryAuthentication
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if downloader.isRunning {
                Text(downloader.status).font(.headline)
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Download progress")
                if let prompt = downloader.prompt {
                    HStack {
                        SecureField(prompt.rawValue, text: $secret).textFieldStyle(.roundedBorder)
                            .onSubmit(submitSecret)
                        Button("Submit", action: submitSecret).disabled(secret.isEmpty)
                    }
                    Text("Sent directly to SteamCMD’s private terminal; never saved by MacWallpaperEngine.").font(.caption).foregroundStyle(.secondary)
                }
                if let challenge = downloader.steamGuardChallenge {
                    SteamGuardInstructions(challenge: challenge)
                }
                Text("Keep this download open while you complete Steam Guard. It continues automatically after approval. Downloads stop after 5 minutes without SteamCMD output or 30 minutes overall.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel download", role: .cancel) { secret = ""; downloader.cancel() }
            } else {
                Text("Download with your Steam account").font(.headline)
                Text(item == nil
                     ? "Steam will download the Windows version of Wallpaper Engine to a temporary folder. Only its shared assets are kept; Windows programs are never run. This can require several GB of temporary disk space."
                     : "Use an account that owns Wallpaper Engine. SteamCMD enforces access. This downloads one item; it does not subscribe or automatically apply it.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: executable == nil ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(executable == nil ? Color.orange : Color.green)
                    Text(executable == nil ? "SteamCMD not found" : "SteamCMD selected").font(.callout)
                    Spacer()
                    Button(executable == nil ? "Choose SteamCMD…" : "Change…", action: chooseExecutable)
                }
                if let executable { Text(executable.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                TextField("Steam account login name", text: Binding(get: { username }, set: { value in
                    if normalizedAccount(username) != normalizedAccount(value) {
                        ownsWallpaperEngine = false
                        secret = ""
                    }
                    username = value
                })).textFieldStyle(.roundedBorder)
                if matchesSavedAccount {
                    Label("Saved Steam sign-in for this account on this Mac", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("steam.savedSignIn")
                } else {
                    Toggle("I own Wallpaper Engine on this Steam account", isOn: $ownsWallpaperEngine)
                }
                Toggle("Keep me signed in on this Mac", isOn: $rememberSession)
                    .accessibilityIdentifier("steam.rememberSession")
                Text("When enabled, Steam-issued sign-in cache is saved privately on this Mac, not your submitted password or Steam Guard codes. Downloads still use temporary staging. Steam may request a fresh login after expiry, revocation, or security checks.")
                    .font(.caption).foregroundStyle(.secondary)
                if downloader.savedAccount != nil {
                    Button("Forget saved Steam sign-in", role: .destructive, action: forgetSavedSignIn)
                        .accessibilityIdentifier("steam.forgetSavedSignIn")
                    Text("Removes saved sign-in from this Mac only; it does not sign out other Steam devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !canRetrySignIn {
                    Button(item == nil ? "Install scene assets" : "Download to Library", systemImage: "arrow.down.circle", action: startDownload)
                        .buttonStyle(.borderedProminent).disabled(!canStartDownload)
                }
                DisclosureGroup("Steam Guard sign-in help", isExpanded: $guardHelpExpanded) {
                    SteamGuardInstructions().padding(.top, 10)
                }
                DisclosureGroup("SteamCMD installation and account help", isExpanded: $setupExpanded) { WorkshopSetupInstructions().padding(.top, 10) }
            }
            if let warning = downloader.sessionWarning {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Saved sign-in warning", systemImage: "exclamationmark.shield")
                        .font(.callout.weight(.semibold))
                    Text(warning).font(.caption).textSelection(.enabled)
                }.foregroundStyle(.orange)
            }
            if let error = downloader.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if canRetrySignIn {
                Button("Retry Steam sign-in", systemImage: "arrow.clockwise", action: startDownload)
                    .buttonStyle(.borderedProminent).disabled(!canStartDownload)
                Text("Starts a new SteamCMD login using the account name above. If prompted, enter your password, then approve the new request or enter a fresh code. The rejected request is not reused. If Steam reports too many attempts, wait before retrying.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !downloader.isRunning && downloader.status == "Download cancelled" { Text(downloader.status).foregroundStyle(.secondary) }
        }
        .onAppear {
            if rememberSession, username.isEmpty, let savedAccount = downloader.savedAccount {
                username = savedAccount
            } else if !rememberSession, downloader.savedAccount != nil, !downloader.isRunning {
                forgetSavedSignIn()
            }
        }
        .onChange(of: rememberSession) {
            if !rememberSession { forgetSavedSignIn() }
        }
        .onChange(of: downloader.savedAccount) { previous, current in
            ownsWallpaperEngine = false
            if current == nil, downloader.errorMessage == nil, let previous,
               normalizedAccount(username) == normalizedAccount(previous) {
                username = ""
                secret = ""
            }
        }
        .onChange(of: downloader.isRunning) {
            if !downloader.isRunning, !rememberSession, downloader.savedAccount != nil {
                forgetSavedSignIn()
            }
        }
        .onChange(of: downloader.prompt) { secret = "" }
        .onDisappear { secret = "" }
    }

    private func startDownload() {
        guard canStartDownload, !downloader.isRunning, let executable else { return }
        secret = ""
        workshop.errorMessage = nil
        if let item {
            downloader.start(item: item, username: username, executable: executable, library: ClientPaths.libraryURL, rememberSession: rememberSession) {
                try await bridge.refreshLibraryAsync()
            }
        } else {
            let destination = ClientPaths.managedAssetsURL
            downloader.installAssets(username: username, executable: executable, destination: destination, rememberSession: rememberSession) {
                try ClientPaths.configureAssetsFolder(at: destination)
            }
        }
    }

    private func submitSecret() {
        downloader.submitSecret(secret)
        secret = ""
    }

    private func normalizedAccount(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func forgetSavedSignIn() {
        guard !downloader.isRunning else { return }
        secret = ""
        downloader.forgetSavedAccount()
        guard downloader.savedAccount == nil, downloader.errorMessage == nil else { return }
        username = ""
        ownsWallpaperEngine = false
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Valve’s SteamCMD"
        panel.message = "Select steamcmd.sh or steamcmd in the extracted macOS SteamCMD distribution."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { executable = panel.url }
    }
}

struct SceneAssetsSetupView: View {
    @Bindable var workshop: WorkshopStore
    @Environment(\.dismiss) private var dismiss
    @State private var assetsPath = ClientPaths.assetsURL.path
    private var downloader: WorkshopDownloader { workshop.downloader }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Set up scene assets").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.disabled(downloader.isRunning).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if ClientPaths.hasSceneAssets(at: URL(fileURLWithPath: assetsPath)) {
                        Label("Scene assets are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(assetsPath).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Close this setup and apply your wallpaper. No restart or wallpaper re-download is needed.")
                    } else {
                        Text("Workshop downloads do not include Wallpaper Engine’s shared shaders and materials. Install them with a Steam account that owns Wallpaper Engine, or use an existing installation.")
                        Button("Locate assets…") {
                            if ClientPaths.selectAssetsFolder() { assetsPath = ClientPaths.assetsURL.path }
                        }.disabled(downloader.isRunning)
                        Divider()
                        SteamDownloadControls(item: nil, workshop: workshop)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 590, height: 640)
            .interactiveDismissDisabled(downloader.isRunning)
            .onChange(of: downloader.isRunning) {
                if !downloader.isRunning { assetsPath = ClientPaths.assetsURL.path }
            }
    }
}

struct WorkshopSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Connect to Steam Workshop", systemImage: "person.badge.key.fill").font(.title2.weight(.semibold))
            WorkshopSetupInstructions()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 570)
    }
}

private struct SteamGuardInstructions: View {
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

private struct WorkshopSetupInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Browsing is public and needs no API key. Downloads require Valve’s SteamCMD and a Steam account that legitimately owns Wallpaper Engine.")
            Text("1. Download and extract Valve’s macOS SteamCMD distribution into a folder you control. Keep steamcmd.sh, steamcmd, Frameworks, and crashhandler.dylib together.")
            Link("Download SteamCMD for macOS from Valve", destination: URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!)
            Text("2. On Apple silicon, SteamCMD uses Intel code and may require Rosetta 2. Run SteamCMD once from Terminal if macOS needs you to approve it or install Rosetta.")
            Text("3. Choose a wallpaper, select steamcmd.sh, enter your Steam account login name, and confirm ownership on first use or when switching accounts. Enter your password or Steam Guard code only when prompted; mobile approval is supported.")
            Text("MacWallpaperEngine runs a private copy of SteamCMD and removes temporary download staging. Keep me signed in on this Mac saves Steam-issued sign-in cache in private app support storage, never submitted passwords or Steam Guard codes. Turn it off or choose Forget saved Steam sign-in to remove the local cache; other Steam devices stay signed in. Steam can request fresh authentication after expiry, revocation, or security checks. Downloads can take longer on first launch while SteamCMD updates.")
            Text("Scene wallpapers need shared resources in addition to the Workshop download. Use Install scene assets… in Settings or the wallpaper details, or locate the assets folder from your purchased installation. Setup downloads the Windows installation but keeps only assets and never runs Windows programs. Application wallpapers are unsupported; Web wallpapers cannot be applied by this renderer.")
            HStack {
                Link("Wallpaper Engine on Steam", destination: URL(string: "https://store.steampowered.com/app/431960/Wallpaper_Engine/")!)
                Spacer()
                Link("Steam Guard help", destination: URL(string: "https://help.steampowered.com/en/wizard/HelpWithSteamIssue/?issueid=808")!)
            }
        }.font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    }
}
