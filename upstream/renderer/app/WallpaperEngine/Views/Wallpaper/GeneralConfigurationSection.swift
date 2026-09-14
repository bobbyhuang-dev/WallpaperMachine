import SwiftUI

struct GeneralConfigurationSection: View {
    @Environment(BridgeStore.self) private var store

    let options: BridgeWallpaperOptionsSnapshot
    let snapshotRevision: UInt64
    let resetRevision: UInt64
    var onError: (Error) -> Void = { _ in }
    @State private var audioResponseEnabled: Bool
    @State private var bridgeActionInProgress = false

    init(
        options: BridgeWallpaperOptionsSnapshot,
        snapshotRevision: UInt64,
        resetRevision: UInt64,
        onError: @escaping (Error) -> Void = { _ in }
    ) {
        self.options = options
        self.snapshotRevision = snapshotRevision
        self.resetRevision = resetRevision
        self.onError = onError
        _audioResponseEnabled = State(initialValue: options.audioResponseEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Audio Response", isOn: Binding {
                audioResponseEnabled
            } set: { enabled in
                setAudioResponseEnabled(enabled)
            })
            .toggleStyle(.switch)
            .disabled(bridgeActionInProgress)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: options) { _, updatedOptions in
            reset(from: updatedOptions)
        }
        .onChange(of: snapshotRevision) { _, _ in
            reset(from: options)
        }
        .onChange(of: resetRevision) { _, _ in
            reset(from: options)
        }
    }

    private func reset(from options: BridgeWallpaperOptionsSnapshot) {
        audioResponseEnabled = options.audioResponseEnabled
    }

    private func setAudioResponseEnabled(_ enabled: Bool) {
        performAsyncBridgeAction {
            try await store.setAudioResponseEnabledAsync(wallpaperId: options.wallpaperId, enabled: enabled)
            self.audioResponseEnabled = enabled
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
            } catch {
                onError(error)
            }
            bridgeActionInProgress = false
        }
    }
}
