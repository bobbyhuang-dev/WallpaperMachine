import AVFoundation
import Foundation
import Observation

enum LibraryLoadState: Equatable {
    case loading, loaded, failed(String)
}

struct WallpaperActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class BridgeStore {
    let bridge: WallpaperBridge
    var appSnapshot: BridgeAppSnapshot
    var librarySnapshot: BridgeLibrarySnapshot
    var wallpaperOptionsSnapshot: BridgeWallpaperOptionsSnapshot?
    var monitorInformationSnapshot: BridgeMonitorInformationSnapshot
    var settingsSnapshot: BridgeSettingsSnapshot
    var snapshotRevision: UInt64
    var latestBridgeErrorMessage: String?
    var latestBridgeErrorRevision: UInt64
    var lockScreenWallpaper: LockScreenWallpaperService?
    @ObservationIgnored var onSnapshotApplied: (() -> Void)?
    /// Reads live web-wallpaper delivery state from whoever owns the web host.
    /// A closure rather than a reference because the host belongs to the app
    /// delegate and outlives no snapshot; nil while no host is running, which
    /// the panel reports as unknown rather than as "nothing is being
    /// delivered".
    @ObservationIgnored var webWallpaperDeliveryStatus: (@MainActor () -> WebWallpaperHost.DeliveryStatus)?
    let editorState = WallpaperEditorState()
    private(set) var activatingWallpaperID: String?
    private(set) var applyingWallpaperID: String?
    private var activeWallpaperEdits: [String: Int] = [:]
    private var wallpaperAppliesNeedingSave = Set<String>()
    private(set) var activationNeedsRefresh = false
    private(set) var libraryLoadState: LibraryLoadState = .loading

    convenience init() throws {
        self.init(bridge: try WallpaperBridge())
    }

    init(bridge: WallpaperBridge) {
        let snapshots = Self.emptySnapshots()

        self.bridge = bridge
        self.appSnapshot = snapshots.app
        self.librarySnapshot = snapshots.library
        self.wallpaperOptionsSnapshot = snapshots.wallpaperOptions
        self.monitorInformationSnapshot = snapshots.monitorInformation
        self.settingsSnapshot = snapshots.settings
        self.snapshotRevision = 0
        self.latestBridgeErrorMessage = nil
        self.latestBridgeErrorRevision = 0
    }

