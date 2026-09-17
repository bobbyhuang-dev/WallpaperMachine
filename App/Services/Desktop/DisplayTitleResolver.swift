import AppKit

/// Swaps the renderer's hardware display labels (`Vendor 1552 - Model 41055 (1 - Primary)`)
/// for the name macOS shows in System Settings, keeping the renderer's id/role suffix.
struct DisplayTitleResolver {
    /// Localized display names keyed by CoreGraphics display id and by display UUID.
    let names: @MainActor () -> [String: String]

    init(names: @escaping @MainActor () -> [String: String]) { self.names = names }

    /// Names from the attached screens, as `NSScreen.localizedName` reports them.
    static let system = DisplayTitleResolver {
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let id = SystemDesktopPictureWorkspace.id(screen) else { continue }
            names[id] = screen.localizedName
            if let number = UInt32(id),
               let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
                names[(CFUUIDCreateString(nil, uuid) as String).uppercased()] = screen.localizedName
            }
        }
        return names
    }

    /// Leaves renderer titles untouched.
    static let renderer = DisplayTitleResolver { [:] }

    /// Snapshot the current names once so a page payload resolves every title consistently.
    @MainActor func resolved() -> ResolvedDisplayTitles { ResolvedDisplayTitles(names: names()) }
}

struct ResolvedDisplayTitles {
    let names: [String: String]

    /// Renderer display ids are `primary`, a live CoreGraphics id, or `identity:{json}`; the live
    /// id also appears in the title's `(id - Role)` suffix, so every form can reach a screen name.
    func title(_ title: String, displayId: String) -> String {
        let suffix = Self.suffix(of: title)
        let candidates = [displayId, Self.liveId(in: suffix), Self.uuid(in: displayId)]
        for candidate in candidates.compactMap({ $0 }) {
            guard let name = names[candidate]?.trimmingCharacters(in: .whitespaces), !name.isEmpty
            else { continue }
            return suffix.isEmpty ? name : "\(name) \(suffix)"
        }
        return title
    }

    /// The renderer's trailing `(id - Role)` group.
    private static func suffix(of title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), open != trimmed.startIndex
        else { return "" }
        return String(trimmed[open...])
    }

    private static func liveId(in suffix: String) -> String? {
        let digits = suffix.dropFirst().prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static func uuid(in displayId: String) -> String? {
        guard displayId.hasPrefix("identity:"),
              let data = displayId.dropFirst("identity:".count).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = object["uuid"] as? String
        else { return nil }
        return uuid.uppercased()
    }
}
