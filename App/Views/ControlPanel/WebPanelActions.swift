import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension WebPanelController {
  func perform(_ action: String, body: [String: Any]) async throws {
    let request = WebPanelRequest(body)
    // Browsing and cancellation stay usable while a native operation awaits I/O.
    switch action {
    case "ready":
      // A page that reports ready has recovered, so a later crash may reload again.
      recoveryAttempted = false
      isReady = true
      Task { await workshop.steamCMDSetup.refresh() }
      return
    case "themeSetting":
      try theme.set(try request.string("key"), value: try request.string("value"))
      return
    case "resetTheme":
      theme.reset()
      return
    case "dismissError":
      actionError = nil
      dismissedErrorRevision = store.latestBridgeErrorRevision
      dismissedLibraryError = libraryFailureMessage
      dismissedDownloadError = workshop.downloader.errorMessage
      return
    case "navigate":
      switch try request.string("page") {
      case "installed": navigation.selection = .wallpaper
      case "discover":
        navigation.selection = .workshop
        if !workshop.hasLoaded && !workshop.isLoading { workshop.search() }
      case "settings": navigation.selection = .settings
      default: throw WebPanelRequest.invalid
      }
      return
    case "workshopSearch":
      guard let kind = WorkshopKind(rawValue: try request.string("kind")),
        let sort = WorkshopSort(rawValue: try request.string("sort")),
        let tags = body["tags"] as? [String], tags.count <= 32, tags.allSatisfy({ $0.count <= 128 })
      else { throw WebPanelRequest.invalid }
      workshop.searchText = try request.string("text")
      workshop.kind = kind
      workshop.sort = sort
      workshop.tags = tags
      workshop.search()
      return
    case "workshopPage":
      workshop.loadPage(Int(try request.number("page", range: 1...1_000_000)))
      return
    case "workshopRetry":
      workshop.retrySearch()
      return
    case "workshopPageSize":
      let range = WorkshopStore.pageSizeRange
      workshop.setPageSize(
        Int(try request.number("size", range: Double(range.lowerBound)...Double(range.upperBound))))
      return
    case "workshopFilters":
      guard let collapsed = body["collapsed"] as? Bool else { throw WebPanelRequest.invalid }
      workshopFiltersCollapsed = collapsed
      defaults.set(collapsed, forKey: Self.workshopFiltersCollapsedKey)
      return
    case "inspectorWidth":
      if body["width"] == nil || body["width"] is NSNull {
        inspectorWidth = nil
        defaults.removeObject(forKey: Self.inspectorWidthKey)
      } else {
        let width = try request.number("width", range: Self.inspectorWidthRange).rounded()
        inspectorWidth = width
        defaults.set(width, forKey: Self.inspectorWidthKey)
      }
      return
    case "workshopSelect":
      guard let id = body["id"] as? String, let item = workshop.workshopItem(id: id) else {
        throw WebPanelRequest.invalid
      }
      workshop.selectedItem = item
      return
    case "importCancel":
      importTask?.cancel()
      importStatus = "Cancelling…"
      return
    case "downloadCancel":
      workshop.downloader.cancel(try download(request))
      return
    case "downloadInput":
      let job = try download(request)
      let secret = try request.string("value")
      guard job.worker.prompt != nil, !secret.isEmpty,
        !secret.contains(where: { $0.isNewline || $0 == "\0" })
      else { throw WebPanelRequest.invalid }
      job.worker.submitSecret(secret)
      return
    case "setupCancel":
      workshop.steamCMDSetup.cancel()
      return
    case "checkForUpdates":
      _ = await updater.checkForUpdates()
      return
    case "downloadUpdate":
      _ = await updater.downloadUpdate()
      return
    case "openReleases":
      updater.openReleases()
      return
    case "revealDownloadedUpdate":
      updater.revealDownloadedUpdate()
      return
    default: break
    }
    guard !commandBusy else {
      throw WallpaperActionError(message: "Wait for the current action to finish.")
    }
    commandBusy = true
    actionError = nil
    scheduleUpdate()
    defer { commandBusy = false }
    switch action {
    case "target":
      let id = try request.string("id")
      guard
        store.settingsSnapshot.displays.contains(where: {
          $0.displayId == id && $0.enabled && $0.mode == .standalone
        })
      else { throw WebPanelRequest.invalid }
      navigation.targetDisplayID = id
    case "select": try await store.selectWallpaperAsync(id: try wallpaperID(request))
    case "favorite":
      let id = try wallpaperID(request)
      if !favoriteIDs.insert(id).inserted { favoriteIDs.remove(id) }
      UserDefaults.standard.set(
        try JSONEncoder().encode(favoriteIDs.sorted()), forKey: Self.favoriteKey)
    case "activate":
      try await store.activateWallpaperAsync(
        id: try wallpaperID(request), displayId: navigation.targetDisplayID)
    case "apply": try await store.applyWallpaperOptionsAsync(wallpaperId: try wallpaperID(request))
    case "revert":
      try await store.cancelWallpaperOptionsAsync(wallpaperId: try wallpaperID(request))
    case "refresh":
      try await store.refreshAllAsync()
      try await store.refreshLibraryAsync()
    case "playback":
      if store.appSnapshot.playbackState == .paused {
        try await store.playAllAsync()
      } else {
        try await store.pauseAllAsync()
      }
    case "delete":
      let id = try wallpaperID(request)
      let title = store.librarySnapshot.wallpapers.first { $0.id == id }?.title ?? id
      if await confirm(
        "Move \(title) to Trash?",
        detail:
          "This removes the library copy and stops it on its displays. Original imports stay untouched.",
        button: "Move to Trash")
      {
        try await store.deleteWallpaperAsync(id: id)
        try forgetFavorites([id])
      }
    case "deleteMany":
      let ids = try wallpaperIDs(request)
      let title =
        ids.count == 1
        ? "Move \(store.librarySnapshot.wallpapers.first(where: { $0.id == ids[0] })?.title ?? ids[0]) to Trash?"
        : "Move \(ids.count) wallpapers to Trash?"
      if await confirm(
        title,
        detail:
          "This removes the library copies and stops them on their displays. Original imports stay untouched.",
        button: "Move to Trash")
      {
        let report = try await store.deleteWallpapersAsync(ids: ids)
        try forgetFavorites(report.deleted)
        if !report.failures.isEmpty {
          let titles = Dictionary(
            store.librarySnapshot.wallpapers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
          let details = report.failures.map { "\(titles[$0.id] ?? $0.id): \($0.error.localizedDescription)" }
          throw WallpaperActionError(
            message:
              "Moved \(report.deleted.count) of \(ids.count) wallpapers to Trash. Couldn't move \(details.joined(separator: "; "))"
          )
        }
      }
    case "reveal":
      NSWorkspace.shared.activateFileViewerSelecting([
        ClientPaths.libraryURL.appendingPathComponent(try wallpaperID(request))
      ])
    case "import": try await beginImport(request)
    case "wallpaperSetting": try await wallpaperSetting(request)
    case "displayConfig": try await displayConfig(request)
    case "property":
      let id = try wallpaperID(request)
      let propertyID = try request.string("propertyID")
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let descriptor = options.properties.first(where: { $0.id == propertyID && $0.enabled })
      else { throw WebPanelRequest.invalid }
      let value = try propertyValue(body["value"], descriptor: descriptor)
      try await store.editPropertyAsync(wallpaperId: id, propertyId: propertyID, value: value)
    case "restoreProperty":
      try await store.restorePropertyDefaultAsync(
        wallpaperId: try wallpaperID(request), propertyId: try request.string("propertyID"))
    case "choosePropertyFile":
      let id = try wallpaperID(request)
      let propertyID = try request.string("propertyID")
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard
        options.properties.contains(where: {
          $0.id == propertyID && $0.enabled && $0.kind == .directory
        })
      else { throw WebPanelRequest.invalid }
      let panel = NSOpenPanel()
      panel.title = "Choose Image"
      panel.allowedContentTypes = [.image]
      if await choose(panel), let url = panel.url {
        try await store.editPropertyAsync(
          wallpaperId: id, propertyId: propertyID, value: .string(value: url.path))
      }
    case "setting":
      let key = try request.string("key")
      switch key {
      case "launchAtLogin":
        try await store.setLaunchAtLoginAsync(enabled: try request.boolean("value"))
      case "pauseOnBattery":
        try await store.setPauseOnBatteryPowerAsync(enabled: try request.boolean("value"))
      case "keepWindowsOnWallpaperClick":
        try DesktopClickRevealPreference.setEnabled(!(try request.boolean("value")))
      case "lockScreenEnabled":
        guard let lock = store.lockScreenWallpaper else {
          throw WallpaperActionError(message: "Lock Screen integration is unavailable.")
        }
        lock.setEnabled(try request.boolean("value"))
      case "videoBackend":
        let mode = try request.string("value")
        // Refuse an unknown mode instead of falling back: silently substituting
        // Compatibility would leave the page reporting a choice never applied.
        guard Self.videoBackendModes.contains(mode) else { throw WebPanelRequest.invalid }
        try await store.setVideoBackendAsync(mode)
      case "renderScale":
        try await store.setRenderScaleAsync(
          Float(try request.clampedNumber("value", to: Self.renderScaleRange)))
      case "contentPacing":
        try await store.setContentPacingEnabledAsync(try request.boolean("value"))
      case "sharedVideoDecode":
        try await store.setSharedVideoDecodeEnabledAsync(try request.boolean("value"))
      case "batteryProfileEnabled", "batteryRenderScale", "batteryTargetFps":
        try await setBatteryQualityProfile(key: key, request: request)
      default: throw WebPanelRequest.invalid
      }
    case "lockScreenRetry": store.lockScreenWallpaper?.refresh()
    case "displaySetting": try await displaySetting(request)
    case "eject":
      try await store.ejectWallpaperFromDisplayAsync(
        displayId: try request.string("displayID"), wallpaperId: try wallpaperID(request))
    case "refreshDisplays": try await store.refreshDisplaysAsync()
    case "locateAssets":
      let panel = NSOpenPanel()
      panel.title = "Locate Scene Assets"
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      if await choose(panel), let url = panel.url {
        try ClientPaths.configureAssetsFolder(at: url)
        workshop.refreshSceneAssetsReadiness()
        // Located assets satisfy the need, so the waiting intent is finished, not downloaded.
        workshop.removeDownloadRequest(id: WorkshopStore.sceneAssetsRequestID)
      }
    case "showLibrary": NSWorkspace.shared.open(ClientPaths.libraryURL)
    case "showLogs": NSWorkspace.shared.open(try store.logFolderURL())
    case "clearCache":
      if await confirm(
        "Clear shader cache?",
        detail: "Shaders will be rebuilt the next time wallpapers need them.", button: "Clear Cache"
      ) {
        try await store.clearShaderCacheAsync()
      }
    case "clearLogs":
      if await confirm(
        "Clear logs?", detail: "This removes diagnostic logs, not wallpapers or settings.",
        button: "Clear Logs")
      {
        try store.clearLogsAsync()
      }
    case "setupInstall":
      let exists = FileManager.default.fileExists(atPath: ClientPaths.managedSteamCMDURL.path)
      if workshop.steamCMDSetup.retainedCandidateURL != nil {
        workshop.steamCMDSetup.retryInstallation()
      } else {
        let approved =
          exists
          ? await confirm(
            "Reinstall SteamCMD?",
            detail:
              "Replace only the managed download tool after validation. Wallpapers and saved sign-in are kept.",
            button: "Reinstall") : true
        if approved { workshop.steamCMDSetup.install(replacingExisting: exists) }
      }
    case "setupLocate":
      let panel = NSOpenPanel()
      panel.title = "Locate SteamCMD"
      panel.canChooseDirectories = true
      panel.canChooseFiles = true
      if await choose(panel), let url = panel.url { workshop.steamCMDSetup.selectExisting(at: url) }
    case "setupApprove":
      let candidate = try await workshop.steamCMDSetup.prepareApproval()
      if await confirm(
        "Allow this SteamCMD installation?",
        detail:
          "This runs software macOS has not approved and may put your data at risk. Only files matching this fingerprint will be allowed. Quarantine is removed from this copy only; global Gatekeeper and signature checks stay enabled.\n\nPath: \(candidate.rootURL.path)\nSHA-256: \(candidate.fingerprint)",
        button: "Allow This Copy and Continue")
      {
        workshop.steamCMDSetup.approveRetainedCandidate(candidate)
      }
    case "setupRevealCandidate":
      if let url = workshop.steamCMDSetup.retainedCandidateURL {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    case "setupDiscardCandidate":
      if await confirm(
        "Discard downloaded SteamCMD?",
        detail:
          "Only the retained candidate is removed. The installed runtime and saved sign-in are kept.",
        button: "Discard Download")
      {
        workshop.steamCMDSetup.discardRetainedCandidate()
      }
    case "requestDownload":
      let item: WorkshopItem?
      if let id = body["id"] as? String, id != WorkshopStore.sceneAssetsRequestID {
        guard let found = workshop.workshopItem(id: id) else { throw WebPanelRequest.invalid }
        item = found
      } else {
        item = nil
      }
      workshop.requestDownload(item: item, rememberSession: remembersSession, bridge: store)
      try checkDownloadError()
    case "continueDownload":
      let account = try request.string("account")
      remembersSession = try request.boolean("rememberSession")
      guard
        workshop.continueDownload(
          id: try request.string("id"), account: account, rememberSession: remembersSession,
          includeResources: try request.boolean("includeResources"), bridge: store)
      else { throw WebPanelRequest.invalid }
      try checkDownloadError()
    case "removeDownloadRequest":
      // Dismissal is idempotent: a request that just started is already gone from the queue.
      workshop.removeDownloadRequest(id: try request.string("id"))
    case "changeDownloadAccount":
      await workshop.changeDownloadAccount(id: try download(request).id)
    case "downloadRetry":
      let job = try download(request)
      guard !job.isPending else { throw WebPanelRequest.invalid }
      // A retry re-enters the same prerequisite ladder; shared assets need consent again.
      workshop.continueDownload(
        id: job.id, account: job.account, rememberSession: remembersSession,
        includeResources: false, bridge: store)
      try checkDownloadError()
    case "clearDownloads": workshop.clearDownloadActivity()
    case "forgetAccount":
      if await confirm(
        "Forget Steam sign-in?",
        detail: "The saved session will be removed. You can sign in again for your next download.",
        button: "Forget Sign-in")
      {
        workshop.downloader.forgetSavedAccount()
        if let error = workshop.downloader.errorMessage {
          throw WallpaperActionError(message: error)
        }
      }
    case "openExternal":
      guard let url = URL(string: try request.string("url")), Self.allowedExternalURL(url) else {
        throw WebPanelRequest.invalid
      }
      NSWorkspace.shared.open(url)
    case "installUpdate":
      if await confirm(
        String(localized: "Restart and install this update?"),
        detail: String(
          localized: "The current app will quit and be replaced. Wallpapers and settings are kept."),
        button: String(localized: "Restart and Install"))
      {
        await updater.installUpdate()
      }
    default: throw WebPanelRequest.invalid
    }
  }

  func wallpaperID(_ request: WebPanelRequest) throws -> String {
    let id = try request.string("id")
    guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
      throw WallpaperActionError(
        message: "This wallpaper is no longer installed. Refresh your library.")
    }
    return id
  }

  /// Distinct installed ids, in request order; any unknown id rejects the whole batch.
  func wallpaperIDs(_ request: WebPanelRequest) throws -> [String] {
    guard let raw = request.body["ids"] as? [String], !raw.isEmpty, raw.count <= 4096 else {
      throw WebPanelRequest.invalid
    }
    let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
    var seen = Set<String>()
    let ids = raw.filter { seen.insert($0).inserted }
    guard ids.allSatisfy(installed.contains) else {
      throw WallpaperActionError(
        message: "Some selected wallpapers are no longer installed. Refresh your library.")
    }
    return ids
  }

  func forgetFavorites(_ ids: [String]) throws {
    guard ids.contains(where: favoriteIDs.contains) else { return }
    favoriteIDs.subtract(ids)
    UserDefaults.standard.set(
      try JSONEncoder().encode(favoriteIDs.sorted()), forKey: Self.favoriteKey)
  }

  func download(_ request: WebPanelRequest) throws -> WorkshopDownload {
    guard
      let job = workshop.downloader.downloads.first(where: {
        $0.id == (request.body["id"] as? String)
      })
    else { throw WebPanelRequest.invalid }
    return job
  }

  func checkDownloadError() throws {
    if let error = workshop.downloader.errorMessage {
      throw WallpaperActionError(message: error)
    }
  }

  func wallpaperSetting(_ request: WebPanelRequest) async throws {
    let id = try wallpaperID(request)
    switch try request.string("key") {
    case "volume":
      try await store.setVolumeAsync(
        wallpaperId: id, volume: Float(try request.number("value", range: 0...1)))
    case "muted":
      try await store.setMutedAsync(wallpaperId: id, muted: try request.boolean("value"))
    case "audioResponseEnabled":
      try await store.setAudioResponseEnabledAsync(
        wallpaperId: id, enabled: try request.boolean("value"))
    default: throw WebPanelRequest.invalid
    }
  }

  func displayConfig(_ request: WebPanelRequest) async throws {
    let id = try wallpaperID(request)
    let display = try request.string("displayID")
    switch try request.string("key") {
    case "enabled":
      try await store.setDisplayConfigEnabledAsync(
        wallpaperId: id, displayId: display, enabled: try request.boolean("value"))
    case "scalingMode":
      try await store.setScalingModeAsync(
        wallpaperId: id, displayId: display, mode: try request.scaling())
    case "scalingFactor":
      try await store.editScalingFactorAsync(
        wallpaperId: id, displayId: display,
        factor: try request.number(
          "value", range: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude))
    case "fps":
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let row = options.displayConfigurations.first(where: { $0.displayId == display }) else {
        throw WebPanelRequest.invalid
      }
      try await store.setTargetFpsAsync(
        wallpaperId: id, displayId: display,
        fps: UInt32(try request.number("value", range: 1...Double(max(1, row.maxFps)))))
    default: throw WebPanelRequest.invalid
    }
  }

  func displaySetting(_ request: WebPanelRequest) async throws {
    let id = try request.string("displayID")
    let key = try request.string("key")
    guard let display = store.settingsSnapshot.displays.first(where: { $0.displayId == id }) else {
      throw WebPanelRequest.invalid
    }
    switch key {
    case "enabled":
      try await store.setDisplayEnabledAsync(displayId: id, enabled: try request.boolean("value"))
    case "mode":
      let mode = try request.string("value")
      guard ["standalone", "mirror"].contains(mode) else { throw WebPanelRequest.invalid }
      try await store.setDisplayModeAsync(
        displayId: id, mode: mode == "mirror" ? .mirror : .standalone)
    case "mirrorTarget":
      try await store.setMirrorTargetAsync(
        displayId: id, targetDisplayId: try request.string("value"))
    default:
      if display.mode == .mirror {
        switch key {
        case "scalingMode":
          try await store.setMirrorScalingModeAsync(displayId: id, mode: try request.scaling())
        case "scalingFactor":
          try await store.setMirrorScalingFactorAsync(
            displayId: id,
            factor: try request.number(
              "value", range: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude))
        case "fps":
          try await store.setMirrorTargetFpsAsync(
            displayId: id,
            fps: UInt32(try request.number("value", range: 1...Double(max(1, display.maxFps)))))
        case "volume":
          try await store.setMirrorVolumeAsync(
            displayId: id, volume: Float(try request.number("value", range: 0...1)))
        case "muted":
          try await store.setMirrorMutedAsync(displayId: id, muted: try request.boolean("value"))
        default: throw WebPanelRequest.invalid
        }
      } else {
        guard
          let wallpaper = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == id }
          )?.wallpaperId
        else {
          throw WallpaperActionError(message: "Choose a wallpaper for this display first.")
        }
        var body = request.body
        body["id"] = wallpaper
        if key == "volume" || key == "muted" {
          try await wallpaperSetting(WebPanelRequest(body))
        } else {
          try await displayConfig(WebPanelRequest(body))
        }
        try await store.applyWallpaperOptionsAsync(wallpaperId: wallpaper)
      }
    }
  }

  func propertyValue(_ value: Any?, descriptor: BridgePropertyDescriptor) throws
    -> BridgePropertyValue
  {
    switch descriptor.kind {
    case .bool: return .bool(value: try WebPanelRequest(["value": value as Any]).boolean("value"))
    case .slider:
      return .number(
        value: try WebPanelRequest(["value": value as Any]).number(
          "value", range: (descriptor.slider?.min ?? 0)...(descriptor.slider?.max ?? 1)))
    case .textInput, .directory:
      guard let value = value as? String, value.count <= 65_536 else {
        throw WebPanelRequest.invalid
      }
      return .string(value: value)
    case .color:
      guard let hex = value as? String, hex.count == 7, hex.first == "#",
        let rgb = UInt32(hex.dropFirst(), radix: 16)
      else { throw WebPanelRequest.invalid }
      return .colorRgb(
        red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
        blue: Double(rgb & 255) / 255)
    case .combo:
      guard let value,
        let option = descriptor.comboOptions.first(where: {
          NSDictionary(dictionary: ["v": Self.propertyValue($0.value)]).isEqual(to: ["v": value])
        })
      else { throw WebPanelRequest.invalid }
      return option.value
    default: throw WebPanelRequest.invalid
    }
  }

  func beginImport(_ request: WebPanelRequest) async throws {
    guard importTask == nil else {
      throw WallpaperActionError(message: "An import is already running.")
    }
    let policy =
      (request.body["duplicates"] as? String) == "keepBoth"
      ? WallpaperImportService.DuplicatePolicy.keepBoth : .skip
    let panel = NSOpenPanel()
    panel.title = "Import Wallpapers"
    panel.message =
      "Choose videos, project folders, or a Steam library. Originals are kept. Web projects can be imported but cannot be played."
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = false
    panel.allowedContentTypes =
      [.folder]
      + WallpaperImportService.videoExtensions.union(WallpaperImportService.webExtensions).sorted()
      .compactMap { UTType(filenameExtension: $0) }
    guard await choose(panel) else { return }
    let urls = panel.urls
    importStatus = "Preparing import…"
    importReport = nil
    importTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.importTask = nil
        self.scheduleUpdate()
      }
      do {
        self.importReport = try await WallpaperImportService().importItems(
          urls, into: ClientPaths.libraryURL, duplicates: policy
        ) { [weak self] status in
          guard let self else { return }
          await MainActor.run {
            self.importStatus = status
            self.scheduleUpdate()
          }
        }
        let refresh = Task { @MainActor in try await self.store.refreshLibraryAsync() }
        try await refresh.value
        self.importStatus =
          self.importReport?.cancelled == true ? "Import cancelled" : "Import complete"
      } catch {
        self.actionError = error.localizedDescription
        self.importStatus = "Import could not finish"
      }
    }
  }

  func choose(_ panel: NSOpenPanel) async -> Bool {
    guard let window = webView?.window else { return false }
    return await withCheckedContinuation { continuation in
      panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK) }
    }
  }

  static let videoBackendModes = ["compatibility", "native_preferred"]
  static let renderScaleRange: ClosedRange<Double> = 0.25...1
  static let batteryTargetFpsRange: ClosedRange<Double> = 1...240

  /// The engine owns the battery profile as one value, so a single changed control
  /// is merged with the other two as the engine currently reports them.
  func setBatteryQualityProfile(key: String, request: WebPanelRequest) async throws {
    let settings = store.settingsSnapshot
    var enabled = settings.batteryProfileEnabled
    var scale = settings.batteryRenderScale
    var fps = settings.batteryTargetFps
    switch key {
    case "batteryProfileEnabled": enabled = try request.boolean("value")
    case "batteryRenderScale":
      scale = Float(try request.clampedNumber("value", to: Self.renderScaleRange))
    case "batteryTargetFps":
      fps = UInt32(try request.clampedNumber("value", to: Self.batteryTargetFpsRange).rounded())
    default: throw WebPanelRequest.invalid
    }
    try await store.setBatteryQualityProfileAsync(
      enabled: enabled, renderScale: scale, targetFps: fps)
  }

  func confirm(_ title: String, detail: String, button: String) async -> Bool {
    guard let window = webView?.window else { return false }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) {
        continuation.resume(returning: $0 == .alertFirstButtonReturn)
      }
    }
  }

  static func allowedExternalURL(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else {
      return false
    }
    return [
      "steamcommunity.com", "store.steampowered.com", "github.com", "www.gnu.org",
      "support.apple.com",
    ].contains(url.host ?? "")
  }
}

