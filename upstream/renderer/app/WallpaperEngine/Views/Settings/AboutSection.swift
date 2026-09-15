import SwiftUI

struct AboutSection: View {
    @Environment(BridgeStore.self) private var store
    @Environment(AppUpdateStore.self) private var updater
    @State private var confirmsInstall = false

    var body: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("MacWallpaperEngine")
                    .font(.title3.bold())
                LabeledContent("App", value: appVersion)
                LabeledContent("Bridge", value: store.settingsSnapshot.bridgeVersion)
                LabeledContent("Core", value: store.settingsSnapshot.coreVersion)
                LabeledContent("Shader Pipeline", value: store.settingsSnapshot.shaderPipelineVersion)
                LabeledContent("Git", value: gitCommitHash)
                LabeledContent("Scene renderer") {
                    Link("bigsaltyfishes / Wallpaper Engine for macOS", destination: rendererURL)
                }
                Text("An independent macOS client. Not affiliated with Wallpaper Engine or Valve. Built on the GPLv2-only open-source renderer; Workshop browsing is independently implemented. No warranty is provided.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("GNU General Public License v2", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")!)
            }
            .padding(.vertical, 8)
        }
        Section("Updates") {
            VStack(alignment: .leading, spacing: 8) {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                if case .downloading(_, _, let percent, let transferred, let total, _) = updater.state {
                    ProgressView(value: total > 0 ? Double(transferred) / Double(total) : percent / 100)
                        .accessibilityLabel(Text("Update download progress"))
                    if total > 0 {
                        Text("\(StorageFormat.bytes(UInt64(transferred))) of \(StorageFormat.bytes(UInt64(total)))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if showsPrimaryAction {
                        Button(actionLabel) { performPrimaryAction() }
                            .disabled(updater.state.isBusy)
                            .accessibilityIdentifier("about.updates.action")
                    }
                    if showsReleasesLink {
                        Button("Open GitHub Releases") { updater.openReleases() }
                    }
                    if showsReveal {
                        Button("Show in Finder") { updater.revealDownloadedUpdate() }
                    }
                }
                Text("Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog("Restart and install this update?", isPresented: $confirmsInstall, titleVisibility: .visible) {
            Button("Restart and Install") {
                Task { await updater.installUpdate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current app will quit and be replaced. Wallpapers and settings are kept.")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var gitCommitHash: String {
        store.settingsSnapshot.gitSha
    }

    private var rendererURL: URL {
        URL(string: "https://github.com/bigsaltyfishes/wallpaper-engine-for-macos.git")!
    }

    private var statusText: String {
        switch updater.state {
        case .unsupported:
            return String(localized: "In-app updates are available only in installed builds.")
        case .idle:
            return String(localized: "Updates not yet checked")
        case .checking:
            return String(localized: "Checking for updates...")
        case .upToDate:
            return String(localized: "Up to date")
        case .available(_, let version), .manual(_, let version):
            return String(localized: "Version \(version) is available from GitHub Releases.")
        case .downloading(_, let version, let percent, _, _, _):
            return String(localized: "Downloading version \(version) — \(Int(percent.rounded())) percent")
        case .ready(_, let version):
            return String(localized: "Version \(version) is ready. Restart the app to install it.")
        case .error(_, _, let code, _):
            return errorText(code)
        }
    }

    private var actionLabel: String {
        switch updater.state {
        case .upToDate: String(localized: "Check Again")
        case .available: String(localized: "Download Update")
        case .downloading(_, _, let percent, _, _, _): String(localized: "Downloading \(Int(percent.rounded())) percent")
        case .ready: String(localized: "Restart and Install")
        case .error(_, .install, _, let version) where version != nil: String(localized: "Retry installation")
        case .error: String(localized: "Retry")
        default: String(localized: "Check for Updates")
        }
    }

    private var showsPrimaryAction: Bool {
        switch updater.state {
        case .unsupported, .manual: false
        default: true
        }
    }

    private var showsReleasesLink: Bool {
        switch updater.state {
        case .unsupported, .manual, .error: true
        default: false
        }
    }

    private var showsReveal: Bool {
        if case .ready = updater.state { return true }
        return false
    }

    private func performPrimaryAction() {
        switch updater.state {
        case .available:
            Task { _ = await updater.downloadUpdate() }
        case .ready:
            confirmsInstall = true
        case .error(_, .install, _, let version) where version != nil:
            confirmsInstall = true
        default:
            Task { _ = await updater.checkForUpdates() }
        }
    }

    private func errorText(_ code: AppUpdateErrorCode) -> String {
        switch code {
        case .network:
            String(localized: "Couldn't reach GitHub Releases. Check your connection and try again.")
        case .configuration:
            String(localized: "The GitHub Release update metadata is unavailable.")
        case .verification:
            String(localized: "The update couldn't be verified, so it wasn't installed.")
        case .permission:
            String(localized: "The updater doesn't have permission to install this update.")
        case .unknown:
            String(localized: "The update couldn't be completed. Try again or install it from GitHub Releases.")
        }
    }
}
