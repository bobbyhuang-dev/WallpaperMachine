use std::collections::BTreeMap;

use crate::{
    actor::state::ApplyCandidates,
    api::{
        BridgeAppSnapshot, BridgeDisplayMode, BridgeDisplayMutationBundle,
        BridgeDisplaySettingsRow, BridgeError, BridgeLibrarySnapshot, BridgeLockScreenScene,
        BridgeMonitorInformationSnapshot, BridgePlaybackState, BridgePropertyValue,
        BridgeNativeVideoWallpaper, BridgeRendererCountersReport,
        BridgeScalingMode, BridgeSettingsSnapshot, BridgeSnapshotBundle, BridgeWallpaperEntry,
        BridgeWallpaperKind, BridgeWallpaperMutationBundle, BridgeWallpaperOptionsSnapshot,
        BridgeWebWallpaper,
    },
    config::{AppConfig, SceneRendererModeCfg, VideoBackendModeCfg, WallpaperConfig},
    power::PowerSource,
};

pub struct Bootstrap;

pub struct GetSceneMediaWallpapers;
pub struct UpdateSceneMedia {
    pub wallpaper_id: String,
    pub state: wallpaper_core::media::MediaPollResult,
}

pub struct GetAllSnapshots;

pub struct GetAppSnapshot;

pub struct GetLibrarySnapshot;

pub struct GetLockScreenScenes;

pub struct GetWebWallpapers;

pub struct GetMonitorInformationSnapshot;

pub struct GetSettingsSnapshot;

pub struct ClearShaderCache;

pub struct GetWallpaperOptionsSnapshot {
    pub wallpaper_id: String,
}

pub struct InjectWallpaperForTest {
    pub id: String,
    pub title: String,
    pub kind: BridgeWallpaperKind,
}

pub struct InjectSceneWallpaperConfigForTest {
    pub id: String,
    pub title: String,
}

pub struct InjectSceneProjectForTest {
    pub id: String,
    pub title: String,
    pub project_json: String,
}

pub struct InjectDisplayForTest {
    pub display_id: String,
    pub title: String,
}

pub struct ReplaceLibraryForTest {
    pub entries: Vec<BridgeWallpaperEntry>,
}

pub struct ReplaceWallpaperConfigForTest {
    pub id: String,
    pub config: WallpaperConfig,
}

pub struct SelectWallpaper {
    pub id: String,
}

pub struct RefreshLibrary;

pub struct RefreshDisplays;

pub struct PollMousePosition;

pub struct SetFilter {
    pub kind: BridgeWallpaperKind,
    pub enabled: bool,
}

pub struct SetDisplayEnabled {
    pub display_id: String,
    pub enabled: bool,
}

pub struct SetDisplayMode {
    pub display_id: String,
    pub mode: BridgeDisplayMode,
}

pub struct SetMirrorTarget {
    pub display_id: String,
    pub target_display_id: String,
}

pub struct SetMirrorScalingMode {
    pub display_id: String,
    pub mode: BridgeScalingMode,
}

pub struct SetMirrorScalingFactor {
    pub display_id: String,
    pub factor: f64,
}

pub struct SetMirrorTargetFps {
    pub display_id: String,
    pub fps: u32,
}

pub struct SetMirrorVolume {
    pub display_id: String,
    pub volume: f32,
}

pub struct SetMirrorMuted {
    pub display_id: String,
    pub muted: bool,
}

pub struct EjectWallpaperFromDisplay {
    pub display_id: String,
    pub wallpaper_id: String,
}

pub struct SetGlobalPlayback {
    pub playback_state: BridgePlaybackState,
}

pub struct Shutdown;

pub struct SetVolume {
    pub wallpaper_id: String,
    pub volume: f32,
}

pub struct SetMuted {
    pub wallpaper_id: String,
    pub muted: bool,
}

pub struct SetAudioResponseEnabled {
    pub wallpaper_id: String,
    pub enabled: bool,
}

pub struct SetDisplayConfigEnabled {
    pub wallpaper_id: String,
    pub display_id: String,
    pub enabled: bool,
}

pub struct SetScalingMode {
    pub wallpaper_id: String,
    pub display_id: String,
    pub mode: BridgeScalingMode,
}

pub struct SetScalingFactor {
    pub wallpaper_id: String,
    pub display_id: String,
    pub factor: f64,
}

pub struct SetTargetFps {
    pub wallpaper_id: String,
    pub display_id: String,
    pub fps: u32,
}

pub struct SetLaunchAtLogin {
    pub enabled: bool,
}

pub struct SetPauseOnBatteryPower {
    pub enabled: bool,
}

pub struct SetPresentationSuspended {
    pub suspended: bool,
}

