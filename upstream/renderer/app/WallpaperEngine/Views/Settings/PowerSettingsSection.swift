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
