import Combine
import SwiftUI

enum SidebarSelection: String, CaseIterable, Identifiable {
    case wallpaper
    case workshop
    case display
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .wallpaper: "Library"
        case .workshop: "Workshop"
        case .display: "Display"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .wallpaper: "photo.on.rectangle"
        case .workshop: "sparkle.magnifyingglass"
        case .display: "display.2"
        case .settings: "gearshape"
        }
    }
}

enum LibraryCategory: String, CaseIterable, Identifiable {
    case all, favorites, active, scenes, videos, webProjects, unknown

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All Wallpapers"
        case .favorites: "Favorites"
        case .active: "Active on selected display"
        case .scenes: "Scenes"
        case .videos: "Videos"
        case .webProjects: "Web Projects"
        case .unknown: "Unknown"
        }
    }

    var kind: WallpaperKindFilter? {
        switch self {
        case .all, .favorites, .active: nil
        case .scenes: .projectScene
        case .videos: .video
        case .webProjects: .webpage
        case .unknown: .unknown
        }
    }

    var systemImage: String {
        switch self {
        case .all: "photo.on.rectangle"
        case .favorites: "heart"
        case .active: "display.badge.checkmark"
        case .scenes: WallpaperKindFilter.projectScene.systemImage
        case .videos: WallpaperKindFilter.video.systemImage
        case .webProjects: WallpaperKindFilter.webpage.systemImage
        case .unknown: WallpaperKindFilter.unknown.systemImage
        }
    }
}

private enum ControlPanelSidebarItem: Hashable {
    case page(SidebarSelection)
    case category(LibraryCategory)
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
    @Published var selection: SidebarSelection?
    @Published var targetDisplayID = "primary"
    @Published var librarySearchText = ""
    @Published var libraryVisibleKinds = Set(WallpaperKindFilter.allCases)
    @Published var libraryShowsActiveOnly = false
    @Published var libraryShowsFavoritesOnly = false
    @Published var libraryScrollID: String?
    @Published var libraryRevealID: String?
    @Published var workshopScrollID: String?

    var libraryCategory: LibraryCategory {
        if libraryShowsActiveOnly { return .active }
        if libraryShowsFavoritesOnly { return .favorites }
        return LibraryCategory.allCases.first { category in
            guard let kind = category.kind else { return false }
            return libraryVisibleKinds == [kind]
        } ?? .all
    }

    func browseLibrary(_ category: LibraryCategory) {
        libraryShowsActiveOnly = category == .active
        libraryShowsFavoritesOnly = category == .favorites
        libraryVisibleKinds = category.kind.map { Set([$0]) } ?? Set(WallpaperKindFilter.allCases)
        libraryRevealID = nil
        libraryScrollID = nil
        selection = .wallpaper
    }

    func revealWallpaper(id: String, store: BridgeStore) async throws {
        guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
            throw WallpaperActionError(message: String(localized: "This wallpaper is no longer in your library. Refresh Library and retry."))
        }
        try await store.selectWallpaperAsync(id: id)
        libraryRevealID = id
        selection = .wallpaper
    }

    init(selection: SidebarSelection? = .wallpaper) {
        self.selection = selection
    }
}

struct ControlPanelView: View {
    let store: BridgeStore
    let workshop: WorkshopStore
    let updater: AppUpdateStore
    @ObservedObject private var navigation: ControlPanelNavigation
    @State private var presentedError: ControlPanelError?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("MacWallpaperEngine.favoriteWallpaperIDs") private var favoriteIDsData = Data()

    init(store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
         updater: AppUpdateStore) {
        self.store = store
        self.navigation = navigation
        self.workshop = workshop
        self.updater = updater
    }

    private var sidebarSelection: Binding<ControlPanelSidebarItem?> {
        Binding {
            switch navigation.selection {
            case .wallpaper, .none: .category(navigation.libraryCategory)
            case let .some(page): .page(page)
            }
        } set: { item in
            switch item {
            case let .category(category): navigation.browseLibrary(category)
            case let .page(page): navigation.selection = page
            case .none: break
            }
        }
    }

    private var categoryCounts: [LibraryCategory: Int] {
        let favorites = Set((try? JSONDecoder().decode([String].self, from: favoriteIDsData)) ?? [])
        var counts: [LibraryCategory: Int] = [.all: store.librarySnapshot.wallpapers.count]
        for wallpaper in store.librarySnapshot.wallpapers {
            if favorites.contains(wallpaper.id) { counts[.favorites, default: 0] += 1 }
            if store.isWallpaperActive(id: wallpaper.id, displayId: navigation.targetDisplayID) {
                counts[.active, default: 0] += 1
            }
            let category: LibraryCategory
            switch wallpaper.kind {
            case .projectScene: category = .scenes
            case .video: category = .videos
            case .webpage: category = .webProjects
            case .unknown: category = .unknown
            }
            counts[category, default: 0] += 1
        }
        return counts
    }

