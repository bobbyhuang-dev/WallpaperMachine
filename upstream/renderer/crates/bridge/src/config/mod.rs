//! On-disk persistence.

pub mod app;
pub mod store;
pub mod wallpaper;
pub mod writer;

pub use app::{
    AppConfig, FilterCfg, GeneralCfg, MonitorCfg, MonitorSettingsCfg, PowerCfg, QualityCfg,
    QualityProfileCfg, SceneRendererModeCfg, SerializedSelector, UiCfg, VideoBackendModeCfg,
    WindowGeom, clamp_render_scale,
};
pub use store::{ConfigLoad, ConfigStore};
pub use wallpaper::{AudioCfg, MonitorRender, WallpaperConfig};
