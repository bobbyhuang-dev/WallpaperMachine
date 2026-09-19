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
  @ObservationIgnored private let scenes: () async throws -> [BridgeLockScreenScene]
  /// Whether any applied wallpaper is a web wallpaper. Web has no lock-screen
  /// renderer, so the app has to be able to say "not applicable" instead of
  /// leaving the user waiting for something that will never arrive.
  @ObservationIgnored private let webWallpapersApplied: () async -> Bool
  @ObservationIgnored private let selection: LockScreenWallpaperSelection
  @ObservationIgnored private let documents: URL
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let scheduleMonitor: (@escaping @MainActor () -> Void) -> Timer
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var monitor: Timer?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var recovered = false
  @ObservationIgnored private var stopping = false
  @ObservationIgnored private(set) var ownsDesktopProvider = false
  @ObservationIgnored private var lastInputs: [LockScreenPublishInput]?
  @ObservationIgnored private var published: LockScreenConfiguration?

  convenience init(bridge: WallpaperBridge) {
    self.init(
      scenes: { try await bridge.lockScreenScenes() },
      webWallpapersApplied: { ((try? await bridge.webWallpapers()) ?? []).isEmpty == false },
      selection: LockScreenWallpaperSelection(
        folder: ClientPaths.supportURL.appendingPathComponent("LockScreen")),
      documents: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Containers/\(LockScreenConfiguration.extensionIdentifier)/Data/Documents",
        isDirectory: true))
  }

  init(
    scenes: @escaping () async throws -> [BridgeLockScreenScene],
    webWallpapersApplied: @escaping () async -> Bool = { false },
    selection: LockScreenWallpaperSelection, documents: URL,
    defaults: UserDefaults = .standard,
    scheduleMonitor: @escaping (@escaping @MainActor () -> Void) -> Timer =
      LockScreenWallpaperService.scheduleMonitorTimer
  ) {
    self.scenes = scenes
    self.webWallpapersApplied = webWallpapersApplied
    self.selection = selection
    self.documents = documents
    self.defaults = defaults
    self.scheduleMonitor = scheduleMonitor
  }

  /// Always recover before either native or PNG providers are allowed to start.
  func start() throws {
    defer { updateMonitor() }
    isRequested = defaults.bool(forKey: Self.preference)
    do {
      try selection.recover()
      recovered = true
      if isRequested { status = "Waiting for committed wallpapers…" }
    } catch {
      errorMessage = error.localizedDescription
      status = "Recovery failed — action required"
      throw error
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard !stopping else { return }
    isRequested = enabled
    updateMonitor()
    if !enabled { defaults.set(false, forKey: Self.preference) }
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

  private func updateMonitor() {
    guard isRequested, recovered, !stopping, errorMessage == nil else {
      monitor?.invalidate()
      monitor = nil
      return
    }
    guard monitor == nil else { return }
    monitor = scheduleMonitor { [weak self] in
      guard let self, self.isRequested, !self.stopping, !self.isBusy,
        self.errorMessage == nil
      else { return }
      // The bridge applies battery policy without opening the control panel.
      self.refresh()
    }
  }

  static func scheduleMonitorTimer(_ callback: @escaping @MainActor () -> Void) -> Timer {
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
      MainActor.assumeIsolated { callback() }
    }
  }

  func shutdown() async throws {
    stopping = true
    updateMonitor()
    generation &+= 1
    work?.cancel()
    await work?.value
    work = nil
    do {
      try restoreNativeSelection()
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
    defer {
      if generation == revision {
        isBusy = false
        updateMonitor()
      }
    }
    do {
      if !recovered {
        try selection.recover()
        recovered = true
      }
      guard isRequested else {
        status = "Restoring system wallpapers…"
        try deactivate()
        errorMessage = nil
        status = "Off"
        return
      }
      status = "Preparing committed wallpapers…"
      let records = try await scenes()
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
          displayUUID: CFUUIDCreateString(nil, uuid) as String,
          wallpaperID: record.wallpaperId, title: record.title,
          projectPath: record.projectPath, assetsPath: record.assetsPath, fps: record.fps,
          scalingMode: mode, scalingFactor: record.scalingFactor,
          propertiesJSON: record.propertiesJson, paused: record.paused)
      }.sorted { $0.displayID < $1.displayID }
      guard !inputs.isEmpty else {
        try deactivate()
        // A web wallpaper has no lock-screen renderer at all, so this is not a
        // failure and not something the user can act on: it is the combination
        // being unsupported. Anything else means nothing eligible is applied yet.
        status = await webWallpapersApplied()
          ? "Not applicable — web wallpapers have no lock-screen support"
          : "Waiting for an applied video or live scene on a connected display"
        errorMessage = nil
        return
      }
      if inputs == lastInputs, isEnabled, let published {
        // Reconcile new Spaces using the same native choice identity. Ordinary
        // snapshots must not invalidate thumbnails or reload WallpaperAgent.
        try selection.synchronize(
          displays: Set(inputs.map(\.displayUUID)), revision: published.revision)
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
      let userAssets = UserAssetStorage.managedRootURL
      let staging = Task.detached(priority: .utility) {
        try LockScreenAssetPublisher.prepare(
          inputs: inputs, documents: root, userAssets: userAssets)
      }
      let prepared = try await withTaskCancellationHandler {
        try await staging.value
      } onCancel: {
        staging.cancel()
      }
      let configuration = prepared.configuration
      try Task.checkCancellation()
      guard generation == revision, isRequested else { return }
      if !ownsDesktopProvider {
        try beforeActivation?()
        ownsDesktopProvider = true
      }
      try publish(configuration)
      // After the configuration naming the new revisions is on disk, never before:
      // a revision is only unreferenced once nothing published points at it.
      LockScreenAssetPublisher.collectGarbage(
        documents: root, keeping: prepared.referencedRevisions)
      try selection.synchronize(
        displays: Set(inputs.map(\.displayUUID)), revision: configuration.revision)
      status = "Waiting for the system wallpaper renderer…"
      try await awaitReadiness(configuration)
      try Task.checkCancellation()
      guard generation == revision, isRequested else { return }
      lastInputs = inputs
      isEnabled = true
      defaults.set(true, forKey: Self.preference)
      status = "Enabled for \(inputs.count) display(s)"
      errorMessage = nil
    } catch is CancellationError {
      // A newer snapshot/disable owns the next publication and final status.
    } catch {
      guard generation == revision else { return }
      var message = error.localizedDescription
      do { try deactivate() } catch {
        message += " Restoration also failed: \(error.localizedDescription)"
      }
      errorMessage = message
      status = "Not enabled — action required"
      AppLog.error("Lock screen wallpaper: \(message)")
    }
  }

  /// Restore the native selection and hand the desktop back to the poster
  /// provider. Both steps always run so a failed restoration can never leave
  /// the poster sync suspended; the first error is rethrown afterwards.
  private func deactivate() throws {
    isEnabled = false
    lastInputs = nil
    var firstError: Error?
    do { try restoreNativeSelection() } catch { firstError = error }
    if ownsDesktopProvider {
      ownsDesktopProvider = false
      do { try afterDeactivation?() } catch { if firstError == nil { firstError = error } }
    }
    if let firstError { throw firstError }
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
  var wallpaperID: String
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

  /// A published configuration, plus every revision directory it names. The caller
  /// needs the second to know what is safe to collect.
  struct Prepared {
    var configuration: LockScreenConfiguration
    var referencedRevisions: Set<String>
  }

  static func prepare(
    inputs: [LockScreenPublishInput], documents: URL, userAssets: URL
  ) throws -> Prepared {
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
        let type = metadata["type"] as? String
      else {
        throw LockScreenWallpaperFailure(
          message: "The committed wallpaper does not declare a project type.")
      }
      guard ["video", "scene"].contains(type.lowercased()) else {
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
      let properties = try publishUserAssets(
        input: input, documents: documents, userAssets: userAssets, reused: &sources)
      scenes.append(
        LockScreenScene(
          displayID: input.displayID, title: input.title,
          projectPath: projectRevision + "/project.json", assetsPath: assetsRevision,
          previewPath: nil,
          fps: input.fps, scalingMode: input.scalingMode, scalingFactor: input.scalingFactor,
          propertiesJSON: properties, paused: input.paused))
    }
    return Prepared(
      configuration: LockScreenConfiguration(scenes: scenes),
      referencedRevisions: Set(sources.values))
  }

  /// Copies the managed user assets this wallpaper actually references into the
  /// extension container and rewrites the property values to point at the copy.
  ///
  /// Only the referenced assets travel: the store may hold imports for every wallpaper
  /// in the library, and the extension has no business seeing any of them. The copy
  /// goes through the same fingerprint-and-atomic-move path as the project payload, so
  /// an unchanged selection is recognised and nothing is copied again on the next
  /// status update.
  ///
  /// Returns the property payload the extension should receive, unchanged when the
  /// wallpaper references no managed asset.
  private static func publishUserAssets(
    input: LockScreenPublishInput, documents: URL, userAssets: URL,
    reused: inout [String: String]
  ) throws -> String? {
    guard let json = input.propertiesJSON, !input.wallpaperID.isEmpty else {
      return input.propertiesJSON
    }
    let store = ManagedUserAssetStore(root: userAssets)
    let manifest = store.manifest(wallpaperId: input.wallpaperID)
    guard !manifest.properties.isEmpty,
      let data = json.data(using: .utf8),
      var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return input.propertiesJSON }

    let manager = FileManager.default
    // Planned before anything is copied: the plan is what the fingerprint covers, so a
    // manifest entry this wallpaper does not reference cannot change the revision, and
    // an unchanged selection is recognised without reading a byte.
    var plan: [(property: String, isFile: Bool, files: [(name: String, source: URL, digest: String)])] = []
    for (propertyId, record) in manifest.properties.sorted(by: { $0.key < $1.key }) {
      guard root[propertyId] != nil, !record.assets.isEmpty else { continue }
      var files: [(name: String, source: URL, digest: String)] = []
      for asset in record.assets.sorted(by: { $0.fileName < $1.fileName }) {
        let stored = try store.storedURL(
          wallpaperId: input.wallpaperID, propertyId: propertyId, asset: asset)
        guard manager.fileExists(atPath: stored.path) else { continue }
        files.append((asset.fileName, stored, asset.digest))
      }
      guard !files.isEmpty else { continue }
      plan.append((propertyId, record.kind == .file, files))
    }
    guard !plan.isEmpty else { return input.propertiesJSON }

    // Content digests rather than file metadata: a clone preserves modification
    // times but a chunked fallback copy does not, and a fingerprint that moved with
    // the copy would republish the same assets on every status update.
    var hash = SHA256()
    hash.update(data: Data("user-assets\u{0}".utf8))
    for entry in plan {
      hash.update(data: Data("\u{0}\(entry.property)\u{0}\(entry.isFile)".utf8))
      for file in entry.files {
        hash.update(data: Data("\u{0}\(file.name)\u{0}\(file.digest)".utf8))
      }
    }
    let relative = "revisions/" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    let published = documents.appendingPathComponent(relative, isDirectory: true)
    if !manager.fileExists(atPath: published.path) {
      let revisions = documents.appendingPathComponent("revisions", isDirectory: true)
      try manager.createDirectory(at: revisions, withIntermediateDirectories: true)
      let pending = revisions.appendingPathComponent(
        ".pending-\(UUID().uuidString)", isDirectory: true)
      defer { try? manager.removeItem(at: pending) }
      for entry in plan {
        let directory = pending.appendingPathComponent(entry.property, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in entry.files {
          try Task.checkCancellation()
          try copyFile(from: file.source, to: directory.appendingPathComponent(file.name))
        }
      }
      try Task.checkCancellation()
      try manager.moveItem(at: pending, to: published)
    }
    reused["user-assets:" + relative] = relative

    for entry in plan {
      let directory = published.appendingPathComponent(entry.property, isDirectory: true)
      // A `file` property names one published file; a `directory` property names the
      // folder, exactly as the renderer already expects on the desktop side.
      root[entry.property] = entry.isFile
        ? directory.appendingPathComponent(entry.files[0].name).path
        : directory.path
    }
    guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    else { return input.propertiesJSON }
    return String(data: encoded, encoding: .utf8)
  }

  /// Removes revision trees the published configuration no longer names.
  ///
  /// Nothing collected this before, so every asset revision the user ever activated
  /// stayed in the container for good. Only the revisions the caller passes are kept,
  /// and only complete fingerprint directories are candidates: a `.pending-` tree
  /// belongs to a publish that is still running.
  static func collectGarbage(documents: URL, keeping referenced: Set<String>) {
    let manager = FileManager.default
    let revisions = documents.appendingPathComponent("revisions", isDirectory: true)
    guard let entries = try? manager.contentsOfDirectory(
      at: revisions, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
    let live = Set(referenced.map { URL(fileURLWithPath: $0).lastPathComponent })
    for entry in entries {
      let name = entry.lastPathComponent
      guard !name.hasPrefix("."), !live.contains(name) else { continue }
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        continue
      }
      do {
        try manager.removeItem(at: entry)
      } catch {
        AppLog.warn("lock screen: could not remove unused revision \(name): \(error.localizedDescription)")
      }
    }
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
