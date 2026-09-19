use serde::{Deserialize, Serialize};
use wallpaper_core::{DisplayIdentity, DisplaySelector, project::ScalingMode};

pub const SCHEMA_VERSION: u32 = 1;
const DEFAULT_MONITOR_VOLUME: f32 = 1.0;
const DEFAULT_MONITOR_FPS: u32 = 60;
/// Lowest internal rasterization scale the renderer will honour. Below this a
/// wallpaper stops being a quality tier and becomes a visibly broken image.
pub const MIN_RENDER_SCALE: f32 = 0.25;
pub const MAX_RENDER_SCALE: f32 = 1.0;
const DEFAULT_BATTERY_RENDER_SCALE: f32 = 0.75;
const DEFAULT_BATTERY_TARGET_FPS: u32 = 30;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub general: GeneralCfg,
    #[serde(default)]
    pub power: PowerCfg,
    #[serde(default)]
    pub ui: UiCfg,
    #[serde(default)]
    pub experimental: ExperimentalCfg,
    /// Which renderer plays a plain local video. Replaces the former
    /// `experimental.native_video_backend` flag; see
    /// [`AppConfig::migrate_legacy_keys`].
    #[serde(default)]
    pub video_backend: VideoBackendModeCfg,
    /// Which renderer draws a scene wallpaper. Independent of
    /// [`AppConfig::video_backend`]: a scene is not a plain video, and the two
    /// choices route different wallpapers. New in this schema, so unlike
    /// `video_backend` it has no predecessor key to migrate from.
    #[serde(default)]
    pub scene_renderer: SceneRendererModeCfg,
    #[serde(default)]
    pub quality: QualityCfg,
    #[serde(default)]
    pub monitors: Vec<MonitorCfg>,
    #[serde(default)]
    pub monitor_settings: Vec<MonitorSettingsCfg>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            general: GeneralCfg::default(),
            power: PowerCfg::default(),
            ui: UiCfg::default(),
            experimental: ExperimentalCfg::default(),
            video_backend: VideoBackendModeCfg::default(),
            scene_renderer: SceneRendererModeCfg::default(),
            quality: QualityCfg::default(),
            monitors: Vec::new(),
            monitor_settings: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GeneralCfg {
    pub last_selected_wallpaper: Option<String>,
}

/// Which renderer plays a plain local video wallpaper.
///
/// `Compatibility` is the scene engine, which supports every wallpaper.
/// `NativePreferred` asks for the platform player where the wallpaper falls
/// inside its declared subset and falls back to the scene engine otherwise, so
/// the choice is a preference rather than a guarantee.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VideoBackendModeCfg {
    #[default]
    Compatibility,
    NativePreferred,
}

/// Which renderer draws a scene wallpaper.
///
/// `Compatibility` is the established Vulkan/MoltenVK path, which supports
/// every scene. `NativeMetalPreferred` asks for the native Metal backend where
/// the whole scene falls inside the subset it can draw, and falls back to
/// Compatibility as a whole scene otherwise, so the choice is a preference
/// rather than a guarantee.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SceneRendererModeCfg {
    #[default]
    Compatibility,
    NativeMetalPreferred,
}

/// Internal rasterization size and frame rate the renderer targets.
///
/// `render_scale` is the fraction of the display's native pixel grid the scene
/// is actually rasterized at. It is not window scaling and not wallpaper
/// scaling: at 0.5 the renderer does a quarter of the pixel work.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct QualityProfileCfg {
    #[serde(default = "default_battery_render_scale")]
    pub render_scale: f32,
    #[serde(default = "default_battery_target_fps")]
    pub target_fps: u32,
}

