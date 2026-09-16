import Foundation
import Observation

@MainActor
@Observable
final class WallpaperEditorState {
    struct FieldKey: Hashable {
        let wallpaperID: String
        let fieldID: String
    }

    struct ScalingDraft {
        let text: String
        let value: Double?
        let errorMessage: String?
    }

    private(set) var scalingDrafts: [FieldKey: ScalingDraft] = [:]
    private(set) var propertyTextDrafts: [FieldKey: String] = [:]
    var expandedSections: [FieldKey: Bool] = [:]

    static func scalingFormat(locale: Locale = .current) -> FloatingPointFormatStyle<Double> {
        .number.locale(locale).grouping(.never).precision(.fractionLength(0...8))
    }

    func setScalingText(_ text: String, key: FieldKey, locale: Locale = .current) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Foundation's parse strategy accepts numeric prefixes (for example "1abc").
        // Check the complete decimal token before using the matching locale parser.
        let decimal = locale.decimalSeparator?.first ?? "."
        var sawDecimal = false
        var sawDigit = false
        var validToken = true
        for (index, character) in trimmed.enumerated() {
            if index == 0 && (character == "+" || character == "-") { continue }
            if character == decimal && !sawDecimal {
                sawDecimal = true
            } else if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                sawDigit = true
            } else {
                validToken = false
                break
            }
        }
        let strategy = FloatingPointParseStrategy(format: Self.scalingFormat(locale: locale), lenient: false)
        let value = try? strategy.parse(trimmed)
        if let value, value.isFinite, value > 0, validToken, sawDigit {
            scalingDrafts[key] = ScalingDraft(text: text, value: value, errorMessage: nil)
        } else {
            scalingDrafts[key] = ScalingDraft(text: text, value: nil,
                errorMessage: String(localized: "Enter a finite scaling factor greater than zero."))
        }
    }

    func setPropertyText(_ text: String, key: FieldKey) { propertyTextDrafts[key] = text }
    func clearScaling(_ key: FieldKey) { scalingDrafts.removeValue(forKey: key) }
    func clearPropertyText(_ key: FieldKey) { propertyTextDrafts.removeValue(forKey: key) }

    func hasPendingEdits(wallpaperID: String) -> Bool {
        scalingDrafts.keys.contains { $0.wallpaperID == wallpaperID }
            || propertyTextDrafts.keys.contains { $0.wallpaperID == wallpaperID }
    }

    func hasInvalidScaling(wallpaperID: String) -> Bool {
        scalingDrafts.contains { $0.key.wallpaperID == wallpaperID && $0.value.value == nil }
    }

    func discard(wallpaperID: String) {
        scalingDrafts = scalingDrafts.filter { $0.key.wallpaperID != wallpaperID }
        propertyTextDrafts = propertyTextDrafts.filter { $0.key.wallpaperID != wallpaperID }
    }
    func reconcile(wallpaperID: String, displayIDs: Set<String>? = nil, textPropertyIDs: Set<String>) {
        if let displayIDs {
            scalingDrafts = scalingDrafts.filter { $0.key.wallpaperID != wallpaperID || displayIDs.contains($0.key.fieldID) }
        }
        propertyTextDrafts = propertyTextDrafts.filter { $0.key.wallpaperID != wallpaperID || textPropertyIDs.contains($0.key.fieldID) }
    }
}
