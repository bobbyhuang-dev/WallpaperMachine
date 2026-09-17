import AppKit

@MainActor
final class WallpaperController {
  static let shared = WallpaperController()
  private var surfaces: [UUID: WallpaperSurface] = [:]
  private var configuration: LockScreenConfiguration?
  private var revisions: [UUID: UInt64] = [:]
  private var observers: [NSObjectProtocol] = []
  private(set) var displaysAsleep = false
  private var started = false

  func start() {
    guard !started else { return }
    started = true
    reload()
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, asleep) in [
      (NSWorkspace.screensDidSleepNotification, true),
      (NSWorkspace.screensDidWakeNotification, false),
    ] {
      observers.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.displaysAsleep = asleep
            self?.surfaces.values.forEach { $0.applyPolicy() }
          }
        })
    }
    for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
      observers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: .init(name), object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.surfaces.values.forEach { $0.applyPolicy() } }
        })
    }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let controller = Unmanaged<WallpaperController>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { controller.reload() }
      }, LockScreenConfiguration.changedNotification as CFString, nil, .deliverImmediately)
  }

  func reload() {
    do {
      let next = try WallpaperRuntime.configuration()
      guard next != configuration else { return }
      configuration = next
      for surface in Array(surfaces.values) {
        guard let scene = selectScene(displayID: surface.displayID) else {
          surface.clear()
          continue
        }
        if surface.hasRenderer, surface.scene.projectPath == scene.projectPath,
          surface.scene.assetsPath == scene.assetsPath,
          surface.scene.propertiesJSON == scene.propertiesJSON,
          surface.scene.scalingMode == scene.scalingMode,
          surface.scene.scalingFactor == scene.scalingFactor
        {
          surface.update(scene: scene)
          acknowledge(surface: surface)
        } else {
          // The hosted CAContext remains the same; only its child renderer changes.
          surface.replace(scene: scene) { [weak self, weak surface] error in
            guard let self, let surface else { return }
            self.acknowledge(surface: surface, error: error)
            if let error {
              WallpaperRuntime.log("Replacement failed: \(error.localizedDescription)")
            }
          }
        }
      }
      WallpaperRuntime.log("Configuration loaded scenes=\(next.scenes.count)")
    } catch {
      // A removed/corrupt manifest must never keep rendering a previously private scene.
      configuration = nil
      surfaces.values.forEach { $0.clear() }
      WallpaperRuntime.log("Configuration unavailable: \(error.localizedDescription)")
    }
  }

  private func acknowledge(surface: WallpaperSurface, error: Error? = nil) {
    guard !surface.preview, let configuration,
      configuration.scenes.contains(surface.scene)
    else { return }
    surface.whenReady { readyError in
      let result = LockScreenReadiness(
        revision: configuration.revision,
        displayID: surface.scene.displayID, error: (error ?? readyError)?.localizedDescription)
      do {
        let data = try JSONEncoder().encode(result)
        try data.write(
          to: WallpaperRuntime.documents.appendingPathComponent("ready-\(result.displayID).json"),
          options: .atomic)
      } catch {
        WallpaperRuntime.log("Readiness acknowledgement failed: \(error.localizedDescription)")
      }
    }
  }

  private func selectScene(displayID: UInt32?) -> LockScreenScene? {
    guard let displayID else { return configuration?.scenes.first }
    return configuration?.scenes.first(where: { $0.displayID == displayID })
  }

  func acquire(id value: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
    do {
      guard let id = WallpaperRuntime.identifier(value), let request,
        let destination = WallpaperRuntime.field("destination", in: request),
        let size = WallpaperRuntime.field("size", in: destination) as? CGSize,
        let scale = WallpaperRuntime.field("scaleFactor", in: destination) as? CGFloat
      else {
        throw WallpaperRuntime.failure("Unsupported native wallpaper creation request.")
      }
      let displayID = WallpaperRuntime.field("directDisplayID", in: destination) as? UInt32
      let preview = WallpaperRuntime.field("isPreview", in: request) as? Bool ?? false
      reload()
      guard let scene = selectScene(displayID: displayID) else {
        throw WallpaperRuntime.failure(
          "No applied wallpaper is available for this display. Enable Animate Lock Screen in MacWallpaperEngine."
        )
      }
      if let existing = surfaces[id], existing.scene == scene, existing.size == size,
        existing.scale == scale
      {
        // Repeated acquires must wait for GPU-ready pixels too.
        existing.whenReady { error in
          do {
            if let error { throw error }
            reply(try WallpaperRuntime.contextReply(existing.context.contextId), nil)
          } catch { reply(nil, error) }
        }
        return
      }
      remove(id)
      let revision = (revisions[id] ?? 0) &+ 1
      revisions[id] = revision
      let surface = try WallpaperSurface(
        scene: scene, displayID: displayID, size: size, scale: scale, preview: preview,
        generation: revision)
      if let mode = WallpaperRuntime.field("presentationMode", in: request) {
        surface.presentation = WallpaperRuntime.enumCase(mode)
      }
      if let activity = WallpaperRuntime.field("activityState", in: request) {
        surface.activity = WallpaperRuntime.enumCase(activity)
      }
      surfaces[id] = surface
      surface.start { [weak self, weak surface] error in
        do {
          if let error { throw error }
          guard let self, let surface, self.revisions[id] == revision, self.surfaces[id] === surface
          else { throw CancellationError() }
          reply(try WallpaperRuntime.contextReply(surface.context.contextId), nil)
          self.acknowledge(surface: surface)
          WallpaperRuntime.log("Acquired id=\(id) display=\(scene.displayID) preview=\(preview)")
        } catch { reply(nil, error) }
      }
    } catch {
      reply(nil, error)
      WallpaperRuntime.log("Acquire failed: \(error.localizedDescription)")
    }
  }

  func update(id value: Any?, request: Any?) throws {
    guard let id = WallpaperRuntime.identifier(value), let surface = surfaces[id], let request
    else { throw WallpaperRuntime.failure("Unknown wallpaper surface.") }
    if let mode = WallpaperRuntime.field("presentationMode", in: request) {
      surface.presentation = WallpaperRuntime.enumCase(mode)
    }
    if let activity = WallpaperRuntime.field("activityState", in: request) {
      surface.activity = WallpaperRuntime.enumCase(activity)
    }
    surface.applyPolicy()
    WallpaperRuntime.log(
      "Updated id=\(id) mode=\(surface.presentation) activity=\(surface.activity)")
  }

  func invalidate(id value: Any?) {
    guard let id = WallpaperRuntime.identifier(value) else { return }
    remove(id)
  }

  func snapshot(id value: Any?, reply: @escaping (Any?, Error?) -> Void) {
    guard let id = WallpaperRuntime.identifier(value), let surface = surfaces[id] else {
      reply(nil, WallpaperRuntime.failure("Unknown wallpaper surface."))
      return
    }
    surface.snapshot(reply: reply)
  }

  private func remove(_ id: UUID) {
    revisions[id] = (revisions[id] ?? 0) &+ 1
    surfaces.removeValue(forKey: id)?.stop()
  }
}
