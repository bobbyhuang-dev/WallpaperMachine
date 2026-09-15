import SwiftUI

struct PowerSettingsSection: View {
    @Environment(BridgeStore.self) private var store
    @State private var presentedError: BridgeErrorAlert?
    @State private var bridgeActionInProgress = false

    var body: some View {
        Section("Power Settings") {
            LabeledContent {
                Toggle("Pause wallpapers on battery", isOn: Binding {
                    store.settingsSnapshot.pauseOnBatteryPower
                } set: { enabled in
                    performAsyncBridgeAction {
                        try await store.setPauseOnBatteryPowerAsync(enabled: enabled)
                    }
                })
                .labelsHidden()
                .toggleStyle(.switch)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pause wallpapers on battery")
                    Text(
                        "Wallpaper playback pauses when the device is running on battery power and resumes automatically when connected to a power source. Playback can also be resumed manually from the menu bar."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(bridgeActionInProgress)
            if let lockScreen = store.lockScreenWallpaper {
                LabeledContent {
                    Toggle("Animate Lock Screen", isOn: Binding {
                        lockScreen.isRequested
                    } set: { enabled in
                        lockScreen.setEnabled(enabled)
                    })
                    .labelsHidden()
                    .toggleStyle(.switch)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Animate Lock Screen")
                        Text("Use the applied video or live scene on the macOS lock screen. Normal desktop wallpaper windows remain live. Playback respects pause and battery settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    if lockScreen.isBusy { ProgressView().controlSize(.small) }
                    Text(lockScreen.status)
                        .foregroundStyle(lockScreen.isEnabled ? Color.primary : Color.secondary)
                    Spacer()
                    if lockScreen.errorMessage != nil {
                        Button("Retry") { lockScreen.refresh() }
                            .disabled(lockScreen.isBusy)
                    }
                }
                .font(.caption)
                if let error = lockScreen.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Experimental: uses private macOS WallpaperExtensionKit and wallpaper-store formats, which may stop working after an OS update. Enabling replaces the native Desktop and Idle provider only on active wallpaper displays and reloads your wallpaper service. Disabling or quitting restores choices still owned by this app; external wallpaper changes are preserved. Requires additional disk space for isolated asset copies. Lock-screen rendering is not guaranteed on every macOS release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("Bridge Error"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func performAsyncBridgeAction(_ action: @escaping () async throws -> Void) {
        guard !bridgeActionInProgress else {
            return
        }

        bridgeActionInProgress = true
        Task {
            do {
                try await action()
                presentedError = nil
            } catch {
                presentedError = BridgeErrorAlert(error: error)
            }
            bridgeActionInProgress = false
        }
    }
}

private struct BridgeErrorAlert: Identifiable {
    let id = UUID()
    let message: String

    init(error: Error) {
        self.message = error.localizedDescription
    }
}
