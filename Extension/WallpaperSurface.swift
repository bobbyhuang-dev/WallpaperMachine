import AppKit
import IOSurface
import Metal

/// One WallpaperID is one compositor surface: never share a CAContext across Spaces.
@MainActor
final class WallpaperSurface {
  let context: CAContext
  let root: CALayer
  private(set) var scene: LockScreenScene
  let displayID: UInt32?
  let size: CGSize
  let scale: CGFloat
  let preview: Bool
  var presentation = "active"
  var activity = "active"
  private var layer: CAMetalLayer?
  private var renderer: OpaquePointer?
  private var frameObserver: NSObjectProtocol?
  private var firstFrameReply: ((Error?) -> Void)?
  private var readyWaiters: [(Error?) -> Void] = []
  private var deadline: Task<Void, Never>?
  private var snapshotWaiters: [(Any?, Error?) -> Void] = []
  private var snapshotDeadline: Task<Void, Never>?
  private var latestSnapshot: IOSurface?
  private var stopped = false
  var hasRenderer: Bool { renderer != nil }
  private var rendererPaused = false
  /// When this surface started presenting, set once its first frame arrived.
  /// Kept apart from readiness so rendering one frame for a snapshot or a
  /// readiness reply cannot become a permanent right to keep rendering.
  private var presentingSince: ContinuousClock.Instant?
  private var previewExpiry: Task<Void, Never>?
  /// An explicit opt-in for a preview that has to keep animating. No host
  /// request sets it today; it exists so the bounded behaviour has a documented
  /// escape hatch rather than being unconditional.
  var continuousPreviewRequested = false
  private let counters: RuntimeCounters
  private var surfaceKey: RuntimeSurfaceKey {
    RuntimeSurfaceKey(
      kind: preview ? .preview : .lockScreen, displayID: scene.displayID, generation: generation)
  }
  private let generation: UInt64

  init(
    scene: LockScreenScene, displayID: UInt32?, size: CGSize, scale: CGFloat, preview: Bool,
    generation: UInt64 = 0, counters: RuntimeCounters? = nil
  ) throws {
    guard size.width.isFinite, size.height.isFinite, scale.isFinite,
      size.width > 0, size.height > 0, scale > 0,
      size.width * scale <= 16_384, size.height * scale <= 16_384,
      size.width * size.height * scale * scale <= 32 * 1024 * 1024
    else {
      throw WallpaperRuntime.failure("Invalid wallpaper surface dimensions.")
    }
    self.scene = scene
    self.displayID = displayID
    self.size = size
    self.scale = scale
    self.preview = preview
    self.generation = generation
    self.counters = counters ?? .shared
    context = try WallpaperRuntime.context(displayID: displayID)
    root = CALayer()
    root.frame = CGRect(origin: .zero, size: size)
    root.contentsScale = scale
    context.layer = root
    CATransaction.flush()
  }

