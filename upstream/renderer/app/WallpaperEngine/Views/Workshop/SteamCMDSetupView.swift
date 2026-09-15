import AppKit
import SwiftUI

struct SteamCMDSetupView: View {
    let setup: SteamCMDSetupStore
    @Environment(WorkshopStore.self) private var workshop
    @State private var confirmsReplacement = false
    @State private var lastSelection: URL?
    @State private var lastActionWasInstall = false
    @State private var approvalCandidate: SteamCMDApprovalCandidate?
    @State private var confirmsApproval = false
    @State private var confirmsDiscard = false
    @State private var preparingApproval = false
    @State private var approvalError: String?

    private var managedExists: Bool { FileManager.default.fileExists(atPath: ClientPaths.managedSteamCMDURL.path) }
    private var controlsDisabled: Bool { setup.isBusy || workshop.downloader.isRunning || preparingApproval }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SteamCMD", systemImage: "arrow.down.circle") .font(.headline)
            status.accessibilityIdentifier("steamcmd.status")
            if let runtime = setup.selectedRuntime {
                Text(runtime.executableURL.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if case .failed = setup.state {
                    Text("The previous installation is still available.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let candidateURL = setup.retainedCandidateURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The downloaded candidate is kept here for approval and retry.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(candidateURL.path).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show Downloaded File") {
                        NSWorkspace.shared.activateFileViewerSelecting([candidateURL])
                    }
                    if case .failed(let issue) = setup.state, issue.kind == .securityApprovalRequired {
                        Button("Allow This SteamCMD…") { prepareApproval() }
                            .buttonStyle(.borderedProminent).disabled(controlsDisabled)
                            .accessibilityIdentifier("steamcmd.approve")
                    }
                    Button("Discard Download…", role: .destructive) { confirmsDiscard = true }
                        .disabled(controlsDisabled)
                }
            }
            if let approvalError {
                Text(approvalError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if setup.isBusy {
                if case .downloading(let received, let expected) = setup.state {
                    ProgressView(value: expected.map { Double(received) / Double(max(1, $0)) })
                    Text(expected.map { String(localized: "\(bytes(received)) of \(bytes($0))") } ?? bytes(received))
                        .font(.caption).monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Button("Cancel") { setup.cancel() }.disabled(setup.state == .committing)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button(setup.retainedCandidateURL != nil ? "Continue Installation" : managedExists ? "Reinstall SteamCMD…" : "Install SteamCMD") { requestInstall() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("steamcmd.install")
                    Button("Locate Existing…") { chooseExisting() }
                }.disabled(controlsDisabled)
                if case .failed = setup.state {
                    Button("Retry") {
                        if setup.retainedCandidateURL != nil { setup.retryInstallation() }
                        else if lastActionWasInstall { requestInstall() }
                        else if let lastSelection { setup.selectExisting(at: lastSelection) }
                        else { Task { await setup.refresh() } }
                    }.disabled(controlsDisabled)
                }
            }
            if workshop.downloader.isRunning {
                Text("Another download is running.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Install Valve’s download tool without signing in. Your Steam account is only needed when downloading wallpapers or scene assets.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await setup.refresh() }
        .confirmationDialog("Reinstall SteamCMD?", isPresented: $confirmsReplacement) {
            Button("Reinstall SteamCMD", role: .destructive) {
                lastActionWasInstall = true
                lastSelection = nil
                setup.install(replacingExisting: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replace only MacWallpaperEngine’s managed SteamCMD installation. The current installation is kept until the replacement passes validation. Saved Steam sign-in and wallpapers are not removed.")
        }
        .confirmationDialog("Allow this SteamCMD installation?", isPresented: $confirmsApproval,
                            presenting: approvalCandidate) { candidate in
            Button("Allow This Copy and Continue") {
                setup.approveRetainedCandidate(candidate)
                approvalCandidate = nil
            }
            Button("Cancel", role: .cancel) { approvalCandidate = nil }
        } message: { candidate in
            Text("This runs software macOS has not approved and may put your data at risk. Only the signed files matching this fingerprint will be allowed. Quarantine is removed from this copy only; global Gatekeeper and signature checks stay enabled. Changed files require another approval.\n\nPath: \(candidate.rootURL.path)\nSHA-256: \(candidate.fingerprint)")
        }
        .confirmationDialog("Discard this downloaded candidate?", isPresented: $confirmsDiscard) {
            Button("Discard Download", role: .destructive) { setup.discardRetainedCandidate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the retained SteamCMD download will be removed. Your installed runtime, wallpapers, and saved Steam sign-in are kept.")
        }
    }

    @ViewBuilder private var status: some View {
        switch setup.state {
        case .idle: Text("Not installed").foregroundStyle(.secondary)
        case .checking: Text("Checking SteamCMD…")
        case .downloading: Text("Downloading SteamCMD from Valve…")
        case .extracting: Text("Extracting SteamCMD…")
        case .updating: Text("Completing SteamCMD installation…")
        case .validating: Text("Validating SteamCMD…")
        case .committing: Text("Saving SteamCMD installation…")
        case .ready: Label("Ready", systemImage: "checkmark.circle")
        case .cancelled: Text("SteamCMD installation cancelled.").foregroundStyle(.secondary)
        case .failed(let issue):
            VStack(alignment: .leading, spacing: 8) {
                Label(issue.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
                if issue.kind == .rosettaRequired {
                    Link("Apple’s Rosetta installation guide", destination: URL(string: "https://support.apple.com/en-us/102527")!)
                }
                if issue.kind == .securityApprovalRequired || issue.kind == .invalidSignature {
                    Link("Apple’s app security guide", destination: URL(string: "https://support.apple.com/en-us/102445")!)
                    Text("Signature checks remain required. Allow This SteamCMD authorizes only the exact downloaded copy after confirmation; it never disables global Gatekeeper or re-signs code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func requestInstall() {
        guard !controlsDisabled else { return }
        if setup.retainedCandidateURL != nil { setup.retryInstallation() }
        else if managedExists { confirmsReplacement = true }
        else {
            lastActionWasInstall = true
            lastSelection = nil
            setup.install()
        }
    }

    private func chooseExisting() {
        guard !controlsDisabled else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate SteamCMD")
        panel.message = String(localized: "Choose steamcmd, steamcmd.sh, or the complete macOS SteamCMD installation folder.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastSelection = url
        lastActionWasInstall = false
        setup.selectExisting(at: url)
    }

    private func prepareApproval() {
        guard !controlsDisabled else { return }
        preparingApproval = true
        approvalError = nil
        Task {
            defer { preparingApproval = false }
            do {
                approvalCandidate = try await setup.prepareApproval()
                confirmsApproval = true
            } catch { approvalError = error.localizedDescription }
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
