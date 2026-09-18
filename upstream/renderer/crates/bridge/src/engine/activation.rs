//! Translate bridge state into the `SceneDesc` list consumed by engine
//! reconciliation, plus the web-wallpaper descriptors the host renders itself.

use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
};

use wallpaper_core::{
    DisplayDesc, DisplaySelector, DisplaySnapshotEntry, EngineError, WallpaperAssignment,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneDesc, SceneDescBuilder, SceneTemplate, WallpaperProjectType},
};

use crate::{
    api::{BridgeError, BridgeErrorKind},
    config::{AppConfig, MonitorCfg, MonitorRender, MonitorSettingsCfg, WallpaperConfig},
    display::{DisplayDescExt, DisplaySelectorExt, DisplaySnapshotExt},
    paths::BridgePaths,
    project::{OverrideMapExt, ProjectModel, PropertyKind, PropertyValue},
};

pub struct ActivationInputs<'a> {
    pub app_config: &'a AppConfig,
    pub wallpapers: &'a BTreeMap<String, WallpaperConfig>,
    pub displays: &'a [DisplaySnapshotEntry],
    /// Conditions that apply to every display: the user's Play/Pause choice,
    /// power policy, display sleep and session lock.
    pub paused: bool,
    /// Displays whose own presentation is suspended, by occlusion for example.
    /// Hiding one screen must not pause the wallpaper on another.
    pub suspended_displays: &'a BTreeSet<u32>,
    pub paths: &'a BridgePaths,
    pub force_shader_refresh: bool,
    /// Parsed manifests keyed by wallpaper id. Web projects are routed to
    /// [`ActivationInputs::build_web`] instead of the scene engine; ids
    /// without a model are treated as engine-rendered.
    pub project_models: &'a BTreeMap<String, ProjectModel>,
    /// Whether plain local video wallpapers may be routed to the native
    /// player. Off by default; see [`ActivationInputs::build_native_video`].
    pub native_video_enabled: bool,
    /// Wallpapers the native player refused, with the reason recorded by the
    /// host. A refusal is permanent for the session, so a wallpaper cannot
    /// oscillate between the two backends.
    pub native_video_rejected: &'a BTreeMap<String, String>,
}

/// A plain local video assigned to one display, played by the host process
/// with the platform video player instead of by the scene engine.
///
/// Only the declared subset reaches this: a project whose type is Video, with
/// a resolvable local media file, and with no option this backend cannot
/// honour. Everything else stays on the scene engine.
#[derive(Clone, Debug, PartialEq)]
pub struct NativeVideoWallpaperDesc {
    pub display: DisplayDesc,
    pub wallpaper_id: String,
    pub media_path: PathBuf,
    /// The user's target frame rate for this display. The host must refuse the
    /// wallpaper rather than silently play at a different rate.
    pub fps: u32,
    pub paused: bool,
    pub volume: f32,
    pub muted: bool,
    pub scaling_mode: ScalingMode,
    pub scaling_factor: f64,
}

/// A web wallpaper assigned to one display, rendered by the host process in a
/// web view rather than by the scene engine.
#[derive(Clone, Debug, PartialEq)]
pub struct WebWallpaperDesc {
    pub display: DisplayDesc,
    pub wallpaper_id: String,
    pub project_dir: PathBuf,
    pub entry_file: String,
    pub fps: u32,
    pub paused: bool,
    pub audio_response_enabled: bool,
    /// Effective user-property values (overrides over manifest defaults),
    /// excluding group and label pseudo-properties.
    pub properties: BTreeMap<String, PropertyValue>,
}

struct DirectSlot<'a> {
    display: DisplayDesc,
    wallpaper_id: &'a str,
    wallpaper: &'a WallpaperConfig,
    monitor: &'a MonitorCfg,
}

struct MirrorSlot {
    display: DisplayDesc,
    source_display_id: u32,
    settings: MonitorSettingsCfg,
}

