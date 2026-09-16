import AppKit
import ExtensionFoundation

private final class WallpaperHandler: NSObject, WallpaperExtensionXPCProtocol {
  func acquire(withId identifier: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
    DispatchQueue.main.async {
      WallpaperController.shared.acquire(id: identifier, request: request, reply: reply)
    }
  }
  func update(withId identifier: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
    DispatchQueue.main.async {
      do {
        try WallpaperController.shared.update(id: identifier, request: request)
        reply(nil)
      } catch { reply(error) }
    }
  }
  func invalidate(withId identifier: Any?, reply: @escaping (Error?) -> Void) {
    DispatchQueue.main.async {
      WallpaperController.shared.invalidate(id: identifier)
      reply(nil)
    }
  }
  func snapshot(withId identifier: Any?, reply: @escaping (Any?, Error?) -> Void) {
    DispatchQueue.main.async { WallpaperController.shared.snapshot(id: identifier, reply: reply) }
  }
  func provideSettingsViewModels(
    withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void
  ) {
    do { reply(try WallpaperSettingsProvider.response(), nil) } catch {
      reply(nil, error)
      WallpaperRuntime.log("Settings unavailable: \(error.localizedDescription)")
    }
  }
  func isChoiceDownloaded(with choiceID: Any?, reply: @escaping (Bool, Error?) -> Void) {
    // The provider is installed locally; its manifest can still report no applied scene.
    reply(true, nil)
  }
  func selectedChoicesDidChange(for identifier: Any?, reply: @escaping (Error?) -> Void) {
    DispatchQueue.main.async {
      WallpaperController.shared.reload()
      reply(nil)
    }
  }
}

private struct NativeWallpaperConfiguration: AppExtensionConfiguration {
  func accept(connection: NSXPCConnection) -> Bool {
    guard WallpaperRuntime.accepts(connection) else {
      WallpaperRuntime.log("Rejected untrusted wallpaper host.")
      return false
    }
    do { try WallpaperRuntime.load() } catch {
      WallpaperRuntime.log(error.localizedDescription)
      return false
    }
    let interface = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
    let names = [
      "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
      "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
      "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperSettingsViewModelsXPC",
    ]
    let classes =
      NSSet(
        array: names.compactMap(NSClassFromString) + [
          NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self,
          NSError.self,
        ]) as! Set<AnyHashable>
    for (selector, indexes, reply) in [
      ("acquireWithId:request:reply:", [0, 1], false), ("acquireWithId:request:reply:", [0], true),
      ("updateWithId:request:reply:", [0, 1], false), ("invalidateWithId:reply:", [0], false),
      ("snapshotWithId:reply:", [0], false), ("snapshotWithId:reply:", [0], true),
      ("provideSettingsViewModelsWithContentTypes:reply:", [0], false),
      ("provideSettingsViewModelsWithContentTypes:reply:", [0], true),
      ("isChoiceDownloadedWith:reply:", [0], false),
      ("selectedChoicesDidChangeFor:reply:", [0], false),
    ] {
      for index in indexes {
        interface.setClasses(
          classes, for: NSSelectorFromString(selector), argumentIndex: index, ofReply: reply)
      }
    }
    connection.exportedInterface = interface
    connection.exportedObject = WallpaperHandler()
    // Surface lifetime is owned by WallpaperID, not transient settings/thumbnail connections.
    connection.resume()
    WallpaperRuntime.log("Accepted native host pid=\(connection.processIdentifier)")
    return true
  }
}

@main
final class MacWallpaperExtension: NSObject, AppExtension {
  override required init() {
    super.init()
    do {
      try WallpaperRuntime.load()
      if ProcessInfo.processInfo.environment["VK_ICD_FILENAMES"] == nil {
        // Packaged apps provide this resource. Local Homebrew builds use the same
        // installed ICD as scripts/build.py without relying on shell environment.
        let bundled = Bundle.main.url(forResource: "MoltenVK_icd", withExtension: "json")
        let homebrew = URL(
          fileURLWithPath: "/opt/homebrew/opt/molten-vk/etc/vulkan/icd.d/MoltenVK_icd.json")
        if let url = bundled
          ?? (FileManager.default.isReadableFile(atPath: homebrew.path) ? homebrew : nil)
        {
          setenv("VK_ICD_FILENAMES", url.path, 1)
        }
      }
      DispatchQueue.main.async { WallpaperController.shared.start() }
      WallpaperRuntime.log("Native wallpaper extension started.")
    } catch { WallpaperRuntime.log("Unavailable: \(error.localizedDescription)") }
  }
  var configuration: some AppExtensionConfiguration { NativeWallpaperConfiguration() }
}
