import SwiftUI

struct DisplayInformationView: View {
    @Environment(BridgeStore.self) private var store
    @State private var expandedDisplayIds = Set<String>()
    @State private var optionsByDisplayId: [String: BridgeWallpaperOptionsSnapshot] = [:]
    @State private var loadingDisplayIds = Set<String>()
    @State private var presentedError: BridgeErrorAlert?
    @State private var actionInProgress = false

    var body: some View {
        Group {
            if store.monitorInformationSnapshot.rows.isEmpty {
                ContentUnavailableView("No Active Wallpapers", systemImage: "display")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Active Wallpapers") {
                        ForEach(store.monitorInformationSnapshot.rows, id: \.displayId) { row in
                            DisclosureGroup(
                                isExpanded: binding(for: row.displayId)
                            ) {
                                activeWallpaperSettings(for: row)
                            } label: {
                                activeWallpaperHeader(for: row)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Display")
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("Bridge Error"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: store.snapshotRevision) { _, _ in
            pruneCachedOptions()
            reloadCachedOptions()
        }
    }

    @ViewBuilder
    private func activeWallpaperSettings(for row: BridgeMonitorInfoRow) -> some View {
        if isMirror(row) {
            mirrorSettings(for: row)
        } else if loadingDisplayIds.contains(row.displayId) {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        } else if let options = optionsByDisplayId[row.displayId] {
            WallpaperOptionsEditorView(
                options: options,
                displayIdFilter: row.displayId,
                displayRowsAreCollapsible: false,
                showsTitle: false,
                showsActions: true,
                scrollsContent: false,
                onError: presentError,
                onApply: { updatedOptions in
                    optionsByDisplayId[row.displayId] = updatedOptions
                }
            )
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            }
            .padding(.vertical, 8)
        } else {
            Text("Wallpaper settings could not be loaded.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
    }

    private func activeWallpaperHeader(for row: BridgeMonitorInfoRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.headline)
                    .lineLimit(2)
                if let targetTitle = row.mirrorTargetTitle {
                    Text("Mirrored \(targetTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(row.wallpaperTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !isMirror(row) {
                Button {
                    eject(row)
                } label: {
                    Label("Eject", systemImage: "eject")
                }
                .disabled(actionInProgress)
            }
        }
    }

    private func binding(for displayId: String) -> Binding<Bool> {
        Binding {
            expandedDisplayIds.contains(displayId)
        } set: { expanded in
            if expanded {
                expandedDisplayIds.insert(displayId)
                if let row = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == displayId }),
                   !isMirror(row)
                {
                    loadOptionsIfNeeded(for: displayId)
                }
            } else {
                expandedDisplayIds.remove(displayId)
            }
        }
    }

    private func loadOptionsIfNeeded(for displayId: String) {
        guard optionsByDisplayId[displayId] == nil,
              !loadingDisplayIds.contains(displayId),
              let row = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == displayId })
        else {
            return
        }

        loadOptions(for: row, force: false)
    }

