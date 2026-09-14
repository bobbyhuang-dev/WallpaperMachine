import AppKit
import SwiftUI

struct WallpaperPageView: View {
    @Environment(BridgeStore.self) private var store
    @AppStorage("MacWallpaperEngine.favoriteWallpaperIDs") private var favoriteIDsData = Data()
    @State private var presentedError: BridgeErrorAlert?
    @State private var bridgeActionInProgress = false
    @State private var visibleKinds = Set(WallpaperKindFilter.allCases)
    @State private var showActiveOnly = false
    @State private var showFavoritesOnly = false
    @State private var showImport = false
    @State private var searchText = ""
    @State private var statusMessage: String?
    @State private var wallpaperToDelete: BridgeWallpaperEntry?

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 18, alignment: .top)]

    private var favoriteIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: favoriteIDsData)) ?? [])
    }

    private var filtersActive: Bool {
        showActiveOnly || showFavoritesOnly || visibleKinds.count != WallpaperKindFilter.allCases.count || !searchText.isEmpty
    }

    private var wallpapers: [BridgeWallpaperEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let favorites = favoriteIDs
        return store.librarySnapshot.wallpapers.filter { wallpaper in
            visibleKinds.contains(WallpaperKindFilter(kind: wallpaper.kind))
                && (!showActiveOnly || wallpaper.active)
                && (!showFavoritesOnly || favorites.contains(wallpaper.id))
                && (query.isEmpty || wallpaper.title.localizedStandardContains(query) || wallpaper.id.localizedStandardContains(query))
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    var body: some View {
        let visibleWallpapers = wallpapers
        let favorites = favoriteIDs
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your collection").font(.title2.bold())
                    Text("\(visibleWallpapers.count) \(visibleWallpapers.count == 1 ? "wallpaper" : "wallpapers") · Select to customize. Apply to your primary display.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if bridgeActionInProgress { ProgressView().controlSize(.small) }
                Toggle(isOn: $showFavoritesOnly) {
                    Label("Favorites", systemImage: showFavoritesOnly ? "heart.fill" : "heart")
                }
                .toggleStyle(.button)
                .help("Show only your favorite wallpapers")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            if let statusMessage {
                HStack {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { self.statusMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss status")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles or Workshop IDs", text: $searchText)
                    .textFieldStyle(.plain)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("library.search")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear library search")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 24).padding(.bottom, 16)
            Divider()

            if visibleWallpapers.isEmpty {
                ContentUnavailableView {
                    Label(filtersActive ? "No matching wallpapers" : "Make your desktop your own", systemImage: filtersActive ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle.angled")
                } description: {
                    Text(filtersActive
                         ? "Try another search or clear your filters to see the rest of your collection."
                         : "Import a video or Wallpaper Engine project, or find something new in Workshop. Your collection stays on this Mac.")
                } actions: {
                    if filtersActive {
                        Button("Clear Search & Filters", action: clearFilters)
                    } else {
                        Button { showImport = true } label: { Label("Import Wallpapers…", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(visibleWallpapers, id: \.id) { wallpaper in
                            WallpaperCardView(
                                wallpaper: wallpaper,
                                isFavorite: favorites.contains(wallpaper.id),
                                select: { select(wallpaper) },
                                apply: { apply(wallpaper) },
                                toggleFavorite: { toggleFavorite(wallpaper.id) },
                                delete: { wallpaperToDelete = wallpaper }
                            )
                            .disabled(bridgeActionInProgress)
                            .contextMenu {
                                Button("Select & Customize") { select(wallpaper) }
                                Button("Apply to Primary Display") { apply(wallpaper) }
                                    .disabled(!wallpaper.supported || bridgeActionInProgress)
                                Button(favorites.contains(wallpaper.id) ? "Remove from Favorites" : "Add to Favorites") {
                                    toggleFavorite(wallpaper.id)
                                }
                                Divider()
                                Button("Delete…", role: .destructive) { wallpaperToDelete = wallpaper }
                                    .disabled(bridgeActionInProgress)
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([ClientPaths.libraryURL.appendingPathComponent(wallpaper.id)])
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImport = true } label: { Label("Import", systemImage: "plus") }
                    .help("Import videos, project folders, or an existing Steam library")
                    .disabled(bridgeActionInProgress)
                Button {
                    performAsyncBridgeAction {
                        try await store.refreshLibraryAsync()
                        statusMessage = "Library refreshed"
                    }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Scan your local library for changes")
                    .disabled(bridgeActionInProgress)
                Menu {
                    Toggle("Active Only", isOn: $showActiveOnly)
                    Toggle("Favorites Only", isOn: $showFavoritesOnly)
                    Divider()
                    ForEach(WallpaperKindFilter.allCases) { filter in
                        Toggle(filter.title, isOn: binding(for: filter))
                    }
                    Divider()
                    Button("Clear Search & Filters", action: clearFilters)
                        .disabled(!filtersActive)
                } label: {
                    Label("Filter", systemImage: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showImport) {
            LibraryImportView().environment(store)
        }
        .alert("Delete wallpaper?", isPresented: Binding(
            get: { wallpaperToDelete != nil },
            set: { if !$0 { wallpaperToDelete = nil } }
        ), presenting: wallpaperToDelete) { wallpaper in
            Button("Move to Trash", role: .destructive) { delete(wallpaper) }
            Button("Cancel", role: .cancel) { wallpaperToDelete = nil }
        } message: { wallpaper in
            Text("“\(wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title)” will be moved from your library to the Mac’s Trash. If active, it will stop playing. Original imported files are kept. You can recover it from Trash.")
        }
        .alert(item: $presentedError) { error in
            Alert(title: Text("Couldn’t Complete Action"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
    }

    private func delete(_ wallpaper: BridgeWallpaperEntry) {
        wallpaperToDelete = nil
        performAsyncBridgeAction {
            try await store.deleteWallpaperAsync(id: wallpaper.id)
            if favoriteIDs.contains(wallpaper.id) { toggleFavorite(wallpaper.id) }
            statusMessage = "Moved \(wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title) to Trash"
        }
    }

    private func select(_ wallpaper: BridgeWallpaperEntry) {
        performAsyncBridgeAction { try await store.selectWallpaperAsync(id: wallpaper.id) }
    }

    private func apply(_ wallpaper: BridgeWallpaperEntry) {
        guard wallpaper.supported else { return }
        performAsyncBridgeAction {
            try await store.selectWallpaperAsync(id: wallpaper.id)
            try await store.setDisplayConfigEnabledAsync(wallpaperId: wallpaper.id, displayId: "primary", enabled: true)
            try await store.applyWallpaperOptionsAsync(wallpaperId: wallpaper.id)
            statusMessage = "Applied \(wallpaper.title) to your primary display"
        }
    }

    private func toggleFavorite(_ id: String) {
        var ids = favoriteIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        if let data = try? JSONEncoder().encode(ids.sorted()) { favoriteIDsData = data }
    }

    private func clearFilters() {
        searchText = ""
        showActiveOnly = false
        showFavoritesOnly = false
        visibleKinds = Set(WallpaperKindFilter.allCases)
    }

    private func binding(for filter: WallpaperKindFilter) -> Binding<Bool> {
        Binding { visibleKinds.contains(filter) } set: { isVisible in
            if isVisible { visibleKinds.insert(filter) } else { visibleKinds.remove(filter) }
        }
    }

    private func performAsyncBridgeAction(_ action: @escaping () async throws -> Void) {
        guard !bridgeActionInProgress else { return }
        bridgeActionInProgress = true
        statusMessage = nil
        Task {
            do {
                try await action()
                presentedError = nil
            } catch {
                presentedError = BridgeErrorAlert(error: error)
            }
            bridgeActionInProgress = false
        }
    }
}

private struct BridgeErrorAlert: Identifiable {
    let id = UUID()
    let message: String
    init(error: Error) { message = error.localizedDescription }
}

private enum WallpaperKindFilter: String, CaseIterable, Identifiable, Hashable {
    case projectScene, video, webpage, unknown
    var id: String { rawValue }

    init(kind: BridgeWallpaperKind) {
        switch kind {
        case .projectScene: self = .projectScene
        case .video: self = .video
        case .webpage: self = .webpage
        case .unknown: self = .unknown
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .projectScene: "Scenes"
        case .video: "Videos"
        case .webpage: "Web Projects"
        case .unknown: "Unknown Types"
        }
    }
}
