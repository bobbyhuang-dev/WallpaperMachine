#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeWallpaperKind {
    ProjectScene,
    Video,
    Webpage,
    Unknown,
}

impl From<wallpaper_core::project::WallpaperProjectType> for BridgeWallpaperKind {
    fn from(value: wallpaper_core::project::WallpaperProjectType) -> Self {
        match value {
            wallpaper_core::project::WallpaperProjectType::Scene => Self::ProjectScene,
            wallpaper_core::project::WallpaperProjectType::Video => Self::Video,
            wallpaper_core::project::WallpaperProjectType::Web => Self::Webpage,
            wallpaper_core::project::WallpaperProjectType::Unknown => Self::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeScalingMode {
    None,
    Stretch,
    Match,
    Fill,
}

/// Committed renderer inputs for a native lock-screen wallpaper display.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeLockScreenScene {
    pub display_id: u32,
    pub title: String,
    pub project_path: String,
    pub assets_path: String,
    pub fps: u32,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
    /// Renderer-ready property overrides with nested keys flattened.
    pub properties_json: Option<String>,
    pub paused: bool,
}

/// Committed inputs for a web wallpaper the host renders in a web view on one
/// display. Mirrors of a web source display appear as separate entries.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeWebWallpaper {
    pub display_id: u32,
    pub wallpaper_id: String,
    pub title: String,
    /// Absolute project directory.
    pub project_path: String,
    /// Entry page relative to `project_path`.
    pub entry_file: String,
    pub fps: u32,
    pub paused: bool,
    pub audio_response_enabled: bool,
    /// Wallpaper Engine `applyUserProperties` payload: `{ id: { value } }`
    /// for every user-editable property, overrides applied over defaults.
    pub properties_json: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeDisplayMode {
    Standalone,
    Mirror,
}

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum BridgePropertyValue {
    Bool { value: bool },
    Number { value: f64 },
    String { value: String },
    ColorRgb { red: f64, green: f64, blue: f64 },
    Empty,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgePropertyKind {
    Slider,
    Combo,
    Bool,
    Color,
    TextInput,
    Text,
    Group,
    Directory,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgePlaybackState {
    Playing,
    Paused,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeAppSnapshot {
    pub playback_state: BridgePlaybackState,
    pub selected_wallpaper_id: Option<String>,
    pub active_wallpaper_ids: Vec<String>,
    pub errors: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeLibraryScanStatus {
    pub scanning: bool,
    pub done: u64,
    pub total: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeWallpaperEntry {
    pub id: String,
    pub title: String,
    pub kind: BridgeWallpaperKind,
    pub supported: bool,
    pub active: bool,
    pub selected: bool,
    pub preview_path: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeLibrarySnapshot {
    pub wallpapers: Vec<BridgeWallpaperEntry>,
    pub scan_status: BridgeLibraryScanStatus,
    pub scene_count: u64,
    pub video_count: u64,
    pub webpage_count: u64,
    pub unknown_count: u64,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
#[allow(clippy::struct_excessive_bools)]
pub struct BridgeDisplayConfigRow {
    pub display_id: String,
    pub title: String,
    pub enabled: bool,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
    pub target_fps: u32,
    pub max_fps: u32,
    pub muted: bool,
    pub volume: f32,
    pub dirty: bool,
    pub can_restore_defaults: bool,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeSliderMetadata {
    pub min: f64,
    pub max: f64,
    pub step: f64,
    pub precision: u32,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeComboOption {
    pub label: String,
    pub value: BridgePropertyValue,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgePropertyDescriptor {
    pub id: String,
    pub kind: BridgePropertyKind,
    pub label_html: String,
    pub value: BridgePropertyValue,
    pub default_value: BridgePropertyValue,
    pub slider: Option<BridgeSliderMetadata>,
    pub combo_options: Vec<BridgeComboOption>,
    pub dirty: bool,
    pub can_restore_defaults: bool,
    pub enabled: bool,
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeWallpaperOptionsSnapshot {
    pub wallpaper_id: String,
    pub title: String,
    pub kind: BridgeWallpaperKind,
    pub supported: bool,
    pub dirty: bool,
    pub properties: Vec<BridgePropertyDescriptor>,
    pub display_configurations: Vec<BridgeDisplayConfigRow>,
    pub audio_response_enabled: bool,
    pub muted: bool,
    pub volume: f32,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeMonitorInfoRow {
    pub display_id: String,
    pub title: String,
    pub wallpaper_id: String,
    pub wallpaper_title: String,
    pub mirror_target_display_id: Option<String>,
    pub mirror_target_title: Option<String>,
    pub scaling_mode: String,
    pub target_fps: String,
    pub audio_response: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeMonitorInformationSnapshot {
    pub rows: Vec<BridgeMonitorInfoRow>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeDisplaySettingsRow {
    pub display_id: String,
    pub title: String,
    pub enabled: bool,
    pub mode: BridgeDisplayMode,
    pub mirror_targets: Vec<String>,
    pub selected_mirror_target: Option<String>,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
    pub target_fps: u32,
    pub max_fps: u32,
    pub muted: bool,
    pub volume: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeLogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeLogStatus {
    pub logs_root: String,
    pub active_session: String,
    pub active_file: String,
    pub active_file_size_bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeStorageStatus {
    pub shader_cache_size_bytes: u64,
    pub logs: BridgeLogStatus,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeSettingsSnapshot {
    pub displays: Vec<BridgeDisplaySettingsRow>,
    pub launch_at_login_available: bool,
    pub launch_at_login_enabled: bool,
    pub pause_on_battery_power: bool,
    pub git_sha: String,
    pub bridge_version: String,
    pub core_version: String,
    pub shader_pipeline_version: String,
    pub storage: BridgeStorageStatus,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeSnapshotBundle {
    pub app: BridgeAppSnapshot,
    pub library: BridgeLibrarySnapshot,
    pub wallpaper_options: Option<BridgeWallpaperOptionsSnapshot>,
    pub monitor_information: BridgeMonitorInformationSnapshot,
    pub settings: BridgeSettingsSnapshot,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeWallpaperMutationBundle {
    pub app: BridgeAppSnapshot,
    pub library: BridgeLibrarySnapshot,
    pub wallpaper_options: BridgeWallpaperOptionsSnapshot,
    pub monitor_information: BridgeMonitorInformationSnapshot,
    pub settings: BridgeSettingsSnapshot,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeDisplayMutationBundle {
    pub app: BridgeAppSnapshot,
    pub library: BridgeLibrarySnapshot,
    pub monitor_information: BridgeMonitorInformationSnapshot,
    pub settings: BridgeSettingsSnapshot,
}

/// Renderer work counters for one wallpaper surface.
///
/// The fields are split on purpose. `timer_wakeups` through `simulation_ticks`
/// are work this surface alone performs and must stop when nobody can see it.
/// The `video_*` fields describe the decoded source, which may legitimately keep
/// running while one of its consumers is hidden as long as another consumer
/// still presents it.
///
/// Counting is off by default. With it off every value is zero, which means
/// "not recorded", never "no work".
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeRendererSurfaceCounters {
    pub display_id: String,
    /// Renderer scene handle: the surface identity.
    pub surface_id: String,
    /// Renderer object identity. Two wallpapers that reused one display and one
    /// handle have different generations and are never merged.
    pub generation: u64,
    /// Identity of the running decoder instance this surface consumes:
    /// `instance:<n>`, or `unknown` when the surface consumes no decoder or
    /// more than one. Two decoders opened from the same file have different
    /// identities and must never be folded together; a roll-up de-duplicates
    /// source work on this, never on the path.
    pub source_id: String,
    /// Scene source path. A human label for the row, not an identity.
    pub source_path: String,
    /// Live decoder instances this surface consumes.
    pub source_count: u64,
    pub backend: String,
    /// Independent reasons, never collapsed into one flag.
    pub effective_pause_reasons: Vec<String>,
    pub paused: bool,
    pub timer_wakeups: u64,
    pub draw_requests: u64,
    pub draw_ticks_suppressed: u64,
    pub draws_executed: u64,
    pub draws_dropped: u64,
    pub render_submissions: u64,
    pub render_failures: u64,
    pub present_requests: u64,
    /// The submitted frame's fence signalled. Not a display presentation.
    pub gpu_completions: u64,
    pub simulation_ticks: u64,
    pub tick_interval_micros: u64,
    /// 0 when the content cannot prove how often it changes.
    pub content_period_micros: u64,
    pub video_decode_outputs: u64,
    pub video_seeks: u64,
    pub video_frames_selected: u64,
    pub video_frames_reused: u64,
    /// Decoded frames superseded before they were ever displayed. A rising
    /// count is how a demand-driven clock is falsified.
    pub video_frames_skipped: u64,
    pub video_selected_generation: u64,
    pub video_conversions: u64,
    pub video_imports: u64,
    /// Bytes of converted video destination textures this surface's texture
    /// cache is keeping alive, and the most it ever kept alive. Gauges, not
    /// running totals, and an allocation ledger over those destination
    /// textures alone: decode pixel buffers, Core Video plane wrappers, the
    /// Vulkan images aliasing them and the swapchain are all outside it, so
    /// neither figure is a residency or process-footprint measurement.
    pub video_conversion_live_bytes: u64,
    pub video_conversion_peak_live_bytes: u64,
}

/// One pull of the renderer counters, plus the process-wide values that belong
/// to no single surface.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeRendererCountersReport {
    /// False means counting is off and every value is zero.
    pub recording: bool,
    pub surfaces: Vec<BridgeRendererSurfaceCounters>,
    /// Spectrum generations the analysis worker produced, process-wide.
    pub audio_analysis_deliveries: u64,
    pub audio_accepted_frames: u64,
    /// Scenes that both enable audio response and are not paused for their own
    /// display. Zero means the capture tap has no consumer.
    pub audio_active_consumers: u32,
    /// Whether the platform can report which frames were actually displayed.
    /// This backend cannot, so present requests are never reported as
    /// presented frames.
    pub presentation_feedback_available: bool,
}

/// A plain local video routed to the native platform player instead of the
/// scene engine.
///
/// Only the declared subset appears here. `fps` is this display's own target
/// rate and is a requirement, not a hint. Admission, however, is judged against
/// `admission_fps`, which is the strictest target across the mirror group this
/// display belongs to: the host must refuse the wallpaper rather than play any
/// member at a rate its own target does not allow, and a refusal sends the
/// whole group back to the scene engine, which supports everything.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeNativeVideoWallpaper {
    pub display_id: u32,
    pub wallpaper_id: String,
    pub title: String,
    /// Absolute path to the media file, already containment-checked against the
    /// project directory.
    pub media_path: String,
    /// This display's own target frame rate: what the player runs at here.
    pub fps: u32,
    /// The target rate the accept-or-refuse decision must be judged against:
    /// the strictest `fps` across this display's mirror group, equal to `fps`
    /// when the display mirrors nothing and is mirrored by nothing.
    ///
    /// A mirror is only ever given a scene by copying its source's, so it
    /// cannot fall back to the scene engine on its own; the group is admitted
    /// or refused as a unit and is only safe at its strictest member's rate.
    /// Probing `fps` on a mirror would accept a verdict taken for a faster
    /// source and play this display above its own target without ever asking.
    pub admission_fps: u32,
    /// Identifies the exact configuration this descriptor was produced from:
    /// the media file, its length and modification time, and `admission_fps`.
    /// Identical for every member of a mirror group. The host must pass it back
    /// to `reject_native_video` when it refuses, so that a refusal arriving
    /// after the user changed something is discarded instead of killing a
    /// configuration the host never judged.
    pub admission_key: u64,
    /// Presentation suspension or the user's own pause, already combined for
    /// this display by the activation rules.
    pub paused: bool,
    pub volume: f32,
    pub muted: bool,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
}
