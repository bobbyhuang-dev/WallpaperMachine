import SwiftUI

struct EditableNumberField: View {
    @Environment(\.isEnabled) private var isEnabled

    let value: UInt32
    let range: ClosedRange<UInt32>
    var accessibilityName: String = String(localized: "Target Frame Rate Value")
    var onCommit: (UInt32) -> Void = { _ in }

    @State private var isEditing = false
    @State private var draft = ""
    @State private var validationError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .focused($focused)
                    .accessibilityLabel(Text(accessibilityName))
                    .accessibilityValue(Text("\(draft) frames per second"))
                    .accessibilityHint(Text(validationError ?? String(localized: "Enter a whole number.")))
                    .onSubmit(commit)
                    .onChange(of: draft) { _, text in
                        if validationError != nil, parsedValue(text) != nil {
                            validationError = nil
                        }
                    }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused {
                            commit()
                        }
                    }
            } else {
                Button(action: beginEditing) {
                    Text(String(value))
                        .monospacedDigit()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text(accessibilityName))
                .accessibilityValue(Text("\(String(value)) frames per second"))
                .accessibilityHint(Text("Edit the frame rate."))
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
    }

    private func beginEditing() {
        guard isEnabled else { return }
        draft = String(value)
        validationError = nil
        isEditing = true
        focused = true
    }

    private func commit() {
        guard isEditing, isEnabled else { return }
        guard let parsed = parsedValue(draft) else {
            validationError = String(localized: "Enter a whole number.")
            return
        }

        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        validationError = nil
        isEditing = false
        focused = false
        onCommit(clamped)
    }

    private func parsedValue(_ text: String) -> UInt32? {
        UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
