import Foundation

@MainActor
extension WebPanelController {
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
    let displays: [[String: Any]] = settings.displays.map { display in
      let active = store.monitorInformationSnapshot.rows.first { $0.displayId == display.displayId }
      let wallpaperOptions = active.flatMap { row in
        store.wallpaperOptionsSnapshot?.wallpaperId == row.wallpaperId
          ? store.wallpaperOptionsSnapshot : displayOptions[row.wallpaperId]
      }
      let config =
        display.mode == .standalone
        ? wallpaperOptions?.displayConfigurations.first { $0.displayId == display.displayId } : nil
      return [
        "id": display.displayId, "title": display.title, "enabled": display.enabled,
        "mode": display.mode == .mirror ? "mirror" : "standalone",
        "mirrorTarget": display.selectedMirrorTarget as Any? ?? null,
        "mirrorTargets": display.mirrorTargets.map { id in
          ["id": id, "title": settings.displays.first { $0.displayId == id }?.title ?? id]
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
        "preview": job.item?.previewURL?.absoluteString as Any? ?? null, "account": job.account,
        "progress": job.progress as Any? ?? null, "pending": job.isPending, "queued": job.isQueued,
        "bytesReceived": job.bytesReceived as Any? ?? null,
        "bytesExpected": job.bytesExpected as Any? ?? null,
        "bytesPerSecond": job.bytesPerSecond as Any? ?? null,
        // The sign-in handoff has no prompt yet; the dialog must stay open through it.
        "authenticating": job.isPending && !job.isQueued && worker.isAuthenticating,
        "cancelled": job.isCancelled,
        "error": worker.errorMessage as Any? ?? null,
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
    return [
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "",
      "page": page, "targetDisplayID": navigation.targetDisplayID,
      "theme": theme.preferences.snapshot,
      "selectedID": store.appSnapshot.selectedWallpaperId as Any? ?? null,
      "paused": store.appSnapshot.playbackState == .paused,
      "busy": commandBusy || store.activatingWallpaperID != nil || store.applyingWallpaperID != nil,
      "error": actionError ?? (libraryError == dismissedLibraryError ? nil : libraryError)
        ?? (store.latestBridgeErrorRevision > dismissedErrorRevision
        ? store.latestBridgeErrorMessage : nil) as Any? ?? null,
      "libraryLoading": loading, "favorites": favoriteIDs.sorted(), "wallpapers": wallpapers,
      "displays": displays,
      "options": store.wallpaperOptionsSnapshot.map(Self.options) as Any? ?? null,
      "settings": [
        "launchAtLogin": settings.launchAtLoginEnabled,
        "launchAtLoginAvailable": settings.launchAtLoginAvailable,
        "pauseOnBattery": settings.pauseOnBatteryPower,
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
      "account": workshop.suggestedAccount,
      "savedAccount": workshop.downloader.savedAccount as Any? ?? null,
      "rememberSession": workshop.downloader.rememberSessionWhileRunning ?? remembersSession,
      "downloadError": downloadError as Any? ?? null,
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

  static func options(_ value: BridgeWallpaperOptionsSnapshot) -> [String: Any] {
    [
      "id": value.wallpaperId, "supported": value.supported, "dirty": value.dirty,
      "volume": value.volume, "muted": value.muted,
      "audioResponseEnabled": value.audioResponseEnabled,
      "displays": value.displayConfigurations.map { row -> [String: Any] in
        [
          "id": row.displayId, "title": row.title, "enabled": row.enabled,
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
      "preview": value.previewURL?.absoluteString as Any? ?? NSNull(), "tags": value.tags,
      "size": value.size, "subscriptions": value.subscriptions, "kind": value.kind.rawValue,
    ]
  }
}
