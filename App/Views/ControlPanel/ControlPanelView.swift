import Combine
import SwiftUI

// Native menu commands share navigation with the bundled WebKit interface.
enum SidebarSelection: String {
  case wallpaper, workshop, display, settings
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
  @Published var selection: SidebarSelection?
  @Published var targetDisplayID = "primary"

  init(selection: SidebarSelection? = .wallpaper) { self.selection = selection }
}

struct ControlPanelView: View {
  let store: BridgeStore
  @ObservedObject var navigation: ControlPanelNavigation
  let workshop: WorkshopStore
  // Held so the app keeps one updater while the bundled interface has no update
  // surface. "Check for Updates…" still runs; its result is not shown yet.
  let updater: AppUpdateStore

  init(
    store: BridgeStore, navigation: ControlPanelNavigation, workshop: WorkshopStore,
    updater: AppUpdateStore
  ) {
    self.store = store
    self.navigation = navigation
    self.workshop = workshop
    self.updater = updater
  }

  var body: some View {
    WebControlPanel(store: store, navigation: navigation, workshop: workshop)
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}
