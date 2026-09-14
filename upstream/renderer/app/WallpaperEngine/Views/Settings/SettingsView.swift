import SwiftUI

struct SettingsView: View {
    let workshop: WorkshopStore
    var body: some View {
        Form {
            LibrarySettingsSection(workshop: workshop)
            ProgramSettingsSection()
            PowerSettingsSection()
            DisplaySettingsSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