impl ActivationInputs<'_> {
    /// Effective paused state for one display: a global reason, or that display
    /// being suspended on its own.
    fn display_paused(&self, display_id: u32) -> bool {
        self.paused || self.suspended_displays.contains(&display_id)
    }

    /// Engine-rendered scenes for every enabled, resolved display. Web
    /// wallpapers are excluded; see [`Self::build_web`].
    ///
    /// # Errors
    ///
    /// Returns an error when an active wallpaper config cannot be converted
    /// into a scene.
    pub fn build(&self) -> Result<Vec<SceneDesc>, BridgeError> {
        let (direct, mirrors) = self.slots();
        let mut scenes = Vec::new();
        for slot in direct {
            // A wallpaper routed to a host-rendered backend must not also get a
            // scene: two renderers for one display would decode and present the
            // same content twice.
            if self.is_web(slot.wallpaper_id) || self.is_native_video(slot.wallpaper_id) {
                continue;
            }
            scenes.push(self.scene_for_monitor(
                slot.display,
                slot.wallpaper_id,
                slot.wallpaper,
                slot.monitor,
            )?);
        }

        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            let Some(source_scene) = scenes
                .iter()
                .find(|scene| scene.display.display_id == mirror.source_display_id)
                .cloned()
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            let audio_volume = AudioVolume::try_from(mirror.settings.volume).map_err(|error| {
                BridgeError::Error {
                    kind: BridgeErrorKind::Engine,
                    message: EngineError::InvalidInput(error.to_string()).to_string(),
                }
            })?;
            let mut scene = source_scene;
            scene.display = mirror.display;
            // A mirror presents on its own display, so it takes that display's
            // suspension rather than the source display's.
            scene.paused = self.display_paused(scene.display.display_id);
            scene.scaling_mode = mirror.settings.parse_scaling_mode();
            scene.scaling_factor = mirror.settings.scaling_factor;
            scene.fps = scene
                .display
                .refresh_rate_hz
                .max(1)
                .min(mirror.settings.target_fps.max(1));
            scene.audio_volume = audio_volume;
            scene.audio_muted = mirror.settings.muted;
            scene.validate().map_err(|error| BridgeError::Error {
                kind: BridgeErrorKind::Engine,
                message: error.to_string(),
            })?;
            scenes.push(scene);
        }

        Ok(scenes)
    }

    /// Host-rendered web wallpapers for every enabled, resolved display,
    /// including mirrors of a web source display.
    ///
    /// # Errors
    ///
    /// Returns an error when a web project has no entry file.
    pub fn build_web(&self) -> Result<Vec<WebWallpaperDesc>, BridgeError> {
        let (direct, mirrors) = self.slots();
        let mut web = Vec::new();
        for slot in direct {
            let Some(model) = self.web_model(slot.wallpaper_id) else {
                continue;
            };
            let entry_file = model.entry_file.clone().ok_or_else(|| {
                BridgeError::invalid_input(format!(
                    "web wallpaper {} declares no entry file",
                    slot.wallpaper_id
                ))
            })?;
            let overrides = model.override_values(&slot.wallpaper.property_overrides);
            let properties = model
                .properties
                .iter()
                .filter(|property| {
                    !matches!(property.kind, PropertyKind::Group | PropertyKind::Text)
                })
                .map(|property| (property.id.clone(), property.effective_value(&overrides)))
                .collect();
            let paused = self.display_paused(slot.display.display_id);
            let render = RenderOverrideResolver {
                wallpaper: slot.wallpaper,
                monitor: slot.monitor,
                display: &slot.display,
                displays: self.displays,
            }
            .resolve();
            let fps = render
                .map_or(60, |render| render.fps)
                .max(1)
                .min(slot.display.refresh_rate_hz.max(1));
            web.push(WebWallpaperDesc {
                display: slot.display,
                wallpaper_id: slot.wallpaper_id.to_string(),
                project_dir: self.paths.steam_workshop_root().join(slot.wallpaper_id),
                entry_file,
                fps,
                paused,
                audio_response_enabled: slot.wallpaper.audio.response_enabled,
                properties,
            });
        }

        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            let Some(source) = web
                .iter()
                .find(|desc| desc.display.display_id == mirror.source_display_id)
                .cloned()
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            let fps = mirror
                .settings
                .target_fps
                .max(1)
                .min(mirror.display.refresh_rate_hz.max(1));
            let paused = self.display_paused(mirror.display.display_id);
            web.push(WebWallpaperDesc {
                display: mirror.display,
                fps,
                paused,
                ..source
            });
        }

        Ok(web)
    }

    fn is_web(&self, wallpaper_id: &str) -> bool {
        self.web_model(wallpaper_id).is_some()
    }

    /// Whether this wallpaper is routed to the native player right now.
    ///
    /// Requires the opt-in, a Video project, a resolvable media file, and no
    /// recorded refusal. Any of those failing leaves it on the scene engine,
    /// which is the backend that supports everything.
    fn is_native_video(&self, wallpaper_id: &str) -> bool {
        self.native_video_media(wallpaper_id).is_some()
    }

    fn native_video_media(&self, wallpaper_id: &str) -> Option<PathBuf> {
        if !self.native_video_enabled {
            return None;
        }
        if self.native_video_rejected.contains_key(wallpaper_id) {
            return None;
        }
        let model = self.project_models.get(wallpaper_id)?;
        if model.project_type != WallpaperProjectType::Video {
            return None;
        }
        let file = model.entry_file.as_ref()?;
        if file.is_empty() {
            return None;
        }
        let media = self
            .paths
            .steam_workshop_root()
            .join(wallpaper_id)
            .join(file);
        // The player opens a path, so a project whose media is missing has to
        // stay on the engine rather than produce a window that can never play.
        media.is_file().then_some(media)
    }

    /// Plain local videos for every enabled, resolved display, including
    /// mirrors of a native-video source display.
    ///
    /// # Errors
    ///
    /// Returns an error when a monitor's audio volume is outside the valid
    /// range.
    pub fn build_native_video(&self) -> Result<Vec<NativeVideoWallpaperDesc>, BridgeError> {
        let (direct, mirrors) = self.slots();
        let mut videos = Vec::new();
        for slot in direct {
            let Some(media_path) = self.native_video_media(slot.wallpaper_id) else {
                continue;
            };
            let render = RenderOverrideResolver {
                wallpaper: slot.wallpaper,
                monitor: slot.monitor,
                display: &slot.display,
                displays: self.displays,
            }
            .resolve();
            let fps = render
                .map_or(60, |render| render.fps)
                .max(1)
                .min(slot.display.refresh_rate_hz.max(1));
            videos.push(NativeVideoWallpaperDesc {
                wallpaper_id: slot.wallpaper_id.to_string(),
                media_path,
                fps,
                paused: self.display_paused(slot.display.display_id),
                volume: slot.wallpaper.audio.volume,
                muted: slot.wallpaper.audio.muted,
                scaling_mode: render
                    .map(crate::config::wallpaper::MonitorRender::parse_scaling_mode)
                    .unwrap_or_default(),
                scaling_factor: render.map_or(1.0, |render| render.scaling_factor),
                display: slot.display,
            });
        }

        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            let Some(source) = videos
                .iter()
                .find(|desc| desc.display.display_id == mirror.source_display_id)
                .cloned()
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            let fps = mirror
                .settings
                .target_fps
                .max(1)
                .min(mirror.display.refresh_rate_hz.max(1));
            videos.push(NativeVideoWallpaperDesc {
                fps,
                paused: self.display_paused(mirror.display.display_id),
                volume: mirror.settings.volume,
                muted: mirror.settings.muted,
                scaling_mode: mirror.settings.parse_scaling_mode(),
                scaling_factor: mirror.settings.scaling_factor,
                display: mirror.display,
                ..source
            });
        }

        Ok(videos)
    }

    fn web_model(&self, wallpaper_id: &str) -> Option<&ProjectModel> {
        self.project_models
            .get(wallpaper_id)
            .filter(|model| model.project_type == WallpaperProjectType::Web)
    }

    /// Resolves enabled monitors to live displays: primary-first direct
    /// assignments, then mirrors whose display is not already used.
    fn slots(&self) -> (Vec<DirectSlot<'_>>, Vec<MirrorSlot>) {
        let mut direct = Vec::new();
        let mut used_displays: Vec<DisplayDesc> = Vec::new();
        let mut monitors = self.app_config.monitors.iter().collect::<Vec<_>>();
        monitors.sort_by_key(|monitor| {
            i32::from(monitor.selector != crate::config::SerializedSelector::Primary)
        });

        for monitor in monitors {
            if !monitor.enabled {
                continue;
            }

            let Some(wallpaper_id) = monitor.wallpaper.as_deref() else {
                continue;
            };

            let Some(wallpaper) = self.wallpapers.get(wallpaper_id) else {
                continue;
            };

            if monitor.mode == "mirror" {
                continue;
            }

            let Some(display) = monitor.resolve_display(self.displays) else {
                continue;
            };
            if used_displays
                .iter()
                .any(|used| used.same_physical_display(&display))
            {
                continue;
            }

            used_displays.push(display.clone());
            direct.push(DirectSlot {
                display,
                wallpaper_id,
                wallpaper,
                monitor,
            });
        }

        let mut mirrors = Vec::new();
        for monitor in self
            .app_config
            .monitors
            .iter()
            .filter(|monitor| monitor.enabled && monitor.mode.eq_ignore_ascii_case("mirror"))
        {
            let Some(display) = monitor.resolve_display(self.displays) else {
                continue;
            };
            if used_displays
                .iter()
                .any(|used| used.same_physical_display(&display))
            {
                continue;
            }
            let Some(target) = monitor.mirror_target.as_ref() else {
                continue;
            };
            let Some(source_display_id) = target
                .to_selector()
                .resolve_display(self.displays)
                .map(|entry| entry.desc.display_id)
            else {
                continue;
            };
            let settings = self
                .app_config
                .monitor_settings
                .iter()
                .find(|settings| settings.selector == monitor.selector)
                .cloned()
                .unwrap_or_else(|| MonitorSettingsCfg {
                    selector: monitor.selector.clone(),
                    ..MonitorSettingsCfg::default()
                });
            mirrors.push(MirrorSlot {
                display,
                source_display_id,
                settings,
            });
        }

        (direct, mirrors)
    }

    fn scene_for_monitor(
        &self,
        display: DisplayDesc,
        wallpaper_id: &str,
        wallpaper: &WallpaperConfig,
        monitor: &MonitorCfg,
    ) -> Result<SceneDesc, BridgeError> {
        let display_paused = self.display_paused(display.display_id);
        SceneDescBuilder::build_from_wallpaper_config(SceneBuildContext {
            display,
            workshop_id: wallpaper_id,
            wallpaper,
            monitor,
            displays: self.displays,
            paused: display_paused,
            paths: self.paths,
            force_shader_refresh: self.force_shader_refresh,
        })
    }
}

