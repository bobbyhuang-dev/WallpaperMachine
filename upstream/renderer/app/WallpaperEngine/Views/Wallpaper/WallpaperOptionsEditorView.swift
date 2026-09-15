import SwiftUI

struct WallpaperOptionsEditorView: View {
    @Environment(BridgeStore.self) private var store

    let options: BridgeWallpaperOptionsSnapshot
    var displayIdFilter: String?
    var displayRowsAreCollapsible = true
    var showsTitle = true
    var showsActions = true
    var scrollsContent = true
    var onError: (Error) -> Void = { _ in }
    var onApply: (BridgeWallpaperOptionsSnapshot) -> Void = { _ in }

    @State private var applyInProgress = false
    @State private var activeDisplayBridgeActionIds: Set<String> = []
    @State private var activePropertyBridgeActionIds: Set<String> = []
    @State private var generalBridgeActionInProgress = false

    var body: some View {
        VStack(spacing: 0) {
            if scrollsContent {
                ScrollView {
                    editorContent
                        .padding(16)
                }
            } else {
                editorContent
            }

            if showsActions {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let invalidDisplayTitle {
                        Text("Correct the scaling factor for \(invalidDisplayTitle) before applying.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if fieldsAreSaving {
                        Text("Wait for the current setting to finish saving.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Spacer()

                        Button("Revert") {
                            let wallpaperId = options.wallpaperId
                            performAsyncBridgeAction {
                                try await store.cancelWallpaperOptionsAsync(wallpaperId: wallpaperId)
                            }
                        }
                        .disabled(!hasPendingChanges || actionsAreDisabled)

                        Button("Apply Changes") {
                            let wallpaperId = options.wallpaperId
                            performAsyncBridgeAction {
                                try await store.applyWallpaperOptionsAsync(wallpaperId: wallpaperId)
                                if let updatedOptions = store.wallpaperOptionsSnapshot,
                                   updatedOptions.wallpaperId == wallpaperId
                                {
                                    onApply(updatedOptions)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasPendingChanges || hasInvalidScaling || actionsAreDisabled || store.activationNeedsRefresh)
                    }
                }
                .padding(14)
            }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsTitle {
                Text(options.title)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Apply Changes saves pending properties and scaling factor. Revert discards only pending changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: expansion("display", default: true)) {
                DisplayConfigurationSection(
                    options: options,
                    displayIdFilter: displayIdFilter,
                    rowsAreCollapsible: displayRowsAreCollapsible,
                    activeDisplayBridgeActionIds: $activeDisplayBridgeActionIds,
                    onError: onError
                )
            } label: {
                Label("Display Configuration", systemImage: "display.2")
                    .font(.headline)
            }

            DisclosureGroup(isExpanded: expansion("general", default: true)) {
                GeneralConfigurationSection(
                    options: options,
                    bridgeActionInProgress: $generalBridgeActionInProgress,
                    onError: onError
                )
                .id("\(options.wallpaperId)-general")
            } label: {
                Label("General Configuration", systemImage: "slider.horizontal.3")
                    .font(.headline)
            }

            DisclosureGroup(isExpanded: expansion("properties", default: !options.properties.isEmpty)) {
                WallpaperPropertiesSection(
                    options: options,
                    activePropertyBridgeActionIds: $activePropertyBridgeActionIds,
                    onError: onError
                )
            } label: {
                Label("Wallpaper Properties", systemImage: "info.circle")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(applyInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil)
    }

    private var hasPendingChanges: Bool {
        options.dirty || store.editorState.hasPendingEdits(wallpaperID: options.wallpaperId)
    }

    private var hasInvalidScaling: Bool {
        store.editorState.hasInvalidScaling(wallpaperID: options.wallpaperId)
    }

    private var invalidDisplayTitle: String? {
        guard hasInvalidScaling else { return nil }
        if let row = options.displayConfigurations.first(where: {
            let key = WallpaperEditorState.FieldKey(wallpaperID: options.wallpaperId, fieldID: $0.displayId)
            return store.editorState.scalingDrafts[key]?.errorMessage != nil
        }) {
            return row.title
        }
        return store.editorState.scalingDrafts.first(where: {
            $0.key.wallpaperID == options.wallpaperId && $0.value.value == nil
        })?.key.fieldID
    }

    private var fieldsAreSaving: Bool {
        !activeDisplayBridgeActionIds.isEmpty || !activePropertyBridgeActionIds.isEmpty
            || generalBridgeActionInProgress || store.isWallpaperEditInProgress(id: options.wallpaperId)
    }

    private var actionsAreDisabled: Bool {
        applyInProgress || fieldsAreSaving || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil
    }

    private func expansion(_ section: String, default defaultValue: Bool) -> Binding<Bool> {
        let key = WallpaperEditorState.FieldKey(wallpaperID: options.wallpaperId, fieldID: "section:\(section)")
        return Binding {
            store.editorState.expandedSections[key] ?? defaultValue
        } set: { expanded in
            store.editorState.expandedSections[key] = expanded
        }
    }

    private func performAsyncBridgeAction(_ action: @escaping () async throws -> Void) {
        guard !actionsAreDisabled else { return }

        let errorRevision = store.latestBridgeErrorRevision
        applyInProgress = true
        Task {
            defer { applyInProgress = false }
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