  func start(completion: @escaping (Error?) -> Void) {
    guard !stopped, renderer == nil else {
      completion(WallpaperRuntime.failure("Wallpaper surface is not available."))
      return
    }
    do {
      let project = try WallpaperRuntime.asset(scene.projectPath)
      let assets = try WallpaperRuntime.asset(scene.assetsPath)
      guard scene.fps > 0, (0...3).contains(scene.scalingMode), scene.scalingFactor.isFinite,
        scene.scalingFactor > 0
      else {
        throw WallpaperRuntime.failure("Invalid lock-screen playback configuration.")
      }
      let cache = WallpaperRuntime.documents.appendingPathComponent("ShaderCache")
        .appendingPathComponent(project.deletingLastPathComponent().lastPathComponent)
      try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
      let metal = CAMetalLayer()
      metal.device = MTLCreateSystemDefaultDevice()
      metal.frame = root.bounds
      metal.contentsScale = scale
      metal.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
      metal.pixelFormat = .bgra8Unorm
      metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
      metal.framebufferOnly = false
      guard metal.device != nil else {
        throw WallpaperRuntime.failure("Metal rendering is unavailable.")
      }
      root.addSublayer(metal)
      layer = metal
      CATransaction.flush()
      frameObserver = NotificationCenter.default.addObserver(
        forName: .init("MacWallpaperEngine.desktopPosterReady"), object: metal, queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated { self?.receive(notification) }
      }
      try check(owe_scene_wallpaper_new(&renderer))
      try check(owe_scene_wallpaper_init(renderer))
      try check(
        owe_scene_wallpaper_init_metal_vulkan(
          renderer, Unmanaged.passUnretained(metal).toOpaque(), UInt32(metal.drawableSize.width),
          UInt32(metal.drawableSize.height), 0, 0, Double(scale)))
      // The lock-screen process never plays sound, reads input, or receives media data.
      try check(owe_scene_wallpaper_set_audio_muted(renderer, true))
      try check(
        owe_scene_wallpaper_set_property_bool(
          renderer, owe_property_audio_response_enabled(), false))
      try check(
        owe_scene_wallpaper_apply_config(
          renderer, project.path, assets.path, cache.path, scene.fps, false, false,
          scene.propertiesJSON))
      try check(
        owe_scene_wallpaper_set_property_bool(
          renderer, owe_property_media_integration_enabled(), false))
      try check(
        owe_scene_wallpaper_set_property_int32(
          renderer, owe_property_scaling_mode(), scene.scalingMode))
      try check(
        owe_scene_wallpaper_set_property_float(
          renderer, owe_property_scaling_factor(), Float(scene.scalingFactor)))
      firstFrameReply = completion
      requestFrame()
      deadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self, let reply = self.firstFrameReply else { return }
        self.firstFrameReply = nil
        self.stop()
        reply(
          WallpaperRuntime.failure(
            "The lock-screen renderer did not produce a frame within 30 seconds."))
      }
    } catch {
      stop()
      completion(error)
    }
  }

  private func check(_ result: Int32) throws {
    guard result != 0 else { return }
    let message = owe_last_error().map { String(cString: $0) } ?? "Unknown native rendering error."
    throw WallpaperRuntime.failure(message)
  }

  private func requestFrame() {
    if let layer {
      NotificationCenter.default.post(
        name: .init("MacWallpaperEngine.requestDesktopPoster"), object: layer)
    }
  }

  private func receive(_ notification: Notification) {
    guard !stopped, let data = notification.userInfo?["pixels"] as? Data,
      let width = notification.userInfo?["width"] as? Int,
      let height = notification.userInfo?["height"] as? Int,
      let bgra = notification.userInfo?["bgra"] as? Bool
    else { return }
    do {
      latestSnapshot = try Self.snapshot(data, width: width, height: height, bgra: bgra)
      if let reply = firstFrameReply {
        firstFrameReply = nil
        deadline?.cancel()
        deadline = nil
        presentingSince = ContinuousClock.now
        counters.record(.readinessFrameRendered, for: surfaceKey)
        applyPolicy()
        WallpaperRuntime.log(
          "Frame ready display=\(scene.displayID) context=\(context.contextId) pixels=\(width)x\(height)"
        )
        reply(nil)
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0(nil) }
      }
      finishSnapshots(error: nil)
    } catch {
      if let reply = firstFrameReply {
        firstFrameReply = nil
        stop()
        reply(error)
      }
      finishSnapshots(error: error)
    }
  }

  private static func snapshot(_ data: Data, width: Int, height: Int, bgra: Bool) throws
    -> IOSurface
  {
    guard width > 0, height > 0, width <= 16_384, height <= 16_384,
      width * height <= 32 * 1024 * 1024, data.count == width * height * 4,
      let provider = CGDataProvider(data: data as CFData)
    else { throw CocoaError(.fileReadCorruptFile) }
    let bitmap =
      bgra
      ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
      : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
    guard
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let surface = IOSurface(properties: [
        .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,
      ])
    else { throw CocoaError(.fileReadCorruptFile) }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    guard
      let target = CGContext(
        data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw CocoaError(.fileReadCorruptFile) }
    target.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return surface
  }

  func update(scene: LockScreenScene) {
    self.scene = scene
    if let renderer {
      do { try check(owe_scene_wallpaper_set_target_fps(renderer, scene.fps)) } catch {
        WallpaperRuntime.log(error.localizedDescription)
      }
    }
    applyPolicy()
  }

  /// Presentation eligibility for this surface, decided by the rules both
  /// processes share. A preview is bounded in time: producing the readiness
  /// frame must not buy it the right to animate for as long as a settings
  /// window happens to stay open.
  private var authorityRequest: WallpaperPresentationAuthority.Request {
    // Native desktop is a frozen poster; the ordinary desktop renderer remains live.
    let locked =
      (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
      ?? false
    return WallpaperPresentationAuthority.Request(
      role: preview ? .preview : .lockScreen,
      userPaused: scene.paused,
      displaysAsleep: WallpaperController.shared.displaysAsleep,
      sessionLocked: locked,
      presentationMode: presentation,
      hostActivity: activity == "suspended" ? .suspended : .active,
      presentedFor: presentingSince.map { ContinuousClock.now - $0 },
      continuousPreviewRequested: continuousPreviewRequested)
  }

  func applyPolicy() {
    guard let renderer, firstFrameReply == nil, !stopped else { return }
    let request = authorityRequest
    let reasons = WallpaperPresentationAuthority.suspensionReasons(for: request)
    let shouldPause = !reasons.isEmpty
    schedulePreviewExpiry(for: request)
    guard shouldPause != rendererPaused else { return }
    do {
      try check(owe_scene_wallpaper_set_paused(renderer, shouldPause))
      rendererPaused = shouldPause
      counters.record(shouldPause ? .presentationSuspended : .presentationAuthorized, for: surfaceKey)
      WallpaperRuntime.log(
        "Playback display=\(scene.displayID) mode=\(presentation) activity=\(activity) locked=\(request.sessionLocked) paused=\(shouldPause) reasons=\(reasons.rawValue)"
      )
    } catch { WallpaperRuntime.log(error.localizedDescription) }
  }

  /// Re-evaluates a preview when its budget runs out, so it stops on its own
  /// rather than waiting for a host update that may never come.
  private func schedulePreviewExpiry(for request: WallpaperPresentationAuthority.Request) {
    previewExpiry?.cancel()
    previewExpiry = nil
    guard let remaining = WallpaperPresentationAuthority.nextReevaluation(for: request) else {
      return
    }
    previewExpiry = Task { [weak self] in
      do { try await Task.sleep(for: remaining) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.previewExpiry = nil
      self.applyPolicy()
    }
  }

  func snapshot(reply: @escaping (Any?, Error?) -> Void) {
    if rendererPaused || stopped {
      do {
        guard let latestSnapshot else {
          throw WallpaperRuntime.failure("Wallpaper frame is not ready.")
        }
        reply(try WallpaperRuntime.snapshotReply(latestSnapshot), nil)
      } catch { reply(nil, error) }
      return
    }
    snapshotWaiters.append(reply)
    requestFrame()
    guard snapshotDeadline == nil else { return }
    snapshotDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      // A frame already known to have been presented is safe if rendering paused meanwhile.
      self?.finishSnapshots(
        error: self?.latestSnapshot == nil
          ? WallpaperRuntime.failure("Wallpaper snapshot timed out.") : nil)
    }
  }

  private func finishSnapshots(error: Error?) {
    snapshotDeadline?.cancel()
    snapshotDeadline = nil
    let waiters = snapshotWaiters
    snapshotWaiters.removeAll()
    for reply in waiters {
      do {
        if let error { throw error }
        guard let latestSnapshot else {
          throw WallpaperRuntime.failure("Wallpaper snapshot is unavailable.")
        }
        reply(try WallpaperRuntime.snapshotReply(latestSnapshot), nil)
      } catch { reply(nil, error) }
    }
  }

  func whenReady(_ reply: @escaping (Error?) -> Void) {
    if stopped {
      reply(CancellationError())
    } else if latestSnapshot != nil {
      reply(nil)
    } else {
      readyWaiters.append(reply)
    }
  }

  func replace(scene: LockScreenScene, completion: @escaping (Error?) -> Void) {
    guard !stopped else {
      completion(CancellationError())
      return
    }
    releaseRenderer()
    self.scene = scene
    rendererPaused = false
    start(completion: completion)
  }

  private func releaseRenderer() {
    deadline?.cancel()
    deadline = nil
    previewExpiry?.cancel()
    previewExpiry = nil
    presentingSince = nil
    if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    frameObserver = nil
    if let renderer {
      _ = owe_scene_wallpaper_begin_surface_reconfigure(renderer)
      _ = owe_scene_wallpaper_shutdown(renderer)
      _ = owe_scene_wallpaper_delete(renderer)
    }
    renderer = nil
    layer?.removeFromSuperlayer()
    layer = nil
    if let reply = firstFrameReply {
      firstFrameReply = nil
      reply(CancellationError())
    }
    let waiters = readyWaiters
    readyWaiters.removeAll()
    waiters.forEach { $0(CancellationError()) }
    finishSnapshots(error: CancellationError())
    latestSnapshot = nil
  }

  func clear() {
    releaseRenderer()
    CATransaction.flush()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    releaseRenderer()
    context.invalidate()
  }
}
