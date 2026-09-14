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

@MainActor
final class ControlPanelNavigation: ObservableObject {
    @Published var selection: SidebarSelection?

    init(selection: SidebarSelection? = .wallpaper) {
        self.selection = selection
    }
}

struct ControlPanelView: View {
    let store: BridgeStore
    let workshop: WorkshopStore
    @ObservedObject private var navigation: ControlPanelNavigation
    @State private var presentedError: ControlPanelError?

    init(store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore) {
        self.store = store
        self.navigation = navigation
        self.workshop = workshop
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section {
                    ForEach(SidebarSelection.allCases) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                            .padding(.vertical, 5)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MacWallpaperEngine").font(.headline).foregroundStyle(.primary)
                        Text("A little life on your desktop.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
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
                    }
                    .disabled(store.appSnapshot.activeWallpaperIds.isEmpty)
                    .accessibilityIdentifier("playback.toggle")
                }
                Section {
                    Text("\(store.librarySnapshot.wallpapers.count) \(store.librarySnapshot.wallpapers.count == 1 ? "wallpaper" : "wallpapers") in your library")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("MacWallpaperEngine")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            switch navigation.selection {
            case .wallpaper, .none:
                HStack(spacing: 0) {
                    WallpaperPageView().frame(minWidth: 470, maxWidth: .infinity)
                    if store.wallpaperOptionsSnapshot != nil {
                        Divider()
                        WallpaperInspectorView().frame(width: 320)
                    }
                }
            case .workshop:
                WorkshopPageView(workshop: workshop)
            case .display:
                DisplayInformationView()
            case .settings:
                SettingsView(workshop: workshop)
            }
        }
        .environment(store)
        .frame(minWidth: 1040, idealWidth: 1240, minHeight: 700, idealHeight: 800)
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
