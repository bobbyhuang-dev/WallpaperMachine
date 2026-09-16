import Combine
import SwiftUI

// Native menu commands share navigation with the bundled WebKit interface.
enum SidebarSelection: String {
  case wallpaper, workshop, display, settings
}

enum SettingsSection: String, CaseIterable {
  case general, appearance, displays, library, storage, about
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
  @Published var selection: SidebarSelection?
  @Published var targetDisplayID = "primary"
  @Published private(set) var settingsSection = SettingsSection.general
  @Published private(set) var settingsSectionToken: UInt64 = 0

  init(selection: SidebarSelection? = .wallpaper) { self.selection = selection }

  func revealSettingsSection(_ section: SettingsSection) {
    settingsSection = section
    settingsSectionToken &+= 1
  }
}

struct ControlPanelView: View {
  let store: BridgeStore
  @ObservedObject var navigation: ControlPanelNavigation
  let workshop: WorkshopStore
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
    WebControlPanel(store: store, navigation: navigation, workshop: workshop, updater: updater)
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}
