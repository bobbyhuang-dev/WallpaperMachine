import XCTest

@testable import MacWallpaperEngine

@MainActor
final class AppLanguageTests: XCTestCase {
  /// A fresh suite. The app-domain `AppleLanguages` override is read back through the
  /// persistent domain because a suite's search list falls through to the global one.
  private struct Suite {
    let name = "AppLanguageTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }
    var appleLanguages: [String]? {
      defaults.persistentDomain(forName: name)?[AppLanguageStore.appleLanguagesKey] as? [String]
    }
    func tearDown() { defaults.removePersistentDomain(forName: name) }
  }

  func testFollowsTheSystemLanguageUntilTheUserChooses() throws {
    let suite = try Suite()
    defer { suite.tearDown() }
    let cases: [([String], String)] = [
      (["zh-CN"], "zh-Hans"), (["zh"], "zh-Hans"), (["zh-Hans-TW"], "zh-Hans"),
      (["fr", "zh-CN", "en"], "zh-Hans"), (["zh-TW"], "en"), (["zh-Hant-HK"], "en"),
      (["en-GB"], "en"), (["fr"], "en"), ([], "en"), (["zhgarbage"], "en"),
    ]
    for (system, expected) in cases {
      let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: system)
      XCTAssertEqual(store.preference, AppLanguageStore.systemChoice, "\(system)")
      XCTAssertEqual(store.effective.tag, expected, "\(system)")
    }
  }

  func testChoiceSurvivesRecreationAndReachesAppleLanguages() throws {
    let suite = try Suite()
    defer { suite.tearDown() }
    suite.defaults.set(true, forKey: "unrelatedPreference")
    let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en-US", "fr"])
    try store.set("zh-Hans")
    XCTAssertEqual(store.effective.tag, "zh-Hans")

    let restored = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en-US", "fr"])
    XCTAssertEqual(restored.preference, "zh-Hans")
    XCTAssertEqual(restored.effective.tag, "zh-Hans")
    // Foundation reads this list at launch; the choice must lead and the user's order follow.
    XCTAssertEqual(suite.appleLanguages, ["zh-Hans", "en-US", "fr"])

    try restored.set(AppLanguageStore.systemChoice)
    XCTAssertEqual(restored.effective.tag, "en")
    let system = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["zh-CN"])
    XCTAssertEqual(system.preference, AppLanguageStore.systemChoice)
    XCTAssertEqual(system.effective.tag, "zh-Hans")
    XCTAssertNil(suite.appleLanguages, "Returning to System must hand the language back to macOS")
    XCTAssertTrue(suite.defaults.bool(forKey: "unrelatedPreference"))
  }

  func testUnknownOrUnsafeTagsAreRefusedAndKeepTheSavedChoice() throws {
    let suite = try Suite()
    defer { suite.tearDown() }
    let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en"])
    try store.set("zh-Hans")
    for value in ["zh-TW", "zh-CN", "fr", "", "en';alert(1);//", "SYSTEM"] {
      XCTAssertThrowsError(try store.set(value), value)
    }
    XCTAssertEqual(store.preference, "zh-Hans")
    XCTAssertEqual(
      AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en"]).preference, "zh-Hans")
    XCTAssertEqual(suite.appleLanguages?.first, "zh-Hans")
  }

  func testDamagedSavedChoiceFallsBackToSystem() throws {
    let suite = try Suite()
    defer { suite.tearDown() }
    suite.defaults.set("tlh", forKey: AppLanguageStore.defaultsKey)
    let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["zh-CN"])
    XCTAssertEqual(store.preference, AppLanguageStore.systemChoice)
    XCTAssertEqual(store.effective.tag, "zh-Hans")
  }

  func testSnapshotOffersEveryShippedLanguageByItsOwnName() throws {
    let suite = try Suite()
    defer { suite.tearDown() }
    let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en"])
    let options = try XCTUnwrap(store.snapshot["options"] as? [[String: String]])
    XCTAssertEqual(options.map { $0["id"] }, AppLanguage.supported.map(\.tag))
    XCTAssertTrue(options.contains { $0["id"] == "zh-Hans" && $0["name"] == "简体中文" })
    XCTAssertTrue(options.contains { $0["id"] == "en" && $0["name"] == "English" })
    XCTAssertEqual(store.snapshot["preference"] as? String, AppLanguageStore.systemChoice)
    XCTAssertEqual(store.snapshot["effective"] as? String, "en")
    // The tests are hosted in the app, so its bundle is the one the picker describes.
    for option in options {
      let tag = try XCTUnwrap(option["id"])
      XCTAssertTrue(
        Bundle.main.localizations.contains(tag),
        "\(tag): the picker offers a language the app does not ship")
    }
  }
}
