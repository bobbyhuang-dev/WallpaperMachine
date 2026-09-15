import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WallpaperPropertiesSection: View {
    let options: BridgeWallpaperOptionsSnapshot
    @Binding var activePropertyBridgeActionIds: Set<String>
    var onError: (Error) -> Void = { _ in }

    private var groups: [WallpaperPropertyGroup] {
        WallpaperPropertyGroup.groups(from: options.properties)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if options.properties.isEmpty {
                Text(options.supported ? "No editable properties loaded." : "This wallpaper type is not editable.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Properties apply to this wallpaper on all displays and are saved with Apply Changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        if group.isUngrouped {
                            ForEach(group.properties, id: \.id) { property in
                                WallpaperPropertyRow(
                                    wallpaperId: options.wallpaperId,
                                    property: property,
                                    activePropertyBridgeActionIds: $activePropertyBridgeActionIds,
                                    onError: onError
                                )
                                .id("\(options.wallpaperId)-\(property.id)")
                            }
                        } else {
                            WallpaperPropertyDisclosureGroup(
                                wallpaperId: options.wallpaperId,
                                group: group,
                                activePropertyBridgeActionIds: $activePropertyBridgeActionIds,
                                onError: onError
                            )
                            .id("\(options.wallpaperId)-group-\(group.id)")
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct WallpaperPropertyGroup: Identifiable {
    let id: String
    let titleHtml: String?
    let properties: [BridgePropertyDescriptor]

    var isUngrouped: Bool {
        titleHtml == nil
    }

    static func groups(from properties: [BridgePropertyDescriptor]) -> [Self] {
        var groups: [Self] = []
        var currentId = "ungrouped"
        var currentTitle: String?
        var currentProperties: [BridgePropertyDescriptor] = []
        var groupOrdinal = 0

        func flush() {
            guard !currentProperties.isEmpty else {
                return
            }
            groups.append(Self(
                id: currentId,
                titleHtml: currentTitle,
                properties: currentProperties
            ))
            currentProperties = []
        }

        for property in properties {
            if property.kind == .group {
                flush()
                groupOrdinal += 1
                currentId = "\(groupOrdinal)-\(property.id)"
                currentTitle = property.labelHtml
            } else {
                currentProperties.append(property)
            }
        }

        flush()
        return groups
    }
}

private struct WallpaperPropertyDisclosureGroup: View {
    @Environment(BridgeStore.self) private var store

    let wallpaperId: String
    let group: WallpaperPropertyGroup
    @Binding var activePropertyBridgeActionIds: Set<String>
    let onError: (Error) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(group.properties, id: \.id) { property in
                    WallpaperPropertyRow(
                        wallpaperId: wallpaperId,
                        property: property,
                        activePropertyBridgeActionIds: $activePropertyBridgeActionIds,
                        onError: onError
                    )
                }
            }
            .padding(.top, 8)
        } label: {
            propertyGroupLabel
                .font(.headline)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        }
    }

    private var expanded: Binding<Bool> {
        let key = WallpaperEditorState.FieldKey(wallpaperID: wallpaperId, fieldID: "property-group:\(group.id)")
        return Binding {
            store.editorState.expandedSections[key] ?? false
        } set: { expanded in
            store.editorState.expandedSections[key] = expanded
        }
    }

    @ViewBuilder
    private var propertyGroupLabel: some View {
        if let titleHtml = group.titleHtml,
           !titleHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            RichTextLabel(html: RichTextLabel.sanitizedPropertyLabelHtml(titleHtml))
        } else {
            Text("Group")
        }
    }
}

private struct WallpaperPropertyRow: View {
    @Environment(BridgeStore.self) private var store
    @Environment(\.isEnabled) private var isEnabled

    let wallpaperId: String
    let property: BridgePropertyDescriptor
    @Binding var activePropertyBridgeActionIds: Set<String>
    let onError: (Error) -> Void
    private let accessibilityName: String
    @State private var boolValue: Bool
    @State private var numberValue: Double
    @State private var textValue: String
    @State private var colorValue: Color
    @State private var numberIsEditing = false
    @State private var bridgeActionInProgress = false