struct WebPanelRequest {
  let body: [String: Any]
  init(_ body: [String: Any]) { self.body = body }
  static var invalid: WallpaperActionError {
    WallpaperActionError(
      message: "This control sent an invalid value. Refresh the interface and retry.")
  }
  func string(_ key: String) throws -> String {
    guard let value = body[key] as? String, value.count <= 65_536 else { throw Self.invalid }
    return value
  }
  func boolean(_ key: String) throws -> Bool {
    guard let value = body[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
      throw Self.invalid
    }
    return value.boolValue
  }
  func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
    guard let value = body[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite, range.contains(value.doubleValue)
    else { throw Self.invalid }
    return value.doubleValue
  }
  /// Quality values are clamped rather than refused: every control only offers
  /// values inside the range, so an outlier means a stale page, and the user's
  /// intent (the nearest supported quality) is still unambiguous.
  func clampedNumber(_ key: String, to range: ClosedRange<Double>) throws -> Double {
    guard let value = body[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite
    else { throw Self.invalid }
    return min(max(value.doubleValue, range.lowerBound), range.upperBound)
  }
  func scaling() throws -> BridgeScalingMode {
    switch try string("value") {
    case "none": .none
    case "stretch": .stretch
    case "match": .match
    case "fill": .fill
    default: throw Self.invalid
    }
  }
}
