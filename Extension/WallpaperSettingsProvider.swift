import Foundation

// Codable layout verified against WallpaperSettingsViewModelsXPC on macOS 26.6.2.
// Reference: https://github.com/kageroumado/phosphene/tree/8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6
private struct WallpaperChoiceIdentity: Codable {
  var id: String
  var descriptor: WallpaperChoiceDescriptor
}
private struct WallpaperChoiceDescriptor: Codable {
  var provider: String
  var identifier: String
  var files: [URL]
  var configuration: Data
}
private struct WallpaperGroupIdentity: Codable { var id: String }
private enum WallpaperDisposability: Codable { case none }
private enum WallpaperRefreshPolicy: Codable { case `default` }
private enum WallpaperContentBadge: Codable { case video }
private enum WallpaperThumbnail: Codable { case image(url: URL) }
private struct WallpaperChoice: Codable {
  var id: WallpaperChoiceIdentity
  var provider: String
  var identifier: String
  var name: String
  var localizedDescription: String
  var thumbnail: WallpaperThumbnail
  var isDownloaded: Bool
  var options: [String]
}
private struct WallpaperSettingsItem: Codable {
  var id: WallpaperChoiceIdentity
  var localizedName: String
  var thumbnail: WallpaperThumbnail
  var choice: WallpaperChoice
  var contentBadge: WallpaperContentBadge
  var showInTopLevel: Bool
  var sortOrder: Int
  var disposability: WallpaperDisposability
}
private struct WallpaperSettingsGroup: Codable {
  var id: WallpaperGroupIdentity
  var items: [WallpaperSettingsItem]
  var localizedName: String
  var disposability: WallpaperDisposability
  var sortOrder: Int
  var sortID: WallpaperGroupIdentity
  var shouldHideItemLabels: Bool
}
private struct WallpaperSettingsModel: Codable {
  var groups: [WallpaperSettingsGroup]
  var refreshPolicy: WallpaperRefreshPolicy
  var isModificationDisabled: Bool
}
private struct WallpaperSettingsModels: Codable {
  var desktop: WallpaperSettingsModel
  var screenSaver: WallpaperSettingsModel
}

@objc(MWEWallpaperSettingsArchive)
private final class WallpaperSettingsArchive: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  let value: WallpaperSettingsModels
  init(_ value: WallpaperSettingsModels) { self.value = value }
  required init?(coder: NSCoder) { return nil }
  func encode(with coder: NSCoder) {
    guard let archiver = coder as? NSKeyedArchiver else { return }
    do { try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels") } catch {
      archiver.failWithError(error)
    }
  }
}

enum WallpaperSettingsProvider {
  static func response() throws -> Any {
    guard let thumbnailURL = Bundle.main.url(forResource: "preview", withExtension: "jpg") else {
      throw WallpaperRuntime.failure("Wallpaper provider preview is missing.")
    }
    let provider = LockScreenConfiguration.extensionIdentifier
    let thumbnail = WallpaperThumbnail.image(url: thumbnailURL)
    let identity = WallpaperChoiceIdentity(
      id: "current",
      descriptor: WallpaperChoiceDescriptor(
        provider: provider, identifier: "current", files: [], configuration: Data("current".utf8)))
    let choice = WallpaperChoice(
      id: identity, provider: provider, identifier: "current", name: "WallpaperMachine",
      localizedDescription: String(localized: "Applied wallpaper, animated on the lock screen"), thumbnail: thumbnail,
      isDownloaded: true, options: [])
    let item = WallpaperSettingsItem(
      id: identity, localizedName: "WallpaperMachine", thumbnail: thumbnail, choice: choice,
      contentBadge: .video, showInTopLevel: true, sortOrder: 0, disposability: .none)
    let group = WallpaperSettingsGroup(
      id: WallpaperGroupIdentity(id: "WallpaperMachine"), items: [item],
      localizedName: "WallpaperMachine", disposability: .none, sortOrder: -100,
      sortID: WallpaperGroupIdentity(id: "com.apple.wallpaper.aerials"), shouldHideItemLabels: false
    )
    let model = WallpaperSettingsModel(
      groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    // This archive is produced and consumed here, never loaded from external input.
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: WallpaperSettingsArchive(
        WallpaperSettingsModels(desktop: model, screenSaver: model)), requiringSecureCoding: false)
    let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
    decoder.requiresSecureCoding = false
    decoder.decodingFailurePolicy = .setErrorAndReturn
    decoder.setClass(
      NSClassFromString("WallpaperSettingsViewModelsXPC"),
      forClassName: "MWEWallpaperSettingsArchive")
    let response = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    decoder.finishDecoding()
    if let error = decoder.error { throw error }
    guard let response else {
      throw WallpaperRuntime.failure("macOS rejected the wallpaper provider description.")
    }
    return response
  }
}
