import SwiftUI

struct DisplayConfigurationSection: View {
    let options: BridgeWallpaperOptionsSnapshot
    var displayIdFilter: String?
    var rowsAreCollapsible = true
    @Binding var activeDisplayBridgeActionIds: Set<String>
    var onError: (Error) -> Void = { _ in }

    private var rows: [BridgeDisplayConfigRow] {
        if let displayIdFilter {
            return options.displayConfigurations.filter { $0.displayId == displayIdFilter }
        }
        return options.displayConfigurations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("No display configuration loaded.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ForEach(rows, id: \.displayId) { row in
                    DisplayConfigurationRow(
                        wallpaperId: options.wallpaperId,
                        row: row,
                        collapsible: rowsAreCollapsible,
                        activeDisplayBridgeActionIds: $activeDisplayBridgeActionIds,
                        onError: onError
                    )
                    .id("\(options.wallpaperId)-\(row.displayId)")
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct DisplayConfigurationRow: View {
    @Environment(BridgeStore.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    let wallpaperId: String
    let row: BridgeDisplayConfigRow
    let collapsible: Bool
    @Binding var activeDisplayBridgeActionIds: Set<String>
    let onError: (Error) -> Void
    @State private var scalingMode: BridgeScalingMode
    @State private var scalingFactor: Double
    @State private var targetFps: Double
    @State private var targetFpsIsEditing = false
    @State private var bridgeActionInProgress = false
    @FocusState private var scalingFactorFocused: Bool

    init(
        wallpaperId: String,
        row: BridgeDisplayConfigRow,
        collapsible: Bool,
        activeDisplayBridgeActionIds: Binding<Set<String>>,
        onError: @escaping (Error) -> Void
    ) {
        self.wallpaperId = wallpaperId
        self.row = row
        self.collapsible = collapsible
        _activeDisplayBridgeActionIds = activeDisplayBridgeActionIds
        self.onError = onError
        _scalingMode = State(initialValue: row.scalingMode)
        _scalingFactor = State(initialValue: row.scalingFactor)
        _targetFps = State(initialValue: Double(Self.clampedTargetFps(row)))
    }

    var body: some View {
        Group {
            if collapsible {
                DisclosureGroup(isExpanded: expanded) {
                    controls
                        .padding(.top, 8)
                } label: {
                    header
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    controls
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        }
        .onChange(of: row) { _, updatedRow in
            scalingMode = updatedRow.scalingMode
            scalingFactor = updatedRow.scalingFactor
            if !targetFpsIsEditing {
                targetFps = Double(Self.clampedTargetFps(updatedRow))
            }
        }
    }

    private var header: some View {
        HStack {
            Text(row.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if row.dirty || scalingDraft != nil {
                Text("Modified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scaling mode and frame rate changes take effect immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Scaling Mode", selection: Binding {
                scalingMode
            } set: { mode in
                performAsyncBridgeAction {
                    try await store.setScalingModeAsync(
                        wallpaperId: wallpaperId,
                        displayId: row.displayId,
                        mode: mode
                    )
                    scalingMode = mode
                }
            }) {
                Text("None").tag(BridgeScalingMode.none)
                Text("Stretch").tag(BridgeScalingMode.stretch)
                Text("Match").tag(BridgeScalingMode.match)
                Text("Fill").tag(BridgeScalingMode.fill)
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text("Scaling mode for \(row.title)"))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Scaling Factor")
                    Spacer()
                    TextField("", text: scalingText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 88)
                        .focused($scalingFactorFocused)
                        .accessibilityLabel(Text("Scaling factor for \(row.title)"))
                        .accessibilityValue(Text("\(scalingText.wrappedValue) times"))
                        .accessibilityHint(Text(scalingDraft?.errorMessage ?? String(localized: "Apply Changes saves the scaling factor.")))
                        .onSubmit(commitScalingFactor)
                }

                if let errorMessage = scalingDraft?.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Apply Changes saves the scaling factor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Target Frame Rate")
                    Spacer()
                    EditableNumberField(
                        value: UInt32(targetFps.rounded()),
                        range: 1...row.maxFps,
                        accessibilityName: String(localized: "Target frame rate for \(row.title)")
                    ) { editedValue in
                        setTargetFps(editedValue)
                    }
                }

                Slider(
                    value: $targetFps,
                    in: 1...Double(row.maxFps),
                    step: 1,
                    onEditingChanged: { editing in
                        targetFpsIsEditing = editing
                        if !editing {
                            setTargetFps(UInt32(targetFps.rounded()))
                        }
                    }
                )
                .accessibilityLabel(Text("Target frame rate for \(row.title)"))
                .accessibilityValue(Text("\(UInt32(targetFps.rounded()).formatted(.number.grouping(.never))) frames per second"))
            }
        }
        .disabled(actionsAreDisabled)
    }

    private var fieldKey: WallpaperEditorState.FieldKey {
        WallpaperEditorState.FieldKey(wallpaperID: wallpaperId, fieldID: row.displayId)
    }

    private var scalingDraft: WallpaperEditorState.ScalingDraft? {
        store.editorState.scalingDrafts[fieldKey]
    }

    private var scalingText: Binding<String> {
        let key = fieldKey
        return Binding {
            store.editorState.scalingDrafts[key]?.text
                ?? scalingFactor.formatted(WallpaperEditorState.scalingFormat(locale: locale))
        } set: { text in
            store.editorState.setScalingText(text, key: key, locale: locale)
        }
    }

    private var expanded: Binding<Bool> {
        let key = WallpaperEditorState.FieldKey(wallpaperID: wallpaperId, fieldID: "display:\(row.displayId)")
        return Binding {
            store.editorState.expandedSections[key] ?? true
        } set: { expanded in
            store.editorState.expandedSections[key] = expanded
        }
    }

    private var actionsAreDisabled: Bool {
        bridgeActionInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil
            || store.isWallpaperEditInProgress(id: wallpaperId)
    }

    private static func clampedTargetFps(_ row: BridgeDisplayConfigRow) -> UInt32 {
        min(max(row.targetFps, 1), row.maxFps)
    }

    private func commitScalingFactor() {
        let key = fieldKey
        guard let draft = store.editorState.scalingDrafts[key], let factor = draft.value else { return }

        performAsyncBridgeAction {
            try await store.editScalingFactorAsync(
                wallpaperId: wallpaperId,
                displayId: row.displayId,
                factor: factor
            )
            scalingFactor = factor
            if store.editorState.scalingDrafts[key]?.text == draft.text {
                store.editorState.clearScaling(key)
            }
            scalingFactorFocused = false
        }
    }

    private func setTargetFps(_ fps: UInt32) {
        let fps = min(max(fps, 1), row.maxFps)
        performAsyncBridgeAction {
            do {
                try await store.setTargetFpsAsync(
                    wallpaperId: wallpaperId,
                    displayId: row.displayId,
                    fps: fps
                )
                targetFps = Double(fps)
            } catch {
                targetFps = Double(Self.clampedTargetFps(row))
                throw error
            }
        }
    }

    private func performAsyncBridgeAction(_ action: @escaping () async throws -> Void) {
        guard isEnabled, !actionsAreDisabled else { return }

        let actionId = "\(wallpaperId):\(row.displayId)"
        let errorRevision = store.latestBridgeErrorRevision
        bridgeActionInProgress = true
        activeDisplayBridgeActionIds.insert(actionId)
        Task {
            defer {
                bridgeActionInProgress = false
                activeDisplayBridgeActionIds.remove(actionId)
            }
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

struct ScalingFactorValidationError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Enter a finite scaling factor greater than zero.")
    }
}
