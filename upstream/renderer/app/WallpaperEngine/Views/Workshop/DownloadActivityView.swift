import SwiftUI

struct DownloadActivityView: View {
    @Bindable var workshop: WorkshopStore

    private var authenticationDownload: WorkshopDownload? {
        workshop.downloader.downloads.first {
            $0.isPending && !$0.isQueued && ($0.worker.prompt != nil || $0.worker.steamGuardChallenge != nil)
        }
    }

    var body: some View {
        if workshop.hasDownloadActivity {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: authenticationDownload == nil ? "arrow.down.circle" : "person.badge.key")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Downloads").font(.callout.weight(.semibold))
                    if workshop.downloader.isRunning {
                        Text("\(workshop.downloader.activeCount)/\(workshop.downloader.maximumConcurrentDownloads) active · \(workshop.downloader.queuedCount) queued")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("Finished downloads").font(.caption).foregroundStyle(.secondary)
                    }
                    if authenticationDownload != nil {
                        Text("Sign-in needed").font(.caption).foregroundStyle(.orange)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !workshop.downloader.isRunning {
                    Button { workshop.clearDownloadActivity() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss download activity")
                }
                Button("Details") {
                    if let download = authenticationDownload ?? workshop.selectedDownload ?? workshop.downloader.downloads.first {
                        workshop.showDownload(download)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .accessibilityElement(children: .contain).accessibilityIdentifier("download.activity")
        }
    }
}

struct DownloadActivityDetails: View {
    @Bindable var workshop: WorkshopStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Download Details").font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Clear finished downloads") { workshop.clearDownloadActivity() }
                    .disabled(!workshop.downloader.downloads.contains { !$0.isPending })
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                List(selection: Binding<String?>(get: { workshop.selectedDownload?.id }, set: { id in
                    if let id, let download = workshop.downloader.downloads.first(where: { $0.id == id }) {
                        workshop.showDownload(download)
                    }
                })) {
                    ForEach(workshop.downloader.downloads) { download in
                        DownloadActivityRow(download: download).tag(download.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 230)
                .accessibilityIdentifier("workshop.downloads")
                Divider()
                selectedDetails
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 540, idealWidth: 700, maxWidth: 760, minHeight: 360, idealHeight: 560, maxHeight: 680)
        .onAppear { workshop.refreshSceneAssetsReadiness() }
    }

    @ViewBuilder private var selectedDetails: some View {
        if let download = workshop.selectedDownload {
            Group {
                if let item = download.item {
                    WorkshopDetailView(item: item, workshop: workshop)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Scene assets").font(.headline)
                            Text(download.account).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if workshop.sceneAssetsReady && !download.isPending {
                                Label("Scene assets are ready", systemImage: "checkmark.circle")
                                Text(ClientPaths.assetsURL.path).font(.caption).textSelection(.enabled)
                                if let warning = download.worker.sessionWarning {
                                    Label(warning, systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                                }
                                if let error = download.worker.errorMessage {
                                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                }
                            } else {
                                SteamDownloadControls(item: nil, workshop: workshop)
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                    }
                }
            }
            .id(ObjectIdentifier(download))
        } else {
            ControlPanelEmptyState("Select a download", systemImage: "arrow.down.circle",
                description: Text("Choose a download to view progress, complete Steam Guard, or show it in Library.")) {}
                .padding(16)
        }
    }
}

private struct DownloadActivityRow: View {
    let download: WorkshopDownload

    private var needsAuthentication: Bool {
        download.isPending && !download.isQueued && (download.worker.prompt != nil || download.worker.steamGuardChallenge != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(download.item?.title ?? String(localized: "Scene assets"))
                .font(.callout.weight(.medium)).lineLimit(2)
            Text(download.account).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if let error = download.worker.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
            } else if needsAuthentication {
                Label("Sign-in needed · \(download.status)", systemImage: "person.badge.key")
                    .foregroundStyle(.orange).lineLimit(2)
            } else if let warning = download.worker.sessionWarning {
                Label(warning, systemImage: "exclamationmark.shield").foregroundStyle(.orange).lineLimit(2)
            } else {
                Text(download.status).foregroundStyle(.secondary).lineLimit(2)
            }
            if download.isPending && !download.isQueued {
                ProgressView(value: download.progress).progressViewStyle(.linear)
                    .accessibilityLabel("Download progress")
            }
        }
        .font(.caption)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("download.job.\(download.id)")
    }
}

struct SteamDownloadControls: View {
    let item: WorkshopItem?
    @Bindable var workshop: WorkshopStore
    @Environment(BridgeStore.self) private var bridge
    @AppStorage("MacWallpaperEngine.rememberSteamSession") private var rememberSession = true
    @State private var secret = ""
    @State private var secretWorkerID: ObjectIdentifier?
    @State private var secretPrompt: WorkshopDownloader.Prompt?
    @State private var refreshError: String?
    @State private var setupExpanded = false
    @State private var guardHelpExpanded = false

    private var downloader: WorkshopDownloadManager { workshop.downloader }
    private var download: WorkshopDownload? { downloader.download(for: item?.id) }
    private var sessionPreference: Bool { downloader.rememberSessionWhileRunning ?? rememberSession }
    private var matchesSavedAccount: Bool {
        guard sessionPreference, let saved = downloader.savedAccount else { return false }
        return WorkshopStore.normalizedAccount(workshop.username) == WorkshopStore.normalizedAccount(saved)
    }
    private var canStartDownload: Bool {
        workshop.steamCMDSetup.selectedRuntime != nil && !workshop.steamCMDSetup.isBusy && download?.isPending != true
            && !WorkshopStore.normalizedAccount(workshop.username).isEmpty
            && (workshop.ownsWallpaperEngine || matchesSavedAccount)
    }
    private var canRetrySignIn: Bool {
        download?.isPending == false && download?.worker.canRetryAuthentication == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let download, download.isPending {
                Text(download.status).font(.headline)
                Text(download.account).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !download.isQueued {
                    ProgressView(value: download.progress).progressViewStyle(.linear).accessibilityLabel("Download progress")
                    if let prompt = download.worker.prompt {
                        let input = secretBinding(to: download, prompt: prompt)
                        SecureField(LocalizedStringKey(prompt.rawValue), text: input)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submitSecret(to: download, prompt: prompt) }
                        Button("Submit") { submitSecret(to: download, prompt: prompt) }
                            .disabled(input.wrappedValue.isEmpty)
                        Text("Sent directly to SteamCMD’s private terminal; never saved by MacWallpaperEngine.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let challenge = download.worker.steamGuardChallenge { SteamGuardInstructions(challenge: challenge) }
                }
                Text(download.isQueued
                     ? "Waiting for a free download slot. Queued downloads start in the order added."
                     : "You can keep browsing. Open Download Details to complete Steam Guard. Downloads stop after 5 minutes without SteamCMD output or 30 minutes overall.").font(.caption).foregroundStyle(.secondary)
                if !workshop.showsDownloadDetails {
                    Button("Download Details") { workshop.showDownload(download) }
                }
                Button(download.isQueued ? "Cancel queued download" : "Cancel download", role: .cancel) {
                    clearSecret()
                    downloader.cancel(download)
                }
            } else {
                SteamCMDSetupView(setup: workshop.steamCMDSetup)
                if workshop.steamCMDSetup.selectedRuntime != nil && !workshop.steamCMDSetup.isBusy { accountForm }
            }
            if let warning = download?.worker.sessionWarning {
                Label(warning, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = download?.worker.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = downloader.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = workshop.downloadErrorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let download, !download.isPending, download.worker.errorMessage == nil {
                Text(download.isCancelled ? String(localized: "Download cancelled") : download.status).foregroundStyle(.secondary)
            }
            if let item, let download, !download.isPending, download.worker.downloadedID == item.id,
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
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if workshop.username.isEmpty { workshop.username = download?.account ?? downloader.suggestedAccount ?? "" }
            if !rememberSession, downloader.savedAccount != nil, !downloader.isRunning { forgetSavedSignIn() }
        }
        .onChange(of: workshop.username) { previous, current in
            if WorkshopStore.normalizedAccount(previous) != WorkshopStore.normalizedAccount(current) {
                workshop.ownsWallpaperEngine = false
                clearSecret()
            }
        }
        .onChange(of: rememberSession) {
            if !rememberSession, !downloader.isRunning { forgetSavedSignIn() }
        }
        .onChange(of: downloader.savedAccount) { previous, current in
            workshop.ownsWallpaperEngine = false
            if current == nil, downloader.errorMessage == nil, let previous,
               WorkshopStore.normalizedAccount(workshop.username) == WorkshopStore.normalizedAccount(previous) {
                workshop.username = ""
                clearSecret()
            }
        }
        .onChange(of: downloader.isRunning) {
            if !downloader.isRunning, !rememberSession, downloader.savedAccount != nil { forgetSavedSignIn() }
        }
        .onChange(of: download?.worker.prompt) { clearSecret() }
        .onChange(of: download?.worker.steamGuardChallenge) { clearSecret() }
        .onChange(of: download.map { ObjectIdentifier($0.worker) }) { clearSecret(); refreshError = nil }
        .onChange(of: item?.id) { clearSecret(); refreshError = nil }
        .onDisappear { clearSecret() }
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Download with your Steam account").font(.headline)
            Text(item == nil
                 ? "Steam will download the Windows version of Wallpaper Engine to a temporary folder. Only its shared assets are kept; Windows programs are never run. This can require several GB of temporary disk space."
                 : "Use an account that owns Wallpaper Engine. SteamCMD enforces access. Downloads run in the background and do not subscribe or automatically apply wallpapers.").font(.callout).foregroundStyle(.secondary)
            TextField("Steam account login name", text: $workshop.username).textFieldStyle(.roundedBorder)
            if matchesSavedAccount {
                Label("Saved Steam sign-in for this account on this Mac", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("steam.savedSignIn")
            } else { Toggle("I own Wallpaper Engine on this Steam account", isOn: $workshop.ownsWallpaperEngine) }
            Toggle("Keep me signed in on this Mac", isOn: Binding(get: { sessionPreference }, set: { value in
                guard !downloader.isRunning else { return }
                rememberSession = value
            }))
                .disabled(downloader.isRunning)
                .accessibilityIdentifier("steam.rememberSession")
            Text("When enabled, Steam-issued sign-in cache is saved privately on this Mac, not your submitted password or Steam Guard codes. Downloads still use temporary staging. Steam may request a fresh login after expiry, revocation, or security checks.").font(.caption).foregroundStyle(.secondary)
            if downloader.isRunning {
                Text("Saved sign-in settings are locked until all active and queued downloads finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if downloader.savedAccount != nil {
                Button("Forget saved Steam sign-in", role: .destructive, action: forgetSavedSignIn)
                    .disabled(downloader.isRunning)
                    .accessibilityIdentifier("steam.forgetSavedSignIn")
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
        clearSecret()
        workshop.startDownload(item: item, username: workshop.username, rememberSession: sessionPreference, bridge: bridge)
    }

    private func secretBinding(to target: WorkshopDownload, prompt: WorkshopDownloader.Prompt) -> Binding<String> {
        Binding(get: {
            guard secretWorkerID == ObjectIdentifier(target.worker), secretPrompt == prompt,
                  download === target, target.isPending, !target.isQueued, target.worker.prompt == prompt else { return "" }
            return secret
        }, set: { value in
            guard download === target, target.isPending, !target.isQueued, target.worker.prompt == prompt else {
                clearSecret()
                return
            }
            secretWorkerID = ObjectIdentifier(target.worker)
            secretPrompt = prompt
            secret = value
        })
    }

    private func submitSecret(to target: WorkshopDownload, prompt: WorkshopDownloader.Prompt) {
        defer { clearSecret() }
        guard !secret.isEmpty, secretWorkerID == ObjectIdentifier(target.worker), secretPrompt == prompt,
              download === target, target.isPending, !target.isQueued, target.worker.prompt == prompt else { return }
        target.worker.submitSecret(secret)
    }

    private func clearSecret() {
        secret = ""
        secretWorkerID = nil
        secretPrompt = nil
    }

    private func forgetSavedSignIn() {
        guard !downloader.isRunning else { return }
        clearSecret()
        downloader.forgetSavedAccount()
        guard downloader.savedAccount == nil, downloader.errorMessage == nil else { return }
        workshop.username = ""
        workshop.ownsWallpaperEngine = false
    }
}
