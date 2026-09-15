import Foundation

/// The app publishes a complete immutable asset revision before replacing this file.
/// The extension never reads draft options or the app's private configuration files.
struct LockScreenConfiguration: Codable, Equatable {
  static let extensionIdentifier = "app.mac-wallpaper-engine.wallpaper-extension"
  static let changedNotification = "app.mac-wallpaper-engine.lock-screen.changed"
  static let fileName = "configuration.json"
  static let supportedVersion = 1

  var version: Int = supportedVersion
  var revision: String = UUID().uuidString
  var scenes: [LockScreenScene]
}

struct LockScreenScene: Codable, Equatable {
  var displayID: UInt32
  var title: String
  /// Paths relative to the extension's Documents directory, never external URLs.
  var projectPath: String
  var assetsPath: String
  var previewPath: String?
  var fps: UInt32
  /// Native renderer values: none=0, stretch=1, fit=2, fill=3.
  var scalingMode: Int32
  var scalingFactor: Double
  var propertiesJSON: String?
  var paused: Bool
}

/// Written only after the system has acquired a GPU-ready non-preview surface.
struct LockScreenReadiness: Codable {
  var revision: String
  var displayID: UInt32
  var error: String?
}