impl Default for QualityProfileCfg {
    fn default() -> Self {
        Self {
            render_scale: DEFAULT_BATTERY_RENDER_SCALE,
            target_fps: DEFAULT_BATTERY_TARGET_FPS,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct QualityCfg {
    /// The scale the user chose. Always the preference, never the value in
    /// force: a power profile can lower what the renderer runs at without
    /// overwriting what the user asked for.
    #[serde(default = "default_render_scale")]
    pub render_scale: f32,
    #[serde(default)]
    pub battery_profile_enabled: bool,
    #[serde(default)]
    pub battery: QualityProfileCfg,
    /// Scene-renderer static-subgraph caching and redundant copy-pass
    /// elimination. On by default: it is a rendering optimization with no
    /// intended visual difference, so the switch exists to take it away when
    /// a wallpaper disagrees, not to opt in.
    #[serde(default = "default_true")]
    pub scene_optimization_enabled: bool,
    /// Stop the scene's periodic tick when the scene has no continuing reason
    /// to redraw, waking it on events instead. Off by default: unlike
    /// `scene_optimization_enabled` this changes when a scene runs at all, so
    /// it is opted into rather than taken away.
    #[serde(default)]
    pub scene_on_demand_enabled: bool,
}

impl Default for QualityCfg {
    fn default() -> Self {
        Self {
            render_scale: MAX_RENDER_SCALE,
            battery_profile_enabled: false,
            battery: QualityProfileCfg::default(),
            scene_optimization_enabled: default_true(),
            scene_on_demand_enabled: false,
        }
    }
}

/// Opt-in behaviour that is not ready to be a default.
///
/// Anything here is off unless the user turns it on, survives a restart, and is
/// expected to be reported as experimental wherever it is surfaced.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExperimentalCfg {
    /// Where the video backend choice used to live. Read so an existing opt-in
    /// survives the move to [`AppConfig::video_backend`], and never written
    /// again: once a config has been saved by this build the key is gone, so
    /// the migration cannot fire against a choice the user has since changed.
    #[serde(default, rename = "native_video_backend", skip_serializing)]
    pub legacy_native_video_backend: Option<bool>,
    /// Pace scene content production to the target rate instead of producing a
    /// frame per display refresh.
    #[serde(default)]
    pub content_pacing: bool,
    /// Let displays showing the same video share one decode session instead of
    /// decoding the file once per surface.
    #[serde(default)]
    pub shared_video_decode: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PowerCfg {
    #[serde(default)]
    pub pause_on_battery_power: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UiCfg {
    #[serde(default = "default_selector_window")]
    pub selector_window: WindowGeom,
    #[serde(default = "default_settings_window")]
    pub settings_window: WindowGeom,
    #[serde(default)]
    pub filter: FilterCfg,
}

impl Default for UiCfg {
    fn default() -> Self {
        Self {
            selector_window: default_selector_window(),
            settings_window: default_settings_window(),
            filter: FilterCfg::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowGeom {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FilterCfg {
    pub scene: bool,
    pub video: bool,
    pub web: bool,
    pub unknown: bool,
}

impl Default for FilterCfg {
    fn default() -> Self {
        Self {
            scene: true,
            video: true,
            web: true,
            unknown: true,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum SerializedSelector {
    #[default]
    Primary,
    Identity {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        uuid: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        vendor_id: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model_id: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        serial_number: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        unit_number: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    #[serde(rename = "live_display_id")]
    LiveDisplayId { display_id: u32 },
}

impl SerializedSelector {
    #[must_use]
    pub fn to_selector(&self) -> DisplaySelector {
        match self {
            Self::Primary => DisplaySelector::Primary,
            Self::Identity {
                uuid,
                vendor_id,
                model_id,
                serial_number,
                unit_number,
                name,
            } => DisplaySelector::Identity(DisplayIdentity {
                uuid: uuid.clone(),
                vendor_id: *vendor_id,
                model_id: *model_id,
                serial_number: *serial_number,
                unit_number: *unit_number,
                name: name.clone(),
            }),
            Self::LiveDisplayId { display_id } => DisplaySelector::LiveDisplayId(*display_id),
        }
    }

    #[must_use]
    pub fn from_selector(sel: &DisplaySelector) -> Self {
        match sel {
            DisplaySelector::Primary => Self::Primary,
            DisplaySelector::Identity(identity) => Self::Identity {
                uuid: identity.uuid.clone(),
                vendor_id: identity.vendor_id,
                model_id: identity.model_id,
                serial_number: identity.serial_number,
                unit_number: identity.unit_number,
                name: identity.name.clone(),
            },
            DisplaySelector::LiveDisplayId(display_id) => Self::LiveDisplayId {
                display_id: *display_id,
            },
        }
    }

    #[must_use]
    /// # Panics
    ///
    /// Panics if a display identity selector cannot be serialized to JSON.
    pub fn id(&self) -> String {
        const PRIMARY_DISPLAY_ID: &str = "primary";
        const IDENTITY_DISPLAY_ID_PREFIX: &str = "identity:";

        match self {
            SerializedSelector::Primary => PRIMARY_DISPLAY_ID.to_string(),
            SerializedSelector::LiveDisplayId { display_id } => display_id.to_string(),
            SerializedSelector::Identity { .. } => {
                let DisplaySelector::Identity(identity) = self.to_selector() else {
                    unreachable!("identity selector must convert to identity")
                };
                format!(
                    "{IDENTITY_DISPLAY_ID_PREFIX}{}",
                    serde_json::to_string(&identity)
                        .expect("display identity selector should serialize")
                )
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MonitorCfg {
    #[serde(flatten, default)]
    pub selector: SerializedSelector,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_monitor_mode")]
    pub mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wallpaper: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mirror_target: Option<SerializedSelector>,
}

impl Default for MonitorCfg {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            enabled: true,
            mode: default_monitor_mode(),
            wallpaper: None,
            mirror_target: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MonitorSettingsCfg {
    #[serde(flatten, default)]
    pub selector: SerializedSelector,
    #[serde(default = "default_scaling_mode")]
    pub scaling_mode: String,
    #[serde(default = "default_scaling_factor")]
    pub scaling_factor: f64,
    #[serde(default = "default_target_fps")]
    pub target_fps: u32,
    #[serde(default = "default_monitor_volume")]
    pub volume: f32,
    #[serde(default)]
    pub muted: bool,
}

impl Default for MonitorSettingsCfg {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            scaling_mode: default_scaling_mode(),
            scaling_factor: default_scaling_factor(),
            target_fps: default_target_fps(),
            volume: default_monitor_volume(),
            muted: false,
        }
    }
}

impl MonitorSettingsCfg {
    #[must_use]
    pub fn parse_scaling_mode(&self) -> ScalingMode {
        match self.scaling_mode.to_ascii_lowercase().as_str() {
            "none" => ScalingMode::None,
            "stretch" => ScalingMode::Stretch,
            "fill" => ScalingMode::Fill,
            "fit" => ScalingMode::Fit,
            _ => ScalingMode::default(),
        }
    }
}

impl AppConfig {
    /// Folds keys this build no longer writes into their replacements.
    ///
    /// Called once on load. The video backend choice moved out of
    /// `experimental`; an existing opt-in has to keep its behaviour, so the
    /// legacy flag is honoured exactly while the new key is still absent. A
    /// config this build has saved never carries the legacy key again, so a
    /// later change of mind cannot be overwritten by it.
    pub fn migrate_legacy_keys(&mut self) {
        let legacy_native = self.experimental.legacy_native_video_backend.take();
        if legacy_native == Some(true) && self.video_backend == VideoBackendModeCfg::Compatibility {
            self.video_backend = VideoBackendModeCfg::NativePreferred;
        }
    }

    /// The render scale in force right now: the battery profile's while that
    /// profile is enabled and the machine is on battery, the user's otherwise.
    #[must_use]
    pub fn effective_render_scale(&self, on_battery: bool) -> f32 {
        let scale = if self.quality.battery_profile_enabled && on_battery {
            self.quality.battery.render_scale
        } else {
            self.quality.render_scale
        };
        clamp_render_scale(scale)
    }
}

/// Confines a render scale to the range the renderer honours.
///
/// A non-finite value is not a scale at all and falls back to native rather
/// than to the low end, because the failure mode of guessing wrong here is a
/// permanently blurry desktop.
#[must_use]
pub fn clamp_render_scale(scale: f32) -> f32 {
    if !scale.is_finite() {
        return MAX_RENDER_SCALE;
    }
    scale.clamp(MIN_RENDER_SCALE, MAX_RENDER_SCALE)
}

#[allow(clippy::single_call_fn)]
fn default_schema_version() -> u32 {
    SCHEMA_VERSION
}

fn default_true() -> bool {
    true
}

#[allow(clippy::single_call_fn)]
fn default_render_scale() -> f32 {
    MAX_RENDER_SCALE
}

#[allow(clippy::single_call_fn)]
fn default_battery_render_scale() -> f32 {
    DEFAULT_BATTERY_RENDER_SCALE
}

#[allow(clippy::single_call_fn)]
fn default_battery_target_fps() -> u32 {
    DEFAULT_BATTERY_TARGET_FPS
}

fn default_monitor_mode() -> String {
    "independent".to_string()
}

fn default_scaling_mode() -> String {
    ScalingMode::default().to_string()
}

fn default_scaling_factor() -> f64 {
    1.0
}

fn default_target_fps() -> u32 {
    DEFAULT_MONITOR_FPS
}

fn default_monitor_volume() -> f32 {
    DEFAULT_MONITOR_VOLUME
}

fn default_selector_window() -> WindowGeom {
    WindowGeom {
        x: 200,
        y: 200,
        width: 1100,
        height: 720,
    }
}

fn default_settings_window() -> WindowGeom {
    WindowGeom {
        x: 520,
        y: 260,
        width: 520,
        height: 440,
    }
}
