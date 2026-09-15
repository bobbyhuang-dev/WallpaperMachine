import AppKit
import CryptoKit
import Darwin
import Observation

@MainActor
@Observable
final class LockScreenWallpaperService {
  private(set) var isEnabled = false
  private(set) var isRequested = false
  private(set) var isBusy = false
  private(set) var status = "Off"
  private(set) var errorMessage: String?
  @ObservationIgnored var beforeActivation: (() throws -> Void)?
  @ObservationIgnored var afterDeactivation: (() throws -> Void)?

  private static let preference = "MacWallpaperEngineAnimateLockScreen"
  @ObservationIgnored private let bridge: WallpaperBridge
  @ObservationIgnored private let selection: LockScreenWallpaperSelection
  @ObservationIgnored private let documents: URL
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var monitor: Timer?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var recovered = false
  @ObservationIgnored private var stopping = false
  @ObservationIgnored private var ownsDesktopProvider = false
  @ObservationIgnored private var lastInputs: [LockScreenPublishInput]?
  @ObservationIgnored private var published: LockScreenConfiguration?

  init(bridge: WallpaperBridge) {
    self.bridge = bridge
    selection = LockScreenWallpaperSelection(
      folder: ClientPaths.supportURL.appendingPathComponent("LockScreen"))
    documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Containers/\(LockScreenConfiguration.extensionIdentifier)/Data/Documents",
      isDirectory: true)
  }

  /// Always recover before either native or PNG providers are allowed to start.
  func start() throws {
    isRequested = UserDefaults.standard.bool(forKey: Self.preference)
    do {
      try selection.recover()
      recovered = true
      if isRequested { status = "Waiting for committed wallpapers…" }
      monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.isRequested, !self.isBusy, self.errorMessage == nil else { return }
          // The bridge applies battery policy without opening the control panel.
          self.refresh()
        }
      }
    } catch {
      errorMessage = error.localizedDescription
      status = "Recovery failed — action required"
      throw error
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard !stopping else { return }
    isRequested = enabled
    if !enabled { UserDefaults.standard.set(false, forKey: Self.preference) }
    refresh()
  }

  func refresh() {
    guard !stopping else { return }
    generation &+= 1
    let revision = generation
    let previous = work
    previous?.cancel()
    isBusy = true
    work = Task { [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled, self.generation == revision else { return }
      await self.update(revision: revision)
    }
  }

  func shutdown() async throws {
    stopping = true
    generation &+= 1
    work?.cancel()
    await work?.value
    work = nil
    do {
      try restoreNativeSelection()
      monitor?.invalidate()
      monitor = nil
      isEnabled = false
      isBusy = false
    } catch {
      stopping = false
      isBusy = false
      errorMessage = error.localizedDescription
      status = "Restoration failed — quit cancelled"
      throw error
    }
  }

  private func update(revision: UInt64) async {
    defer { if generation == revision { isBusy = false } }
    do {
      if !recovered {
        try selection.recover()
        recovered = true
      }
      guard isRequested else {
        status = "Restoring system wallpapers…"
        try restoreNativeSelection()
        isEnabled = false
        lastInputs = nil
        try afterDeactivation?()
        ownsDesktopProvider = false
        errorMessage = nil
        status = "Off"
        return
      }
      status = "Preparing committed wallpapers…"
      let records = try await bridge.lockScreenScenes()
      try Task.checkCancellation()
      guard generation == revision else { return }
      try selection.checkCompatibility()
      let inputs = try records.map { record -> LockScreenPublishInput in
        guard CGDisplayIsOnline(record.displayId) != 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(record.displayId)?.takeRetainedValue()
        else {
          throw LockScreenWallpaperFailure(
            message:
              "An active wallpaper display is no longer connected. Refresh displays before retrying."
          )
        }
        let mode: Int32
        switch record.scalingMode {
        case .none: mode = 0
        case .stretch: mode = 1
        case .match: mode = 2
        case .fill: mode = 3
        }
        return LockScreenPublishInput(
          displayID: record.displayId,
          displayUUID: CFUUIDCreateString(nil, uuid) as String, title: record.title,
          projectPath: record.projectPath, assetsPath: record.assetsPath, fps: record.fps,
          scalingMode: mode, scalingFactor: record.scalingFactor,
          propertiesJSON: record.propertiesJson, paused: record.paused)
      }.sorted { $0.displayID < $1.displayID }
      guard !inputs.isEmpty else {
        try restoreNativeSelection()
        isEnabled = false
        lastInputs = nil
        status = "Waiting for an applied video or live scene on a connected display"
        errorMessage = nil
        return
      }
      if inputs == lastInputs, isEnabled {
        // Still reconcile new Spaces and detect external native selections,
        // but neither recopy assets nor rewrite/restart for ordinary snapshots.
        try selection.synchronize(displays: Set(inputs.map(\.displayUUID)))
        status = "Enabled for \(inputs.count) display(s)"
        errorMessage = nil
        return
      }
      let mappingChanged =
        inputs.map { "\($0.displayID):\($0.projectPath):\($0.assetsPath)" }
        != lastInputs?.map { "\($0.displayID):\($0.projectPath):\($0.assetsPath)" }
      if mappingChanged {
        try clearManifest()
        isEnabled = false
      }
      let root = documents
      let staging = Task.detached(priority: .utility) {
        try LockScreenAssetPublisher.prepare(inputs: inputs, documents: root)
      }
      let configuration = try await withTaskCancellationHandler {
        try await staging.value
      } onCancel: {
        staging.cancel()
      }
      try Task.checkCancellation()
      guard generation == revision, isRequested else { return }
      if !ownsDesktopProvider {
        try beforeActivation?()
        ownsDesktopProvider = true
      }
      try publish(configuration)
      try selection.synchronize(displays: Set(inputs.map(\.displayUUID)))
      status = "Waiting for the system wallpaper renderer…"
      try await awaitReadiness(configuration)
      lastInputs = inputs
      isEnabled = true
      UserDefaults.standard.set(true, forKey: Self.preference)
      status = "Enabled for \(inputs.count) display(s)"
      errorMessage = nil
    } catch is CancellationError {
      // A newer snapshot/disable owns the next publication and final status.
    } catch {
      guard generation == revision else { return }
      isEnabled = false
      lastInputs = nil
      var message = error.localizedDescription
      do {
        try restoreNativeSelection()
        try afterDeactivation?()
        ownsDesktopProvider = false
      } catch {
        message += " Restoration also failed: \(error.localizedDescription)"
      }
      errorMessage = message
      status = "Not enabled — action required"
      AppLog.error("Lock screen wallpaper: \(message)")
    }
  }

  private func awaitReadiness(_ configuration: LockScreenConfiguration) async throws {
    let deadline = Date().addingTimeInterval(35)
    while Date() < deadline {
      try Task.checkCancellation()
      var ready = true
      for scene in configuration.scenes {
        let file = documents.appendingPathComponent("ready-\(scene.displayID).json")
        guard let data = try? Data(contentsOf: file),
          let state = try? JSONDecoder().decode(LockScreenReadiness.self, from: data),
          state.revision == configuration.revision, state.displayID == scene.displayID
        else {
          ready = false
          continue
        }
        if let error = state.error { throw LockScreenWallpaperFailure(message: error) }
      }
      if ready { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw LockScreenWallpaperFailure(
      message:
        "macOS did not load the lock-screen renderer. The original wallpaper has been restored. Check for another wallpaper app or a conflicting system-wide wallpaper selection."
    )
  }

  private func restoreNativeSelection() throws {
    var manifestError: Error?
    do { try clearManifest() } catch { manifestError = error }
    // A full disk or inaccessible container must never prevent restoring the
    // user's native selections. Preserve both errors when recovery also fails.
    do { try selection.synchronize(displays: []) } catch {
      if let manifestError {
        throw LockScreenWallpaperFailure(
          message:
            "\(manifestError.localizedDescription) Native restoration: \(error.localizedDescription)"
        )
      }
      throw error
    }
    if let manifestError { throw manifestError }
  }

  private func clearManifest() throws {
    // Do not create a sandbox container merely because the feature is off.
    guard
      FileManager.default.fileExists(
        atPath: documents.appendingPathComponent(LockScreenConfiguration.fileName).path)
    else {
      published = nil
      return
    }
    try publish(LockScreenConfiguration(scenes: []))
  }

  private func publish(_ configuration: LockScreenConfiguration) throws {
    guard configuration != published else { return }
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(configuration).write(
      to: documents.appendingPathComponent(LockScreenConfiguration.fileName), options: .atomic)
    published = configuration
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(LockScreenConfiguration.changedNotification as CFString), nil, nil, true)
  }
}

private struct LockScreenPublishInput: Equatable, Sendable {
  var displayID: UInt32
  var displayUUID: String
  var title: String
  var projectPath: String
  var assetsPath: String
  var fps: UInt32
  var scalingMode: Int32
  var scalingFactor: Double
  var propertiesJSON: String?
  var paused: Bool
}

/// A source-tree metadata fingerprint reuses immutable snapshots without reading
/// gigabytes of unchanged video. Copies never follow symlinks out of a project.
private enum LockScreenAssetPublisher {
  private struct Item {
    var relative: String
    var directory: Bool
    var size: Int
    var modified: Date
  }

  static func prepare(inputs: [LockScreenPublishInput], documents: URL) throws
    -> LockScreenConfiguration
  {
    var sources: [String: String] = [:]
    var scenes: [LockScreenScene] = []
    for input in inputs {
      try Task.checkCancellation()
      guard input.projectPath.hasPrefix("/"), input.assetsPath.hasPrefix("/") else {
        throw LockScreenWallpaperFailure(
          message: "The committed wallpaper contains a non-absolute source path.")
      }
      let project = URL(fileURLWithPath: input.projectPath)
      guard project.lastPathComponent == "project.json" else {
        throw LockScreenWallpaperFailure(
          message: "The committed wallpaper does not reference project.json.")
      }
      let source = project.deletingLastPathComponent()
      let data = try Data(contentsOf: project)
      guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = metadata["type"] as? String,
        ["video", "scene"].contains(type.lowercased())
      else {
        throw LockScreenWallpaperFailure(
          message: "Only committed video and live scene projects support Animate Lock Screen.")
      }
      let projectRevision = try snapshot(source: source, documents: documents, reused: &sources)
      let assetsRevision: String
      if type.lowercased() == "scene" {
        assetsRevision = try snapshot(
          source: URL(fileURLWithPath: input.assetsPath, isDirectory: true),
          documents: documents, reused: &sources)
      } else {
        // Video rendering does not consume shared scene assets.
        assetsRevision = projectRevision
      }
      scenes.append(
        LockScreenScene(
          displayID: input.displayID, title: input.title,
          projectPath: projectRevision + "/project.json", assetsPath: assetsRevision,
          previewPath: nil,
          fps: input.fps, scalingMode: input.scalingMode, scalingFactor: input.scalingFactor,
          propertiesJSON: input.propertiesJSON, paused: input.paused))
    }
    return LockScreenConfiguration(scenes: scenes)
  }

  private static func snapshot(source: URL, documents: URL, reused: inout [String: String]) throws
    -> String
  {
    let source = source.standardizedFileURL
    if let existing = reused[source.path] { return existing }
    let items = try inventory(source)
    let fingerprint = digest(source: source, items: items)
    let relative = "revisions/\(fingerprint)"
    let destination = documents.appendingPathComponent(relative, isDirectory: true)
    let manager = FileManager.default
    if !manager.fileExists(atPath: destination.path) {
      let revisions = documents.appendingPathComponent("revisions", isDirectory: true)
      try manager.createDirectory(at: revisions, withIntermediateDirectories: true)
      let pending = revisions.appendingPathComponent(
        ".pending-\(UUID().uuidString)", isDirectory: true)
      try manager.createDirectory(at: pending, withIntermediateDirectories: false)
      defer { try? manager.removeItem(at: pending) }
      for item in items {
        try Task.checkCancellation()
        let target = pending.appendingPathComponent(item.relative, isDirectory: item.directory)
        if item.directory {
          try manager.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
          try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          // APFS clones isolate writes without duplicating large files;
          // a chunked fallback keeps cancellation responsive elsewhere.
          try copyFile(from: source.appendingPathComponent(item.relative), to: target)
        }
      }
      guard digest(source: source, items: try inventory(source)) == fingerprint else {
        throw LockScreenWallpaperFailure(
          message:
            "Wallpaper assets changed while preparing the lock screen. Retry after the download or edit finishes."
        )
      }
      try Task.checkCancellation()
      try manager.moveItem(at: pending, to: destination)
    }
    reused[source.path] = relative
    return relative
  }

  private static func inventory(_ source: URL) throws -> [Item] {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      .fileSizeKey, .contentModificationDateKey,
    ]
    let root = try source.resourceValues(forKeys: keys)
    guard root.isDirectory == true, root.isSymbolicLink != true else {
      throw LockScreenWallpaperFailure(
        message: "The wallpaper asset source must be a real directory: \(source.path)")
    }
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: source, includingPropertiesForKeys: Array(keys),
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw LockScreenWallpaperFailure(message: "Cannot enumerate wallpaper assets: \(source.path)")
    }
    var result: [Item] = []
    for case let file as URL in enumerator {
      try Task.checkCancellation()
      let values = try file.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true,
        values.isDirectory == true || values.isRegularFile == true
      else {
        throw LockScreenWallpaperFailure(
          message: "Lock-screen assets cannot contain symbolic links or special files: \(file.path)"
        )
      }
      result.append(
        Item(
          relative: String(file.path.dropFirst(source.path.count + 1)),
          directory: values.isDirectory == true, size: values.fileSize ?? 0,
          modified: values.contentModificationDate ?? .distantPast))
    }
    if let enumerationError { throw enumerationError }
    return result.sorted { $0.relative < $1.relative }
  }

  private static func digest(source: URL, items: [Item]) -> String {
    var hash = SHA256()
    hash.update(data: Data(source.path.utf8))
    for item in items {
      hash.update(
        data: Data(
          "\u{0}\(item.relative)\u{0}\(item.directory)\u{0}\(item.size)\u{0}\(item.modified.timeIntervalSince1970)"
            .utf8))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func copyFile(from source: URL, to destination: URL) throws {
    if clonefile(source.path, destination.path, 0) == 0 { return }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw LockScreenWallpaperFailure(
        message: "Cannot create lock-screen asset: \(destination.path)")
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    while true {
      try Task.checkCancellation()
      guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
      try output.write(contentsOf: chunk)
    }
  }
}
