import Foundation

@MainActor
extension WebPanelController {
  /// Register native dependencies without materializing a page payload while hidden.
  func trackSnapshotDependencies() {
    _ = store.appSnapshot
    _ = store.librarySnapshot
    _ = store.wallpaperOptionsSnapshot
    _ = store.monitorInformationSnapshot
    _ = store.settingsSnapshot
    _ = store.snapshotRevision
    _ = store.libraryLoadState
    _ = store.activatingWallpaperID
    _ = store.applyingWallpaperID
    _ = store.latestBridgeErrorMessage
    _ = store.latestBridgeErrorRevision
    let lock = store.lockScreenWallpaper
    _ = lock?.isRequested
    _ = lock?.isBusy
    _ = lock?.status
    _ = lock?.errorMessage
    _ = workshop.searchText
    _ = workshop.kind
    _ = workshop.sort
    _ = workshop.tags
    _ = workshop.items
    _ = workshop.selectedItem
    _ = workshop.page
    _ = workshop.totalPages
    _ = workshop.totalCount
    _ = workshop.isLoading
    _ = workshop.hasLoaded
    _ = workshop.errorMessage
    _ = workshop.sceneAssetsReady
    _ = workshop.sceneAssetsFailure
    _ = workshop.downloadRequests
    _ = workshop.username
    _ = workshop.suggestedAccount
    let setup = workshop.steamCMDSetup
    _ = setup.state
    _ = setup.isBusy
    _ = setup.selectedRuntime
    _ = setup.retainedCandidateURL
    let downloader = workshop.downloader
    _ = updater.state
    _ = downloader.savedAccount
    _ = downloader.rememberSessionWhileRunning
    _ = downloader.errorMessage
    _ = downloader.sessionConflictDetected
    for job in downloader.downloads {
      _ = job.status
      _ = job.errorMessage
      _ = job.progress
      _ = job.bytesReceived
      _ = job.bytesExpected
      _ = job.bytesPerSecond
      _ = job.isPending
      _ = job.isQueued
      _ = job.isCancelled
      let worker = job.worker
      _ = worker.steamGuardChallenge
      _ = worker.isAuthenticating
      _ = worker.errorMessage
      _ = worker.prompt
      _ = worker.sessionWarning
    }
  }

  /// A dismissal suppresses exactly the message the user dismissed; a later,
  /// different failure surfaces again, and clearing the source re-arms it.
  var libraryFailureMessage: String? {
    if case .failed(let message) = store.libraryLoadState { message } else { nil }
  }

  var downloadError: String? {
    let message = workshop.downloader.errorMessage
    return message == dismissedDownloadError ? nil : message
  }

  func reconcileDismissedErrors() {
    if libraryFailureMessage == nil { dismissedLibraryError = nil }
    if workshop.downloader.errorMessage == nil { dismissedDownloadError = nil }
  }

  /// Width the page keeps clear for the traffic lights when the window draws them over
  /// the page's top bar. Zero when the page is windowless or the lights are hidden.
  var windowControlsInset: Double {
    guard let window = webView?.window,
      window.styleMask.contains(.fullSizeContentView),
      !window.styleMask.contains(.fullScreen),
      window.titleVisibility == .hidden,
      let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview,
      !zoom.isHidden
    else { return 0 }
    return max(0, superview.convert(zoom.frame, to: nil).maxX.rounded(.up))
  }

