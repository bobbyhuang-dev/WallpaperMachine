import AppKit
import Combine

struct AppThemePreferences: Equatable {
  enum Mode: String {
    case system, light, dark

    var appearance: NSAppearance? {
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
    }
  }

  enum Tone: String {
    case neutral, warm, cool
  }

  var mode: Mode = .system
  var accent = "#80bbff"
  var tone: Tone = .neutral

  var snapshot: [String: Any] {
    ["mode": mode.rawValue, "accent": accent, "tone": tone.rawValue]
  }

  static func validAccent(_ value: String) -> Bool {
    value.utf8.count == 7 && value.first == "#"
      && value.utf8.dropFirst().allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }
}

/// Native storage survives the panel's ephemeral WebKit data store and process recovery.
@MainActor
final class AppThemeStore: ObservableObject {
  static let shared = AppThemeStore()
  static let defaultsKey = "MacWallpaperEngine.appTheme"
  @Published private(set) var preferences: AppThemePreferences
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let saved = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
    var preferences = AppThemePreferences()
    if let mode = saved["mode"] as? String, let value = AppThemePreferences.Mode(rawValue: mode) {
      preferences.mode = value
    }
    if let accent = saved["accent"] as? String, AppThemePreferences.validAccent(accent) {
      preferences.accent = accent.lowercased()
    }
    if let tone = saved["tone"] as? String, let value = AppThemePreferences.Tone(rawValue: tone) {
      preferences.tone = value
    }
    self.preferences = preferences
  }

  func set(_ key: String, value: String) throws {
    var next = preferences
    switch key {
    case "mode":
      guard let mode = AppThemePreferences.Mode(rawValue: value) else {
        throw WebPanelRequest.invalid
      }
      next.mode = mode
    case "accent":
      guard AppThemePreferences.validAccent(value) else { throw WebPanelRequest.invalid }
      next.accent = value.lowercased()
    case "tone":
      guard let tone = AppThemePreferences.Tone(rawValue: value) else {
        throw WebPanelRequest.invalid
      }
      next.tone = tone
    default: throw WebPanelRequest.invalid
    }
    guard next != preferences else { return }
    defaults.set(next.snapshot, forKey: Self.defaultsKey)
    preferences = next
  }

  func reset() {
    defaults.removeObject(forKey: Self.defaultsKey)
    preferences = AppThemePreferences()
  }
}