    init(
        wallpaperId: String,
        property: BridgePropertyDescriptor,
        activePropertyBridgeActionIds: Binding<Set<String>>,
        onError: @escaping (Error) -> Void
    ) {
        self.wallpaperId = wallpaperId
        self.property = property
        _activePropertyBridgeActionIds = activePropertyBridgeActionIds
        self.onError = onError
        accessibilityName = RichTextLabel.plainPropertyLabel(property.labelHtml, fallback: property.id)
        _boolValue = State(initialValue: property.value.boolValue ?? false)
        _numberValue = State(initialValue: property.value.numberValue ?? 0)
        _textValue = State(initialValue: property.value.stringValue ?? "")
        _colorValue = State(initialValue: property.value.colorValue ?? .white)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                propertyLabel

                if property.dirty || store.editorState.propertyTextDrafts[fieldKey] != nil {
                    Text("Modified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if property.canRestoreDefaults {
                    Button("Restore Defaults", action: restoreDefault)
                        .buttonStyle(.link)
                        .accessibilityLabel(Text("Restore defaults for \(accessibilityName)"))
                        .disabled(actionsAreDisabled)
                }
            }

            control
                .disabled(!property.enabled || actionsAreDisabled)
        }
        .onChange(of: property.value) { _, _ in
            synchronizeValue()
        }
        .onChange(of: property.kind) { _, _ in
            synchronizeValue()
        }
    }

    @ViewBuilder
    private var propertyLabel: some View {
        if property.labelHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(property.id)
        } else {
            RichTextLabel(html: RichTextLabel.sanitizedPropertyLabelHtml(property.labelHtml))
        }
    }

    @ViewBuilder
    private var control: some View {
        switch property.kind {
        case .bool:
            Toggle(accessibilityName, isOn: Binding {
                boolValue
            } set: { value in
                edit(.bool(value: value)) {
                    boolValue = value
                }
            })
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(Text(accessibilityName))
            .accessibilityValue(boolValue ? Text("On") : Text("Off"))
        case .slider:
            let metadata = sliderMetadata
            HStack {
                Slider(
                    value: $numberValue,
                    in: metadata.range,
                    step: metadata.step,
                    onEditingChanged: { editing in
                        numberIsEditing = editing
                        if !editing {
                            edit(.number(value: numberValue))
                        }
                    }
                )
                .accessibilityLabel(Text(accessibilityName))
                .accessibilityValue(Text(numberValue.formatted(.number.grouping(.never).precision(.fractionLength(metadata.precision)))))
                Text(numberValue.formatted(.number.grouping(.never).precision(.fractionLength(metadata.precision))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        case .textInput:
            TextField("Value", text: propertyText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text(accessibilityName))
                .accessibilityValue(Text(propertyText.wrappedValue))
                .onSubmit(commitPropertyText)
        case .color:
            ColorPicker(accessibilityName, selection: Binding {
                colorValue
            } set: { value in
                colorValue = value
                let color = NSColor(value).usingColorSpace(.sRGB) ?? .white
                edit(
                    .colorRgb(
                        red: Double(color.redComponent),
                        green: Double(color.greenComponent),
                        blue: Double(color.blueComponent)
                    )
                )
            })
            .labelsHidden()
            .accessibilityLabel(Text(accessibilityName))
            .accessibilityValue(colorAccessibilityValue)
        case .directory:
            HStack(spacing: 8) {
                Text(textValue.isEmpty ? String(localized: "No image selected") : textValue)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(textValue.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !textValue.isEmpty {
                    Button("Clear") {
                        edit(.string(value: "")) {
                            textValue = ""
                        }
                    }
                    .accessibilityLabel(Text("Clear image for \(accessibilityName)"))
                }

                Button(action: chooseTexture) {
                    Label("Choose Image", systemImage: "photo.badge.plus")
                }
                .accessibilityLabel(Text("Choose image for \(accessibilityName)"))
                .accessibilityValue(Text(textValue.isEmpty ? String(localized: "No image selected") : textValue))
            }
        case .combo, .text, .group, .unknown:
            Text("Unsupported property type.")
                .foregroundStyle(.secondary)
        }
    }

    private var fieldKey: WallpaperEditorState.FieldKey {
        WallpaperEditorState.FieldKey(wallpaperID: wallpaperId, fieldID: property.id)
    }

    private var propertyText: Binding<String> {
        let key = fieldKey
        return Binding {
            store.editorState.propertyTextDrafts[key] ?? property.value.stringValue ?? ""
        } set: { text in
            store.editorState.setPropertyText(text, key: key)
        }
    }

    private var colorAccessibilityValue: Text {
        let color = NSColor(colorValue).usingColorSpace(.sRGB) ?? .white
        let format = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0...1))
        let red = Double(color.redComponent).formatted(format)
        let green = Double(color.greenComponent).formatted(format)
        let blue = Double(color.blueComponent).formatted(format)
        return Text("Red \(red), green \(green), blue \(blue)")
    }

    private var actionsAreDisabled: Bool {
        bridgeActionInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil
            || store.isWallpaperEditInProgress(id: wallpaperId)
    }

    private func synchronizeValue() {
        boolValue = property.value.boolValue ?? false
        if !numberIsEditing {
            numberValue = property.value.numberValue ?? 0
        }
        textValue = property.value.stringValue ?? ""
        colorValue = property.value.colorValue ?? .white
    }

    private func commitPropertyText() {
        let key = fieldKey
        guard let text = store.editorState.propertyTextDrafts[key] else { return }
        edit(.string(value: text)) {
            if store.editorState.propertyTextDrafts[key] == text {
                store.editorState.clearPropertyText(key)
            }
        }
    }

    private func restoreDefault() {
        let key = fieldKey
        let pendingText = store.editorState.propertyTextDrafts[key]
        performAsyncBridgeAction {
            try await store.restorePropertyDefaultAsync(wallpaperId: wallpaperId, propertyId: property.id)
            if store.editorState.propertyTextDrafts[key] == pendingText {
                store.editorState.clearPropertyText(key)
            }
            boolValue = property.defaultValue.boolValue ?? false
            numberValue = property.defaultValue.numberValue ?? 0
            textValue = property.defaultValue.stringValue ?? ""
            colorValue = property.defaultValue.colorValue ?? .white
        }
    }

    private func edit(_ value: BridgePropertyValue, afterSuccess: (() -> Void)? = nil) {
        performAsyncBridgeAction {
            do {
                try await store.editPropertyAsync(wallpaperId: wallpaperId, propertyId: property.id, value: value)
                afterSuccess?()
            } catch {
                synchronizeValue()
                throw error
            }
        }
    }

    private func chooseTexture() {
        guard isEnabled, !actionsAreDisabled else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.title = String(localized: "Choose Image")

        if panel.runModal() == .OK,
           let url = panel.url
        {
            let path = url.path
            edit(.string(value: path)) {
                textValue = path
            }
        }
    }

    private func performAsyncBridgeAction(_ action: @escaping () async throws -> Void) {
        guard isEnabled, !actionsAreDisabled else { return }

        let actionId = "\(wallpaperId):\(property.id)"
        let errorRevision = store.latestBridgeErrorRevision
        bridgeActionInProgress = true
        activePropertyBridgeActionIds.insert(actionId)
        Task {
            defer {
                bridgeActionInProgress = false
                activePropertyBridgeActionIds.remove(actionId)
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

    private var sliderMetadata: SliderMetadata {
        SliderMetadata(property.slider)
    }
}

private struct SliderMetadata {
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    init(_ metadata: BridgeSliderMetadata?) {
        let lowerBound = metadata?.min ?? 0
        let upperBound = metadata?.max ?? 1
        range = lowerBound <= upperBound ? lowerBound...upperBound : 0...1
        let rawStep = metadata?.step ?? 0.01
        step = rawStep.isFinite && rawStep > 0 ? rawStep : 0.01
        precision = Swift.min(Int(metadata?.precision ?? 2), 12)
    }
}

private extension BridgePropertyValue {
    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var colorValue: Color? {
        if case let .colorRgb(red, green, blue) = self {
            return Color(red: red, green: green, blue: blue)
        }
        return nil
    }
}
