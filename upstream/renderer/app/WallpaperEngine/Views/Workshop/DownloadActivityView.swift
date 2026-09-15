import SwiftUI

struct DownloadActivityView: View {
    @Bindable var workshop: WorkshopStore

    var body: some View {
        if workshop.hasDownloadActivity {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: workshop.downloader.prompt != nil || workshop.downloader.steamGuardChallenge != nil ? "person.badge.key" : "arrow.down.circle")
                VStack(alignment: .leading, spacing: 3) {
                    Text(workshop.downloadItem?.title ?? String(localized: "Scene assets")).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(workshop.downloader.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if workshop.downloader.isRunning {
                    ProgressView(value: workshop.downloader.progress).frame(maxWidth: 100)
                    Button("Cancel") { workshop.downloader.cancel() }
                } else {
                    Button { workshop.clearDownloadActivity() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss download activity")
                }
                Button("Details") { workshop.showsDownloadDetails = true }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .accessibilityElement(children: .contain).accessibilityIdentifier("download.activity")
        }
    }
}

struct DownloadActivityDetails: View {
    @Bindable var workshop: WorkshopStore
    @Environment(\.dismiss) private var dismiss
    @Environment(BridgeStore.self) private var bridge

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Download Details").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(workshop.downloadItem?.title ?? String(localized: "Scene assets")).font(.headline).textSelection(.enabled)
            Text(workshop.downloadUsername).font(.caption).foregroundStyle(.secondary)
            if let item = workshop.downloadItem, !workshop.downloader.isRunning,
               bridge.librarySnapshot.wallpapers.contains(where: { $0.id == item.id }) {
                WorkshopDetailView(item: item, workshop: workshop)
            } else {
                ScrollView {
                    if workshop.downloadItem == nil && workshop.sceneAssetsReady && !workshop.downloader.isRunning {
                        Label("Scene assets are ready", systemImage: "checkmark.circle")
                    } else {
                        SteamDownloadControls(item: workshop.downloadItem, workshop: workshop)
                    }
                }
            }
        }.padding(24).frame(width: 570, height: 680)
    }
}

struct SteamDownloadControls: View {
    let item: WorkshopItem?
    @Bindable var workshop: WorkshopStore
    @Environment(BridgeStore.self) private var bridge
    @AppStorage("MacWallpaperEngine.rememberSteamSession") private var rememberSession = true
    @State private var secret = ""
    @State private var refreshError: String?
    @State private var setupExpanded = false
    @State private var guardHelpExpanded = false