  func snapshot() -> [String: Any] {
    let settings = store.settingsSnapshot
    let setup = workshop.steamCMDSetup
    let lock = store.lockScreenWallpaper
    let null = NSNull()
    var previews: [String: URL] = [:]
    let wallpapers: [[String: Any]] = store.librarySnapshot.wallpapers.map { entry in
      var preview: Any = null
      if let path = entry.previewPath {
        previews[entry.id] = URL(fileURLWithPath: path)
        var components = URLComponents()
        components.scheme = "mwe-ui"
        components.host = "preview"
        components.path = "/" + entry.id
        preview = components.url?.absoluteString as Any? ?? null
      }
      return [
        "id": entry.id, "title": entry.title, "kind": Self.kind(entry.kind), "preview": preview,
        "active": store.isWallpaperActive(id: entry.id, displayId: navigation.targetDisplayID),
        "supported": entry.supported, "tags": [],
      ]
    }
    assets.previews = previews
    var thumbnails: [String: URL] = [:]
    for item in workshop.items + workshop.downloader.downloads.compactMap(\.item) + workshop.downloadRequests.compactMap(\.item)
    where item.previewURL?.scheme == "https" {
      thumbnails[item.id] = item.previewURL
    }
    assets.thumbnails = thumbnails
    let titles = displayTitles.resolved()
    let displays: [[String: Any]] = settings.displays.map { display in
      let active = store.monitorInformationSnapshot.rows.first { $0.displayId == display.displayId }
      let wallpaperOptions = active.flatMap { row in
        store.wallpaperOptionsSnapshot?.wallpaperId == row.wallpaperId
          ? store.wallpaperOptionsSnapshot
          : (displayOptionsRevision == store.snapshotRevision ? displayOptions[row.wallpaperId] : nil)
      }
      let config =
        display.mode == .standalone
        ? wallpaperOptions?.displayConfigurations.first { $0.displayId == display.displayId } : nil
      return [
        "id": display.displayId, "title": titles.title(display.title, displayId: display.displayId),
        "enabled": display.enabled, "mode": display.mode == .mirror ? "mirror" : "standalone",
        "mirrorTarget": display.selectedMirrorTarget as Any? ?? null,
        "mirrorTargets": display.mirrorTargets.map { id in
          let title = settings.displays.first { $0.displayId == id }?.title ?? id
          return ["id": id, "title": titles.title(title, displayId: id)]
        }, "scalingMode": Self.scaling(config?.scalingMode ?? display.scalingMode),
        "scalingFactor": config?.scalingFactor ?? display.scalingFactor,
        "fps": config?.targetFps ?? display.targetFps, "maxFps": display.maxFps,
        "volume": config == nil ? display.volume : wallpaperOptions?.volume ?? display.volume,
        "muted": config == nil ? display.muted : wallpaperOptions?.muted ?? display.muted,
        "wallpaperID": active?.wallpaperId as Any? ?? null,
      ]
    }
    var setupError: String?
    var canApprove = false
    var setupProgress: Double?
    let setupStatus: String
    switch setup.state {
    case .idle: setupStatus = "Not installed"
    case .checking: setupStatus = "Checking SteamCMD…"
    case .downloading(let received, let expected):
      setupStatus = "Downloading SteamCMD…"
      if let expected, expected > 0 { setupProgress = min(1, Double(received) / Double(expected)) }
    case .extracting: setupStatus = "Extracting SteamCMD…"
    case .updating: setupStatus = "Completing installation…"
    case .validating: setupStatus = "Validating SteamCMD…"
    case .committing: setupStatus = "Saving installation…"
    case .ready: setupStatus = "Ready"
    case .cancelled: setupStatus = "Installation cancelled"
    case .failed(let issue):
      setupStatus = "Setup needs attention"
      setupError = issue.detail
      canApprove = issue.kind == .securityApprovalRequired && setup.retainedCandidateURL != nil
    }
    let downloads: [[String: Any]] = workshop.downloader.downloads.map { job in
      let worker = job.worker
      let challenge: String?
      switch worker.steamGuardChallenge {
      case .mobileApproval: challenge = "mobileApproval"
      case .authenticatorCode: challenge = "authenticatorCode"
      case .emailCode: challenge = "emailCode"
      case .none: challenge = nil
      }
      return [
        "id": job.id, "wallpaperID": job.item?.id as Any? ?? null,
        "title": job.item?.title ?? "Scene assets", "status": job.status,
        "preview": job.item?.previewURL?.absoluteString as Any? ?? null,
        "thumbnail": job.item.flatMap(Self.thumbnailAddress) as Any? ?? null, "account": job.account,
        "progress": job.progress as Any? ?? null, "pending": job.isPending, "queued": job.isQueued,
        "bytesReceived": job.bytesReceived as Any? ?? null,
        "bytesExpected": job.bytesExpected as Any? ?? null,
        "bytesPerSecond": job.bytesPerSecond as Any? ?? null,
        // The sign-in handoff has no prompt yet; the dialog must stay open through it.
        "authenticating": job.isPending && !job.isQueued && worker.isAuthenticating,
        "cancelled": job.isCancelled,
        "error": job.errorMessage as Any? ?? null,
        "prompt": worker.prompt?.rawValue as Any? ?? null,
        "securePrompt": worker.prompt == .password, "challenge": challenge as Any? ?? null,
        "warning": worker.sessionWarning as Any? ?? null,
      ]
    }
    let downloadRequests: [[String: Any]] = workshop.downloadRequests.map { request in
      [
        "id": request.id, "wallpaperID": request.item?.id as Any? ?? null,
        "title": request.item?.title ?? "Scene assets",
        "preview": request.item?.previewURL?.absoluteString as Any? ?? null,
        "thumbnail": request.item.flatMap(Self.thumbnailAddress) as Any? ?? null,
        "account": request.account, "rememberSession": request.rememberSession,
        "stage": workshop.stage(for: request).rawValue,
      ]
    }
    let loading: Bool
    let libraryError: String?
    switch store.libraryLoadState {
    case .loading:
      loading = true
      libraryError = nil
    case .loaded:
      loading = false
      libraryError = nil
    case .failed(let message):
      loading = false
      libraryError = message
    }
    let page: String
    switch navigation.selection {
    case .workshop: page = "discover"
    case .settings, .display: page = "settings"
    default: page = "installed"
    }
    let videoBackends: [[String: Any]] = settings.videoBackends.map { report in
      [
        "displayId": Int(report.displayId), "displayName": report.displayName,
        "wallpaperId": report.wallpaperId, "wallpaperTitle": report.wallpaperTitle,
        "backend": report.backend,
        "fallbackReason": report.fallbackReason as Any? ?? null,
      ]
    }
    return [
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "",
      "repositoryURL": AppUpdateConfiguration.repositoryURL.absoluteString,
      "windowControlsInset": windowControlsInset,
      "page": page, "targetDisplayID": navigation.targetDisplayID,
      "settingsSection": navigation.settingsSection.rawValue,
      "settingsSectionToken": Int(navigation.settingsSectionToken),
      "theme": theme.preferences.snapshot,
      "selectedID": store.appSnapshot.selectedWallpaperId as Any? ?? null,
      "paused": store.appSnapshot.playbackState == .paused,
      "busy": commandBusy || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil,
      "error": actionError ?? (libraryError == dismissedLibraryError ? nil : libraryError)
        ?? (store.latestBridgeErrorRevision > dismissedErrorRevision
        ? store.latestBridgeErrorMessage : nil) as Any? ?? null,
      "libraryLoading": loading, "favorites": favoriteIDs.sorted(), "wallpapers": wallpapers,
      "workshopFiltersCollapsed": workshopFiltersCollapsed,
      "inspectorWidth": inspectorWidth as Any? ?? null,
      "displays": displays,
      "options": store.wallpaperOptionsSnapshot.map { Self.options($0, titles: titles) } as Any? ?? null,
      "settings": [
        "launchAtLogin": settings.launchAtLoginEnabled,
        "launchAtLoginAvailable": settings.launchAtLoginAvailable,
        "pauseOnBattery": settings.pauseOnBatteryPower,
        "videoBackend": settings.videoBackend, "videoBackends": videoBackends,
        "contentPacing": settings.contentPacingEnabled,
        "sharedVideoDecode": settings.sharedVideoDecodeEnabled,
        "sharedVideoDecodeSessions": Int(settings.sharedVideoDecodeSessions),
        "sharedVideoDecodeConsumers": Int(settings.sharedVideoDecodeConsumers),
        "renderScale": Double(settings.renderScale),
        "preferredRenderScale": Double(settings.preferredRenderScale),
        "renderScaleSupported": settings.renderScaleSupported,
        "batteryProfileEnabled": settings.batteryProfileEnabled,
        "batteryRenderScale": Double(settings.batteryRenderScale),
        "batteryTargetFps": Int(settings.batteryTargetFps),
        "onBatteryPower": settings.onBatteryPower,
        "keepWindowsOnWallpaperClick": !DesktopClickRevealPreference.isEnabled,
        "lockScreenEnabled": lock?.isRequested ?? false, "lockScreenAvailable": lock != nil,
        "lockScreenBusy": lock?.isBusy ?? false, "lockScreenStatus": lock?.status ?? "Unavailable",
        "lockScreenError": lock?.errorMessage as Any? ?? null,
        "sceneAssetsReady": workshop.sceneAssetsReady,
        "sceneAssetsWarning": workshop.sceneAssetsFailure as Any? ?? null,
        "assetsPath": ClientPaths.assetsURL.path, "libraryPath": ClientPaths.libraryURL.path,
        "shaderCacheBytes": settings.storage.shaderCacheSizeBytes,
        "logBytes": settings.storage.logs.activeFileSizeBytes,
        "bridgeVersion": settings.bridgeVersion, "coreVersion": settings.coreVersion,
        "shaderVersion": settings.shaderPipelineVersion, "gitSha": settings.gitSha,
      ],
      "workshop": [
        "text": workshop.searchText, "kind": workshop.kind.rawValue, "sort": workshop.sort.rawValue,
        "tags": workshop.tags, "items": workshop.items.map(Self.workshopItem),
        "selectedID": workshop.selectedItem?.id as Any? ?? null, "page": workshop.page,
        "totalPages": workshop.totalPages, "totalCount": workshop.totalCount,
        "reachable": workshop.reachableCount, "pageSize": workshop.pageSize,
        "loading": workshop.isLoading, "loaded": workshop.hasLoaded,
        "error": workshop.errorMessage as Any? ?? null,
      ],
      "setup": [
        "status": setupStatus, "busy": setup.isBusy, "ready": setup.selectedRuntime != nil,
        "error": setupError as Any? ?? null, "canApprove": canApprove,
        "candidatePath": setup.retainedCandidateURL?.path as Any? ?? null,
        "canCancel": setup.isBusy && setup.state != .committing,
        "progress": setupProgress as Any? ?? null,
      ],
      "downloads": downloads, "downloadRequests": downloadRequests,
      "downloadSlots": workshop.downloader.slotLimit,
      "account": workshop.suggestedAccount,
      "savedAccount": workshop.downloader.savedAccount as Any? ?? null,
      "rememberSession": workshop.downloader.rememberSessionWhileRunning ?? remembersSession,
      "downloadError": downloadError as Any? ?? null,
      "update": Self.update(updater.state),
      "import": [
        "busy": importTask != nil, "status": importStatus,
        "report": importReport.map { report -> [String: Any] in
          [
            "imported": report.importedIDs.count, "skipped": report.skipped.count,
            "failures": report.failures, "cancelled": report.cancelled,
          ]
        } as Any? ?? null,
      ],
    ]
  }

