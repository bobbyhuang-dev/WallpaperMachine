import SwiftUI

private let projectURL = URL(string: "https://github.com/bigsaltyfishes/wallpaper-engine-for-macos.git")!

struct AboutSection: View {
    @Environment(BridgeStore.self) private var store

    var body: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("MacWallpaperEngine")
                    .font(.title3.bold())
                LabeledContent("App", value: appVersion)
                LabeledContent("Bridge", value: store.settingsSnapshot.bridgeVersion)
                LabeledContent("Core", value: store.settingsSnapshot.coreVersion)
                LabeledContent("Shader Pipeline", value: store.settingsSnapshot.shaderPipelineVersion)
                LabeledContent("Git", value: gitCommitHash)
                LabeledContent("Scene renderer") {
                    Link("bigsaltyfishes / Wallpaper Engine for macOS", destination: projectURL)
                }
                Text("An independent macOS client. Not affiliated with Wallpaper Engine or Valve. Built on the GPLv2-only open-source renderer; Workshop browsing is independently implemented. No warranty is provided.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("GNU General Public License v2", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")!)
            }
            .padding(.vertical, 8)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ""
    }

    private var gitCommitHash: String {
        store.settingsSnapshot.gitSha
    }
}
