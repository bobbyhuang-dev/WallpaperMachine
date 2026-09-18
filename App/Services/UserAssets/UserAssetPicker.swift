import AppKit
import Foundation
import UniformTypeIdentifiers

/// Chooses the file or folder a `file` / `directory` wallpaper property points at.
///
/// A protocol rather than a concrete call so no test ever opens a panel: unit tests
/// drive `UserAssetStore` with plain URLs and never construct `UserAssetPicker`.
@MainActor protocol UserAssetPicking: AnyObject {
    func chooseFile(filter: UserAssetFilter, propertyTitle: String) -> URL?
    func chooseDirectory(propertyTitle: String) -> URL?
}

@MainActor final class UserAssetPicker: UserAssetPicking {
    func chooseFile(filter: UserAssetFilter, propertyTitle: String) -> URL? {
        let panel = configuredPanel(propertyTitle: propertyTitle)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        let types = filter.allowedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseDirectory(propertyTitle: String) -> URL? {
        let panel = configuredPanel(propertyTitle: propertyTitle)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func configuredPanel(propertyTitle: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = propertyTitle
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.showsHiddenFiles = false
        // The application target is not sandboxed — only `Extension/WallpaperExtension.entitlements`
        // sets `com.apple.security.app-sandbox`. A plain POSIX path therefore stays readable
        // across relaunches, so nothing here needs security-scoped bookmarks; do not add them.
        // The sandboxed lock-screen extension is a different matter: it cannot read a file the
        // user picked here, so staged user assets are a desktop-wallpaper feature only.
        return panel
    }
}