pub struct SetDisplayPresentationSuspended {
    pub display_id: String,
    pub suspended: bool,
}

pub struct SetRendererCountersEnabled {
    pub enabled: bool,
}

pub struct RendererCounters;

pub struct SetVideoBackend {
    pub mode: VideoBackendModeCfg,
}

pub struct SetSceneRenderer {
    pub mode: SceneRendererModeCfg,
}

pub struct SetRenderScale {
    pub scale: f32,
}

pub struct SetBatteryQualityProfile {
    pub enabled: bool,
    pub render_scale: f32,
    pub target_fps: u32,
}

pub struct SetContentPacingEnabled {
    pub enabled: bool,
}

pub struct SetSharedVideoDecodeEnabled {
    pub enabled: bool,
}

pub struct SetSceneOptimizationEnabled {
    pub enabled: bool,
}

pub struct SetSceneOnDemandEnabled {
    pub enabled: bool,
}

pub struct SetSceneVideoPlaneSamplingEnabled {
    pub enabled: bool,
}

/// A web page registered or dropped its audio listener.
pub struct SetWebAudioSubscribed {
    pub wallpaper_id: String,
    pub display_id: u32,
    pub subscribed: bool,
}

pub struct SetMediaIntegrationEnabled {
    pub wallpaper_id: String,
    pub enabled: bool,
}

/// Delivers one already-serialized SceneScript media event to every desktop
/// scene that opted in.
pub struct FanOutSystemMediaEvent {
    pub json: String,
}

