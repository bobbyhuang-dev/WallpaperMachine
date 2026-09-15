import SwiftUI

struct WallpaperCardView: View {
    let wallpaper: BridgeWallpaperEntry
    let isFavorite: Bool
    let activeOnTarget: Bool
    let onActivate: () -> Void
    let toggleFavorite: () -> Void
    @Environment(\.wallpaperCardFocus) private var gridFocus
    @Environment(\.wallpaperCardActivationDisabled) private var activationDisabled

    private var title: String { wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title }
    private var kind: WallpaperKindFilter { WallpaperKindFilter(kind: wallpaper.kind) }

    private var playbackTitle: String {
        if activeOnTarget { return String(localized: "Active on selected display") }
        if wallpaper.active { return String(localized: "Active on another display") }
        if !wallpaper.supported { return String(localized: "Not playable") }
        return String(localized: "Not active")
    }

    private var playbackSymbol: String {
        if activeOnTarget { return "display.badge.checkmark" }
        if wallpaper.active { return "display.2" }
        return wallpaper.supported ? "stop.circle" : "exclamationmark.triangle"
    }

    private var accessibilityStatus: String {
        var values = [kind.kindTitle, playbackTitle]
        if wallpaper.selected { values.append(String(localized: "Selected")) }
        if !wallpaper.supported, wallpaper.active { values.append(String(localized: "Not playable")) }
        return values.joined(separator: ", ")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let gridFocus {
                activationButton.focused(gridFocus, equals: wallpaper.id)
            } else {
                activationButton
            }

            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? String(localized: "Remove \(title) from favorites") : String(localized: "Add \(title) to favorites"))
            .help(isFavorite ? String(localized: "Remove from favorites") : String(localized: "Add to favorites"))
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(wallpaper.selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: wallpaper.selected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private var activationButton: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 0) {
                WallpaperPreviewView(wallpaper: wallpaper)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.kindTitle)
                        Label(playbackTitle, systemImage: playbackSymbol)
                            .lineLimit(2, reservesSpace: true)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 28)
                }
                .padding(12)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(activationDisabled)
        .onKeyPress(.return, phases: .down) { press in
            guard !activationDisabled,
                  press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
            onActivate()
            return .handled
        }
        .accessibilityIdentifier("library.item.\(wallpaper.id)")
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityStatus)
        .accessibilityAddTraits(wallpaper.selected ? .isSelected : [])
        .accessibilityHint(wallpaper.supported
            ? String(localized: "Apply to the selected display and view wallpaper settings")
            : String(localized: "View details about why this wallpaper cannot be played"))
        .help(wallpaper.supported
            ? String(localized: "Apply to the selected display and view wallpaper settings")
            : String(localized: "This wallpaper type cannot be played by the renderer"))
    }
}

extension EnvironmentValues {
    @Entry var wallpaperCardFocus: FocusState<String?>.Binding? = nil
    @Entry var wallpaperCardActivationDisabled = false
}

struct WallpaperPreviewView: View {
    let wallpaper: BridgeWallpaperEntry
    @State private var previewImage: NSImage?

    var body: some View {
        Color(nsColor: .controlBackgroundColor)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: WallpaperKindFilter(kind: wallpaper.kind).systemImage)
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: wallpaper.previewPath) {
                previewImage = nil
                guard let path = wallpaper.previewPath else { return }
                let data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: URL(fileURLWithPath: path))
                }.value
                guard !Task.isCancelled, let data else { return }
                previewImage = NSImage(data: data)
            }
    }
}
