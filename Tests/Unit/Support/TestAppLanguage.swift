import Foundation

@testable import MacWallpaperEngine

extension AppLanguageStore {
  /// A store pinned to English for tests that read rendered labels.
  ///
  /// `WebPanelController` falls back to `AppLanguageStore.shared`, which reads the
  /// developer's own app-domain defaults and macOS language list, so a panel test
  /// that leaves the language implicit renders whatever the developer last chose in
  /// the app. Tests that inspect wording pass this store instead; tests that want a
  /// specific language build their own with `systemLanguages`.
  @MainActor
  static func english() -> AppLanguageStore {
    let suite = "app.mac-wallpaper-engine.tests.language-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return AppLanguageStore(defaults: defaults, systemLanguages: ["en"])
  }
}
