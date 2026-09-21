import AppKit
import IOSurface
import Security

/// All private ABI assumptions are checked against the loaded system classes.
/// No fallback offsets, process injection, or lock-screen window impersonation.
enum WallpaperRuntime {
  static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  private static var handle: UnsafeMutableRawPointer?

  static func load() throws {
    if handle == nil {
      guard
        let framework = dlopen(
          "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit",
          RTLD_LAZY)
      else {
        throw failure("This macOS version does not provide WallpaperExtensionKit.")
      }
      handle = framework
    }
    for name in [
      "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperCreationRequestXPC",
      "WallpaperUpdateRequestXPC", "WallpaperIDXPC", "WallpaperSettingsViewModelsXPC",
    ] {
      guard NSClassFromString(name) != nil else {
        throw failure("Missing macOS wallpaper type: \(name)")
      }
    }
    _ = try storage(className: "WallpaperRemoteContextXPC", member: "box", count: 4)
    _ = try storage(
      className: "WallpaperSnapshotXPC", member: "rawValue",
      count: MemoryLayout<UnsafeRawPointer>.size)
  }

  static func failure(_ message: String) -> NSError {
    NSError(
      domain: "WallpaperMachine.LockScreen", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }

  private static func storage(className: String, member: String, count: Int) throws -> (
    AnyClass, Int
  ) {
    guard let cls = NSClassFromString(className), let ivar = class_getInstanceVariable(cls, member)
    else {
      throw failure("Unsupported macOS wallpaper layout: \(className).\(member)")
    }
    let offset = ivar_getOffset(ivar)
    guard offset == MemoryLayout<UnsafeRawPointer>.size,
      offset + count == class_getInstanceSize(cls)
        || (count == 4 && offset + 8 == class_getInstanceSize(cls))
    else {
      throw failure("Unsupported macOS wallpaper payload size: \(className)")
    }
    return (cls, offset)
  }

  static func contextReply(_ contextID: UInt32) throws -> AnyObject {
    let (cls, offset): (AnyClass, Int) = try storage(
      className: "WallpaperRemoteContextXPC", member: "box", count: 4)
    guard let raw = class_createInstance(cls, 0) else {
      throw failure("Cannot allocate wallpaper context reply.")
    }
    let object = raw as AnyObject
    Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(
      of: contextID, as: UInt32.self)
    return object
  }

  static func snapshotReply(_ surface: IOSurface) throws -> AnyObject {
    let (cls, offset): (AnyClass, Int) = try storage(
      className: "WallpaperSnapshotXPC", member: "rawValue",
      count: MemoryLayout<UnsafeRawPointer>.size)
    guard let raw = class_createInstance(cls, 0) else {
      throw failure("Cannot allocate wallpaper snapshot reply.")
    }
    let object = raw as AnyObject
    let retained = Unmanaged.passRetained(surface).toOpaque()
    Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(
      of: retained, as: UnsafeMutableRawPointer.self)
    return object
  }

  static func context(displayID: UInt32?) throws -> CAContext {
    guard let cls = NSClassFromString("CAContext"),
      class_getClassMethod(cls, NSSelectorFromString("remoteContextWithOptions:")) != nil,
      class_getInstanceMethod(cls, NSSelectorFromString("contextId")) != nil,
      class_getInstanceMethod(cls, NSSelectorFromString("setLayer:")) != nil,
      class_getInstanceMethod(cls, NSSelectorFromString("invalidate")) != nil
    else {
      throw failure("Remote wallpaper composition is unavailable on this macOS version.")
    }
    let options: [String: Any] = displayID.map { ["displayId": $0] } ?? [:]
    guard
      let context = (cls as AnyObject).perform(
        NSSelectorFromString("remoteContextWithOptions:"), with: options)?.takeUnretainedValue()
        as? CAContext,
      context.contextId != 0
    else { throw failure("macOS refused to create a remote wallpaper surface.") }
    return context
  }

  /// Treat an unavailable audit token or signature lookup as an untrusted caller.
  static func accepts(_ connection: NSXPCConnection) -> Bool {
    guard connection.responds(to: NSSelectorFromString("auditToken")) else { return false }
    var token = connection.auditToken
    let data = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(
        nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code
    else { return false }
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }

  static func field(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 8 else { return nil }
    let mirror = Mirror(reflecting: value)
    if let child = mirror.children.first(where: { $0.label == label }) { return child.value }
    for child in mirror.children {
      if let result = field(label, in: child.value, depth: depth + 1) { return result }
    }
    return nil
  }

  static func identifier(_ value: Any?, depth: Int = 0) -> UUID? {
    guard let value, depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    for child in Mirror(reflecting: value).children {
      if let uuid = identifier(child.value, depth: depth + 1) { return uuid }
    }
    return nil
  }

  static func enumCase(_ value: Any) -> String {
    Mirror(reflecting: value).children.first?.label ?? String(describing: value)
  }

  static func configuration() throws -> LockScreenConfiguration {
    let url = documents.appendingPathComponent(LockScreenConfiguration.fileName)
    let configuration = try JSONDecoder().decode(
      LockScreenConfiguration.self, from: Data(contentsOf: url))
    guard configuration.version == LockScreenConfiguration.supportedVersion else {
      throw failure("Unsupported lock-screen configuration version.")
    }
    return configuration
  }

  static func asset(_ relativePath: String) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !components.contains(".."),
      !components.contains("."), !components.contains("")
    else {
      throw failure("Invalid lock-screen asset path.")
    }
    let root = documents.resolvingSymlinksInPath().standardizedFileURL
    let url = root.appendingPathComponent(relativePath).resolvingSymlinksInPath()
      .standardizedFileURL
    guard url.path.hasPrefix(root.path + "/"), FileManager.default.isReadableFile(atPath: url.path)
    else { throw failure("Lock-screen asset is unavailable: \(relativePath)") }
    return url
  }

  static func log(_ message: String) {
    NSLog("[MWE LockScreen] %@", message)
    // Small bounded local diagnostic, never asset contents or authentication data.
    let file = documents.appendingPathComponent("extension.log")
    try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512 * 1024 {
      try? FileManager.default.removeItem(at: file)
    }
    let data = Data("\(Date()) \(message)\n".utf8)
    if !FileManager.default.fileExists(atPath: file.path) {
      try? data.write(to: file)
      return
    }
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  }
}