  static func update(_ state: AppUpdateState) -> [String: Any] {
    let null = NSNull()
    let status: String
    let statusText: String
    var percent: Any = null
    var transferred: Any = null
    var total: Any = null
    switch state {
    case .unsupported:
      status = "unsupported"
      statusText = String(localized: "In-app updates are available only in installed builds.")
    case .idle:
      status = "idle"
      statusText = String(localized: "Updates not yet checked")
    case .checking:
      status = "checking"
      statusText = String(localized: "Checking for updates...")
    case .upToDate:
      status = "upToDate"
      statusText = String(localized: "Up to date")
    case .available(_, let version):
      status = "available"
      statusText = String(localized: "Version \(version) is available from GitHub Releases.")
    case .manual(_, let version):
      status = "manual"
      statusText = String(localized: "Version \(version) is available from GitHub Releases.")
    case .downloading(_, let version, let value, let done, let expected, _):
      status = "downloading"
      statusText = String(
        localized: "Downloading version \(version) — \(Int(value.rounded())) percent")
      percent = value
      transferred = done
      total = expected
    case .ready(_, let version):
      status = "ready"
      statusText = String(localized: "Version \(version) is ready. Restart the app to install it.")
    case .error(_, _, let code, _):
      status = "error"
      statusText = updateErrorText(code)
    }
    let action: Any
    let actionLabel: String
    let showsAction: Bool
    switch state {
    case .unsupported, .manual:
      action = null
      actionLabel = ""
      showsAction = false
    case .available:
      action = "downloadUpdate"
      actionLabel = String(localized: "Download Update")
      showsAction = true
    case .ready:
      action = "installUpdate"
      actionLabel = String(localized: "Restart and Install")
      showsAction = true
    case .error(_, .install, _, let version) where version != nil:
      action = "installUpdate"
      actionLabel = String(localized: "Retry installation")
      showsAction = true
    case .error:
      action = "checkForUpdates"
      actionLabel = String(localized: "Retry")
      showsAction = true
    case .upToDate:
      action = "checkForUpdates"
      actionLabel = String(localized: "Check Again")
      showsAction = true
    case .downloading(_, _, let value, _, _, _):
      action = "downloadUpdate"
      actionLabel = String(localized: "Downloading \(Int(value.rounded())) percent")
      showsAction = true
    case .checking, .idle:
      action = "checkForUpdates"
      actionLabel = String(localized: "Check for Updates")
      showsAction = true
    }
    let showsReleases: Bool
    switch state {
    case .unsupported, .manual, .error: showsReleases = true
    default: showsReleases = false
    }
    let showsReveal: Bool
    if case .ready = state { showsReveal = true } else { showsReveal = false }
    return [
      "status": status, "statusText": statusText, "action": action, "actionLabel": actionLabel,
      "showsAction": showsAction, "showsReleases": showsReleases, "showsReveal": showsReveal,
      "busy": state.isBusy, "percent": percent, "transferred": transferred, "total": total,
      "footnote": String(
        localized:
          "Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm."
      ),
      "releasesLabel": String(localized: "Open GitHub Releases"),
      "revealLabel": String(localized: "Show in Finder"),
      "progressLabel": String(localized: "Update download progress"),
    ]
  }

