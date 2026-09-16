import Foundation

/// macOS's "Click wallpaper to reveal desktop" option (System Settings ›
/// Desktop & Dock), stored by WindowManager as
/// `com.apple.WindowManager EnableStandardClickToShowDesktop`. Unset means
/// "Always"; `false` is the "Only in Stage Manager" choice. The app never
/// changes it on its own: it only reflects and applies the user's toggle.
struct DesktopClickRevealPreference {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let key = "EnableStandardClickToShowDesktop" as CFString

    /// `true` while a wallpaper click still slides windows aside.
    static var isEnabled: Bool {
        (CFPreferencesCopyAppValue(key, domain) as? Bool) ?? true
    }

    /// Writes the same value System Settings writes so the toggle round-trips there.
    static func setEnabled(_ enabled: Bool) throws {
        CFPreferencesSetAppValue(key, enabled ? kCFBooleanTrue : kCFBooleanFalse, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw WallpaperActionError(message: String(localized: "macOS did not accept the desktop click preference. Change “Click wallpaper to reveal desktop” in System Settings › Desktop & Dock instead."))
        }
    }
}
