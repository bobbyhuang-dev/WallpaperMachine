import XCTest

@testable import WallpaperMachine

@MainActor
final class AppThemeTests: XCTestCase {
  func testThemeSurvivesRecreationAndResetLeavesOtherPreferencesUntouched() throws {
    let name = "AppThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "unrelatedPreference")

    let store = AppThemeStore(defaults: defaults)
    try store.set("mode", value: "light")
    try store.set("accent", value: "#B43271")
    try store.set("tone", value: "warm")
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.mode, .light)
    XCTAssertEqual(restored.preferences.accent, "#b43271")
    XCTAssertEqual(restored.preferences.tone, .warm)

    restored.reset()
    let reset = AppThemeStore(defaults: defaults)
    XCTAssertEqual(reset.preferences.mode, .system)
    XCTAssertNotEqual(reset.preferences.accent, "#b43271")
    XCTAssertEqual(reset.preferences.tone, .neutral)
    XCTAssertTrue(defaults.bool(forKey: "unrelatedPreference"))
  }

  func testInvalidThemeChangeCannotOverwriteSavedPreferences() throws {
    let name = "AppThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppThemeStore(defaults: defaults)
    try store.set("mode", value: "dark")
    try store.set("accent", value: "#aa3366")
    let before = store.preferences
    for (key, value) in [
      ("mode", "sepia"), ("accent", "#fff';alert(1)//"), ("tone", "sepia"),
      ("background", "#ffffff"),
    ] {
      XCTAssertThrowsError(try store.set(key, value: value))
    }
    XCTAssertEqual(store.preferences, before)
    XCTAssertEqual(AppThemeStore(defaults: defaults).preferences, before)
  }

  func testDamagedSavedColorDoesNotDiscardValidAppearanceChoice() throws {
    let name = "AppThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(
      ["mode": "dark", "accent": "not-a-color", "tone": "warm"],
      forKey: AppThemeStore.defaultsKey)
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.mode, .dark)
    XCTAssertTrue(AppThemePreferences.validAccent(restored.preferences.accent))
    XCTAssertEqual(restored.preferences.tone, .warm)
  }
}
