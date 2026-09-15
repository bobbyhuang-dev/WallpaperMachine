import SwiftUI

struct DisplayInformationView: View {
    @Environment(BridgeStore.self) private var store
    @EnvironmentObject private var navigation: ControlPanelNavigation
    @State private var expandedDisplayIds = Set<String>()
    @State private var optionsCache: [OptionsKey: CachedOptions] = [:]
    @State private var requestGeneration: UInt64 = 0
    @State private var presentedError: BridgeErrorAlert?
    @State private var actionInProgress = false

    private struct OptionsKey: Hashable {
        let displayID: String
        let wallpaperID: String

        init(_ row: BridgeMonitorInfoRow) {
            displayID = row.displayId
            wallpaperID = row.wallpaperId
        }
    }

    private struct CachedOptions {
        let generation: UInt64
        var options: BridgeWallpaperOptionsSnapshot?
        var isLoading: Bool
        var errorMessage: String?
    }

    var body: some View {
        Group {
            if store.settingsSnapshot.displays.isEmpty {
                ContentUnavailableView(
                    "No Displays",
                    systemImage: "display",
                    description: Text("Check your display connections, then refresh displays in Library.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Displays") {
                        ForEach(store.settingsSnapshot.displays, id: \.displayId) { display in
                            let row = monitorRow(for: display.displayId)
                            if display.mode == .mirror || row != nil {
                                DisclosureGroup(isExpanded: binding(for: display.displayId)) {
                                    if display.mode == .mirror {
                                        mirrorSettings(for: display)
                                    } else if let row, !isMirror(row) {
                                        activeWallpaperSettings(for: row)
                                    }
                                } label: {
                                    displayHeader(for: display, row: row)
                                }
                            } else {
                                displayHeader(for: display, row: nil)
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
        .onAppear {
            pruneCachedOptions()
            reloadExpandedOptions()
        }
        .onChange(of: store.snapshotRevision) { _, _ in
            pruneCachedOptions()
            reloadExpandedOptions()
        }
    }

    @ViewBuilder
    private func activeWallpaperSettings(for row: BridgeMonitorInfoRow) -> some View {
        let key = OptionsKey(row)
        let cached = optionsCache[key]
        VStack(alignment: .leading, spacing: 12) {
            if let message = cached?.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Wallpaper settings could not be loaded.", systemImage: "exclamationmark.triangle")
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry") {
                        loadOptions(for: key, force: true)
                    }
                    .accessibilityLabel(Text("Retry wallpaper settings for \(row.title)"))
                }
            }

            if let cached, let options = cached.options {
                WallpaperOptionsEditorView(
                    options: options,
                    displayIdFilter: key.displayID,
                    displayRowsAreCollapsible: false,
                    showsTitle: false,
                    showsActions: true,
                    scrollsContent: false,
                    onError: presentError,
                    onApply: { updatedOptions in
                        cacheAppliedOptions(updatedOptions, for: key, generation: cached.generation)
                    }
                )
                .id(key)
                .disabled(actionInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil || cached.errorMessage != nil)
            } else if cached?.errorMessage == nil {
                ProgressView("Loading wallpaper settings…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task {
                        loadOptions(for: key, force: false)
                    }
            }
        }
        .padding(.vertical, 12)
    }

    private func displayHeader(
        for display: BridgeDisplaySettingsRow,
        row: BridgeMonitorInfoRow?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(display.title)
                    .font(.headline)
                    .lineLimit(2)
                if let row {
                    Text(row.wallpaperTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("No wallpaper assigned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !display.enabled {
                    Label("Disabled", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let targetTitle = row?.mirrorTargetTitle {
                    Text("Mirrored \(targetTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if display.mode == .mirror {
                    Text("Mirror displays use their source display’s wallpaper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Choose Wallpaper") {
                        chooseWallpaper(for: display.displayId)
                    }
                    .disabled(!display.enabled || display.mode != .standalone)
                    .accessibilityLabel(Text("Choose wallpaper for \(display.title)"))

                    if let row, display.mode == .standalone, !isMirror(row) {
                        Button {
                            eject(row)
                        } label: {
                            Label("Eject", systemImage: "eject")
                        }
                        .disabled(actionInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil)
                        .accessibilityLabel(Text("Eject wallpaper from \(display.title)"))
                    }
                }

                if !display.enabled || display.mode != .standalone {
                    Button("Display Settings") {
                        navigation.selection = .settings
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func binding(for displayId: String) -> Binding<Bool> {
        Binding {
            expandedDisplayIds.contains(displayId)
        } set: { expanded in
            if expanded {
                expandedDisplayIds.insert(displayId)
                if let row = monitorRow(for: displayId), !isMirror(row) {
                    loadOptions(for: OptionsKey(row), force: true)
                }
            } else {
                expandedDisplayIds.remove(displayId)
            }
        }
    }

    private func chooseWallpaper(for displayID: String) {
        guard let display = store.settingsSnapshot.displays.first(where: { $0.displayId == displayID }),
              display.enabled, display.mode == .standalone else {
            return
        }
        navigation.targetDisplayID = displayID
        navigation.selection = .wallpaper
    }

    private func monitorRow(for displayID: String) -> BridgeMonitorInfoRow? {
        store.monitorInformationSnapshot.rows.first { $0.displayId == displayID }
    }

    private func isCurrentAssignment(_ key: OptionsKey) -> Bool {
        store.settingsSnapshot.displays.contains {
            $0.displayId == key.displayID && $0.mode == .standalone
        } && store.monitorInformationSnapshot.rows.contains {
            $0.displayId == key.displayID && $0.wallpaperId == key.wallpaperID && !isMirror($0)
        }
    }

    private func loadOptions(for key: OptionsKey, force: Bool) {
        guard isCurrentAssignment(key) else {
            return
        }
        if !force, let cached = optionsCache[key], cached.options != nil || cached.isLoading {
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        let snapshotRevision = store.snapshotRevision
        optionsCache[key] = CachedOptions(
            generation: generation,
            options: optionsCache[key]?.options,
            isLoading: true,
            errorMessage: nil
        )
        Task {
            let result: Result<BridgeWallpaperOptionsSnapshot, Error>
            do {
                result = .success(try await store.wallpaperOptionsSnapshotAsync(wallpaperId: key.wallpaperID))
            } catch {
                result = .failure(error)
            }

            guard var cached = optionsCache[key], cached.generation == generation else {
                return
            }
            guard isCurrentAssignment(key) else {
                optionsCache[key] = nil
                return
            }
            guard store.snapshotRevision == snapshotRevision else {
                loadOptions(for: key, force: true)
                return
            }

            cached.isLoading = false
            switch result {
            case .success(let options):
                if options.wallpaperId == key.wallpaperID {
                    cached.options = options
                } else {
                    cached.errorMessage = String(localized: "The loaded settings do not match this wallpaper. Retry.")
                }
            case .failure(let error):
                cached.errorMessage = error.localizedDescription
            }
            optionsCache[key] = cached
        }
    }

    private func cacheAppliedOptions(
        _ options: BridgeWallpaperOptionsSnapshot,
        for key: OptionsKey,
        generation: UInt64
    ) {
        guard options.wallpaperId == key.wallpaperID,
              isCurrentAssignment(key),
              optionsCache[key]?.generation == generation else {
            return
        }
        requestGeneration &+= 1
        optionsCache[key] = CachedOptions(
            generation: requestGeneration,
            options: options,
            isLoading: false,
            errorMessage: nil
        )
    }

    private func eject(_ row: BridgeMonitorInfoRow) {
        let key = OptionsKey(row)
        guard !actionInProgress, store.activatingWallpaperID == nil, store.applyingWallpaperID == nil, isCurrentAssignment(key) else {
            return
        }

        actionInProgress = true
        let errorRevision = store.latestBridgeErrorRevision
        Task {
            defer { actionInProgress = false }
            do {
                try await store.ejectWallpaperFromDisplayAsync(
                    displayId: key.displayID,
                    wallpaperId: key.wallpaperID
                )
                pruneCachedOptions()
                presentedError = nil
            } catch {
                if store.latestBridgeErrorRevision == errorRevision {
                    presentError(error)
                }
            }
        }
    }

    private func pruneCachedOptions() {
        let displayIDs = Set(store.settingsSnapshot.displays.map(\.displayId))
        expandedDisplayIds.formIntersection(displayIDs)
        optionsCache = optionsCache.filter { isCurrentAssignment($0.key) }
    }

    private func reloadExpandedOptions() {
        for displayID in expandedDisplayIds {
            if let row = monitorRow(for: displayID), !isMirror(row) {
                loadOptions(for: OptionsKey(row), force: true)
            }
        }
    }

    private func presentError(_ error: Error) {
        presentedError = BridgeErrorAlert(error: error)
    }

    private func isMirror(_ row: BridgeMonitorInfoRow) -> Bool {
        row.mirrorTargetDisplayId != nil
    }

    @ViewBuilder
    private func mirrorSettings(for display: BridgeDisplaySettingsRow) -> some View {
        MirrorDisplayControls(display: display, onError: presentError)
            .disabled(actionInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil)
            .padding(.vertical, 12)
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
            Text("Changes to this mirror display take effect immediately.")
                .font(.callout)
                .foregroundStyle(.secondary)

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
            .accessibilityLabel(Text("Scaling mode for \(display.title)"))
            .disabled(actionInProgress)

            HStack {
                Text("Scaling Factor")
                Spacer()
                TextField("", text: $scalingFactorDraft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .accessibilityLabel(Text("Scaling factor for \(display.title)"))
                    .accessibilityValue(Text("\(scalingFactorDraft) times"))
                    .focused($scalingFactorFocused)
                    .onSubmit(commitScalingFactor)
                    .onChange(of: scalingFactorFocused) { _, isFocused in
                        if !isFocused {
                            commitScalingFactor()
                        }
                    }
                Text("×")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .disabled(actionInProgress)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Target Frame Rate")
                    Spacer()
                    EditableNumberField(
                        value: UInt32(targetFps.rounded()),
                        range: 1...display.maxFps,
                        accessibilityName: String(localized: "Target frame rate for \(display.title)")
                    ) { editedValue in
                        setTargetFps(editedValue)
                    }
                    Text("FPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
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
                .accessibilityLabel(Text("Target frame rate for \(display.title)"))
                .accessibilityValue(Text("\(Int(targetFps.rounded())) FPS"))
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
                    .accessibilityLabel(Text(muted
                        ? String(localized: "Unmute \(display.title)")
                        : String(localized: "Mute \(display.title)")))
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
                    .accessibilityLabel(Text("Volume for \(display.title)"))
                    .accessibilityValue(Text(volume.formatted(.percent.precision(.fractionLength(0)))))
                    .disabled(muted || actionInProgress)
                    .opacity(muted ? 0.45 : 1.0)
                }
            }
        }
        .disabled(store.activatingWallpaperID != nil || store.applyingWallpaperID != nil)
        .onChange(of: display) { _, updatedDisplay in
            reset(from: updatedDisplay)
        }
    }

    private func reset(from display: BridgeDisplaySettingsRow) {
        scalingMode = display.scalingMode
        if !scalingFactorFocused {
            scalingFactorDraft = Self.formattedScalingFactor(display.scalingFactor)
        }
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
        guard !actionInProgress, store.activatingWallpaperID == nil, store.applyingWallpaperID == nil else {
            return
        }
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
        guard !actionInProgress,
              store.activatingWallpaperID == nil,
              store.applyingWallpaperID == nil,
              store.settingsSnapshot.displays.contains(where: { $0.displayId == display.displayId && $0.mode == .mirror }) else {
            return
        }

        actionInProgress = true
        let errorRevision = store.latestBridgeErrorRevision
        Task {
            defer { actionInProgress = false }
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

private struct BridgeErrorAlert: Identifiable {
    let id = UUID()
    let message: String

    init(error: Error) {
        self.message = error.localizedDescription
    }
}
