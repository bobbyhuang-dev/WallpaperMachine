import SwiftUI

struct GeneralConfigurationSection: View {
    @Environment(BridgeStore.self) private var store
    @Environment(\.isEnabled) private var isEnabled

    let options: BridgeWallpaperOptionsSnapshot
    @Binding var bridgeActionInProgress: Bool
    var onError: (Error) -> Void = { _ in }
    @State private var audioResponseEnabled: Bool
    @State private var muted: Bool
    @State private var volume: Double
    @State private var volumeIsEditing = false

    init(
        options: BridgeWallpaperOptionsSnapshot,
        bridgeActionInProgress: Binding<Bool>,
        onError: @escaping (Error) -> Void = { _ in }
    ) {
        self.options = options
        _bridgeActionInProgress = bridgeActionInProgress
        self.onError = onError
        _audioResponseEnabled = State(initialValue: options.audioResponseEnabled)
        _muted = State(initialValue: options.muted)
        _volume = State(initialValue: Double(options.volume))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Changes take effect immediately. Audio settings affect this wallpaper on all displays.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Audio Response", isOn: Binding {
                audioResponseEnabled
            } set: { enabled in
                setAudioResponseEnabled(enabled)
            })
            .toggleStyle(.switch)
            .accessibilityLabel(Text("Audio response for \(options.title)"))
            .accessibilityValue(audioResponseEnabled ? Text("On") : Text("Off"))
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Reacts to sound playing in other apps, not the microphone. macOS asks for system audio recording access when an enabled wallpaper starts. Wallpaper volume and mute do not affect this input.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if bridgeActionInProgress {
                ProgressView("Updating audio response…")
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text(volume.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        setMuted(!muted)
                    } label: {
                        Label(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(muted ? Text("Unmute \(options.title)") : Text("Mute \(options.title)"))
                    .accessibilityValue(muted ? Text("Muted") : Text("Unmuted"))

                    Slider(
                        value: $volume,
                        in: 0...1,
                        onEditingChanged: { editing in
                            volumeIsEditing = editing
                            if !editing {
                                setVolume(Float(volume))
                            }
                        }
                    )
                    .disabled(muted)
                    .accessibilityLabel(Text("Volume for \(options.title)"))
                    .accessibilityValue(Text(volume.formatted(.percent.precision(.fractionLength(0)))))
                }
            }
        }
        .disabled(actionsAreDisabled)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: options) { _, updatedOptions in
            audioResponseEnabled = updatedOptions.audioResponseEnabled
            muted = updatedOptions.muted
            if !volumeIsEditing {
                volume = Double(updatedOptions.volume)
            }
        }
    }

    private var actionsAreDisabled: Bool {
        bridgeActionInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil
            || store.isWallpaperEditInProgress(id: options.wallpaperId)
    }

    private func setAudioResponseEnabled(_ enabled: Bool) {
        performAsyncBridgeAction {
            try await store.setAudioResponseEnabledAsync(wallpaperId: options.wallpaperId, enabled: enabled)
            audioResponseEnabled = enabled
        }
    }

    private func setMuted(_ muted: Bool) {
        performAsyncBridgeAction {
            try await store.setMutedAsync(wallpaperId: options.wallpaperId, muted: muted)
            self.muted = muted
        }
    }

    private func setVolume(_ volume: Float) {
        performAsyncBridgeAction {
            do {
                try await store.setVolumeAsync(wallpaperId: options.wallpaperId, volume: volume)
                self.volume = Double(volume)
            } catch {
                self.volume = Double(options.volume)
                throw error
            }
        }
    }

    private func performAsyncBridgeAction(_ action: @escaping () async throws -> Void) {
        guard isEnabled, !actionsAreDisabled else { return }

        let errorRevision = store.latestBridgeErrorRevision
        bridgeActionInProgress = true
        Task {
            defer { bridgeActionInProgress = false }
            do {
                try await action()
            } catch {
                if store.latestBridgeErrorRevision == errorRevision {
                    onError(error)
                }
            }
        }
    }
}
