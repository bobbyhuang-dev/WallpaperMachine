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
    try store.set("icon", value: "night")
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.mode, .light)
    XCTAssertEqual(restored.preferences.accent, "#b43271")
    XCTAssertEqual(restored.preferences.tone, .warm)
    XCTAssertEqual(restored.preferences.icon, .night)

    restored.reset()
    let reset = AppThemeStore(defaults: defaults)
    XCTAssertEqual(reset.preferences.mode, .system)
    XCTAssertNotEqual(reset.preferences.accent, "#b43271")
    XCTAssertEqual(reset.preferences.tone, .neutral)
    XCTAssertEqual(reset.preferences.icon, .day)
    XCTAssertTrue(defaults.bool(forKey: "unrelatedPreference"))
  }

  func testInvalidThemeChangeCannotOverwriteSavedPreferences() throws {
    let name = "AppThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppThemeStore(defaults: defaults)
    try store.set("mode", value: "dark")
    try store.set("accent", value: "#aa3366")
    try store.set("icon", value: "minimal")
    let before = store.preferences
    for (key, value) in [
      ("mode", "sepia"), ("accent", "#fff';alert(1)//"), ("tone", "sepia"),
      ("icon", "../other"), ("background", "#ffffff"),
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
      ["mode": "dark", "accent": "not-a-color", "tone": "warm", "icon": "minimal"],
      forKey: AppThemeStore.defaultsKey)
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.mode, .dark)
    XCTAssertTrue(AppThemePreferences.validAccent(restored.preferences.accent))
    XCTAssertEqual(restored.preferences.tone, .warm)
    XCTAssertEqual(restored.preferences.icon, .minimal)
  }

  func testUnknownSavedIconDoesNotDiscardOtherPreferences() throws {
    let name = "AppThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(
      ["mode": "dark", "accent": "#aa3366", "tone": "cool", "icon": "unavailable"],
      forKey: AppThemeStore.defaultsKey)
    let restored = AppThemeStore(defaults: defaults)
    XCTAssertEqual(restored.preferences.icon, .day)
    XCTAssertEqual(restored.preferences.mode, .dark)
    XCTAssertEqual(restored.preferences.accent, "#aa3366")
    XCTAssertEqual(restored.preferences.tone, .cool)
  }
}