  static func updateErrorText(_ code: AppUpdateErrorCode) -> String {
    switch code {
    case .network:
      String(localized: "Couldn't reach GitHub Releases. Check your connection and try again.")
    case .configuration:
      String(localized: "The GitHub Release update metadata is unavailable.")
    case .verification:
      String(localized: "The update couldn't be verified, so it wasn't installed.")
    case .permission:
      String(localized: "The updater doesn't have permission to install this update.")
    case .unknown:
      String(localized: "The update couldn't be completed. Try again or install it from GitHub Releases.")
    }
  }

  static func kind(_ value: BridgeWallpaperKind) -> String {
    switch value {
    case .projectScene: "Scene"
    case .video: "Video"
    case .webpage: "Web"
    case .unknown: "Unknown"
    }
  }

  static func scaling(_ value: BridgeScalingMode) -> String {
    switch value {
    case .none: "none"
    case .stretch: "stretch"
    case .match: "match"
    case .fill: "fill"
    }
  }

  static func options(
    _ value: BridgeWallpaperOptionsSnapshot, titles: ResolvedDisplayTitles
  ) -> [String: Any] {
    [
      "id": value.wallpaperId, "supported": value.supported, "dirty": value.dirty,
      "volume": value.volume, "muted": value.muted,
      "audioResponseEnabled": value.audioResponseEnabled,
      "displays": value.displayConfigurations.map { row -> [String: Any] in
        [
          "id": row.displayId, "title": titles.title(row.title, displayId: row.displayId),
          "enabled": row.enabled,
          "scalingMode": scaling(row.scalingMode), "scalingFactor": row.scalingFactor,
          "fps": row.targetFps, "maxFps": row.maxFps,
        ]
      },
      "properties": value.properties.map { property -> [String: Any] in
        let kind: String
        switch property.kind {
        case .bool: kind = "boolean"
        case .directory: kind = "file"
        case .slider: kind = "slider"
        case .combo: kind = "combo"
        case .color: kind = "color"
        case .textInput: kind = "textInput"
        case .text, .group, .unknown: kind = "text"
        }
        return [
          "id": property.id, "kind": kind, "label": plainLabel(property.labelHtml),
          "value": propertyValue(property.value),
          "defaultValue": propertyValue(property.defaultValue),
          "enabled": property.enabled, "dirty": property.dirty,
          "min": property.slider?.min ?? 0, "max": property.slider?.max ?? 1,
          "step": property.slider?.step ?? 0.01,
          "options": property.comboOptions.map {
            ["label": $0.label, "value": propertyValue($0.value)]
          },
        ]
      },
    ]
  }

