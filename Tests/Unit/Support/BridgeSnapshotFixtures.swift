import Foundation

@testable import MacWallpaperEngine

/// Snapshot values for tests that need a settings snapshot but do not care what
/// is in it.
///
/// The bridge snapshot is a flat record with no defaults, so every test that
/// builds one has to name every field. Centralising that here means adding a
/// setting touches this file instead of every unrelated test, and it keeps those
/// tests describing what they actually assert rather than restating the whole
/// record.
enum BridgeSnapshotFixtures {
  static func storage() -> BridgeStorageStatus {
    BridgeStorageStatus(
      shaderCacheSizeBytes: 0,
      logs: BridgeLogStatus(
        logsRoot: "", activeSession: "", activeFile: "", activeFileSizeBytes: 0))
  }

  /// A wallpaper options snapshot carrying shipped defaults: audio response on,
  /// media integration off, unmuted at full volume. Tests that care about one of
  /// those pass it explicitly.
  static func options(
    wallpaperId: String = "wallpaper",
    title: String = "Wallpaper",
    kind: BridgeWallpaperKind = .projectScene,
    supported: Bool = true,
    dirty: Bool = false,
    properties: [BridgePropertyDescriptor] = [],
    displayConfigurations: [BridgeDisplayConfigRow] = [],
    audioResponseEnabled: Bool = true,
    mediaIntegrationEnabled: Bool = false,
    muted: Bool = false,
    volume: Float = 1
  ) -> BridgeWallpaperOptionsSnapshot {
    BridgeWallpaperOptionsSnapshot(
      wallpaperId: wallpaperId,
      title: title,
      kind: kind,
      supported: supported,
      dirty: dirty,
      properties: properties,
      displayConfigurations: displayConfigurations,
      audioResponseEnabled: audioResponseEnabled,
      mediaIntegrationEnabled: mediaIntegrationEnabled,
      muted: muted,
      volume: volume)
  }

  /// A settings snapshot carrying shipped defaults: compatibility backend, full
  /// render scale, no battery profile, both experiments off and scene optimisation
  /// on. Tests that care about one of those pass it explicitly.
  static func settings(
    displays: [BridgeDisplaySettingsRow] = [],
    pauseOnBatteryPower: Bool = false,
    videoBackend: String = "compatibility",
    videoBackends: [BridgeVideoBackendReport] = [],
    contentPacingEnabled: Bool = false,
    sharedVideoDecodeEnabled: Bool = false,
    sharedVideoDecodeSessions: UInt32 = 0,
    sharedVideoDecodeConsumers: UInt32 = 0,
    sceneOptimizationEnabled: Bool = true,
    sceneOnDemandEnabled: Bool = false,
    sceneRenderer: String = "compatibility",
    sceneUpdateModes: [BridgeSceneUpdateModeReport] = [],
    sceneRenderers: [BridgeSceneBackendReport] = [],
    userAssetsPath: String = "/tmp/UserAssets",
    renderScale: Float = 1,
    preferredRenderScale: Float = 1,
    batteryProfileEnabled: Bool = false,
    batteryRenderScale: Float = 0.75,
    batteryTargetFps: UInt32 = 30,
    onBatteryPower: Bool = false,
    renderScaleSupported: Bool = true
  ) -> BridgeSettingsSnapshot {
    BridgeSettingsSnapshot(
      displays: displays,
      launchAtLoginAvailable: false,
      launchAtLoginEnabled: false,
      pauseOnBatteryPower: pauseOnBatteryPower,
      gitSha: "",
      bridgeVersion: "",
      coreVersion: "",
      shaderPipelineVersion: "",
      storage: storage(),
      videoBackend: videoBackend,
      videoBackends: videoBackends,
      contentPacingEnabled: contentPacingEnabled,
      sharedVideoDecodeEnabled: sharedVideoDecodeEnabled,
      sharedVideoDecodeSessions: sharedVideoDecodeSessions,
      sharedVideoDecodeConsumers: sharedVideoDecodeConsumers,
      sceneOptimizationEnabled: sceneOptimizationEnabled,
      sceneOnDemandEnabled: sceneOnDemandEnabled,
      sceneRenderer: sceneRenderer,
      sceneUpdateModes: sceneUpdateModes,
      sceneRenderers: sceneRenderers,
      userAssetsPath: userAssetsPath,
      renderScale: renderScale,
      preferredRenderScale: preferredRenderScale,
      batteryProfileEnabled: batteryProfileEnabled,
      batteryRenderScale: batteryRenderScale,
      batteryTargetFps: batteryTargetFps,
      onBatteryPower: onBatteryPower,
      renderScaleSupported: renderScaleSupported)
  }
}
