import AppKit
import SwiftUI

struct WallpaperPageView: View {
    @Environment(BridgeStore.self) private var store
    @EnvironmentObject private var navigation: ControlPanelNavigation
    @AppStorage("MacWallpaperEngine.favoriteWallpaperIDs") private var favoriteIDsData = Data()
    @State private var presentedError: BridgeErrorAlert?
    @State private var bridgeActionInProgress = false
    @State private var showImport = false
    @State private var statusMessage: String?
    @State private var statusWallpaperID: String?
    @State private var statusIsError = false
    @State private var wallpaperToDelete: BridgeWallpaperEntry?
    @State private var gridColumnCount = 1
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedWallpaperID: String?

    private let columns = [GridItem(.adaptive(minimum: 164, maximum: 240), spacing: 12, alignment: .top)]

    private var favoriteIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: favoriteIDsData)) ?? [])
    }

    private var actionsDisabled: Bool { bridgeActionInProgress || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil }

    private var filtersActive: Bool {
        navigation.libraryShowsActiveOnly || navigation.libraryShowsFavoritesOnly
            || navigation.libraryVisibleKinds.count != WallpaperKindFilter.allCases.count
            || !navigation.librarySearchText.isEmpty
    }

    private func wallpapers(favorites: Set<String>) -> [BridgeWallpaperEntry] {
        if let revealID = navigation.libraryRevealID {
            return store.librarySnapshot.wallpapers.filter { $0.id == revealID }
        }
        let query = navigation.librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.librarySnapshot.wallpapers.filter { wallpaper in
            navigation.libraryVisibleKinds.contains(WallpaperKindFilter(kind: wallpaper.kind))
                && (!navigation.libraryShowsActiveOnly || store.isWallpaperActive(id: wallpaper.id, displayId: navigation.targetDisplayID))
                && (!navigation.libraryShowsFavoritesOnly || favorites.contains(wallpaper.id))
                && (query.isEmpty || wallpaper.title.localizedStandardContains(query) || wallpaper.id.localizedStandardContains(query))
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    var body: some View {
        let favorites = favoriteIDs
        let visibleWallpapers = wallpapers(favorites: favorites)
        VStack(spacing: 0) {
            header(visibleCount: visibleWallpapers.count)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        activationStatus
                        if !store.librarySnapshot.wallpapers.isEmpty {
                            libraryLoadNotice.padding(.bottom, 12)
                        }
                        if navigation.libraryRevealID != nil {
                            Button {
                                navigation.libraryRevealID = nil
                                focusedWallpaperID = nil
                            } label: {
                                Label("Back to Results", systemImage: "arrow.backward")
                            }
                            .buttonStyle(.link)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        }

                        if visibleWallpapers.isEmpty {
                            emptyContent
                                .frame(maxWidth: .infinity, minHeight: 260)
                                .padding(16)
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(visibleWallpapers, id: \.id) { wallpaper in
                                    WallpaperCardView(
                                        wallpaper: wallpaper,
                                        isFavorite: favorites.contains(wallpaper.id),
                                        activeOnTarget: store.isWallpaperActive(id: wallpaper.id, displayId: navigation.targetDisplayID),
                                        onActivate: { apply(wallpaper) },
                                        toggleFavorite: { toggleFavorite(wallpaper.id) }
                                    )
                                    .id(wallpaper.id)
                                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                                        guard focusedWallpaperID == wallpaper.id,
                                              press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                                        return moveFocus(press.key, from: wallpaper.id, in: visibleWallpapers, proxy: proxy)
                                    }
                                    .contextMenu {
                                        Button("Select & Customize") { select(wallpaper) }
                                            .disabled(actionsDisabled)
                                        Button("Apply to Selected Display") { apply(wallpaper) }
                                            .disabled(actionsDisabled || store.activationNeedsRefresh)
                                        Button(favorites.contains(wallpaper.id) ? "Remove from Favorites" : "Add to Favorites") {
                                            toggleFavorite(wallpaper.id)
                                        }
                                        Divider()
                                        Button("Delete…", role: .destructive) { wallpaperToDelete = wallpaper }
                                            .disabled(actionsDisabled)
                                            .help("Move this wallpaper to Trash; original imported files are kept")
                                            .accessibilityIdentifier("library.delete.\(wallpaper.id)")
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([ClientPaths.libraryURL.appendingPathComponent(wallpaper.id)])
                                        }
                                    }
                                }
                            }
                            .environment(\.wallpaperCardFocus, $focusedWallpaperID)
                            .environment(\.wallpaperCardActivationDisabled, actionsDisabled || store.activationNeedsRefresh)
                            .scrollTargetLayout()
                            .onGeometryChange(for: Int.self) { geometry in
                                max(1, Int((geometry.size.width + 12) / (164 + 12)))
                            } action: { gridColumnCount = $0 }
                            .padding(12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition(id: scrollPosition(revealID: navigation.libraryRevealID), anchor: .top)
                .id(navigation.libraryRevealID)
                .onChange(of: focusedWallpaperID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImport = true } label: { Label("Import", systemImage: "plus") }
                    .help("Import videos, project folders, or an existing Steam library")
                    .disabled(actionsDisabled)
                Button(action: refreshLibrary) { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Scan your local library for changes")
                    .disabled(actionsDisabled || store.libraryLoadState == .loading)
            }
        }
        .onChange(of: navigation.librarySearchText) { _, _ in navigation.libraryRevealID = nil }
        .onChange(of: navigation.libraryVisibleKinds) { _, _ in navigation.libraryRevealID = nil }
        .onChange(of: navigation.libraryShowsActiveOnly) { _, _ in navigation.libraryRevealID = nil }
        .onChange(of: navigation.libraryShowsFavoritesOnly) { _, _ in navigation.libraryRevealID = nil }
        .onChange(of: visibleWallpapers) { _, wallpapers in
            if let focusedWallpaperID, !wallpapers.contains(where: { $0.id == focusedWallpaperID }) {
                self.focusedWallpaperID = nil
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

    @ViewBuilder private var activationStatus: some View {
        if let statusMessage, statusWallpaperID == nil || statusWallpaperID == store.appSnapshot.selectedWallpaperId {
            HStack(alignment: .top, spacing: 8) {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wallpaper.activationStatus")
                Spacer(minLength: 0)
                Button { self.statusMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss status")
            }
            .padding(12)
        }
    }

    private func header(visibleCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your collection").font(.title3.bold())
                Text("Click a wallpaper to apply it to the selected display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    navigation.libraryRevealID = nil
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Search Library")
                TextField("Search titles or Workshop IDs", text: $navigation.librarySearchText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .disableAutocorrection(true)
                    .focused($searchFocused)
                    .accessibilityIdentifier("library.search")
                if !navigation.librarySearchText.isEmpty {
                    Button { navigation.librarySearchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear library search")
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)) }

            HStack(spacing: 8) {
                Menu {
                    Toggle("Active Only", isOn: $navigation.libraryShowsActiveOnly)
                    Toggle("Favorites Only", isOn: $navigation.libraryShowsFavoritesOnly)
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
                Spacer(minLength: 0)
                if actionsDisabled { ProgressView().controlSize(.small) }
                Text("\(visibleCount) of \(store.librarySnapshot.wallpapers.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Showing \(visibleCount) of \(store.librarySnapshot.wallpapers.count) wallpapers")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var libraryLoadNotice: some View {
        switch store.libraryLoadState {
        case .loading:
            ProgressView("Refreshing library…")
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.top, 12)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Library refresh failed", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: refreshLibrary).disabled(actionsDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder private var emptyContent: some View {
        if store.librarySnapshot.wallpapers.isEmpty, store.libraryLoadState == .loading {
            ProgressView("Loading your library…")
        } else if case let .failed(message) = store.libraryLoadState, store.librarySnapshot.wallpapers.isEmpty {
            ControlPanelEmptyState("Couldn’t load your library", systemImage: "exclamationmark.triangle",
                description: Text(message)) {
                Button("Retry", action: refreshLibrary).disabled(actionsDisabled)
            }
        } else if navigation.libraryRevealID != nil {
            ControlPanelEmptyState("Wallpaper no longer available", systemImage: "questionmark.folder",
                description: Text("This wallpaper is no longer in your library. Refresh Library and retry.")) {
                Button("Refresh Library", action: refreshLibrary).disabled(actionsDisabled)
            }
        } else if store.librarySnapshot.wallpapers.isEmpty {
            ControlPanelEmptyState("Make your desktop your own", systemImage: "photo.on.rectangle.angled",
                description: Text("Import a video or Wallpaper Engine project, or find something new in Workshop. Your collection stays on this Mac.")) {
                VStack(spacing: 8) {
                    Button { showImport = true } label: { Label("Import Wallpapers…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .disabled(actionsDisabled)
                    Button("Browse Workshop") { navigation.selection = .workshop }
                }
            }
        } else {
            ControlPanelEmptyState("No matching wallpapers", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Try another search or clear your filters to see the rest of your collection.")) {
                Button("Clear Search & Filters", action: clearFilters)
            }
        }
    }

    private func scrollPosition(revealID: String?) -> Binding<String?> {
        Binding {
            revealID ?? navigation.libraryScrollID
        } set: { id in
            // A reveal has its own scroll view and must never overwrite the saved results anchor.
            guard revealID == nil, navigation.libraryRevealID == nil, let id else { return }
            navigation.libraryScrollID = id
        }
    }

    private func moveFocus(_ key: KeyEquivalent, from id: String, in wallpapers: [BridgeWallpaperEntry], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return .ignored }
        let offset: Int
        switch key {
        case .leftArrow: offset = -1
        case .rightArrow: offset = 1
        case .upArrow: offset = -gridColumnCount
        case .downArrow: offset = gridColumnCount
        default: return .ignored
        }
        let nextID = wallpapers[min(max(index + offset, 0), wallpapers.count - 1)].id
        proxy.scrollTo(nextID)
        focusedWallpaperID = nextID
        return .handled
    }

    private func refreshLibrary() {
        performAsyncBridgeAction(reportsFailure: false) {
            try await store.refreshLibraryAsync()
            statusMessage = String(localized: "Library refreshed")
        }
    }

    private func delete(_ wallpaper: BridgeWallpaperEntry) {
        wallpaperToDelete = nil
        performAsyncBridgeAction {
            try await store.deleteWallpaperAsync(id: wallpaper.id)
            if favoriteIDs.contains(wallpaper.id) { toggleFavorite(wallpaper.id) }
            statusMessage = String(localized: "Moved \(wallpaper.title.isEmpty ? wallpaper.id : wallpaper.title) to Trash")
        }
    }

    private func select(_ wallpaper: BridgeWallpaperEntry) {
        performAsyncBridgeAction { try await store.selectWallpaperAsync(id: wallpaper.id) }
    }

    private func apply(_ wallpaper: BridgeWallpaperEntry) {
        let targetID = navigation.targetDisplayID
        let targetTitle = store.settingsSnapshot.displays.first { $0.displayId == targetID }?.title ?? targetID
        performAsyncBridgeAction(wallpaperID: wallpaper.id) {
            try await store.activateWallpaperAsync(id: wallpaper.id, displayId: targetID)
            statusWallpaperID = wallpaper.id
            statusMessage = String(localized: "Applied to \(targetTitle)")
        }
    }

    private func toggleFavorite(_ id: String) {
        var ids = favoriteIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        if let data = try? JSONEncoder().encode(ids.sorted()) { favoriteIDsData = data }
    }

    private func clearFilters() {
        navigation.libraryRevealID = nil
        navigation.librarySearchText = ""
        navigation.libraryShowsActiveOnly = false
        navigation.libraryShowsFavoritesOnly = false
        navigation.libraryVisibleKinds = Set(WallpaperKindFilter.allCases)
    }

    private func binding(for filter: WallpaperKindFilter) -> Binding<Bool> {
        Binding { navigation.libraryVisibleKinds.contains(filter) } set: { isVisible in
            if isVisible { navigation.libraryVisibleKinds.insert(filter) } else { navigation.libraryVisibleKinds.remove(filter) }
        }
    }

    private func performAsyncBridgeAction(wallpaperID: String? = nil, reportsFailure: Bool = true, _ action: @escaping () async throws -> Void) {
        guard !actionsDisabled else { return }
        bridgeActionInProgress = true
        statusMessage = nil
        statusWallpaperID = nil
        statusIsError = false
        let errorRevision = store.latestBridgeErrorRevision
        Task {
            defer { bridgeActionInProgress = false }
            do {
                try await action()
                presentedError = nil
            } catch {
                guard reportsFailure, store.latestBridgeErrorRevision == errorRevision else { return }
                if let wallpaperID {
                    statusWallpaperID = wallpaperID
                    statusMessage = error.localizedDescription
                    statusIsError = true
                } else {
                    presentedError = BridgeErrorAlert(error: error)
                }
            }
        }
    }
}

private struct BridgeErrorAlert: Identifiable {
    let id = UUID()
    let message: String
    init(error: Error) { message = error.localizedDescription }
}

enum WallpaperKindFilter: String, CaseIterable, Identifiable, Hashable {
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

    var kindTitle: String {
        switch self {
        case .projectScene: String(localized: "Scene")
        case .video: String(localized: "Video")
        case .webpage: String(localized: "Web")
        case .unknown: String(localized: "Unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .projectScene: "sparkles.rectangle.stack"
        case .video: "film"
        case .webpage: "globe"
        case .unknown: "questionmark.square"
        }
    }
}