pub trait WallpaperAssignmentExt {
    fn build_mirror_assignments(
        app_config: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> Vec<(DisplaySelector, WallpaperAssignment)>;
}

impl WallpaperAssignmentExt for WallpaperAssignment {
    fn build_mirror_assignments(
        app_config: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> Vec<(DisplaySelector, WallpaperAssignment)> {
        let mut assignments = Vec::new();

        for monitor in &app_config.monitors {
            if !monitor.enabled || monitor.mode != "mirror" {
                continue;
            }
            if monitor
                .selector
                .to_selector()
                .resolve_display(displays)
                .is_none()
            {
                continue;
            }
            let Some(target) = monitor.mirror_target.as_ref() else {
                continue;
            };
            assignments.push((
                monitor.selector.to_selector(),
                WallpaperAssignment::Mirror(target.to_selector()),
            ));
        }

        assignments
    }
}

trait MonitorCfgActivationExt {
    fn resolve_display(&self, displays: &[DisplaySnapshotEntry]) -> Option<DisplayDesc>;
}

impl MonitorCfgActivationExt for MonitorCfg {
    fn resolve_display(&self, displays: &[DisplaySnapshotEntry]) -> Option<DisplayDesc> {
        self.selector
            .to_selector()
            .resolve_display(displays)
            .map(|entry| entry.desc.clone())
    }
}

pub trait SceneDescBuilderExt {
    fn build_from_wallpaper_config(
        context: SceneBuildContext<'_>,
    ) -> Result<SceneDesc, BridgeError>
    where
        Self: Sized;
}

impl SceneDescBuilderExt for SceneDescBuilder {
    fn build_from_wallpaper_config(
        context: SceneBuildContext<'_>,
    ) -> Result<SceneDesc, BridgeError> {
        let project_json = context
            .paths
            .steam_workshop_root()
            .join(context.workshop_id)
            .join("project.json");
        let assets_path = context.paths.assets_root();
        let audio_volume =
            AudioVolume::try_from(context.wallpaper.audio.volume).map_err(|error| {
                BridgeError::Error {
                    kind: BridgeErrorKind::Engine,
                    message: EngineError::InvalidInput(error.to_string()).to_string(),
                }
            })?;
        let render_override = RenderOverrideResolver {
            wallpaper: context.wallpaper,
            monitor: context.monitor,
            display: &context.display,
            displays: context.displays,
        }
        .resolve();
        let fps = render_override.map_or(60, |render| render.fps);
        let max_fps = context.display.refresh_rate_hz.max(1);
        let scaling_mode = render_override
            .map(crate::config::wallpaper::MonitorRender::parse_scaling_mode)
            .unwrap_or_default();
        let scaling_factor = render_override.map_or(1.0, |render| render.scaling_factor);
        let property_override_json = if !context.wallpaper.r#type.eq_ignore_ascii_case("scene")
            || context.wallpaper.property_overrides.is_empty()
        {
            None
        } else {
            let overrides = context
                .wallpaper
                .property_overrides
                .iter()
                .map(|(id, value)| (id.clone(), PropertyValue::from_json(value)))
                .collect::<BTreeMap<_, _>>();

            Some(overrides.to_override_json())
        };
        let mut builder = SceneTemplate::builder(project_json.to_string_lossy())
            .assets_path(assets_path.to_string_lossy())
            .fps(fps.max(1).min(max_fps))
            .paused(context.paused)
            .scaling_mode(scaling_mode)
            .scaling_factor(scaling_factor)
            .audio_response_enabled(context.wallpaper.audio.response_enabled)
            .audio_volume(audio_volume.into())
            .audio_muted(context.wallpaper.audio.muted)
            .shader_cache_path(context.paths.shader_cache_root().to_string_lossy())
            .force_shader_refresh(context.force_shader_refresh);

        if let Some(json) = property_override_json {
            builder = builder.property_override_json(json);
        }

        builder
            .build()
            .map(|template| template.for_display(context.display))
            .map_err(|error| BridgeError::Error {
                kind: BridgeErrorKind::Engine,
                message: error.to_string(),
            })
    }
}

pub struct SceneBuildContext<'a> {
    display: DisplayDesc,
    workshop_id: &'a str,
    wallpaper: &'a WallpaperConfig,
    monitor: &'a MonitorCfg,
    displays: &'a [DisplaySnapshotEntry],
    paused: bool,
    paths: &'a BridgePaths,
    force_shader_refresh: bool,
}

struct RenderOverrideResolver<'a> {
    wallpaper: &'a WallpaperConfig,
    monitor: &'a MonitorCfg,
    display: &'a DisplayDesc,
    displays: &'a [DisplaySnapshotEntry],
}

impl<'a> RenderOverrideResolver<'a> {
    fn resolve(&self) -> Option<&'a MonitorRender> {
        self.wallpaper
            .monitors
            .iter()
            .find(|render| render.selector == self.monitor.selector)
            .or_else(|| {
                self.wallpaper
                    .monitors
                    .iter()
                    .find(|render| self.matches(render))
            })
    }

    fn matches(&self, render: &MonitorRender) -> bool {
        let Some(display_snapshot) = self.display_snapshot() else {
            return false;
        };

        if render.selector == crate::config::SerializedSelector::Primary {
            return self
                .displays
                .first()
                .is_some_and(|primary| display_snapshot.matches_primary(primary));
        }

        let render_selector = render.selector.to_selector();
        render_selector.matches_display(display_snapshot)
    }

    fn display_snapshot(&self) -> Option<&'a DisplaySnapshotEntry> {
        self.displays
            .iter()
            .find(|display| display.desc.same_physical_display(self.display))
    }
}