    func refreshAllAsync() async throws {
        try requireIdleActivation()
        do {
            let bundle = try await (activationNeedsRefresh ? bridge.refreshDisplays() : bridge.allSnapshots())
            apply(bundle)
            libraryLoadState = .loaded
            activationNeedsRefresh = false
        } catch {
            libraryLoadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func bootstrapAsync() async throws {
        libraryLoadState = .loading
        do {
            let bundle = try await bridge.bootstrap()
            apply(bundle)
            libraryLoadState = .loaded
        } catch {
            libraryLoadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func refreshLibraryAsync() async throws {
        try requireIdleActivation()
        do {
            let bundle = try await bridge.refreshLibrary()
            apply(bundle)
            libraryLoadState = .loaded
        } catch {
            libraryLoadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteWallpaperAsync(id: String) async throws {
        let report = try await deleteWallpapersAsync(ids: [id])
        if let failure = report.failures.first { throw failure.error }
    }

    /// Trashes each wallpaper independently so one failure never blocks the rest;
    /// the library refreshes once after the whole batch.
    func deleteWallpapersAsync(
        ids: [String],
        recycle: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) async throws -> WallpaperDeletionReport {
        var report = WallpaperDeletionReport()
        for id in ids {
            do {
                // Validate before stopping playback; never touch an external source folder.
                _ = try WallpaperDeletionService.wallpaperURL(id: id, library: ClientPaths.libraryURL)
                let displayIDs = Set(monitorInformationSnapshot.rows.filter {
                    $0.wallpaperId == id && $0.mirrorTargetDisplayId == nil
                }.map(\.displayId))
                for displayID in displayIDs.sorted() {
                    try await ejectWallpaperFromDisplayAsync(displayId: displayID, wallpaperId: id)
                }
                try WallpaperDeletionService.moveToTrash(id: id, library: ClientPaths.libraryURL, recycle: recycle)
                report.deleted.append(id)
            } catch {
                report.failures.append((id: id, error: error))
            }
        }
        guard !report.deleted.isEmpty else { return report }
        try await refreshLibraryAsync()
        for id in report.deleted { editorState.discard(wallpaperID: id) }
        return report
    }

    func refreshDisplaysAsync() async throws {
        let bundle = try await bridge.refreshDisplays()
        apply(bundle)
    }

    func selectWallpaperAsync(id: String) async throws {
        let bundle = try await bridge.selectWallpaper(id: id)
        apply(bundle)
    }

    func activateWallpaperAsync(id: String, displayId: String) async throws {
        try requireIdleActivation()
        try requireIdleWallpaperEdits(id: id)
        guard librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
            throw WallpaperActionError(message: String(localized: "This wallpaper is no longer in your library. Refresh Library and choose another wallpaper."))
        }
        activatingWallpaperID = id
        defer { activatingWallpaperID = nil }
        try await selectWallpaperAsync(id: id)
        guard !activationNeedsRefresh else {
            throw WallpaperActionError(message: String(localized: "Refresh all wallpaper state before applying again."))
        }
        try validateActivationTarget(displayId)
        guard let options = wallpaperOptionsSnapshot, options.wallpaperId == id else {
            throw WallpaperActionError(message: String(localized: "Wallpaper settings are unavailable. Refresh Library and retry."))
        }
        if isWallpaperActive(id: id, displayId: displayId), !options.dirty,
           !wallpaperAppliesNeedingSave.contains(id), !editorState.hasPendingEdits(wallpaperID: id) { return }
        guard options.supported else {
            throw WallpaperActionError(message: String(localized: "This wallpaper type cannot be played on macOS. You can still inspect or remove it from your library."))
        }
        guard let row = options.displayConfigurations.first(where: { $0.displayId == displayId }) else {
            throw WallpaperActionError(message: String(localized: "No configuration is available for this display. Refresh Displays and retry."))
        }
        try validatePendingWallpaperEdits(id: id, options: options)
        try await validateWallpaperForPlaybackAsync(id: id)
        try await commitPendingWallpaperEditsAsync(id: id)
        // Validation and async draft commits may outlive a display topology change.
        try validateActivationTarget(displayId)
        let previouslyActive = isWallpaperActive(id: id, displayId: displayId)
        var applyCompleted = false
        do {
            try await setDisplayConfigEnabledAsync(wallpaperId: id, displayId: displayId, enabled: true)
            try await applyValidatedWallpaperOptionsAsync(wallpaperId: id)
            applyCompleted = true
            try validateActivationTarget(displayId)
            guard isWallpaperActive(id: id, displayId: displayId) else {
                throw WallpaperActionError(message: String(localized: "The display did not report this wallpaper as active. Refresh Displays and retry."))
            }
        } catch {
            // A bridge error may happen after reconciliation. Never infer rollback from a stale bundle.
            try await resyncAfterFailedApplyAsync(cause: error)
            if isWallpaperActive(id: id, displayId: displayId), applyCompleted || !previouslyActive {
                throw WallpaperActionError(message: String(localized: "The display assignment changed, but the operation could not be fully saved: \(error.localizedDescription)"))
            }
            do {
                try await setDisplayConfigEnabledAsync(wallpaperId: id, displayId: displayId, enabled: row.enabled)
            } catch let restoreError {
                activationNeedsRefresh = true
                throw WallpaperActionError(message: String(localized: "Could not apply the wallpaper: \(error.localizedDescription). Could not restore the display draft: \(restoreError.localizedDescription). Refresh all wallpaper state before retrying."))
            }
            throw error
        }
    }

    func isWallpaperActive(id: String, displayId: String) -> Bool {
        monitorInformationSnapshot.rows.contains {
            $0.displayId == displayId && $0.wallpaperId == id && $0.mirrorTargetDisplayId == nil
        }
    }

    private func validateActivationTarget(_ displayId: String) throws {
        guard let target = settingsSnapshot.displays.first(where: { $0.displayId == displayId }),
              target.enabled, target.mode == .standalone else {
            throw WallpaperActionError(message: String(localized: "The selected display is unavailable, disabled, or mirroring another display. Choose an enabled independent display in Settings."))
        }
    }

    private func requireIdleActivation() throws {
        guard activatingWallpaperID == nil, applyingWallpaperID == nil else {
            throw WallpaperActionError(message: String(localized: "Wait for the current wallpaper to finish applying."))
        }
    }

    func isWallpaperEditInProgress(id: String) -> Bool { activeWallpaperEdits[id, default: 0] > 0 }

    private func requireIdleWallpaperEdits(id: String) throws {
        guard !isWallpaperEditInProgress(id: id) else {
            throw WallpaperActionError(message: String(localized: "Wait for the pending setting to finish before applying."))
        }
    }

    private func beginWallpaperEdit(_ id: String) { activeWallpaperEdits[id, default: 0] += 1 }
    private func endWallpaperEdit(_ id: String) {
        if activeWallpaperEdits[id, default: 0] <= 1 { activeWallpaperEdits.removeValue(forKey: id) }
        else { activeWallpaperEdits[id, default: 0] -= 1 }
    }

    private func validatePendingWallpaperEdits(id: String, options: BridgeWallpaperOptionsSnapshot) throws {
        for (key, draft) in editorState.scalingDrafts where key.wallpaperID == id {
            guard draft.value != nil,
                  options.displayConfigurations.contains(where: { $0.displayId == key.fieldID }) else {
                throw WallpaperActionError(message: draft.errorMessage ?? String(localized: "A pending display setting is no longer available. Revert it before applying."))
            }
        }
        for key in editorState.propertyTextDrafts.keys where key.wallpaperID == id {
            guard options.properties.contains(where: { $0.id == key.fieldID && $0.kind == .textInput && $0.enabled }) else {
                throw WallpaperActionError(message: String(localized: "A pending property is no longer editable. Revert it before applying."))
            }
        }
    }

    func commitPendingWallpaperEditsAsync(id: String) async throws {
        let options = try await wallpaperOptionsSnapshotAsync(wallpaperId: id)
        try validatePendingWallpaperEdits(id: id, options: options)
        let scaling = editorState.scalingDrafts.filter { $0.key.wallpaperID == id }.sorted { $0.key.fieldID < $1.key.fieldID }
        let text = editorState.propertyTextDrafts.filter { $0.key.wallpaperID == id }.sorted { $0.key.fieldID < $1.key.fieldID }
        for (key, draft) in scaling {
            if let value = draft.value {
                try await editScalingFactorAsync(wallpaperId: id, displayId: key.fieldID, factor: value)
            }
        }
        for (key, value) in text {
            try await editPropertyAsync(wallpaperId: id, propertyId: key.fieldID, value: .string(value: value))
        }
    }

    func wallpaperOptionsSnapshotAsync(
        wallpaperId: String
    ) async throws -> BridgeWallpaperOptionsSnapshot {
        try await bridge.wallpaperOptionsSnapshot(wallpaperId: wallpaperId)
    }

    func setFilterAsync(kind: BridgeWallpaperKind, enabled: Bool) async throws {
        let bundle = try await bridge.setFilter(kind: kind, enabled: enabled)
        apply(bundle)
    }

    func setVolumeAsync(wallpaperId: String, volume: Float) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setVolume(wallpaperId: wallpaperId, volume: volume)
        apply(bundle)
    }

    func setMutedAsync(wallpaperId: String, muted: Bool) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setMuted(wallpaperId: wallpaperId, muted: muted)
        apply(bundle)
    }

    func setAudioResponseEnabledAsync(wallpaperId: String, enabled: Bool) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        do {
            let bundle = try await bridge.setAudioResponseEnabled(wallpaperId: wallpaperId, enabled: enabled)
            apply(bundle)
        } catch {
            // Capture failures roll the saved option back; discard any in-flight snapshot.
            try? await refreshAllAsync()
            throw error
        }
    }

    func setMediaIntegrationEnabledAsync(wallpaperId: String, enabled: Bool) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setMediaIntegrationEnabled(wallpaperId: wallpaperId, enabled: enabled)
        apply(bundle)
    }

    func setDisplayConfigEnabledAsync(
        wallpaperId: String,
        displayId: String,
        enabled: Bool
    ) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setDisplayConfigEnabled(
            wallpaperId: wallpaperId,
            displayId: displayId,
            enabled: enabled
        )
        apply(bundle)
    }