    var body: some View {
        @Bindable var workshop = workshop
        let counts = categoryCounts
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                Section {
                    Label(SidebarSelection.wallpaper.title, systemImage: SidebarSelection.wallpaper.systemImage)
                        .tag(ControlPanelSidebarItem.page(.wallpaper))
                    ForEach(LibraryCategory.allCases) { category in
                        HStack(spacing: 6) {
                            Label(category.title, systemImage: category.systemImage)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(counts[category, default: 0].formatted())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        .padding(.leading, 8)
                        .padding(.vertical, 2)
                        .tag(ControlPanelSidebarItem.category(category))
                        .accessibilityElement(children: .combine)
                        .help(category.title)
                        .accessibilityIdentifier("library.category.\(category.rawValue)")
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MacWallpaperEngine")
                            .font(.headline).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                            .help("MacWallpaperEngine")
                        Text("A little life on your desktop.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    ForEach([SidebarSelection.workshop, .display, .settings]) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .lineLimit(2)
                            .tag(ControlPanelSidebarItem.page(item))
                            .padding(.vertical, 2)
                    }
                }
                Section("Playback") {
                    Button {
                        Task {
                            do {
                                if store.appSnapshot.playbackState == .paused {
                                    try await store.playAllAsync()
                                } else {
                                    try await store.pauseAllAsync()
                                }
                            } catch { presentedError = ControlPanelError(error: error) }
                        }
                    } label: {
                        Label(store.appSnapshot.playbackState == .paused ? "Resume wallpapers" : "Pause wallpapers",
                              systemImage: store.appSnapshot.playbackState == .paused ? "play.fill" : "pause.fill")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(store.appSnapshot.activeWallpaperIds.isEmpty)
                    .accessibilityIdentifier("playback.toggle")
                }
                Section {
                    Text("\(store.librarySnapshot.wallpapers.count) wallpapers in your library")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("MacWallpaperEngine")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            VStack(spacing: 0) {
            switch navigation.selection {
            case .wallpaper, .none:
                HSplitView {
                    WallpaperPageView().frame(minWidth: 240, maxWidth: .infinity)
                    WallpaperInspectorView().frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                }
            case .workshop:
                HSplitView {
                    WorkshopPageView(workshop: workshop).frame(minWidth: 240, maxWidth: .infinity)
                    Group {
                        if let item = workshop.selectedItem {
                            WorkshopDetailView(item: item, workshop: workshop)
                        } else {
                            ScrollView {
                                ControlPanelEmptyState("Select a wallpaper", systemImage: "sidebar.right",
                                    description: Text("Select a Workshop wallpaper to see its details. Browsing does not change your desktop.")) {}
                                    .padding(16)
                            }
                        }
                    }.frame(minWidth: 280, idealWidth: 320, maxWidth: 420, maxHeight: .infinity)
                }
            case .display:
                DisplayInformationView()
            case .settings:
                SettingsView(workshop: workshop)
            }
                DownloadActivityView(workshop: workshop)
            }
        }
        .environment(store)
        .environment(workshop)
        .environment(updater)
        .environmentObject(navigation)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .onChange(of: store.latestBridgeErrorRevision) { _, _ in
            guard let message = store.latestBridgeErrorMessage else {
                return
            }
            presentedError = ControlPanelError(message: message)
        }
        .task {
            do {
                try await store.refreshAllAsync()
            } catch {
                presentedError = ControlPanelError(error: error)
            }
        }
        // Sheet content does not pick up the environment applied above, and Download Details is
        // where Steam Guard is completed: without these it traps on the first @Environment read.
        .sheet(isPresented: $workshop.showsDownloadDetails) {
            DownloadActivityDetails(workshop: workshop)
                .environment(store)
                .environment(workshop)
                .environmentObject(navigation)
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("Couldn’t complete that action"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct ControlPanelError: Identifiable {
    let id = UUID()
    let message: String

    init(error: Error) {
        self.message = error.localizedDescription
    }

    init(message: String) {
        self.message = message
    }
}

struct ControlPanelEmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text
    let actions: Actions

    init(_ title: LocalizedStringKey, systemImage: String, description: Text,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            VStack(spacing: 8) { actions }
        }
        .multilineTextAlignment(.center)
        .frame(minWidth: 0, maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

struct WallpaperTargetPicker: View {
    @Environment(BridgeStore.self) private var store
    @EnvironmentObject private var navigation: ControlPanelNavigation
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    private var selectedDisplayTitle: String {
        store.settingsSnapshot.displays.first { $0.displayId == navigation.targetDisplayID }?.title
            ?? String(localized: "Selected display unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply to").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Menu {
                    Picker("Apply to", selection: $navigation.targetDisplayID) {
                        if !store.settingsSnapshot.displays.contains(where: { $0.displayId == navigation.targetDisplayID }) {
                            Text("Selected display unavailable").tag(navigation.targetDisplayID)
                        }
                        ForEach(store.settingsSnapshot.displays, id: \.displayId) { display in
                            Text(display.title).tag(display.displayId)
                                .disabled(!display.enabled || display.mode != .standalone)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(selectedDisplayTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .help(selectedDisplayTitle)
                .accessibilityLabel("Apply to")
                .accessibilityValue(selectedDisplayTitle)
                .accessibilityIdentifier("wallpaper.targetDisplay")
                Button {
                    isRefreshing = true
                    Task {
                        defer { isRefreshing = false }
                        let revision = store.latestBridgeErrorRevision
                        do {
                            if store.activationNeedsRefresh { try await store.refreshAllAsync() }
                            else { try await store.refreshDisplaysAsync() }
                            errorMessage = nil
                        } catch {
                            if store.latestBridgeErrorRevision == revision { errorMessage = error.localizedDescription }
                        }
                    }
                } label: { Label("Refresh Displays", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .help("Refresh Displays")
            }
            .disabled(store.activatingWallpaperID != nil || store.applyingWallpaperID != nil || isRefreshing)
            if store.activationNeedsRefresh {
                Text("Refresh all wallpaper state before applying again.").font(.caption).foregroundStyle(.orange)
            }
            if let target = store.settingsSnapshot.displays.first(where: { $0.displayId == navigation.targetDisplayID }),
               !target.enabled || target.mode != .standalone {
                Text("Choose an enabled independent display.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Display Settings") { navigation.selection = .settings }.buttonStyle(.link)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
