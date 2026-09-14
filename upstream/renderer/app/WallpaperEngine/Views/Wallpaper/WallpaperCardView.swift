import SwiftUI

struct WallpaperCardView: View {
    let wallpaper: BridgeWallpaperEntry
    let isFavorite: Bool
    let select: () -> Void
    let apply: () -> Void
    let toggleFavorite: () -> Void
    let delete: () -> Void
    @State private var previewImage: NSImage?

    private var kindTitle: String {
        switch wallpaper.kind {
        case .projectScene: String(localized: "Scene")
        case .video: String(localized: "Video")
        case .webpage: String(localized: "Web")
        case .unknown: String(localized: "Unknown")
        }
    }

    private var fallbackSystemImage: String {
        switch wallpaper.kind {
        case .projectScene: "sparkles.rectangle.stack"
        case .video: "film"
        case .webpage: "globe"
        case .unknown: "questionmark.square"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 12) {
                    Color(nsColor: .controlBackgroundColor)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay {
                            if let previewImage {
                                Image(nsImage: previewImage)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: fallbackSystemImage)
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .clipped()
                        .overlay(alignment: .topLeading) {
                            if wallpaper.active {
                                Label("Active", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(10)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)

                    Text(wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title)
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(kindTitle)
                        if !wallpaper.supported {
                            Text("· Not playable").foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                        if wallpaper.selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title)
            .accessibilityValue("\(kindTitle)\(wallpaper.selected ? ", selected" : "")\(wallpaper.active ? ", active" : "")\(wallpaper.supported ? "" : ", not playable")")
            .accessibilityHint("Select to view display settings and wallpaper properties")
            .help("Select to inspect wallpaper properties and display settings")

            HStack {
                Button(action: apply) {
                    Label("Apply", systemImage: "desktopcomputer")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!wallpaper.supported)
                .help(wallpaper.supported ? "Apply to your primary display, preserving other display assignments" : "This wallpaper type cannot be played by the renderer")
                .accessibilityLabel("Apply \(wallpaper.title) to primary display")

                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
                }
                .accessibilityLabel(isFavorite ? "Remove \(wallpaper.title) from favorites" : "Add \(wallpaper.title) to favorites")
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive, action: delete) {
                Label("Delete…", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .help("Move this wallpaper to Trash; original imported files are kept")
            .accessibilityLabel("Delete \(wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title)")
            .accessibilityIdentifier("library.delete.\(wallpaper.id)")
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(wallpaper.selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: wallpaper.selected ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .task(id: wallpaper.previewPath) {
            previewImage = nil
            guard let path = wallpaper.previewPath else { return }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
            guard !Task.isCancelled, let data else { return }
            previewImage = NSImage(data: data)
        }
    }
}