  static func propertyValue(_ value: BridgePropertyValue) -> Any {
    switch value {
    case .bool(let value): value
    case .number(let value): value
    case .string(let value): value
    case .colorRgb(let red, let green, let blue):
      String(
        format: "#%02x%02x%02x", Int(max(0, min(1, red)) * 255), Int(max(0, min(1, green)) * 255),
        Int(max(0, min(1, blue)) * 255))
    case .empty: NSNull()
    }
  }

  static func plainLabel(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
  }

  static func workshopItem(_ value: WorkshopItem) -> [String: Any] {
    [
      "id": value.id, "title": value.title, "creator": value.creator, "summary": value.summary,
      "preview": value.previewURL?.absoluteString as Any? ?? NSNull(),
      "thumbnail": thumbnailAddress(for: value) as Any? ?? NSNull(), "tags": value.tags,
      "size": value.size, "subscriptions": value.subscriptions, "kind": value.kind.rawValue,
    ]
  }

  /// The panel-local address of the item's cached still thumbnail; nil when Steam gave no preview.
  static func thumbnailAddress(for value: WorkshopItem) -> String? {
    guard value.previewURL?.scheme == "https" else { return nil }
    var components = URLComponents()
    components.scheme = "mwe-ui"
    components.host = "thumbnail"
    components.path = "/" + value.id
    return components.url?.absoluteString
  }
}