/// Uploads `$mediaThumbnail` RGBA to every opted-in desktop scene.
pub struct FanOutSystemMediaArtwork {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Asks which applied desktop scenes should be fed now-playing right now.
///
/// The host reads the system player only while something would receive it, so
/// an empty answer is what keeps a machine with the setting off — or one whose
/// wallpapers are all paused or suspended — from being asked for Automation
/// permission and from running the adapter. The handles themselves matter too:
/// a scene that has just been created starts with no media state, and the host
/// can only know to replay for it by seeing a handle it has not fed.
pub struct GetSystemMediaSceneHandles;

/// Asks which applied desktop scenes their user allowed near media at all.
///
/// Distinct from `GetSystemMediaSceneHandles`, which answers "should this be
/// receiving media now" and therefore shrinks when playback stops. Consent does
/// not shrink: a wallpaper whose button press is on its way must be judged on
/// what its user permitted, not on whether it happens to be presenting.
pub struct GetSystemMediaConsentHandles;

/// Stores the absolute path the host staged for a file or directory property,
/// or clears it. The path is persisted exactly as given.
pub struct SetPropertyPath {
    pub wallpaper_id: String,
    pub property_id: String,
    pub path: Option<String>,
}

pub struct GetNativeVideoWallpapers;

/// The host could not play a wallpaper natively and hands it back.
pub struct RejectNativeVideo {
    pub wallpaper_id: String,
    /// The `admission_key` of the descriptor the host judged. A key that no
    /// longer matches the wallpaper's live configuration means the refusal
    /// arrived after the user changed something, and it is discarded.
    pub admission_key: u64,
    pub reason: String,
}

pub struct SetPowerSource {
    pub source: PowerSource,
    pub initial_sample: bool,
}

pub struct InitialFrameReady;

pub struct EditProperty {
    pub wallpaper_id: String,
    pub property_id: String,
    pub value: BridgePropertyValue,
}

pub struct RestorePropertyDefault {
    pub wallpaper_id: String,
    pub property_id: String,
}

pub struct ApplyWallpaperOptions {
    pub wallpaper_id: String,
}

pub struct CancelWallpaperOptions {
    pub wallpaper_id: String,
}

pub struct CommitApplyAfterReconcile {
    pub wallpaper_id: String,
    pub candidates: ApplyCandidates,
    pub scenes: Vec<wallpaper_core::project::SceneDesc>,
    pub generation: u64,
}

pub struct CommitDisplayAfterReconcile {
    pub app_config: AppConfig,
    pub wallpaper_configs: BTreeMap<String, WallpaperConfig>,
    pub display_settings: BTreeMap<String, BridgeDisplaySettingsRow>,
    pub scenes: Vec<wallpaper_core::project::SceneDesc>,
    pub generation: u64,
}

pub struct CompleteRestoreAfterReconcile {
    pub result: Result<Vec<wallpaper_core::project::SceneDesc>, BridgeError>,
    pub generation: u64,
}

pub struct ReconcileFailed {
    pub error: BridgeError,
    pub generation: u64,
}

pub struct CompleteAudioResponse {
    pub wallpaper_id: String,
    pub previous_enabled: bool,
    pub result: Result<(), BridgeError>,
}

pub type AllSnapshotsReply = Result<BridgeSnapshotBundle, BridgeError>;
pub type BootstrapReply = AllSnapshotsReply;
pub type AppSnapshotReply = Result<BridgeAppSnapshot, BridgeError>;
pub type LibrarySnapshotReply = Result<BridgeLibrarySnapshot, BridgeError>;
pub type LockScreenScenesReply = Result<Vec<BridgeLockScreenScene>, BridgeError>;
pub type WebWallpapersReply = Result<Vec<BridgeWebWallpaper>, BridgeError>;
pub type MonitorInformationSnapshotReply = Result<BridgeMonitorInformationSnapshot, BridgeError>;
pub type SettingsSnapshotReply = Result<BridgeSettingsSnapshot, BridgeError>;
pub type ClearShaderCacheReply = Result<BridgeSettingsSnapshot, BridgeError>;
pub type WallpaperOptionsSnapshotReply = Result<BridgeWallpaperOptionsSnapshot, BridgeError>;
pub type TestMutationReply = Result<(), BridgeError>;
pub type SelectWallpaperReply = AllSnapshotsReply;
pub type RefreshLibraryReply = AllSnapshotsReply;
pub type RefreshDisplaysReply = AllSnapshotsReply;
pub type PollMousePositionReply = Result<(), BridgeError>;
pub type SetFilterReply = AllSnapshotsReply;
pub type DisplayMutationReply = Result<BridgeDisplayMutationBundle, crate::api::BridgeError>;
pub type SetDisplayEnabledReply = DisplayMutationReply;
pub type SetDisplayModeReply = DisplayMutationReply;
pub type SetMirrorTargetReply = DisplayMutationReply;
pub type SetMirrorScalingModeReply = DisplayMutationReply;
pub type SetMirrorScalingFactorReply = DisplayMutationReply;
pub type SetMirrorTargetFpsReply = DisplayMutationReply;
pub type SetMirrorVolumeReply = DisplayMutationReply;
pub type SetMirrorMutedReply = DisplayMutationReply;
pub type EjectWallpaperFromDisplayReply = DisplayMutationReply;
pub type SetGlobalPlaybackReply = AllSnapshotsReply;
pub type SetPauseOnBatteryPowerReply = AllSnapshotsReply;
pub type SetPresentationSuspendedReply = Result<(), BridgeError>;
pub type SetDisplayPresentationSuspendedReply = Result<(), BridgeError>;
pub type SetPowerSourceReply = AllSnapshotsReply;
pub type InitialFrameReadyReply = AllSnapshotsReply;
pub type ShutdownReply = Result<(), BridgeError>;
pub type WallpaperMutationReply = Result<BridgeWallpaperMutationBundle, crate::api::BridgeError>;
pub type CommitApplyAfterReconcileReply = WallpaperMutationReply;
pub type CommitDisplayAfterReconcileReply = DisplayMutationReply;
pub type SetRendererCountersEnabledReply = Result<(), BridgeError>;
pub type RendererCountersReply = Result<BridgeRendererCountersReport, BridgeError>;
pub type SetVideoBackendReply = AllSnapshotsReply;
pub type SetRenderScaleReply = AllSnapshotsReply;
pub type SetBatteryQualityProfileReply = AllSnapshotsReply;
pub type SetContentPacingEnabledReply = AllSnapshotsReply;
pub type SetSharedVideoDecodeEnabledReply = AllSnapshotsReply;
pub type SetSceneOptimizationEnabledReply = AllSnapshotsReply;
pub type SetSceneRendererReply = AllSnapshotsReply;
pub type SetSceneOnDemandEnabledReply = AllSnapshotsReply;
pub type SetSceneVideoPlaneSamplingEnabledReply = AllSnapshotsReply;
pub type SetWebAudioSubscribedReply = Result<(), BridgeError>;
pub type SetMediaIntegrationEnabledReply = WallpaperMutationReply;
pub type FanOutSystemMediaEventReply = Result<(), BridgeError>;
pub type FanOutSystemMediaArtworkReply = Result<(), BridgeError>;
pub type GetSystemMediaSceneHandlesReply = Result<Vec<u64>, BridgeError>;
pub type GetSystemMediaConsentHandlesReply = Result<Vec<u64>, BridgeError>;
pub type SetPropertyPathReply = WallpaperMutationReply;
pub type GetNativeVideoWallpapersReply = Result<Vec<BridgeNativeVideoWallpaper>, BridgeError>;
pub type RejectNativeVideoReply = Result<(), BridgeError>;
pub type CompleteRestoreAfterReconcileReply = Result<(), BridgeError>;
pub type ReconcileFailedReply = Result<(), BridgeError>;