    private func loadOptions(for row: BridgeMonitorInfoRow, force: Bool) {
        guard force || optionsByDisplayId[row.displayId] == nil else {
            return
        }
        guard !loadingDisplayIds.contains(row.displayId) else {
            return
        }
        if force,
           let updatedOptions = store.wallpaperOptionsSnapshot,
           updatedOptions.wallpaperId == row.wallpaperId
        {
            optionsByDisplayId[row.displayId] = updatedOptions
            return
        }

        loadingDisplayIds.insert(row.displayId)
        Task {
            do {
                let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: row.wallpaperId)
                optionsByDisplayId[row.displayId] = options
                presentedError = nil
            } catch {
                presentError(error)
            }
            loadingDisplayIds.remove(row.displayId)
        }
    }

    private func eject(_ row: BridgeMonitorInfoRow) {
        guard !actionInProgress else {
            return
        }

        actionInProgress = true
        Task {
            do {
                try await store.ejectWallpaperFromDisplayAsync(
                    displayId: row.displayId,
                    wallpaperId: row.wallpaperId
                )
                expandedDisplayIds.remove(row.displayId)
                optionsByDisplayId[row.displayId] = nil
                presentedError = nil
            } catch {
                presentError(error)
            }
            actionInProgress = false
        }
    }

    private func pruneCachedOptions() {
        let activeDisplayIds = Set(store.monitorInformationSnapshot.rows.map(\.displayId))
        expandedDisplayIds.formIntersection(activeDisplayIds)
        optionsByDisplayId = optionsByDisplayId.filter { activeDisplayIds.contains($0.key) }
        loadingDisplayIds.formIntersection(activeDisplayIds)
    }

    private func reloadCachedOptions() {
        for row in store.monitorInformationSnapshot.rows where optionsByDisplayId[row.displayId] != nil && !isMirror(row) {
            loadOptions(for: row, force: true)
        }
    }

    private func presentError(_ error: Error) {
        presentedError = BridgeErrorAlert(error: error)
    }

    private func isMirror(_ row: BridgeMonitorInfoRow) -> Bool {
        row.mirrorTargetDisplayId != nil
    }

    @ViewBuilder
    private func mirrorSettings(for row: BridgeMonitorInfoRow) -> some View {
        if let display = store.settingsSnapshot.displays.first(where: { $0.displayId == row.displayId }) {
            VStack(alignment: .leading, spacing: 12) {
                MirrorDisplayControls(
                    display: display,
                    onError: presentError
                )

            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            }
            .padding(.vertical, 8)
        } else {
            Text("Display settings could not be loaded.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
    }
}

private struct MirrorDisplayControls: View {
    @Environment(BridgeStore.self) private var store

    let display: BridgeDisplaySettingsRow
    let onError: (Error) -> Void

    @State private var scalingMode: BridgeScalingMode
    @State private var scalingFactorDraft: String
    @State private var targetFps: Double
    @State private var muted: Bool
    @State private var volume: Double
    @State private var actionInProgress = false
    @FocusState private var scalingFactorFocused: Bool

    init(display: BridgeDisplaySettingsRow, onError: @escaping (Error) -> Void) {
        self.display = display
        self.onError = onError
        _scalingMode = State(initialValue: display.scalingMode)
        _scalingFactorDraft = State(initialValue: Self.formattedScalingFactor(display.scalingFactor))
        _targetFps = State(initialValue: Double(Self.clampedTargetFps(display)))
        _muted = State(initialValue: display.muted)
        _volume = State(initialValue: Double(display.volume))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Scaling Mode", selection: Binding {
                scalingMode
            } set: { mode in
                setScalingMode(mode)
            }) {
                Text("None").tag(BridgeScalingMode.none)
                Text("Stretch").tag(BridgeScalingMode.stretch)
                Text("Match").tag(BridgeScalingMode.match)
                Text("Fill").tag(BridgeScalingMode.fill)
            }
            .pickerStyle(.menu)
            .disabled(actionInProgress)

            HStack {
                Text("Scaling Factor")
                Spacer()
                TextField("", text: $scalingFactorDraft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .focused($scalingFactorFocused)
                    .onSubmit(commitScalingFactor)
                    .onChange(of: scalingFactorFocused) { _, isFocused in
                        if !isFocused {
                            commitScalingFactor()
                        }
                    }
            }
            .disabled(actionInProgress)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Target Frame Rate")
                    Spacer()
                    EditableNumberField(
                        value: UInt32(targetFps.rounded()),
                        range: 1...display.maxFps
                    ) { editedValue in
                        setTargetFps(editedValue)
                    }
                }

                Slider(
                    value: Binding {
                        targetFps
                    } set: { value in
                        targetFps = value
                    },
                    in: 1...Double(display.maxFps),
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing {
                            setTargetFps(UInt32(targetFps.rounded()))
                        }
                    }
                )
            }
            .disabled(actionInProgress)

            VStack(alignment: .leading, spacing: 6) {
                Text("Volume")

                HStack {
                    Button {
                        setMuted(!muted)
                    } label: {
                        Label(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(actionInProgress)

                    Slider(
                        value: Binding {
                            volume
                        } set: { value in
                            volume = value
                        },
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing {
                                setVolume(Float(volume))
                            }
                        }
                    )
                    .disabled(muted || actionInProgress)
                    .opacity(muted ? 0.45 : 1.0)
                }
            }
        }
        .onChange(of: display) { _, updatedDisplay in
            reset(from: updatedDisplay)
        }
    }

    private func reset(from display: BridgeDisplaySettingsRow) {
        scalingMode = display.scalingMode
        scalingFactorDraft = Self.formattedScalingFactor(display.scalingFactor)
        targetFps = Double(Self.clampedTargetFps(display))
        muted = display.muted
        volume = Double(display.volume)
    }

    private static func formattedScalingFactor(_ factor: Double) -> String {
        factor.formatted(.number.precision(.fractionLength(1...3)))
    }

    private static func clampedTargetFps(_ display: BridgeDisplaySettingsRow) -> UInt32 {
        min(max(display.targetFps, 1), display.maxFps)
    }

    private func commitScalingFactor() {
        let trimmed = scalingFactorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let factor = Double(trimmed), factor.isFinite, factor > 0 else {
            scalingFactorDraft = Self.formattedScalingFactor(display.scalingFactor)
            onError(ScalingFactorValidationError())
            return
        }

        performAsyncBridgeAction {
            try await store.setMirrorScalingFactorAsync(displayId: display.displayId, factor: factor)
            scalingFactorDraft = Self.formattedScalingFactor(factor)
            scalingFactorFocused = false
        }
    }

    private func setScalingMode(_ mode: BridgeScalingMode) {
        performAsyncBridgeAction {
            try await store.setMirrorScalingModeAsync(displayId: display.displayId, mode: mode)
            scalingMode = mode
        }
    }

    private func setTargetFps(_ fps: UInt32) {
        let fps = min(max(fps, 1), display.maxFps)
        performAsyncBridgeAction {
            try await store.setMirrorTargetFpsAsync(displayId: display.displayId, fps: fps)
            targetFps = Double(fps)
        }
    }

    private func setMuted(_ muted: Bool) {
        performAsyncBridgeAction {
            try await store.setMirrorMutedAsync(displayId: display.displayId, muted: muted)
            self.muted = muted
        }
    }

    private func setVolume(_ volume: Float) {
        performAsyncBridgeAction {
            try await store.setMirrorVolumeAsync(displayId: display.displayId, volume: volume)
            self.volume = Double(volume)
        }
    }

    private func performAsyncBridgeAction(_ action: @escaping () async throws -> Void) {
        guard !actionInProgress else {
            return
        }

        actionInProgress = true
        Task {
            do {
                try await action()
            } catch {
                onError(error)
            }
            actionInProgress = false
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