    private var downloader: WorkshopDownloader { workshop.downloader }
    private var matchesActivity: Bool { workshop.hasDownloadActivity && downloader.currentItemID == item?.id }
    private var matchesSavedAccount: Bool {
        guard rememberSession, let saved = downloader.savedAccount else { return false }
        return WorkshopStore.normalizedAccount(workshop.username) == WorkshopStore.normalizedAccount(saved)
    }
    private var canStartDownload: Bool {
        workshop.steamCMDSetup.selectedRuntime != nil && !workshop.steamCMDSetup.isBusy && !downloader.isRunning
            && !WorkshopStore.normalizedAccount(workshop.username).isEmpty
            && (workshop.ownsWallpaperEngine || matchesSavedAccount)
    }
    private var canRetrySignIn: Bool { matchesActivity && downloader.canRetryAuthentication }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if downloader.isRunning && matchesActivity {
                Text(downloader.status).font(.headline)
                ProgressView(value: downloader.progress).progressViewStyle(.linear).accessibilityLabel("Download progress")
                if let prompt = downloader.prompt {
                    SecureField(LocalizedStringKey(prompt.rawValue), text: $secret)
                        .textFieldStyle(.roundedBorder).onSubmit(submitSecret)
                    Button("Submit", action: submitSecret).disabled(secret.isEmpty)
                    Text("Sent directly to SteamCMD’s private terminal; never saved by MacWallpaperEngine.").font(.caption).foregroundStyle(.secondary)
                }
                if let challenge = downloader.steamGuardChallenge { SteamGuardInstructions(challenge: challenge) }
                Text("You can keep browsing. Open Download Details to complete Steam Guard. Downloads stop after 5 minutes without SteamCMD output or 30 minutes overall.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel download", role: .cancel) { secret = ""; downloader.cancel() }
            } else if downloader.isRunning {
                Text("Another download is running.").foregroundStyle(.secondary)
                Button("Download Details") { workshop.showsDownloadDetails = true }
            } else {
                SteamCMDSetupView(setup: workshop.steamCMDSetup)
                if workshop.steamCMDSetup.selectedRuntime != nil && !workshop.steamCMDSetup.isBusy { accountForm }
            }
            if matchesActivity, let warning = downloader.sessionWarning {
                Label(warning, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if matchesActivity, let error = downloader.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = workshop.downloadErrorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if matchesActivity && !downloader.isRunning && downloader.wasCancelled { Text("Download cancelled").foregroundStyle(.secondary) }
            if let item, matchesActivity, downloader.downloadedID == item.id,
               !bridge.librarySnapshot.wallpapers.contains(where: { $0.id == item.id }) {
                Text("Downloaded; refresh Library before applying.").font(.callout).foregroundStyle(.secondary)
                Button("Refresh Library") {
                    let revision = bridge.latestBridgeErrorRevision
                    Task {
                        do { try await bridge.refreshLibraryAsync(); refreshError = nil }
                        catch { if revision == bridge.latestBridgeErrorRevision { refreshError = error.localizedDescription } }
                    }
                }.disabled(bridge.activatingWallpaperID != nil || bridge.applyingWallpaperID != nil)
                if let refreshError { Text(refreshError).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .onAppear {
            if rememberSession, workshop.username.isEmpty, let saved = downloader.savedAccount { workshop.username = saved }
            else if !rememberSession, downloader.savedAccount != nil, !downloader.isRunning { forgetSavedSignIn() }
        }
        .onChange(of: workshop.username) { previous, current in
            if WorkshopStore.normalizedAccount(previous) != WorkshopStore.normalizedAccount(current) {
                workshop.ownsWallpaperEngine = false
                secret = ""
            }
        }
        .onChange(of: rememberSession) { if !rememberSession { forgetSavedSignIn() } }
        .onChange(of: downloader.savedAccount) { previous, current in
            workshop.ownsWallpaperEngine = false
            if current == nil, downloader.errorMessage == nil, let previous,
               WorkshopStore.normalizedAccount(workshop.username) == WorkshopStore.normalizedAccount(previous) {
                workshop.username = ""
                secret = ""
            }
        }
        .onChange(of: downloader.isRunning) {
            if !downloader.isRunning, !rememberSession, downloader.savedAccount != nil { forgetSavedSignIn() }
        }
        .onChange(of: downloader.prompt) { secret = "" }
        .onChange(of: item?.id) { secret = ""; refreshError = nil }
        .onDisappear { secret = "" }
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Download with your Steam account").font(.headline)
            Text(item == nil
                 ? "Steam will download the Windows version of Wallpaper Engine to a temporary folder. Only its shared assets are kept; Windows programs are never run. This can require several GB of temporary disk space."
                 : "Use an account that owns Wallpaper Engine. SteamCMD enforces access. This downloads one item; it does not subscribe or automatically apply it.").font(.callout).foregroundStyle(.secondary)
            TextField("Steam account login name", text: $workshop.username).textFieldStyle(.roundedBorder)
            if matchesSavedAccount {
                Label("Saved Steam sign-in for this account on this Mac", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("steam.savedSignIn")
            } else { Toggle("I own Wallpaper Engine on this Steam account", isOn: $workshop.ownsWallpaperEngine) }
            Toggle("Keep me signed in on this Mac", isOn: $rememberSession).accessibilityIdentifier("steam.rememberSession")
            Text("When enabled, Steam-issued sign-in cache is saved privately on this Mac, not your submitted password or Steam Guard codes. Downloads still use temporary staging. Steam may request a fresh login after expiry, revocation, or security checks.").font(.caption).foregroundStyle(.secondary)
            if downloader.savedAccount != nil {
                Button("Forget saved Steam sign-in", role: .destructive, action: forgetSavedSignIn).accessibilityIdentifier("steam.forgetSavedSignIn")
                Text("Removes saved sign-in from this Mac only; it does not sign out other Steam devices.").font(.caption).foregroundStyle(.secondary)
            }
            Button(canRetrySignIn ? "Retry Steam sign-in" : item == nil ? "Install scene assets" : "Download to Library",
                   systemImage: canRetrySignIn ? "arrow.clockwise" : "arrow.down.circle", action: startDownload)
                .buttonStyle(.borderedProminent).disabled(!canStartDownload)
            if canRetrySignIn {
                Text("Starts a new SteamCMD login using the account name above. If prompted, enter your password, then approve the new request or enter a fresh code. The rejected request is not reused. If Steam reports too many attempts, wait before retrying.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Steam Guard sign-in help", isExpanded: $guardHelpExpanded) { SteamGuardInstructions().padding(.top, 8) }
            DisclosureGroup("SteamCMD installation and account help", isExpanded: $setupExpanded) { WorkshopSetupInstructions().padding(.top, 8) }
        }
    }

    private func startDownload() {
        guard canStartDownload else { return }
        secret = ""
        workshop.startDownload(item: item, username: workshop.username, rememberSession: rememberSession, bridge: bridge)
    }
    private func submitSecret() { downloader.submitSecret(secret); secret = "" }
    private func forgetSavedSignIn() {
        guard !downloader.isRunning else { return }
        secret = ""
        downloader.forgetSavedAccount()
        guard downloader.savedAccount == nil, downloader.errorMessage == nil else { return }
        workshop.username = ""
        workshop.ownsWallpaperEngine = false
    }
}