    func setScalingModeAsync(
        wallpaperId: String,
        displayId: String,
        mode: BridgeScalingMode
    ) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setScalingMode(
            wallpaperId: wallpaperId,
            displayId: displayId,
            mode: mode
        )
        apply(bundle)
    }

    func editScalingFactorAsync(wallpaperId: String, displayId: String, factor: Double) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.editScalingFactor(wallpaperId: wallpaperId, displayId: displayId, factor: factor)
        apply(bundle)
    }

    func setTargetFpsAsync(wallpaperId: String, displayId: String, fps: UInt32) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setTargetFps(wallpaperId: wallpaperId, displayId: displayId, fps: fps)
        apply(bundle)
    }

    func editPropertyAsync(
        wallpaperId: String,
        propertyId: String,
        value: BridgePropertyValue
    ) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.editProperty(wallpaperId: wallpaperId, propertyId: propertyId, value: value)
        apply(bundle)
    }

    /// The path a `file` or `directory` property points at. `nil` clears it; the engine
    /// stores the string verbatim, so what is passed here is what the panel reads back.
    func setPropertyPathAsync(wallpaperId: String, propertyId: String, path: String?) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setPropertyPath(wallpaperId: wallpaperId, propertyId: propertyId, path: path)
        apply(bundle)
    }

    func restorePropertyDefaultAsync(wallpaperId: String, propertyId: String) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.restorePropertyDefault(wallpaperId: wallpaperId, propertyId: propertyId)
        apply(bundle)
    }

    func setDisplayEnabledAsync(displayId: String, enabled: Bool) async throws {
        let bundle = try await bridge.setDisplayEnabled(displayId: displayId, enabled: enabled)
        apply(bundle)
    }

    func setDisplayModeAsync(displayId: String, mode: BridgeDisplayMode) async throws {
        let bundle = try await bridge.setDisplayMode(displayId: displayId, mode: mode)
        apply(bundle)
    }

    func setMirrorTargetAsync(displayId: String, targetDisplayId: String) async throws {
        let bundle = try await bridge.setMirrorTarget(displayId: displayId, targetDisplayId: targetDisplayId)
        apply(bundle)
    }

    func setMirrorScalingModeAsync(displayId: String, mode: BridgeScalingMode) async throws {
        let bundle = try await bridge.setMirrorScalingMode(displayId: displayId, mode: mode)
        apply(bundle)
    }

    func setMirrorScalingFactorAsync(displayId: String, factor: Double) async throws {
        let bundle = try await bridge.setMirrorScalingFactor(displayId: displayId, factor: factor)
        apply(bundle)
    }

    func setMirrorTargetFpsAsync(displayId: String, fps: UInt32) async throws {
        let bundle = try await bridge.setMirrorTargetFps(displayId: displayId, fps: fps)
        apply(bundle)
    }

    func setMirrorVolumeAsync(displayId: String, volume: Float) async throws {
        let bundle = try await bridge.setMirrorVolume(displayId: displayId, volume: volume)
        apply(bundle)
    }

    func setMirrorMutedAsync(displayId: String, muted: Bool) async throws {
        let bundle = try await bridge.setMirrorMuted(displayId: displayId, muted: muted)
        apply(bundle)
    }

    func setLaunchAtLoginAsync(enabled: Bool) async throws {
        let bundle = try await bridge.setLaunchAtLogin(enabled: enabled)
        apply(bundle)
    }

    func setPauseOnBatteryPowerAsync(enabled: Bool) async throws {
        let bundle = try await bridge.setPauseOnBatteryPower(enabled: enabled)
        apply(bundle)
    }

    func setVideoBackendAsync(_ mode: String) async throws {
        let bundle = try await bridge.setVideoBackend(mode: mode)
        apply(bundle)
    }

    func setRenderScaleAsync(_ scale: Float) async throws {
        let bundle = try await bridge.setRenderScale(scale: scale)
        apply(bundle)
    }

    func setBatteryQualityProfileAsync(enabled: Bool, renderScale: Float, targetFps: UInt32) async throws {
        let bundle = try await bridge.setBatteryQualityProfile(
            enabled: enabled, renderScale: renderScale, targetFps: targetFps)
        apply(bundle)
    }

    func setContentPacingEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setContentPacingEnabled(enabled: enabled)
        apply(bundle)
    }

    func setSharedVideoDecodeEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setSharedVideoDecodeEnabled(enabled: enabled)
        apply(bundle)
    }

    /// Scene subgraph reuse and redundant-pass removal. The engine publishes the saved
    /// preference rather than a reading taken from a running scene, so the snapshot this
    /// returns is what the page reports back.
    func setSceneOptimizationEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setSceneOptimizationEnabled(enabled: enabled)
        apply(bundle)
    }

    /// Whole-scene on-demand updating. Off by default. The bundle carries back the saved
    /// preference plus `sceneUpdateModes`, which is the live per-scene read-back: the
    /// preference being on does not mean any scene actually stopped ticking.
    func setSceneOnDemandEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setSceneOnDemandEnabled(enabled: enabled)
        apply(bundle)
    }

    /// Direct NV12 plane sampling inside native Metal scenes. Off by default and
    /// experimental. A preference: the `videoPath` of each `sceneRenderers` row is
    /// what each running scene's video textures actually did.
    func setSceneVideoPlaneSamplingEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setSceneVideoPlaneSamplingEnabled(enabled: enabled)
        apply(bundle)
    }

    /// Which renderer draws scene wallpapers. A preference: `sceneRenderers` in the
    /// returned bundle is what each running scene actually got.
    func setSceneRendererAsync(_ mode: String) async throws {
        let bundle = try await bridge.setSceneRenderer(mode: mode)
        apply(bundle)
    }

    func applyWallpaperOptionsAsync(wallpaperId: String) async throws {
        try requireIdleActivation()
        try requireIdleWallpaperEdits(id: wallpaperId)
        guard !activationNeedsRefresh else {
            throw WallpaperActionError(message: String(localized: "Refresh all wallpaper state before applying again."))
        }
        applyingWallpaperID = wallpaperId
        defer { applyingWallpaperID = nil }
        try await validateWallpaperForPlaybackAsync(id: wallpaperId)
        try await commitPendingWallpaperEditsAsync(id: wallpaperId)
        do {
            try await applyValidatedWallpaperOptionsAsync(wallpaperId: wallpaperId)
        } catch {
            // The engine restores its previous configuration when an apply fails,
            // so re-read it instead of leaving the UI stuck behind a manual refresh.
            try await resyncAfterFailedApplyAsync(cause: error)
            throw error
        }
    }

    private func validateWallpaperForPlaybackAsync(id wallpaperId: String) async throws {
        let folder = ClientPaths.libraryURL.appendingPathComponent(wallpaperId)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("project.json"))) as? [String: Any]
        if let file = manifest?["file"] as? String, (manifest?["type"] as? String)?.lowercased() == "video" {
            let asset = AVURLAsset(url: folder.appendingPathComponent(file))
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw NSError(domain: "MacWallpaperEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "This video cannot be decoded. Import a complete, playable video file before applying it.")])
            }
        }
        if (manifest?["type"] as? String)?.lowercased() == "scene" {
            let assets = ClientPaths.assetsURL
            guard ClientPaths.hasSceneAssets(at: assets) else {
                throw NSError(domain: "MacWallpaperEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "This wallpaper is downloaded, but Wallpaper Engine’s shared scene assets are not installed. Use Install scene assets… in Settings or the Workshop wallpaper, or locate the assets folder from your purchased installation.")])
            }
            setenv("MAC_WALLPAPER_ENGINE_ASSETS_ROOT", assets.path, 1)
        }
        if (manifest?["type"] as? String)?.lowercased() == "web" {
            guard let file = manifest?["file"] as? String, !file.isEmpty,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) else {
                throw NSError(domain: "MacWallpaperEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "This web wallpaper’s entry page is missing. Import the complete project folder, including its HTML file, before applying it.")])
            }
        }
    }

    private func applyValidatedWallpaperOptionsAsync(wallpaperId: String) async throws {
        do {
            let bundle = try await bridge.applyWallpaperOptions(wallpaperId: wallpaperId)
            apply(bundle)
            guard bundle.wallpaperOptions.wallpaperId == wallpaperId, !bundle.wallpaperOptions.dirty else {
                throw WallpaperActionError(message: String(localized: "Applying was interrupted by another playback or display change. Your pending edits have been kept. Refresh and retry."))
            }
            editorState.discard(wallpaperID: wallpaperId)
            wallpaperAppliesNeedingSave.remove(wallpaperId)
        } catch {
            wallpaperAppliesNeedingSave.insert(wallpaperId)
            // `activationNeedsRefresh` disables every Library action, so only the
            // callers may latch it, and only when they cannot re-read the engine.
            throw error
        }
    }

    /// Re-reads authoritative engine state after a failed apply. A successful
    /// re-read means the app and engine agree again, so the Library stays usable.
    /// Only a failed re-read forces the user through a manual refresh.
    private func resyncAfterFailedApplyAsync(cause: Error) async throws {
        do {
            let actual = try await bridge.allSnapshots()
            apply(actual)
        } catch let refreshError {
            activationNeedsRefresh = true
            throw WallpaperActionError(message: String(localized: "Could not confirm the display state after applying: \(cause.localizedDescription). Refresh failed: \(refreshError.localizedDescription). Refresh all wallpaper state before retrying."))
        }
    }

    func cancelWallpaperOptionsAsync(wallpaperId: String) async throws {
        try requireIdleActivation()
        try requireIdleWallpaperEdits(id: wallpaperId)
        applyingWallpaperID = wallpaperId
        defer { applyingWallpaperID = nil }
        let bundle = try await bridge.cancelWallpaperOptions(wallpaperId: wallpaperId)
        apply(bundle)
        editorState.discard(wallpaperID: wallpaperId)
    }

    func pauseAllAsync() async throws {
        let bundle = try await bridge.pauseAll()
        apply(bundle)
    }

    func playAllAsync() async throws {
        let bundle = try await bridge.playAll()
        apply(bundle)
    }

    func setPresentationSuspendedAsync(_ suspended: Bool) async throws {
        try await bridge.setPresentationSuspended(suspended: suspended)
    }

    func setDisplayPresentationSuspendedAsync(displayID: UInt32, suspended: Bool) async throws {
        try await bridge.setDisplayPresentationSuspended(
            displayId: String(displayID), suspended: suspended)
    }

    /// Turns renderer work counting on or off. Off by default; the renderer
    /// performs no bookkeeping until this is on, and nothing is pushed back —
    /// counters are only ever read by `rendererCountersAsync`.
    func setRendererCountersEnabledAsync(_ enabled: Bool) async throws {
        try await bridge.setRendererCountersEnabled(enabled: enabled)
    }

    func rendererCountersAsync() async throws -> BridgeRendererCountersReport {
        try await bridge.rendererCounters()
    }

    func ejectWallpaperFromDisplayAsync(
        displayId: String,
        wallpaperId: String
    ) async throws {
        try requireIdleActivation()
        let bundle = try await bridge.ejectWallpaperFromDisplay(displayId: displayId, wallpaperId: wallpaperId)
        apply(bundle)
    }

    func shutdownAsync() async throws {
        try await bridge.shutdown()
    }

    func clearShaderCacheAsync() async throws {
        settingsSnapshot = try await bridge.clearShaderCache()
        finishSnapshotApply()
    }

    func clearLogsAsync() throws {
        let status = try bridge.clearLogs()
        settingsSnapshot.storage = BridgeStorageStatus(
            shaderCacheSizeBytes: settingsSnapshot.storage.shaderCacheSizeBytes,
            logs: status
        )
        finishSnapshotApply()
    }

    func logFolderURL() throws -> URL {
        URL(fileURLWithPath: try bridge.logFolderPath(), isDirectory: true)
    }

    func emitLog(level: BridgeLogLevel, file: String, line: UInt32, message: String) throws {
        try bridge.emitGuiLog(level: level, file: file, line: line, message: message)
    }

    private struct Snapshots {
        let app: BridgeAppSnapshot
        let library: BridgeLibrarySnapshot
        let wallpaperOptions: BridgeWallpaperOptionsSnapshot?
        let monitorInformation: BridgeMonitorInformationSnapshot
        let settings: BridgeSettingsSnapshot
    }

    private static func emptySnapshots() -> Snapshots {
        Snapshots(
            app: BridgeAppSnapshot(
                playbackState: .paused,
                selectedWallpaperId: nil,
                activeWallpaperIds: [],
                errors: []
            ),
            library: BridgeLibrarySnapshot(
                wallpapers: [],
                scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0),
                sceneCount: 0,
                videoCount: 0,
                webpageCount: 0,
                unknownCount: 0
            ),
            wallpaperOptions: nil,
            monitorInformation: BridgeMonitorInformationSnapshot(rows: []),
            settings: BridgeSettingsSnapshot(
                displays: [],
                launchAtLoginAvailable: false,
                launchAtLoginEnabled: false,
                pauseOnBatteryPower: false,
                gitSha: "",
                bridgeVersion: "",
                coreVersion: "",
                shaderPipelineVersion: "",
                storage: BridgeStorageStatus(
                    shaderCacheSizeBytes: 0,
                    logs: BridgeLogStatus(
                        logsRoot: "",
                        activeSession: "",
                        activeFile: "",
                        activeFileSizeBytes: 0
                    )
                ),
                videoBackend: "compatibility",
                videoBackends: [],
                contentPacingEnabled: false,
                sharedVideoDecodeEnabled: false,
                sharedVideoDecodeSessions: 0,
                sharedVideoDecodeConsumers: 0,
                sceneOptimizationEnabled: true,
                sceneOnDemandEnabled: false,
                sceneVideoPlaneSamplingEnabled: false,
                sceneRenderer: "compatibility",
                sceneUpdateModes: [],
                sceneRenderers: [],
                userAssetsPath: "",
                renderScale: 1,
                preferredRenderScale: 1,
                batteryProfileEnabled: false,
                batteryRenderScale: 0.75,
                batteryTargetFps: 30,
                onBatteryPower: false,
                renderScaleSupported: false
            )
        )
    }

    private func apply(_ bundle: BridgeSnapshotBundle) {
        self.appSnapshot = bundle.app
        self.librarySnapshot = bundle.library
        self.wallpaperOptionsSnapshot = bundle.wallpaperOptions
        self.monitorInformationSnapshot = bundle.monitorInformation
        self.settingsSnapshot = bundle.settings
        finishSnapshotApply()
    }

    private func apply(_ bundle: BridgeWallpaperMutationBundle) {
        self.appSnapshot = bundle.app
        self.librarySnapshot = bundle.library
        self.wallpaperOptionsSnapshot = bundle.wallpaperOptions
        self.monitorInformationSnapshot = bundle.monitorInformation
        self.settingsSnapshot = bundle.settings
        finishSnapshotApply()
    }

    private func apply(_ bundle: BridgeDisplayMutationBundle) {
        self.appSnapshot = bundle.app
        self.librarySnapshot = bundle.library
        self.monitorInformationSnapshot = bundle.monitorInformation
        self.settingsSnapshot = bundle.settings
        finishSnapshotApply()
    }

    private func finishSnapshotApply() {
        if let options = wallpaperOptionsSnapshot {
            editorState.reconcile(wallpaperID: options.wallpaperId,
                textPropertyIDs: Set(options.properties.filter { $0.kind == .textInput }.map(\.id)))
        }
        self.snapshotRevision &+= 1
        onSnapshotApplied?()
        if let message = appSnapshot.errors.last,
           message != latestBridgeErrorMessage {
            latestBridgeErrorMessage = message
            latestBridgeErrorRevision &+= 1
        }
    }
}
