use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    fs,
    sync::Arc,
};

use kameo::{
    actor::{ActorRef, Spawn},
    error::SendError,
    message::{Context, Message},
    reply::{DelegatedReply, Reply},
};
use wallpaper_core::{
    DisplayIdentity, DisplaySelector, DisplaySnapshotEntry, WallpaperAssignment,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneDesc, SceneHandle, SerdeValudeExt},
    render::{
        RendererCounterKind, RendererSharedCounterKind, RendererSurfaceCounters, shared_value,
    },
};

use crate::{
    actor::{
        messages::{
            self, ApplyWallpaperOptions, Bootstrap, CancelWallpaperOptions, ClearShaderCache,
            CommitApplyAfterReconcile, CommitDisplayAfterReconcile, CompleteAudioResponse,
            CompleteRestoreAfterReconcile, EditProperty, EjectWallpaperFromDisplay,
            GetAllSnapshots, GetAppSnapshot, GetLibrarySnapshot, GetLockScreenScenes,
            GetMonitorInformationSnapshot, GetSettingsSnapshot, GetWallpaperOptionsSnapshot,
            GetWebWallpapers,
            InitialFrameReady, InjectDisplayForTest, InjectSceneProjectForTest,
            InjectSceneWallpaperConfigForTest, InjectWallpaperForTest, PollMousePosition,
            GetNativeVideoWallpapers, ReconcileFailed, RefreshDisplays, RefreshLibrary,
            RejectNativeVideo, RendererCounters,
            ReplaceLibraryForTest,
            ReplaceWallpaperConfigForTest, RestorePropertyDefault, SelectWallpaper,
            SetAudioResponseEnabled, SetBatteryQualityProfile, SetContentPacingEnabled,
            SetDisplayConfigEnabled, SetDisplayEnabled, SetDisplayMode,
            SetDisplayPresentationSuspended,
            SetFilter, SetGlobalPlayback, SetLaunchAtLogin, SetMediaIntegrationEnabled,
            SetMirrorMuted, SetMirrorScalingFactor,
            SetMirrorScalingMode, SetMirrorTarget, SetMirrorTargetFps, SetMirrorVolume, SetMuted,
            SetPauseOnBatteryPower, SetPowerSource, SetPresentationSuspended, SetPropertyPath,
            SetRenderScale,
            SetRendererCountersEnabled, SetScalingFactor, SetScalingMode,
            SetSceneOptimizationEnabled, SetSharedVideoDecodeEnabled, SetTargetFps,
            SetVideoBackend, SetVolume, SetWebAudioSubscribed,
            Shutdown,
        },
        state::BridgeActorState,
    },
    api::{
        BridgeAppSnapshot, BridgeDisplayMode, BridgeDisplayMutationBundle,
        BridgeDisplaySettingsRow, BridgeError, BridgeLibraryScanStatus, BridgeLibrarySnapshot,
        BridgeLockScreenScene, BridgeNativeVideoWallpaper, BridgePlaybackState,
        BridgePropertyValue,
        BridgeRendererCountersReport, BridgeRendererSurfaceCounters, BridgeScalingMode,
        BridgeSnapshotBundle, BridgeWallpaperEntry, BridgeWallpaperKind,
        BridgeWallpaperMutationBundle, BridgeWebWallpaper, MousePollingControl,
    },
    config::{
        AppConfig, ConfigStore, SerializedSelector, VideoBackendModeCfg, WallpaperConfig,
    },
    display::{DisplaySelectorExt, DisplaySnapshotExt},
    engine::{ActivationInputs, EngineFacade, NativeVideoRejection, NativeVideoRejections},
    library::scan,
    login::LaunchAtLoginController,
    paths::BridgePaths,
    project::{
        DirectoryMode, FileMedia, ProjectModel, ProjectProperty, PropertyKind, PropertyMetadata,
        PropertyValue,
    },
    state::drafts::WallpaperOptionsDraft,
};

const PRIMARY_DISPLAY_ID: &str = "primary";
const IDENTITY_DISPLAY_ID_PREFIX: &str = "identity:";
const INDEPENDENT_DISPLAY_MODE: &str = "independent";
const MIRROR_DISPLAY_MODE: &str = "mirror";

macro_rules! is_color_channel_valid {
    ($color:expr) => {
        ($color.is_finite() && (0.0..=1.0).contains(&$color))
    };
}

#[derive(kameo::Actor)]
pub struct BridgeActor<E: EngineFacade> {
    pub state: BridgeActorState,
    generation: u64,
    latest_reconcile_generation: u64,
    reconciled_generation: u64,
    repair_after_reconcile_generation: Option<u64>,
    active_restore_generation: Option<u64>,
    restore_requested_after_active: bool,
    pending_audio_changes: HashSet<String>,
    #[allow(dead_code)]
    pub engine: E,
    #[allow(dead_code)]
    pub config_store: Option<ConfigStore>,
    launch_at_login: LaunchAtLoginController,
    paths: BridgePaths,
    mouse_polling: Arc<MousePollingControl>,
}

enum PlaybackChangeOrigin {
    Manual,
    Power,
}

#[derive(Clone)]
pub struct BridgeActorHandle<E: EngineFacade> {
    actor: ActorRef<BridgeActor<E>>,
    runtime: Option<Arc<tokio::runtime::Runtime>>,
}

impl<E: EngineFacade> Drop for BridgeActorHandle<E> {
    fn drop(&mut self) {
        let Some(runtime) = self.runtime.take() else {
            return;
        };

        match Arc::try_unwrap(runtime) {
            Ok(runtime) => runtime.shutdown_background(),
            Err(runtime) => {
                self.runtime = Some(runtime);
            }
        }
    }
}

impl<E: EngineFacade> BridgeActorHandle<E> {
    #[allow(clippy::single_call_fn)]
    pub fn spawn(
        state: BridgeActorState,
        engine: E,
        config_store: Option<ConfigStore>,
        launch_at_login: LaunchAtLoginController,
        paths: BridgePaths,
        mouse_polling: Arc<MousePollingControl>,
    ) -> Result<Self, BridgeError> {
        let actor = BridgeActor {
            state,
            generation: 0,
            latest_reconcile_generation: 0,
            reconciled_generation: 0,
            repair_after_reconcile_generation: None,
            active_restore_generation: None,
            restore_requested_after_active: false,
            pending_audio_changes: HashSet::new(),
            engine,
            config_store,
            launch_at_login,
            paths,
            mouse_polling,
        };
        actor.refresh_mouse_polling_policy();

        let runtime = Arc::new(
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .thread_name("wallpaper-bridge-actor-runtime")
                .build()
                .map_err(|error| {
                    BridgeError::engine(format!("failed to start bridge actor runtime: {error}"))
                })?,
        );
        let actor = {
            let _guard = runtime.enter();
            BridgeActor::spawn_in_thread(actor)
        };

        Ok(Self {
            actor,
            runtime: Some(runtime),
        })
    }

    pub async fn ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<E>: Message<M>,
        <BridgeActor<E> as Message<M>>::Reply: kameo::reply::Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.actor.ask(message).await.map_err(map_send_error)
    }

    pub fn blocking_ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<E>: Message<M>,
        <BridgeActor<E> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.actor
            .ask(message)
            .blocking_send()
            .map_err(map_send_error)
    }
}

fn map_send_error<M>(error: SendError<M, BridgeError>) -> BridgeError {
    match error {
        SendError::HandlerError(error) => error,
        other => BridgeError::engine(other.to_string()),
    }
}

fn duplicate_error(error: &BridgeError) -> BridgeError {
    BridgeError::Error {
        kind: error.kind(),
        message: error.message().to_string(),
    }
}

/// Web pages that are registered audio listeners and are in a position to hear
/// anything: their wallpaper has audio response on and their own display is
/// not paused.
///
/// A page that never registered a listener is not a consumer no matter what
/// its wallpaper's settings say, which is what keeps the tap shut for the
/// common case of a web wallpaper that does not use audio at all.
fn web_audio_consumers(
    inputs: &ActivationInputs<'_>,
    subscribers: &BTreeMap<String, BTreeSet<u32>>,
) -> u32 {
    if subscribers.is_empty() {
        return 0;
    }
    let Ok(web) = inputs.build_web() else {
        return 0;
    };

    u32::try_from(
        web.iter()
            .filter(|desc| desc.audio_response_enabled && !desc.paused)
            .filter(|desc| {
                subscribers
                    .get(&desc.wallpaper_id)
                    .is_some_and(|displays| displays.contains(&desc.display.display_id))
            })
            .count(),
    )
    .unwrap_or(u32::MAX)
}

/// Adds the authored kind, and the file/directory options, beside a property's
/// value in an `applyUserProperties` payload.
///
/// Wallpaper Engine passes the property type through to the page, and a page
/// cannot act on a file or directory property without it: the value alone says
/// nothing about whether to screen extensions, nor whether the directory is
/// pulled from on demand or pushed wholesale.
fn describe_property_kind(
    property: &ProjectProperty,
    entry: &mut serde_json::Map<String, serde_json::Value>,
) {
    let kind = match &property.kind {
        PropertyKind::Slider => "slider",
        PropertyKind::Combo => "combo",
        PropertyKind::Bool => "bool",
        PropertyKind::Color => "color",
        PropertyKind::TextInput => "textinput",
        PropertyKind::Text => "text",
        PropertyKind::Group => "group",
        PropertyKind::File => "file",
        PropertyKind::Directory => "directory",
        PropertyKind::Texture => "texture",
        PropertyKind::Unknown(raw) => raw.as_str(),
    };
    let _ = entry.insert(
        "type".to_string(),
        serde_json::Value::String(kind.to_string()),
    );

    let (filter, mode) = match &property.metadata {
        PropertyMetadata::File { filter } => (Some(filter), None),
        PropertyMetadata::Directory { filter, mode } => (Some(filter), Some(*mode)),
        _ => return,
    };
    // Absent when the project declared nothing, so a page can tell "any file"
    // from a filter this build happened to fall back to.
    if filter.is_some_and(|filter| filter.raw.is_some()) {
        let media = match filter.map(|filter| filter.media) {
            Some(FileMedia::Video) => "video",
            _ => "image",
        };
        let _ = entry.insert(
            "fileFilter".to_string(),
            serde_json::Value::String(media.to_string()),
        );
    }
    if let Some(mode) = mode {
        let mode = match mode {
            DirectoryMode::FetchAll => "fetchall",
            DirectoryMode::OnDemand => "ondemand",
        };
        let _ = entry.insert(
            "mode".to_string(),
            serde_json::Value::String(mode.to_string()),
        );
    }
}

impl<E: EngineFacade> BridgeActor<E> {
    /// Conditions that stop every display at once. Per-display occlusion is in
    /// `state.suspended_displays` and is composed on top of this.
    fn playback_paused(&self) -> bool {
        self.state.presentation_suspended
            || self.state.playback_state == crate::api::BridgePlaybackState::Paused
    }

    /// True when no connected display can present: either a global reason, or
    /// every connected display suspended on its own.
    fn every_display_paused(&self) -> bool {
        if self.playback_paused() {
            return true;
        }
        if self.state.suspended_displays.is_empty() {
            return false;
        }
        let displays = self.engine.display_snapshot();
        !displays.is_empty()
            && displays.iter().all(|entry| {
                self.state
                    .suspended_displays
                    .contains(&entry.desc.display_id)
            })
    }

    fn refresh_mouse_polling_policy(&self) {
        self.mouse_polling
            .set_policy_enabled(!self.every_display_paused());
    }
}

impl<E: EngineFacade + Clone> BridgeActor<E> {
    fn app_snapshot(&self) -> BridgeAppSnapshot {
        BridgeAppSnapshot {
            playback_state: self.state.playback_state,
            selected_wallpaper_id: self.state.selected_wallpaper_id.clone(),
            active_wallpaper_ids: self.state.active_wallpaper_ids.clone(),
            errors: self.state.errors.clone(),
        }
    }

    fn library_snapshot(&self) -> BridgeLibrarySnapshot {
        let selected_wallpaper_id = self.state.selected_wallpaper_id.as_deref();
        let active_wallpaper_ids = self.state.active_wallpaper_ids.clone();
        let all_wallpapers = self
            .state
            .library
            .iter()
            .map(|entry| {
                let mut entry = entry.clone();
                entry.selected = selected_wallpaper_id == Some(entry.id.as_str());
                entry.active = active_wallpaper_ids.iter().any(|id| id == &entry.id);
                entry
            })
            .collect::<Vec<_>>();
        let wallpapers = all_wallpapers
            .iter()
            .filter(|entry| self.state.filter_enabled(entry.kind))
            .cloned()
            .collect::<Vec<_>>();

        BridgeLibrarySnapshot {
            scene_count: all_wallpapers
                .iter()
                .filter(|entry| entry.kind == BridgeWallpaperKind::ProjectScene)
                .count() as u64,
            video_count: all_wallpapers
                .iter()
                .filter(|entry| entry.kind == BridgeWallpaperKind::Video)
                .count() as u64,
            webpage_count: all_wallpapers
                .iter()
                .filter(|entry| entry.kind == BridgeWallpaperKind::Webpage)
                .count() as u64,
            unknown_count: all_wallpapers
                .iter()
                .filter(|entry| entry.kind == BridgeWallpaperKind::Unknown)
                .count() as u64,
            wallpapers,
            scan_status: BridgeLibraryScanStatus {
                scanning: false,
                done: 0,
                total: 0,
            },
        }
    }

    fn all_snapshots(&self) -> BridgeSnapshotBundle {
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        BridgeSnapshotBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            wallpaper_options: self
                .state
                .selected_wallpaper_id
                .as_ref()
                .and_then(|id| self.state.options(&displays, id.clone()).ok()),
            monitor_information: self.state.monitor_info(&displays),
            settings: self.state.settings(&displays, launch_at_login, &self.paths, self.engine.video_pipeline_state()),
        }
    }

    fn snapshots_with_options(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        Ok(BridgeSnapshotBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            wallpaper_options: Some(self.state.options(&displays, wallpaper_id)?),
            monitor_information: self.state.monitor_info(&displays),
            settings: self.state.settings(&displays, launch_at_login, &self.paths, self.engine.video_pipeline_state()),
        })
    }

    fn wallpaper_bundle(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        Ok(BridgeWallpaperMutationBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            wallpaper_options: self.state.options(&displays, wallpaper_id)?,
            monitor_information: self.state.monitor_info(&displays),
            settings: self.state.settings(&displays, launch_at_login, &self.paths, self.engine.video_pipeline_state()),
        })
    }

    fn display_bundle(&self) -> BridgeDisplayMutationBundle {
        let displays = self.engine.display_snapshot();
        let launch_at_login = self.launch_at_login.status();
        BridgeDisplayMutationBundle {
            app: self.app_snapshot(),
            library: self.library_snapshot(),
            monitor_information: self.state.monitor_info(&displays),
            settings: self.state.settings(&displays, launch_at_login, &self.paths, self.engine.video_pipeline_state()),
        }
    }

    fn bump_generation(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.refresh_mouse_polling_policy();
    }

    fn reserve_reconcile(&mut self) -> u64 {
        self.bump_generation();
        self.latest_reconcile_generation = self.generation;
        self.repair_after_reconcile_generation = None;
        self.generation
    }

    fn finish_reconcile(&mut self, generation: u64, actor: ActorRef<BridgeActor<E>>) {
        self.reconciled_generation = generation;
        self.refresh_mouse_polling_policy();
        if self.active_restore_generation == Some(generation) {
            self.active_restore_generation = None;
            if self.restore_requested_after_active {
                self.restore_requested_after_active = false;
                self.spawn_restore(actor);
                return;
            }
        }
        if self.repair_after_reconcile_generation == Some(generation) {
            self.spawn_restore(actor);
        }
    }

    fn reconcile_current(&self, generation: u64) -> bool {
        generation == self.generation && generation == self.latest_reconcile_generation
    }

    fn stale_reconcile(&mut self, generation: u64, actor: ActorRef<BridgeActor<E>>) {
        self.refresh_mouse_polling_policy();
        if self.active_restore_generation == Some(generation) {
            self.active_restore_generation = None;
            if self.restore_requested_after_active {
                self.restore_requested_after_active = false;
                self.spawn_restore(actor);
                return;
            }
        }

        let latest_generation = self.latest_reconcile_generation;
        if latest_generation == 0 {
            return;
        }

        if generation == latest_generation || self.reconciled_generation == latest_generation {
            self.spawn_restore(actor);
        } else {
            self.repair_after_reconcile_generation = Some(latest_generation);
        }
    }

    #[allow(clippy::needless_pass_by_value)]
    fn reconcile_failure(
        &mut self,
        generation: u64,
        error: BridgeError,
        actor: ActorRef<BridgeActor<E>>,
    ) {
        self.refresh_mouse_polling_policy();
        self.state.errors.push(error.message().to_string());

        if self.reconcile_current(generation) {
            self.spawn_restore(actor);
            return;
        }

        if self.active_restore_generation.is_some() {
            self.restore_requested_after_active = true;
        } else {
            self.spawn_restore(actor);
        }
    }

    fn wallpaper_handles(&self, wallpaper_id: &str, include_mirrors: bool) -> Vec<SceneHandle> {
        let displays = self.engine.display_snapshot();
        let mut handles = Vec::new();
        let mut used_display_ids = Vec::new();

        for monitor in self.state.app_config.monitors.iter().filter(|monitor| {
            monitor.enabled
                && (monitor.wallpaper.as_deref() == Some(wallpaper_id)
                    || include_mirrors
                        && monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE)
                        && monitor
                            .mirror_target
                            .as_ref()
                            .is_some_and(|target| self.target_has_wallpaper(target, wallpaper_id)))
        }) {
            let Some(snapshot) = monitor.selector.to_selector().resolve_display(&displays) else {
                continue;
            };
            let Some(handle) = snapshot.handle else {
                continue;
            };
            if used_display_ids.contains(&snapshot.desc.display_id) {
                continue;
            }

            handles.push(handle);
            used_display_ids.push(snapshot.desc.display_id);
        }

        handles
    }

    fn target_has_wallpaper(&self, selector: &SerializedSelector, wallpaper_id: &str) -> bool {
        self.state.app_config.monitors.iter().any(|monitor| {
            monitor.enabled
                && monitor.wallpaper.as_deref() == Some(wallpaper_id)
                && monitor.selector == *selector
        })
    }

    async fn set_playback(
        &mut self,
        playback_state: BridgePlaybackState,
        origin: PlaybackChangeOrigin,
    ) -> Result<(), BridgeError> {
        let previous = self.state.playback_state;
        let previous_paused = self.playback_paused();
        self.state.playback_state = playback_state;
        if let Err(error) = self.apply_engine_pause(previous_paused).await {
            self.state.playback_state = previous;
            return Err(error);
        }
        match origin {
            PlaybackChangeOrigin::Manual => {
                if playback_state == BridgePlaybackState::Playing
                    && self.state.power_source == crate::power::PowerSource::Battery
                {
                    self.state.auto_paused_for_battery = false;
                    self.state.battery_pause_suppressed = true;
                } else if playback_state == BridgePlaybackState::Paused {
                    self.state.auto_paused_for_battery = false;
                }
            }
            PlaybackChangeOrigin::Power => {}
        }
        self.bump_generation();
        Ok(())
    }


    /// Every open scene handle, once each.
    #[allow(clippy::single_call_fn)]
    fn open_scene_handles(&self) -> Vec<SceneHandle> {
        let mut handles = Vec::new();
        for entry in self.engine.display_snapshot() {
            let Some(handle) = entry.handle else {
                continue;
            };
            if !handles.contains(&handle) {
                handles.push(handle);
            }
        }
        handles
    }

    /// Pushes the render scale that is in force to every open scene.
    ///
    /// Set as a live renderer property, one open scene at a time. Going
    /// through a reconcile instead would reparse every project and reopen
    /// every video for what is a quality control the user drags.
    async fn apply_effective_render_scale(&self) -> Result<(), BridgeError> {
        let scale = self.effective_render_scale();
        for handle in self.open_scene_handles() {
            self.engine
                .set_render_scale(handle, scale)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        Ok(())
    }

    fn effective_render_scale(&self) -> f32 {
        self.state
            .app_config
            .effective_render_scale(self.state.power_source == crate::power::PowerSource::Battery)
    }

    /// The frame-rate ceiling the active power profile imposes, if any.
    fn active_target_fps_cap(&self) -> Option<u32> {
        let quality = &self.state.app_config.quality;
        (quality.battery_profile_enabled
            && self.state.power_source == crate::power::PowerSource::Battery)
            .then(|| quality.battery.target_fps.max(1))
    }

    fn quality_runtime(&self) -> QualityRuntime {
        QualityRuntime {
            render_scale: self.effective_render_scale(),
            target_fps_cap: self.active_target_fps_cap(),
        }
    }

    /// Puts the quality settings the current power source calls for into
    /// effect on everything already running.
    ///
    /// Restoring hands back the user's own saved per-display target rate, read
    /// from the live configuration rather than from a remembered constant.
    /// It never touches playback, so a pause the user asked for survives.
    async fn apply_quality_profile(&self) -> Result<(), BridgeError> {
        self.apply_effective_render_scale().await?;
        let cap = self.active_target_fps_cap();
        let displays = self.engine.display_snapshot();
        let rates = self
            .activation_inputs(&displays, self.playback_paused())
            .target_frame_rates();
        for entry in &displays {
            let Some(handle) = entry.handle else {
                continue;
            };
            let Some(configured) = rates.get(&entry.desc.display_id).copied() else {
                continue;
            };
            let fps = cap.map_or(configured, |cap| configured.min(cap)).max(1);
            self.engine
                .set_fps(handle, fps)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        Ok(())
    }

    async fn apply_power_policy(&mut self) -> Result<(), BridgeError> {
        // The quality profile and the pause policy are independent opt-ins: a
        // user who enabled only the quality profile must still have it applied
        // when the power source changes. With the profile off this touches
        // nothing, so a power transition cannot restate a rate or a scale on a
        // user who never asked for the feature.
        if self.state.app_config.quality.battery_profile_enabled {
            self.apply_quality_profile().await?;
        }
        if !self.state.app_config.power.pause_on_battery_power {
            self.state.auto_paused_for_battery = false;
            self.state.battery_pause_suppressed = false;
            self.state.pending_battery_pause_after_initial_frame = false;
            return Ok(());
        }

        match self.state.power_source {
            crate::power::PowerSource::Battery => {
                if self.state.playback_state == BridgePlaybackState::Playing
                    && !self.state.battery_pause_suppressed
                {
                    if self.state.pending_battery_pause_after_initial_frame {
                        return Ok(());
                    }
                    log::info!("pausing wallpaper playback on battery power");
                    self.set_playback(BridgePlaybackState::Paused, PlaybackChangeOrigin::Power)
                        .await?;
                    self.state.auto_paused_for_battery = true;
                }
            }
            crate::power::PowerSource::External => {
                self.state.battery_pause_suppressed = false;
                self.state.pending_battery_pause_after_initial_frame = false;
                if self.state.auto_paused_for_battery {
                    log::info!("resuming wallpaper playback on external power");
                    self.set_playback(BridgePlaybackState::Playing, PlaybackChangeOrigin::Power)
                        .await?;
                    self.state.auto_paused_for_battery = false;
                }
            }
            crate::power::PowerSource::Unknown => {}
        }
        Ok(())
    }

    fn display_handle(
        &self,
        wallpaper_id: &str,
        selector: &SerializedSelector,
    ) -> Option<SceneHandle> {
        let displays = self.engine.display_snapshot();

        self.state
            .app_config
            .monitors
            .iter()
            .find(|monitor| {
                monitor.enabled
                    && monitor.wallpaper.as_deref() == Some(wallpaper_id)
                    && &monitor.selector == selector
            })
            .and_then(|monitor| monitor.selector.to_selector().resolve_display(&displays))
            .and_then(|snapshot| snapshot.handle)
    }

    fn mirror_display_handle(
        &self,
        selector: &SerializedSelector,
        displays: &[DisplaySnapshotEntry],
    ) -> Option<SceneHandle> {
        self.state
            .app_config
            .monitors
            .iter()
            .find(|monitor| {
                monitor.enabled
                    && monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE)
                    && &monitor.selector == selector
            })
            .and_then(|monitor| monitor.selector.to_selector().resolve_display(displays))
            .and_then(|snapshot| snapshot.handle)
    }

    fn commit_app_config(&mut self, app_config: AppConfig) -> Result<(), BridgeError> {
        if let Some(store) = &self.config_store {
            store.save_app_config(&app_config)?;
        }
        self.state.app_config = app_config;
        Ok(())
    }

    fn save_wallpaper(
        &mut self,
        wallpaper_id: String,
        config: WallpaperConfig,
    ) -> Result<(), BridgeError> {
        if let Some(store) = &self.config_store {
            store.save_wallpaper(&config)?;
        }
        self.state.wallpaper_configs.insert(wallpaper_id, config);
        Ok(())
    }

    fn refresh_library(&mut self) -> Result<(), BridgeError> {
        let workshop_root = BridgePaths::new().steam_workshop_root();
        let entries = scan(&workshop_root)?;
        let project_models = entries
            .iter()
            .filter_map(|entry| {
                let project_json = workshop_root.join(&entry.workshop_id).join("project.json");
                ProjectModel::load(&entry.workshop_id, project_json)
                    .ok()
                    .map(|model| (entry.workshop_id.clone(), model))
            })
            .collect();
        self.state.replace_library(
            entries
                .iter()
                .map(crate::api::BridgeWallpaperEntry::from)
                .collect(),
        );
        self.state.project_models = project_models;
        Ok(())
    }

    fn load_wallpapers(&mut self) -> Result<(), BridgeError> {
        let Some(store) = &self.config_store else {
            return Ok(());
        };
        let missing_ids = self
            .state
            .configured_ids()
            .iter()
            .filter(|id| !self.state.wallpaper_configs.contains_key(*id))
            .cloned()
            .collect::<Vec<_>>();
        let loaded = missing_ids
            .iter()
            .map(|id| store.load_wallpaper(id).map(|config| (id.clone(), config)))
            .collect::<Result<Vec<_>, _>>()?;

        for (id, config) in loaded {
            self.state.wallpaper_configs.insert(id, config);
        }
        Ok(())
    }

    async fn refresh_displays(&mut self) -> Result<(), BridgeError> {
        self.engine
            .refresh_displays()
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.refresh_mouse_polling_policy();
        self.sync_displays()
    }

    fn sync_displays(&mut self) -> Result<(), BridgeError> {
        let displays = self.engine.display_snapshot();
        let mut next = self.state.app_config.clone();
        if !next.sync_known_monitors(&displays) {
            return Ok(());
        }

        if let Some(store) = &self.config_store {
            store.save_app_config(&next)?;
        }
        self.state.app_config = next;
        self.state.rebase_drafts();
        Ok(())
    }

    async fn reconcile_configured(&mut self) -> Result<(), BridgeError> {
        self.load_wallpapers()?;
        let has_configured_wallpapers = !self.state.configured_ids().is_empty();
        let displays = self.engine.display_snapshot();
        if !has_configured_wallpapers || displays.is_empty() {
            self.refresh_mouse_polling_policy();
            return Ok(());
        }
        if let Some(scenes) = self.unchanged_configured_scenes(&displays)? {
            self.state.set_active_ids_from_scenes(&scenes);
            self.refresh_mouse_polling_policy();
            return Ok(());
        }

        let app_config = self.state.app_config.clone();
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let result = self
            .reconcile_engine(app_config.clone(), wallpaper_configs)
            .await;
        self.refresh_mouse_polling_policy();
        let scenes = result?;
        self.state.set_active_ids_from_scenes(&scenes);
        Ok(())
    }

    fn activation_inputs<'a>(
        &'a self,
        displays: &'a [DisplaySnapshotEntry],
        paused: bool,
    ) -> ActivationInputs<'a> {
        ActivationInputs {
            app_config: &self.state.app_config,
            wallpapers: &self.state.wallpaper_configs,
            displays,
            paused,
            suspended_displays: &self.state.suspended_displays,
            paths: &self.paths,
            force_shader_refresh: false,
            project_models: &self.state.project_models,
            native_video_enabled: self.state.app_config.video_backend == VideoBackendModeCfg::NativePreferred,
            native_video_rejected: &self.state.native_video_rejected,
        }
    }

    /// Every admission key the live configuration currently produces, per
    /// wallpaper id. Recorded refusals are ignored, so a repeat refusal for a
    /// configuration that is already excluded still reads as current.
    fn native_video_admission_keys(&self) -> BTreeMap<String, BTreeSet<u64>> {
        let displays = self.engine.display_snapshot();
        self.activation_inputs(&displays, self.playback_paused())
            .native_video_admission_keys()
    }

    /// Drops refusals whose configuration is gone, reporting whether any went.
    ///
    /// [`ActivationInputs`] already ignores a record whose key matches no live
    /// slot, so dropping it does not by itself change routing; what the return
    /// value buys is knowing that routing just changed, because a slot that
    /// was excluded is offered natively again and the scene engine has to let
    /// go of it. Without this the map would also keep dead records for the
    /// rest of the session.
    ///
    /// A wallpaper's records are checked against *all* of its live keys, one
    /// per display slot: the same clip on two displays at different target
    /// rates has two keys, and a record matching either of them is alive.
    /// A wallpaper with no live key at all — unassigned, or with missing media
    /// — is left alone, because nothing has been shown to have changed.
    fn prune_stale_native_video_rejections(&mut self) -> bool {
        if self.state.native_video_rejected.is_empty() {
            return false;
        }
        let live_keys = self.native_video_admission_keys();
        let mut pruned = false;
        self.state.native_video_rejected.retain(|wallpaper_id, by_key| {
            let Some(live) = live_keys.get(wallpaper_id) else {
                return true;
            };
            by_key.retain(|admission_key, record| {
                if live.contains(admission_key) {
                    return true;
                }
                pruned = true;
                log::info!(
                    "native video wallpaper {wallpaper_id} refusal for admission key \
                     {admission_key} no longer applies and is dropped (was: {})",
                    record.reason
                );
                false
            });
            !by_key.is_empty()
        });
        pruned
    }

    /// Committed web wallpapers for connected displays, rendered by the host.
    /// Committed plain-video wallpapers routed to the native player.
    ///
    /// Empty whenever the backend is off, so the host creates nothing and the
    /// scene engine keeps every wallpaper.
    fn native_video_wallpapers(&self) -> Result<Vec<BridgeNativeVideoWallpaper>, BridgeError> {
        let displays = self.engine.display_snapshot();
        self.activation_inputs(&displays, self.playback_paused())
            .build_native_video()?
            .into_iter()
            .map(|desc| {
                let title = self
                    .state
                    .library
                    .iter()
                    .find(|entry| entry.id == desc.wallpaper_id)
                    .map(|entry| entry.title.clone())
                    .unwrap_or_default();
                let media_path = desc
                    .media_path
                    .into_os_string()
                    .into_string()
                    .map_err(|_| {
                        BridgeError::invalid_input("video wallpaper path is not UTF-8")
                    })?;
                Ok(BridgeNativeVideoWallpaper {
                    display_id: desc.display.display_id,
                    wallpaper_id: desc.wallpaper_id,
                    title,
                    media_path,
                    fps: desc.fps,
                    admission_fps: desc.admission_fps,
                    admission_key: desc.admission_key,
                    paused: desc.paused,
                    volume: desc.volume,
                    muted: desc.muted,
                    scaling_mode: BridgeScalingMode::from(desc.scaling_mode),
                    scaling_factor: desc.scaling_factor,
                })
            })
            .collect()
    }

    fn web_wallpapers(&self) -> Result<Vec<BridgeWebWallpaper>, BridgeError> {
        let displays = self.engine.display_snapshot();
        self.activation_inputs(&displays, self.playback_paused())
            .build_web()?
            .into_iter()
            .map(|desc| {
                let title = self
                    .state
                    .library
                    .iter()
                    .find(|entry| entry.id == desc.wallpaper_id)
                    .map(|entry| entry.title.clone())
                    .unwrap_or_default();
                let project_path = std::path::absolute(&desc.project_dir)
                    .map_err(|error| BridgeError::Error {
                        kind: crate::api::BridgeErrorKind::Io,
                        message: error.to_string(),
                    })?
                    .into_os_string()
                    .into_string()
                    .map_err(|_| BridgeError::invalid_input("web wallpaper path is not UTF-8"))?;
                let model = self.state.project_models.get(&desc.wallpaper_id);
                let properties = desc
                    .properties
                    .iter()
                    .map(|(id, value)| {
                        let mut entry = serde_json::Map::new();
                        let _ = entry.insert("value".to_string(), value.to_json());
                        if let Some(property) = model.and_then(|model| {
                            model.properties.iter().find(|property| property.id == *id)
                        }) {
                            describe_property_kind(property, &mut entry);
                        }
                        (id.clone(), serde_json::Value::Object(entry))
                    })
                    .collect::<serde_json::Map<_, _>>();
                let media_integration_enabled = self
                    .state
                    .wallpaper_configs
                    .get(&desc.wallpaper_id)
                    .is_some_and(|config| config.media_integration_enabled);
                Ok(BridgeWebWallpaper {
                    display_id: desc.display.display_id,
                    wallpaper_id: desc.wallpaper_id,
                    title,
                    project_path,
                    entry_file: desc.entry_file,
                    fps: desc.fps,
                    paused: desc.paused,
                    audio_response_enabled: desc.audio_response_enabled,
                    media_integration_enabled,
                    properties_json: serde_json::Value::Object(properties).to_string(),
                })
            })
            .collect()
    }

    fn lock_screen_scenes(&self) -> Result<Vec<BridgeLockScreenScene>, BridgeError> {
        let displays = self.engine.display_snapshot();
        let scenes = self.activation_inputs(&displays, self.state.playback_state == BridgePlaybackState::Paused).build()?;

        scenes
            .into_iter()
            .map(|mut scene| {
                let wallpaper_id = std::path::Path::new(&scene.scene_path)
                    .parent()
                    .and_then(std::path::Path::file_name)
                    .and_then(std::ffi::OsStr::to_str)
                    .ok_or_else(|| {
                        BridgeError::engine(format!(
                            "cannot identify lock-screen wallpaper from {}",
                            scene.scene_path
                        ))
                    })?;
                let title = self
                    .state
                    .library
                    .iter()
                    .find(|entry| entry.id == wallpaper_id)
                    .ok_or_else(|| BridgeError::Error {
                        kind: crate::api::BridgeErrorKind::Library,
                        message: format!(
                            "lock-screen wallpaper {wallpaper_id} is not in the library"
                        ),
                    })?
                    .title
                    .clone();
                for path in [&mut scene.scene_path, &mut scene.assets_path] {
                    if !std::path::Path::new(path.as_str()).is_absolute() {
                        *path = std::path::absolute(&*path)
                            .map_err(|error| BridgeError::Error {
                                kind: crate::api::BridgeErrorKind::Io,
                                message: error.to_string(),
                            })?
                            .into_os_string()
                            .into_string()
                            .map_err(|_| {
                                BridgeError::invalid_input("lock-screen source path is not UTF-8")
                            })?;
                    }
                }
                let properties_json = scene
                    .property_override_json
                    .as_deref()
                    .map(|json| {
                        let flat = serde_json::from_str::<serde_json::Value>(json)
                            .map_err(|error| BridgeError::engine(error.to_string()))?
                            .flatten()
                            .map_err(|error| BridgeError::engine(error.to_string()))?;
                        serde_json::to_string(&flat)
                            .map_err(|error| BridgeError::engine(error.to_string()))
                    })
                    .transpose()?;
                Ok(BridgeLockScreenScene {
                    display_id: scene.display.display_id,
                    title,
                    project_path: scene.scene_path,
                    assets_path: scene.assets_path,
                    fps: scene.fps,
                    scaling_mode: scene.scaling_mode.into(),
                    scaling_factor: scene.scaling_factor,
                    properties_json,
                    paused: scene.paused,
                })
            })
            .collect()
    }

    fn unchanged_configured_scenes(
        &self,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<Option<Vec<SceneDesc>>, BridgeError> {
        let scenes = self.activation_inputs(displays, self.playback_paused()).build()?;
        let snapshot = self.engine.display_snapshot();
        let has_direct_runtime = |entry: &&DisplaySnapshotEntry| {
            entry.handle.is_some()
                && matches!(entry.assignment, Some(WallpaperAssignment::Direct(_)))
        };

        if scenes.len() != snapshot.iter().filter(has_direct_runtime).count() {
            return Ok(None);
        }

        if scenes.iter().all(|scene| {
            snapshot.iter().any(|entry| {
                entry.handle.is_some()
                    && entry
                        .assignment
                        .as_ref()
                        .is_some_and(|assignment| match assignment {
                            WallpaperAssignment::Direct(template) => {
                                template.for_display(scene.display.clone()) == *scene
                            }
                            WallpaperAssignment::Mirror(_) => false,
                        })
            })
        }) {
            Ok(Some(scenes))
        } else {
            Ok(None)
        }
    }

    fn save_configs(
        &self,
        app_config: &AppConfig,
        wallpaper_config: &WallpaperConfig,
    ) -> Result<(), BridgeError> {
        if let Some(store) = &self.config_store {
            store.save_app_config(app_config)?;
            store.save_wallpaper(wallpaper_config)?;
        }
        Ok(())
    }

    /// System audio capture only needs to run while something that is actually
    /// presenting consumes it. Volume and mute are separate controls: silencing
    /// a wallpaper does not switch off its audio response, and an
    /// audio-response wallpaper on a hidden display is not a consumer.
    ///
    /// Both kinds of consumer count. A scene consumes through its renderer
    /// handle. A web page has no handle at all and consumes only once it has
    /// registered an audio listener, so leaving it out would keep the tap shut
    /// on a display showing nothing but web wallpapers.
    fn audio_capture_suspended(&self) -> bool {
        let displays = self.engine.display_snapshot();
        let inputs = self.activation_inputs(&displays, self.playback_paused());
        let Ok(scenes) = inputs.build() else {
            // Without a resolvable scene list, fall back to the coarse global
            // condition rather than guessing that nothing consumes audio.
            return self.playback_paused();
        };

        !scenes
            .iter()
            .any(|scene| scene.audio_response_enabled && !scene.paused)
            && web_audio_consumers(&inputs, &self.state.web_audio_subscribers) == 0
    }

    /// Wallpapers that both enable audio response and are not paused for their
    /// own display, counting subscribed web pages alongside scenes. This is the
    /// same rule the capture tap follows, reported as a number so a diagnostic
    /// session can see why the tap is open or closed.
    fn audio_consumer_count(&self) -> u32 {
        let displays = self.engine.display_snapshot();
        let inputs = self.activation_inputs(&displays, self.playback_paused());
        let Ok(scenes) = inputs.build() else {
            return 0;
        };
        let scene_consumers = scenes
            .iter()
            .filter(|scene| scene.audio_response_enabled && !scene.paused)
            .count();

        u32::try_from(scene_consumers)
            .unwrap_or(u32::MAX)
            .saturating_add(web_audio_consumers(&inputs, &self.state.web_audio_subscribers))
    }

    async fn apply_engine_pause(&self, previous_paused: bool) -> Result<(), BridgeError> {
        let paused = self.playback_paused();
        let audio_suspended = self.audio_capture_suspended();
        let result = async {
            self.engine.set_all_paused(paused).await?;
            // A global resume must not restart a display that is still hidden
            // on its own, so per-display suspension is re-applied on top.
            for display_id in &self.state.suspended_displays {
                self.engine.set_display_paused(*display_id, true).await?;
            }
            self.engine.set_audio_capture_suspended(audio_suspended).await
        }
        .await;
        if let Err(error) = result {
            let mut message = error.to_string();
            // Either operation may have changed live state before failing.
            // Restore both sides before the caller rolls back its actor state.
            if let Err(rollback) = self.engine.set_all_paused(previous_paused).await {
                message.push_str(&format!("; renderer pause rollback failed: {rollback}"));
            }
            if let Err(rollback) = self
                .engine
                .set_audio_capture_suspended(previous_paused)
                .await
            {
                message.push_str(&format!("; audio capture rollback failed: {rollback}"));
            }
            return Err(BridgeError::engine(message));
        }
        self.refresh_mouse_polling_policy();
        Ok(())
    }

    fn spawn_restore(&mut self, actor: ActorRef<BridgeActor<E>>) {
        if self.active_restore_generation.is_some() {
            self.restore_requested_after_active = true;
            return;
        }
        let generation = self.reserve_reconcile();
        self.active_restore_generation = Some(generation);
        let engine = self.engine.clone();
        let app_config = self.state.app_config.clone();
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let project_models = self.state.configured_project_models(&app_config);
        let paused = self.playback_paused();
        let suspended_displays = self.state.suspended_displays.clone();
        let native_video_rejected_snapshot = self.state.native_video_rejected.clone();
        let quality = self.quality_runtime();
        let paths = self.paths.clone();
        tokio::spawn(async move {
            let result = reconcile_with(
                engine,
                app_config,
                wallpaper_configs,
                project_models,
                paused,
                suspended_displays,
                paths,
                false,
                native_video_rejected_snapshot,
                quality,
            )
            .await;
            let _ = actor
                .ask(CompleteRestoreAfterReconcile { result, generation })
                .await;
        });
    }

    #[allow(clippy::needless_pass_by_value)]
    fn commit_display_settings(
        &mut self,
        app_config: AppConfig,
        display_settings: BTreeMap<String, BridgeDisplaySettingsRow>,
        scenes: Vec<SceneDesc>,
    ) -> Result<(), BridgeError> {
        self.refresh_mouse_polling_policy();
        if let Some(store) = &self.config_store {
            store.save_app_config(&app_config)?;
        }
        self.state.app_config = app_config;
        self.state.display_settings = display_settings;
        self.state.set_active_ids_from_scenes(&scenes);
        self.state.rebase_drafts();
        self.refresh_mouse_polling_policy();
        Ok(())
    }

    async fn reconcile_engine(
        &self,
        app_config: AppConfig,
        wallpaper_configs: BTreeMap<String, WallpaperConfig>,
    ) -> Result<Vec<SceneDesc>, BridgeError> {
        let project_models = self.state.configured_project_models(&app_config);
        reconcile_with(
            self.engine.clone(),
            app_config,
            wallpaper_configs,
            project_models,
            self.playback_paused(),
            self.state.suspended_displays.clone(),
            self.paths.clone(),
            false,
            self.state.native_video_rejected.clone(),
            self.quality_runtime(),
        )
        .await
    }

    fn delegate_display(
        &mut self,
        app_config: AppConfig,
        display_settings: BTreeMap<String, BridgeDisplaySettingsRow>,
        ctx: &mut Context<Self, DelegatedReply<messages::DisplayMutationReply>>,
    ) -> DelegatedReply<messages::DisplayMutationReply> {
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let project_models = self.state.configured_project_models(&app_config);
        let generation = self.reserve_reconcile();
        let paused = self.playback_paused();
        let suspended_displays = self.state.suspended_displays.clone();
        let actor = ctx.actor_ref().clone();
        let engine = self.engine.clone();
        let native_video_rejected_snapshot = self.state.native_video_rejected.clone();
        let quality = self.quality_runtime();
        let paths = self.paths.clone();
        ctx.spawn(async move {
            let scenes = match reconcile_with(
                engine,
                app_config.clone(),
                wallpaper_configs.clone(),
                project_models,
                paused,
                suspended_displays,
                paths,
                false,
                native_video_rejected_snapshot,
                quality,
            )
            .await
            {
                Ok(scenes) => scenes,
                Err(error) => {
                    let _ = actor
                        .ask(ReconcileFailed {
                            error: duplicate_error(&error),
                            generation,
                        })
                        .await;
                    return Err(error);
                }
            };
            actor
                .ask(CommitDisplayAfterReconcile {
                    app_config,
                    wallpaper_configs,
                    display_settings,
                    scenes,
                    generation,
                })
                .await
                .map_err(map_send_error)
        })
    }

    fn selector_for(
        &self,
        display_id: &str,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<SerializedSelector, BridgeError> {
        if display_id == PRIMARY_DISPLAY_ID {
            if displays.is_empty() && !self.state.display_settings.contains_key(display_id) {
                return Err(BridgeError::invalid_input(format!(
                    "unknown display id {display_id}"
                )));
            }
            return Ok(SerializedSelector::Primary);
        }

        if let Some(encoded) = display_id.strip_prefix(IDENTITY_DISPLAY_ID_PREFIX) {
            let identity = serde_json::from_str::<DisplayIdentity>(encoded).map_err(|error| {
                BridgeError::invalid_input(format!("invalid display identity selector: {error}"))
            })?;
            let selector = SerializedSelector::from_selector(&DisplaySelector::Identity(identity));
            if displays.is_empty()
                || displays
                    .iter()
                    .any(|display| selector.to_selector().matches_display(display))
            {
                return Ok(selector);
            }
            return Err(BridgeError::invalid_input(format!(
                "unknown display id {display_id}"
            )));
        }

        if displays.is_empty() {
            return if self.state.display_settings.contains_key(display_id) {
                Ok(SerializedSelector::LiveDisplayId {
                    display_id: Self::parse_display_id(display_id)?,
                })
            } else {
                Err(BridgeError::invalid_input(format!(
                    "unknown display id {display_id}"
                )))
            };
        }

        let display_id_u32 = Self::parse_display_id(display_id)?;
        let display = displays
            .iter()
            .find(|display| display.desc.display_id == display_id_u32)
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown display id {display_id}"))
            })?;
        if displays
            .first()
            .is_some_and(|primary| display.matches_primary(primary))
        {
            return Ok(SerializedSelector::Primary);
        }

        Ok(display.connected_selector())
    }

    fn normalized_config(&self, displays: &[DisplaySnapshotEntry]) -> AppConfig {
        self.state.app_config.normalized(displays)
    }

    fn display_rows(
        &self,
        app_config: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> BTreeMap<String, BridgeDisplaySettingsRow> {
        if displays.is_empty() {
            return self
                .state
                .display_settings
                .iter()
                .map(|(display_id, row)| {
                    let mut row = row.clone();
                    if let Some(monitor) = display_id.parse::<u32>().ok().and_then(|display_id| {
                        app_config.monitors.iter().find(|monitor| {
                            monitor.selector == SerializedSelector::LiveDisplayId { display_id }
                        })
                    }) {
                        row.enabled = monitor.enabled;
                        row.mode = if monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE) {
                            BridgeDisplayMode::Mirror
                        } else {
                            BridgeDisplayMode::Standalone
                        };
                        row.selected_mirror_target =
                            monitor
                                .mirror_target
                                .as_ref()
                                .map(|selector| match selector {
                                    SerializedSelector::LiveDisplayId { display_id } => {
                                        display_id.to_string()
                                    }
                                    SerializedSelector::Primary => PRIMARY_DISPLAY_ID.to_string(),
                                    SerializedSelector::Identity { .. } => {
                                        let DisplaySelector::Identity(identity) =
                                            selector.to_selector()
                                        else {
                                            unreachable!(
                                                "identity selector must convert to identity"
                                            )
                                        };
                                        format!(
                                            "{IDENTITY_DISPLAY_ID_PREFIX}{}",
                                            serde_json::to_string(&identity).expect(
                                                "display identity selector should serialize"
                                            )
                                        )
                                    }
                                });
                    } else if display_id == PRIMARY_DISPLAY_ID {
                        row.enabled = true;
                        row.mode = BridgeDisplayMode::Standalone;
                        row.selected_mirror_target = None;
                    }
                    (display_id.clone(), row)
                })
                .collect();
        }

        let mut candidate_state = self.state.clone();
        candidate_state.app_config = app_config.clone();
        candidate_state
            .settings(displays, self.launch_at_login.status(), &self.paths, self.engine.video_pipeline_state())
            .displays
            .into_iter()
            .map(|row| (row.display_id.clone(), row))
            .collect()
    }

    fn validate_display_settings(
        app_config: &AppConfig,
        displays: &[DisplaySnapshotEntry],
        display_settings: &BTreeMap<String, BridgeDisplaySettingsRow>,
    ) -> Result<(), BridgeError> {
        let valid_ids = if displays.is_empty() {
            display_settings
                .keys()
                .filter_map(|display_id| display_id.parse::<u32>().ok())
                .collect::<Vec<_>>()
        } else {
            displays
                .iter()
                .map(|display| display.desc.display_id)
                .collect::<Vec<_>>()
        };

        for monitor in &app_config.monitors {
            let source_id = match &monitor.selector {
                SerializedSelector::Primary => valid_ids.first().copied(),
                SerializedSelector::LiveDisplayId { display_id } => {
                    valid_ids.contains(display_id).then_some(*display_id)
                }
                SerializedSelector::Identity { .. } => displays
                    .iter()
                    .find(|display| monitor.selector.to_selector().matches_display(display))
                    .map(|display| display.desc.display_id),
            };
            let Some(source_id) = source_id else {
                continue;
            };

            if monitor.mode != MIRROR_DISPLAY_MODE {
                continue;
            }

            let target = monitor.mirror_target.as_ref().ok_or_else(|| {
                BridgeError::invalid_input(format!(
                    "mirror mode for display {source_id} requires a target"
                ))
            })?;
            if Self::valid_target(target, source_id, displays, &valid_ids).is_none() {
                return Err(BridgeError::invalid_input(format!(
                    "unknown mirror target for display {source_id}"
                )));
            }
            app_config.validate_mirror_change(&monitor.selector, target)?;
        }

        Ok(())
    }

    fn valid_target(
        selector: &SerializedSelector,
        display_id: u32,
        displays: &[DisplaySnapshotEntry],
        valid_ids: &[u32],
    ) -> Option<u32> {
        match selector {
            SerializedSelector::LiveDisplayId {
                display_id: target_id,
            } => valid_ids
                .contains(target_id)
                .then_some(*target_id)
                .filter(|target_id| *target_id != display_id),
            SerializedSelector::Primary => displays
                .first()
                .map(|display| display.desc.display_id)
                .or_else(|| valid_ids.first().copied())
                .filter(|target_id| *target_id != display_id),
            SerializedSelector::Identity { .. } => displays
                .iter()
                .find(|display| {
                    display.desc.display_id != display_id
                        && selector.to_selector().matches_display(display)
                })
                .map(|display| display.desc.display_id),
        }
    }

    fn source_display_id(
        &self,
        selector: &SerializedSelector,
        displays: &[DisplaySnapshotEntry],
    ) -> Result<u32, BridgeError> {
        match selector {
            SerializedSelector::Primary => displays
                .first()
                .map(|display| display.desc.display_id)
                .or_else(|| {
                    self.state
                        .display_settings
                        .get(PRIMARY_DISPLAY_ID)
                        .and_then(|row| {
                            row.title
                                .rsplit_once(" - Primary)")?
                                .0
                                .rsplit_once('(')?
                                .1
                                .parse()
                                .ok()
                        })
                })
                .ok_or_else(|| BridgeError::invalid_input("unknown display id primary")),
            SerializedSelector::LiveDisplayId { display_id } => Ok(*display_id),
            SerializedSelector::Identity { .. } => displays
                .iter()
                .find(|display| selector.to_selector().matches_display(display))
                .map(|display| display.desc.display_id)
                .ok_or_else(|| BridgeError::invalid_input("unknown display identity")),
        }
    }

    fn parse_display_id(display_id: &str) -> Result<u32, BridgeError> {
        display_id
            .parse::<u32>()
            .map_err(|_| BridgeError::invalid_input(format!("invalid display id {display_id}")))
    }

    fn monitor_settings_mut(
        app_config: &mut AppConfig,
        selector: SerializedSelector,
    ) -> &mut crate::config::MonitorSettingsCfg {
        if let Some(index) = app_config
            .monitor_settings
            .iter()
            .position(|settings| settings.selector == selector)
        {
            return &mut app_config.monitor_settings[index];
        }

        app_config
            .monitor_settings
            .push(crate::config::MonitorSettingsCfg {
                selector,
                ..crate::config::MonitorSettingsCfg::default()
            });
        app_config
            .monitor_settings
            .last_mut()
            .expect("settings entry was just inserted")
    }

    fn require_mirror_monitor<'a>(
        app_config: &'a AppConfig,
        selector: &SerializedSelector,
    ) -> Result<&'a crate::config::MonitorCfg, BridgeError> {
        let monitor = app_config
            .monitors
            .iter()
            .find(|monitor| &monitor.selector == selector)
            .ok_or_else(|| BridgeError::invalid_input("unknown mirror display"))?;
        if monitor.enabled && monitor.mode.eq_ignore_ascii_case(MIRROR_DISPLAY_MODE) {
            Ok(monitor)
        } else {
            Err(BridgeError::invalid_input(
                "display is not configured for mirror mode",
            ))
        }
    }
}

/// The quality settings a reconcile has to re-assert on the scenes it opens.
///
/// A freshly opened scene starts at its descriptor's rate and at native
/// rasterization size, so without this a wallpaper change would silently
/// discard the render scale and the active power profile.
#[derive(Clone, Copy, Debug)]
struct QualityRuntime {
    render_scale: f32,
    target_fps_cap: Option<u32>,
}

#[allow(clippy::too_many_arguments)]
async fn reconcile_with<E: EngineFacade>(
    engine: E,
    app_config: AppConfig,
    wallpaper_configs: BTreeMap<String, WallpaperConfig>,
    project_models: BTreeMap<String, ProjectModel>,
    paused: bool,
    suspended_displays: BTreeSet<u32>,
    paths: BridgePaths,
    force_shader_refresh: bool,
    native_video_rejected: NativeVideoRejections,
    quality: QualityRuntime,
) -> Result<Vec<SceneDesc>, BridgeError> {
    let displays = engine.display_snapshot();
    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpaper_configs,
        suspended_displays: &suspended_displays,
        displays: &displays,
        paused,
        paths: &paths,
        force_shader_refresh,
        project_models: &project_models,
        native_video_enabled: app_config.video_backend == VideoBackendModeCfg::NativePreferred,
        native_video_rejected: &native_video_rejected,
    }
    .build()?;
    let results = engine
        .reconcile_scenes(scenes.clone())
        .await
        .map_err(|error| BridgeError::engine(error.to_string()))?;

    // Sync audios
    let mut audio_handles = Vec::new();
    let mut used_display_ids = HashSet::new();
    for scene in &scenes {
        let Some(result) = results
            .iter()
            .find(|result| result.display_id == scene.display.display_id)
        else {
            continue;
        };

        if used_display_ids.contains(&result.display_id) {
            continue;
        }

        audio_handles.push((scene, result.handle));
        used_display_ids.insert(result.display_id);
    }
    for (scene, handle) in audio_handles {
        engine
            .set_audio_volume(handle, scene.audio_volume)
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        engine
            .set_audio_muted(handle, scene.audio_muted)
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        engine
            .set_audio_capture_enabled(handle, scene.audio_response_enabled)
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        // A newly opened scene already rasterizes at native size, so only a
        // reduced scale has anything to assert here.
        if quality.render_scale < crate::config::app::MAX_RENDER_SCALE {
            engine
                .set_render_scale(handle, quality.render_scale)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        if let Some(cap) = quality.target_fps_cap {
            let fps = scene.fps.min(cap).max(1);
            if fps != scene.fps {
                engine
                    .set_fps(handle, fps)
                    .await
                    .map_err(|error| BridgeError::engine(error.to_string()))?;
            }
        }
    }

    Ok(scenes)
}

impl<E: EngineFacade + Clone> Message<Bootstrap> for BridgeActor<E> {
    type Reply = messages::BootstrapReply;

    async fn handle(
        &mut self,
        _msg: Bootstrap,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.errors.clear();

        // Process-wide renderer switches live in C, not in the config file, so
        // a persisted opt-in only survives a restart if it is pushed back in
        // before anything opens.
        let experimental = self.state.app_config.experimental;
        if let Err(error) = self
            .engine
            .set_content_pacing_enabled(experimental.content_pacing)
        {
            self.state.errors.push(error.to_string());
        }
        if let Err(error) = self
            .engine
            .set_shared_video_decode_enabled(experimental.shared_video_decode)
        {
            self.state.errors.push(error.to_string());
        }
        if let Err(error) = self
            .engine
            .set_scene_optimization_enabled(self.state.app_config.quality.scene_optimization_enabled)
        {
            self.state.errors.push(error.to_string());
        }

        if let Err(error) = self.refresh_displays().await {
            self.state.errors.push(error.message().to_string());
        }
        if let Err(error) = self.refresh_library() {
            self.state.errors.push(error.message().to_string());
        }
        if let Err(error) = self.load_wallpapers() {
            self.state.errors.push(error.message().to_string());
        }
        if let Err(error) = self.reconcile_configured().await {
            self.state.errors.push(error.message().to_string());
        }

        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<GetAllSnapshots> for BridgeActor<E> {
    type Reply = messages::AllSnapshotsReply;

    async fn handle(
        &mut self,
        _msg: GetAllSnapshots,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<GetAppSnapshot> for BridgeActor<E> {
    type Reply = messages::AppSnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetAppSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.app_snapshot())
    }
}

impl<E: EngineFacade + Clone> Message<GetLibrarySnapshot> for BridgeActor<E> {
    type Reply = messages::LibrarySnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetLibrarySnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.library_snapshot())
    }
}

impl<E: EngineFacade + Clone> Message<GetLockScreenScenes> for BridgeActor<E> {
    type Reply = messages::LockScreenScenesReply;

    async fn handle(
        &mut self,
        _msg: GetLockScreenScenes,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.lock_screen_scenes()
    }
}

impl<E: EngineFacade + Clone> Message<GetWebWallpapers> for BridgeActor<E> {
    type Reply = messages::WebWallpapersReply;

    async fn handle(
        &mut self,
        _msg: GetWebWallpapers,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.web_wallpapers()
    }
}

impl<E: EngineFacade + Clone> Message<GetMonitorInformationSnapshot> for BridgeActor<E> {
    type Reply = messages::MonitorInformationSnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetMonitorInformationSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        Ok(self.state.monitor_info(&displays))
    }
}

impl<E: EngineFacade + Clone> Message<GetSettingsSnapshot> for BridgeActor<E> {
    type Reply = messages::SettingsSnapshotReply;

    async fn handle(
        &mut self,
        _msg: GetSettingsSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        Ok(self
            .state
            .settings(&displays, self.launch_at_login.status(), &self.paths, self.engine.video_pipeline_state()))
    }
}

impl<E: EngineFacade + Clone> Message<PollMousePosition> for BridgeActor<E> {
    type Reply = messages::PollMousePositionReply;

    async fn handle(
        &mut self,
        _msg: PollMousePosition,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.mouse_polling.is_enabled() {
            return Ok(());
        }
        self.engine
            .poll_mouse_position()
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))
    }
}

impl<E: EngineFacade + Clone> Message<ClearShaderCache> for BridgeActor<E> {
    type Reply = messages::ClearShaderCacheReply;

    async fn handle(
        &mut self,
        _msg: ClearShaderCache,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let cache_root = self.paths.shader_cache_root();
        match fs::remove_dir_all(&cache_root) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(BridgeError::Error {
                    kind: crate::api::BridgeErrorKind::Io,
                    message: format!("failed to clear shader cache: {error}"),
                });
            }
        }
        fs::create_dir_all(&cache_root).map_err(|error| BridgeError::Error {
            kind: crate::api::BridgeErrorKind::Io,
            message: format!("failed to recreate shader cache: {error}"),
        })?;

        self.load_wallpapers()?;
        let app_config = self.state.app_config.clone();
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let project_models = self.state.configured_project_models(&app_config);
        let result = reconcile_with(
            self.engine.clone(),
            app_config,
            wallpaper_configs,
            project_models,
            self.playback_paused(),
            self.state.suspended_displays.clone(),
            self.paths.clone(),
            true,
            self.state.native_video_rejected.clone(),
            self.quality_runtime(),
        )
        .await;
        self.refresh_mouse_polling_policy();
        let scenes = result?;
        self.state.set_active_ids_from_scenes(&scenes);
        self.bump_generation();

        let displays = self.engine.display_snapshot();
        Ok(self
            .state
            .settings(&displays, self.launch_at_login.status(), &self.paths, self.engine.video_pipeline_state()))
    }
}

impl<E: EngineFacade + Clone> Message<GetWallpaperOptionsSnapshot> for BridgeActor<E> {
    type Reply = messages::WallpaperOptionsSnapshotReply;

    async fn handle(
        &mut self,
        msg: GetWallpaperOptionsSnapshot,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        self.state.options(&displays, msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<InjectWallpaperForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectWallpaperForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.library.push(BridgeWallpaperEntry {
            id: msg.id,
            title: msg.title,
            kind: msg.kind,
            supported: matches!(
                msg.kind,
                BridgeWallpaperKind::ProjectScene
                    | BridgeWallpaperKind::Video
                    | BridgeWallpaperKind::Webpage
            ),
            active: false,
            selected: false,
            preview_path: None,
        });
        self.bump_generation();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<InjectSceneWallpaperConfigForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectSceneWallpaperConfigForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let config = WallpaperConfig::new_for(&msg.id, "scene");
        self.state.library.push(BridgeWallpaperEntry {
            id: msg.id.clone(),
            title: msg.title,
            kind: BridgeWallpaperKind::ProjectScene,
            supported: true,
            active: false,
            selected: false,
            preview_path: None,
        });
        self.state.wallpaper_drafts.insert(
            msg.id.clone(),
            WallpaperOptionsDraft::from_committed(config.clone()),
        );
        self.state.wallpaper_configs.insert(msg.id, config);
        self.bump_generation();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<InjectSceneProjectForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectSceneProjectForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let model = ProjectModel::parse(&msg.id, &msg.project_json)
            .map_err(|error| BridgeError::invalid_input(error.to_string()))?;
        let entry = BridgeWallpaperEntry {
            id: msg.id.clone(),
            title: if msg.title.is_empty() {
                model.title.clone()
            } else {
                msg.title
            },
            kind: BridgeWallpaperKind::from(model.project_type),
            supported: true,
            active: false,
            selected: false,
            preview_path: None,
        };
        let config = WallpaperConfig::new_for(&msg.id, "scene");
        self.state.library.push(entry);
        self.state.project_models.insert(msg.id.clone(), model);
        self.state.wallpaper_drafts.insert(
            msg.id.clone(),
            WallpaperOptionsDraft::from_committed(config.clone()),
        );
        self.state.wallpaper_configs.insert(msg.id, config);
        self.bump_generation();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<InjectDisplayForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: InjectDisplayForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let selector = SerializedSelector::LiveDisplayId {
            display_id: Self::parse_display_id(&msg.display_id)?,
        };
        self.state.app_config.ensure_monitor(selector);
        let mirror_targets = self
            .state
            .display_settings
            .keys()
            .filter(|target| target.as_str() != msg.display_id)
            .cloned()
            .collect();
        self.state.display_settings.insert(
            msg.display_id.clone(),
            BridgeDisplaySettingsRow {
                display_id: msg.display_id.clone(),
                title: msg.title,
                enabled: true,
                mode: BridgeDisplayMode::Standalone,
                mirror_targets,
                selected_mirror_target: None,
                scaling_mode: BridgeScalingMode::from(ScalingMode::default()),
                scaling_factor: 1.0,
                target_fps: 60,
                max_fps: 60,
                muted: false,
                volume: 1.0,
            },
        );
        let ids = self
            .state
            .display_settings
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for row in self.state.display_settings.values_mut() {
            row.mirror_targets = ids
                .iter()
                .filter(|target| target.as_str() != row.display_id)
                .cloned()
                .collect();
        }
        self.bump_generation();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<ReplaceLibraryForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: ReplaceLibraryForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.replace_library(msg.entries);
        self.bump_generation();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<ReplaceWallpaperConfigForTest> for BridgeActor<E> {
    type Reply = messages::TestMutationReply;

    async fn handle(
        &mut self,
        msg: ReplaceWallpaperConfigForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.wallpaper_drafts.insert(
            msg.id.clone(),
            WallpaperOptionsDraft::from_committed(msg.config.clone()),
        );
        self.state.wallpaper_configs.insert(msg.id, msg.config);
        self.bump_generation();
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SelectWallpaper> for BridgeActor<E> {
    type Reply = messages::SelectWallpaperReply;

    async fn handle(
        &mut self,
        msg: SelectWallpaper,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.ensure_wallpaper_exists(&msg.id)?;
        let should_load_wallpaper = !self.state.wallpaper_configs.contains_key(&msg.id)
            && !self.state.wallpaper_drafts.contains_key(&msg.id);
        let loaded_wallpaper = if should_load_wallpaper {
            self.config_store
                .as_ref()
                .map(|store| store.load_wallpaper(&msg.id))
                .transpose()?
        } else {
            None
        };

        if let Some(config) = loaded_wallpaper {
            self.state
                .wallpaper_configs
                .entry(msg.id.clone())
                .or_insert(config);
        }
        self.state.app_config.general.last_selected_wallpaper = Some(msg.id.clone());
        self.state.selected_wallpaper_id = Some(msg.id.clone());
        self.generation = self.generation.wrapping_add(1);
        self.snapshots_with_options(msg.id)
    }
}

impl<E: EngineFacade + Clone> Message<RefreshLibrary> for BridgeActor<E> {
    type Reply = messages::RefreshLibraryReply;

    async fn handle(
        &mut self,
        _msg: RefreshLibrary,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.refresh_library()?;
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<RefreshDisplays> for BridgeActor<E> {
    type Reply = messages::RefreshDisplaysReply;

    async fn handle(
        &mut self,
        _msg: RefreshDisplays,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.refresh_displays().await?;
        self.reconcile_configured().await?;
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetFilter> for BridgeActor<E> {
    type Reply = messages::SetFilterReply;

    async fn handle(
        &mut self,
        msg: SetFilter,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        match msg.kind {
            BridgeWallpaperKind::ProjectScene => self.state.filter_scene = msg.enabled,
            BridgeWallpaperKind::Video => self.state.filter_video = msg.enabled,
            BridgeWallpaperKind::Webpage => self.state.filter_webpage = msg.enabled,
            BridgeWallpaperKind::Unknown => self.state.filter_unknown = msg.enabled,
        }
        self.generation = self.generation.wrapping_add(1);
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayEnabled> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetDisplayEnabledReply>;

    async fn handle(
        &mut self,
        msg: SetDisplayEnabled,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        let mut app_config = self.normalized_config(&displays);
        let enabled = if selector == SerializedSelector::Primary {
            true
        } else {
            msg.enabled
        };
        let monitor = app_config.ensure_monitor(selector.clone());
        monitor.enabled = enabled;
        if monitor.selector == SerializedSelector::Primary {
            monitor.mode = INDEPENDENT_DISPLAY_MODE.to_string();
            monitor.mirror_target = None;
        }
        let display_settings = self.display_rows(&app_config, &displays);
        reply_try!(Self::validate_display_settings(
            &app_config,
            &displays,
            &display_settings,
        ));
        self.delegate_display(app_config, display_settings, ctx)
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayMode> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetDisplayModeReply>;

    async fn handle(
        &mut self,
        msg: SetDisplayMode,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        if selector == SerializedSelector::Primary && msg.mode == BridgeDisplayMode::Mirror {
            return ctx.reply(Err(BridgeError::invalid_input(
                "primary display cannot use mirror mode",
            )));
        }
        let source_display_id = reply_try!(self.source_display_id(&selector, &displays));
        let mut app_config = self.normalized_config(&displays);
        let valid_ids = if displays.is_empty() {
            self.state
                .display_settings
                .keys()
                .filter_map(|display_id| display_id.parse::<u32>().ok())
                .collect::<Vec<_>>()
        } else {
            self.normalized_config(&displays)
                .monitor_rows(&displays)
                .into_iter()
                .filter(|row| row.connected)
                .filter_map(|row| row.display_index.and_then(|index| displays.get(index)))
                .map(|display| display.desc.display_id)
                .collect::<Vec<_>>()
        };

        match msg.mode {
            BridgeDisplayMode::Standalone => {
                let monitor = app_config.ensure_monitor(selector.clone());
                monitor.mode = INDEPENDENT_DISPLAY_MODE.to_string();
                monitor.mirror_target = None;
                if monitor.selector == SerializedSelector::Primary {
                    monitor.enabled = true;
                }
            }
            BridgeDisplayMode::Mirror => {
                let target_display_id = if let Some(target) = app_config
                    .monitors
                    .iter()
                    .find(|monitor| monitor.selector == selector)
                    .and_then(|monitor| monitor.mirror_target.as_ref())
                    .and_then(|target| {
                        Self::valid_target(target, source_display_id, &displays, &valid_ids)
                    }) {
                    target
                } else {
                    reply_try!(
                        valid_ids
                            .iter()
                            .copied()
                            .find(|target| *target != source_display_id)
                            .ok_or_else(|| {
                                BridgeError::invalid_input("mirror mode requires another display")
                            })
                    )
                };
                let target =
                    reply_try!(self.selector_for(&target_display_id.to_string(), &displays));
                reply_try!(app_config.validate_mirror_change(&selector, &target));
                let monitor = app_config.ensure_monitor(selector);
                monitor.enabled = true;
                monitor.mode = MIRROR_DISPLAY_MODE.to_string();
                monitor.mirror_target = Some(target);
            }
        }

        let display_settings = self.display_rows(&app_config, &displays);
        reply_try!(Self::validate_display_settings(
            &app_config,
            &displays,
            &display_settings,
        ));
        self.delegate_display(app_config, display_settings, ctx)
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorTarget> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetMirrorTargetReply>;

    async fn handle(
        &mut self,
        msg: SetMirrorTarget,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        if selector == SerializedSelector::Primary {
            return ctx.reply(Err(BridgeError::invalid_input(
                "primary display cannot use mirror mode",
            )));
        }
        let target = reply_try!(self.selector_for(&msg.target_display_id, &displays));
        let mut app_config = self.normalized_config(&displays);
        reply_try!(app_config.validate_mirror_change(&selector, &target));
        let monitor = app_config.ensure_monitor(selector);
        monitor.enabled = true;
        monitor.mode = MIRROR_DISPLAY_MODE.to_string();
        monitor.mirror_target = Some(target);
        let display_settings = self.display_rows(&app_config, &displays);
        reply_try!(Self::validate_display_settings(
            &app_config,
            &displays,
            &display_settings,
        ));
        self.delegate_display(app_config, display_settings, ctx)
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorScalingMode> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetMirrorScalingModeReply>;

    async fn handle(
        &mut self,
        msg: SetMirrorScalingMode,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        let handle = self.mirror_display_handle(&selector, &displays);
        let mut app_config = self.normalized_config(&displays);
        reply_try!(Self::require_mirror_monitor(&app_config, &selector));
        let scaling_mode = ScalingMode::from(msg.mode);
        Self::monitor_settings_mut(&mut app_config, selector).scaling_mode =
            scaling_mode.to_string();
        reply_try!(self.commit_app_config(app_config));
        if let Some(handle) = handle {
            reply_try!(
                self.engine
                    .set_scaling_mode(handle, scaling_mode)
                    .await
                    .map_err(|error| BridgeError::engine(error.to_string()))
            );
        }
        self.bump_generation();
        ctx.reply(Ok(self.display_bundle()))
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorScalingFactor> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetMirrorScalingFactorReply>;

    async fn handle(
        &mut self,
        msg: SetMirrorScalingFactor,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        if !msg.factor.is_finite() || msg.factor <= 0.0 {
            return ctx.reply(Err(BridgeError::invalid_input(
                "scaling factor must be greater than 0",
            )));
        }
        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        let handle = self.mirror_display_handle(&selector, &displays);
        let mut app_config = self.normalized_config(&displays);
        reply_try!(Self::require_mirror_monitor(&app_config, &selector));
        Self::monitor_settings_mut(&mut app_config, selector).scaling_factor = msg.factor;
        reply_try!(self.commit_app_config(app_config));
        if let Some(handle) = handle {
            reply_try!(
                self.engine
                    .set_scaling_factor(handle, msg.factor)
                    .await
                    .map_err(|error| BridgeError::engine(error.to_string()))
            );
        }
        self.bump_generation();
        ctx.reply(Ok(self.display_bundle()))
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorTargetFps> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetMirrorTargetFpsReply>;

    async fn handle(
        &mut self,
        msg: SetMirrorTargetFps,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        let source_display_id = reply_try!(self.source_display_id(&selector, &displays));
        let max_fps = reply_try!(
            displays
                .iter()
                .find(|display| display.desc.display_id == source_display_id)
                .map(|display| display.desc.refresh_rate_hz.max(1))
                .ok_or_else(|| {
                    BridgeError::invalid_input(format!("unknown display id {source_display_id}"))
                })
        );
        let handle = self.mirror_display_handle(&selector, &displays);
        let mut app_config = self.normalized_config(&displays);
        reply_try!(Self::require_mirror_monitor(&app_config, &selector));
        let target_fps = msg.fps.max(1).min(max_fps);
        Self::monitor_settings_mut(&mut app_config, selector).target_fps = target_fps;
        reply_try!(self.commit_app_config(app_config));
        if let Some(handle) = handle {
            reply_try!(
                self.engine
                    .set_fps(handle, target_fps)
                    .await
                    .map_err(|error| BridgeError::engine(error.to_string()))
            );
        }
        self.bump_generation();
        ctx.reply(Ok(self.display_bundle()))
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorVolume> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetMirrorVolumeReply>;

    async fn handle(
        &mut self,
        msg: SetMirrorVolume,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        if !(0.0..=1.0).contains(&msg.volume) {
            return ctx.reply(Err(BridgeError::invalid_input(
                "mirror volume must be between 0 and 1",
            )));
        }
        let volume = reply_try!(
            AudioVolume::try_from(msg.volume)
                .map_err(|error| BridgeError::invalid_input(error.to_string()))
        );
        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        let handle = self.mirror_display_handle(&selector, &displays);
        let mut app_config = self.normalized_config(&displays);
        reply_try!(Self::require_mirror_monitor(&app_config, &selector));
        Self::monitor_settings_mut(&mut app_config, selector).volume = msg.volume;
        reply_try!(self.commit_app_config(app_config));
        if let Some(handle) = handle {
            reply_try!(
                self.engine
                    .set_audio_volume(handle, volume)
                    .await
                    .map_err(|error| BridgeError::engine(error.to_string()))
            );
        }
        self.bump_generation();
        ctx.reply(Ok(self.display_bundle()))
    }
}

impl<E: EngineFacade + Clone> Message<SetMirrorMuted> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::SetMirrorMutedReply>;

    async fn handle(
        &mut self,
        msg: SetMirrorMuted,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        let handle = self.mirror_display_handle(&selector, &displays);
        let mut app_config = self.normalized_config(&displays);
        reply_try!(Self::require_mirror_monitor(&app_config, &selector));
        Self::monitor_settings_mut(&mut app_config, selector).muted = msg.muted;
        reply_try!(self.commit_app_config(app_config));
        if let Some(handle) = handle {
            reply_try!(
                self.engine
                    .set_audio_muted(handle, msg.muted)
                    .await
                    .map_err(|error| BridgeError::engine(error.to_string()))
            );
        }
        self.bump_generation();
        ctx.reply(Ok(self.display_bundle()))
    }
}

impl<E: EngineFacade + Clone> Message<SetLaunchAtLogin> for BridgeActor<E> {
    type Reply = messages::DisplayMutationReply;

    async fn handle(
        &mut self,
        msg: SetLaunchAtLogin,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.launch_at_login.set_enabled(msg.enabled)?;
        Ok(self.display_bundle())
    }
}

impl<E: EngineFacade + Clone> Message<SetPauseOnBatteryPower> for BridgeActor<E> {
    type Reply = messages::SetPauseOnBatteryPowerReply;

    async fn handle(
        &mut self,
        msg: SetPauseOnBatteryPower,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.power.pause_on_battery_power = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        if !msg.enabled {
            self.state.auto_paused_for_battery = false;
            self.state.battery_pause_suppressed = false;
            self.state.pending_battery_pause_after_initial_frame = false;
        }
        self.apply_power_policy().await?;
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetPresentationSuspended> for BridgeActor<E> {
    type Reply = messages::SetPresentationSuspendedReply;

    async fn handle(
        &mut self,
        msg: SetPresentationSuspended,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.state.presentation_suspended == msg.suspended {
            return Ok(());
        }
        let previous_paused = self.playback_paused();
        self.state.presentation_suspended = msg.suspended;
        if let Err(error) = self.apply_engine_pause(previous_paused).await {
            self.state.presentation_suspended = !msg.suspended;
            return Err(error);
        }
        self.bump_generation();
        log::info!(
            "presentation {}",
            if msg.suspended { "suspended" } else { "resumed" }
        );
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayPresentationSuspended> for BridgeActor<E> {
    type Reply = messages::SetDisplayPresentationSuspendedReply;

    async fn handle(
        &mut self,
        msg: SetDisplayPresentationSuspended,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let display_id: u32 = msg.display_id.parse().map_err(|_| {
            BridgeError::invalid_input(format!("unknown display id {}", msg.display_id))
        })?;
        let was_suspended = self.state.suspended_displays.contains(&display_id);
        if was_suspended == msg.suspended {
            return Ok(());
        }
        let previous_paused = self.playback_paused();
        if msg.suspended {
            self.state.suspended_displays.insert(display_id);
        } else {
            self.state.suspended_displays.remove(&display_id);
        }
        // The scene on this display takes the new state; the others keep
        // whatever they already had, so a hidden screen cannot stop a visible
        // one and a visible screen cannot restart a hidden one.
        let paused = self.playback_paused() || msg.suspended;
        let audio_suspended = self.audio_capture_suspended();
        let result = async {
            self.engine.set_display_paused(display_id, paused).await?;
            self.engine
                .set_audio_capture_suspended(audio_suspended)
                .await
        }
        .await;
        if let Err(error) = result {
            let mut message = error.to_string();
            if msg.suspended {
                self.state.suspended_displays.remove(&display_id);
            } else {
                self.state.suspended_displays.insert(display_id);
            }
            if let Err(rollback) = self
                .engine
                .set_display_paused(display_id, previous_paused || was_suspended)
                .await
            {
                message.push_str(&format!("; display pause rollback failed: {rollback}"));
            }
            if let Err(rollback) = self
                .engine
                .set_audio_capture_suspended(self.audio_capture_suspended())
                .await
            {
                message.push_str(&format!("; audio capture rollback failed: {rollback}"));
            }
            return Err(BridgeError::engine(message));
        }
        self.refresh_mouse_polling_policy();
        self.bump_generation();
        log::info!(
            "display {display_id} presentation {}",
            if msg.suspended { "suspended" } else { "resumed" }
        );
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SetVideoBackend> for BridgeActor<E> {
    type Reply = messages::SetVideoBackendReply;

    async fn handle(
        &mut self,
        msg: SetVideoBackend,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.state.app_config.video_backend == msg.mode {
            return Ok(self.all_snapshots());
        }
        let mut app_config = self.state.app_config.clone();
        app_config.video_backend = msg.mode;
        // Changing the backend moves wallpapers between renderers, so the
        // refusals recorded against the previous setting no longer describe
        // anything: keeping them would permanently exclude a wallpaper that was
        // only ever refused by a configuration the user has since changed.
        self.state.native_video_rejected.clear();
        // A wallpaper that changes backend must stop being rendered by the old
        // one in the same transition, so the scene list is rebuilt before the
        // new setting is committed: a failure leaves the previous backend
        // running rather than nothing at all.
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let scenes = self.reconcile_engine(app_config.clone(), wallpaper_configs).await?;
        if let Some(store) = &self.config_store {
            store.save_app_config(&app_config)?;
        }
        self.state.app_config = app_config;
        self.state.set_active_ids_from_scenes(&scenes);
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetRenderScale> for BridgeActor<E> {
    type Reply = messages::SetRenderScaleReply;

    async fn handle(
        &mut self,
        msg: SetRenderScale,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let scale = crate::config::clamp_render_scale(msg.scale);
        self.state.app_config.quality.render_scale = scale;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // What the user saved is not necessarily what runs: a battery profile
        // already in force keeps its own scale until the machine leaves
        // battery power.
        self.apply_effective_render_scale().await?;
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetBatteryQualityProfile> for BridgeActor<E> {
    type Reply = messages::SetBatteryQualityProfileReply;

    async fn handle(
        &mut self,
        msg: SetBatteryQualityProfile,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let quality = &mut self.state.app_config.quality;
        quality.battery_profile_enabled = msg.enabled;
        quality.battery.render_scale = crate::config::clamp_render_scale(msg.render_scale);
        quality.battery.target_fps = msg.target_fps.max(1);
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // Turning the profile off has to hand the renderer back the user's own
        // settings in the same step, or a machine that is on battery right now
        // stays degraded until it is unplugged and replugged.
        self.apply_quality_profile().await?;
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetContentPacingEnabled> for BridgeActor<E> {
    type Reply = messages::SetContentPacingEnabledReply;

    async fn handle(
        &mut self,
        msg: SetContentPacingEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.experimental.content_pacing = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        self.engine
            .set_content_pacing_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetSharedVideoDecodeEnabled> for BridgeActor<E> {
    type Reply = messages::SetSharedVideoDecodeEnabledReply;

    async fn handle(
        &mut self,
        msg: SetSharedVideoDecodeEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.state.app_config.experimental.shared_video_decode == msg.enabled {
            return Ok(self.all_snapshots());
        }
        self.state.app_config.experimental.shared_video_decode = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        self.engine
            .set_shared_video_decode_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        // A decoder is chosen when its source is opened, so a wallpaper that is
        // already running keeps the decoder it started with. Rebuilding the
        // scene list is what makes the new setting describe what is on screen
        // rather than only what the next wallpaper change will get.
        let app_config = self.state.app_config.clone();
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let scenes = self.reconcile_engine(app_config, wallpaper_configs).await?;
        self.state.set_active_ids_from_scenes(&scenes);
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetSceneOptimizationEnabled> for BridgeActor<E> {
    type Reply = messages::SetSceneOptimizationEnabledReply;

    async fn handle(
        &mut self,
        msg: SetSceneOptimizationEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.app_config.quality.scene_optimization_enabled = msg.enabled;
        if let Some(store) = &self.config_store {
            store.save_app_config(&self.state.app_config)?;
        }
        // Frame-building strategy, not scene content: running scenes pick it
        // up where they are, so nothing here rebuilds or reparses anything.
        self.engine
            .set_scene_optimization_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.bump_generation();
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<SetWebAudioSubscribed> for BridgeActor<E> {
    type Reply = messages::SetWebAudioSubscribedReply;

    async fn handle(
        &mut self,
        msg: SetWebAudioSubscribed,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let subscribers = &mut self.state.web_audio_subscribers;
        if msg.subscribed {
            let _ = subscribers
                .entry(msg.wallpaper_id)
                .or_default()
                .insert(msg.display_id);
        } else if let Some(displays) = subscribers.get_mut(&msg.wallpaper_id) {
            let _ = displays.remove(&msg.display_id);
            if displays.is_empty() {
                let _ = subscribers.remove(&msg.wallpaper_id);
            }
        }

        // The last consumer of either kind going away has to close the tap,
        // so this is re-evaluated rather than only ever opened.
        self.engine
            .set_audio_capture_suspended(self.audio_capture_suspended())
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))
    }
}

impl<E: EngineFacade + Clone> Message<SetMediaIntegrationEnabled> for BridgeActor<E> {
    type Reply = messages::SetMediaIntegrationEnabledReply;

    async fn handle(
        &mut self,
        msg: SetMediaIntegrationEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_media_integration_enabled_immediate(msg.enabled);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetPropertyPath> for BridgeActor<E> {
    type Reply = messages::SetPropertyPathReply;

    async fn handle(
        &mut self,
        msg: SetPropertyPath,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let model = self.state.project_model(&msg.wallpaper_id)?.clone();
        let kind = model
            .properties
            .iter()
            .find(|property| property.id == msg.property_id)
            .map(|property| property.kind.clone())
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown property id {}", msg.property_id))
            })?;
        // A texture picker names a scene asset, not a path the host may stage,
        // so it is refused here rather than quietly accepting a path the scene
        // engine would then fail to resolve.
        if !matches!(kind, PropertyKind::File | PropertyKind::Directory) {
            return Err(BridgeError::invalid_input(format!(
                "property id {} is not a file or directory property",
                msg.property_id
            )));
        }

        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_property_path_immediate(&model, &msg.property_id, msg.path);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<GetNativeVideoWallpapers> for BridgeActor<E> {
    type Reply = messages::GetNativeVideoWallpapersReply;

    async fn handle(
        &mut self,
        _msg: GetNativeVideoWallpapers,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        // This is where the host asks what to play, so it is where a refusal
        // that has outlived its configuration expires. The wallpaper goes back
        // to the native player, so the scene engine has to let go of it in the
        // same step or both would render it.
        if self.prune_stale_native_video_rejections() {
            let app_config = self.state.app_config.clone();
            let wallpaper_configs = self.state.wallpaper_configs.clone();
            let scenes = self.reconcile_engine(app_config, wallpaper_configs).await?;
            self.state.set_active_ids_from_scenes(&scenes);
        }
        self.native_video_wallpapers()
    }
}

impl<E: EngineFacade + Clone> Message<RejectNativeVideo> for BridgeActor<E> {
    type Reply = messages::RejectNativeVideoReply;

    async fn handle(
        &mut self,
        msg: RejectNativeVideo,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let live_keys = self.native_video_admission_keys();
        let current = live_keys.get(&msg.wallpaper_id);
        if !current.is_some_and(|keys| keys.contains(&msg.admission_key)) {
            // The host judged a configuration that no longer exists: the user
            // changed the target rate, an option or the media file while the
            // refusal was in flight. Recording it would kill a configuration
            // nothing has actually refused.
            log::info!(
                "native video wallpaper {} refused for admission key {} that is no longer \
                 current ({}); the configuration changed while the refusal was in flight, so \
                 the refusal is dropped",
                msg.wallpaper_id,
                msg.admission_key,
                msg.reason
            );
            return Ok(());
        }
        // Recorded once per admission key and never retried, so a wallpaper the
        // player cannot honour cannot bounce between the two backends. Keyed by
        // admission key rather than by wallpaper id: another display's refusal
        // of the same clip is a different decision and must not be overwritten.
        let record = NativeVideoRejection {
            reason: msg.reason.clone(),
        };
        if self
            .state
            .native_video_rejected
            .entry(msg.wallpaper_id.clone())
            .or_default()
            .insert(msg.admission_key, record)
            .is_some()
        {
            return Ok(());
        }
        log::info!(
            "native video wallpaper {} refused for admission key {}: {}; falling back to the \
             scene engine",
            msg.wallpaper_id,
            msg.admission_key,
            msg.reason
        );
        // The scene engine has to take it back now, or the display shows
        // nothing until something else triggers a reconcile.
        let app_config = self.state.app_config.clone();
        let wallpaper_configs = self.state.wallpaper_configs.clone();
        let scenes = self.reconcile_engine(app_config, wallpaper_configs).await?;
        self.state.set_active_ids_from_scenes(&scenes);
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<SetRendererCountersEnabled> for BridgeActor<E> {
    type Reply = messages::SetRendererCountersEnabledReply;

    async fn handle(
        &mut self,
        msg: SetRendererCountersEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.engine
            .set_renderer_counters_enabled(msg.enabled)
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        self.state.renderer_counters_enabled = msg.enabled;
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<RendererCounters> for BridgeActor<E> {
    type Reply = messages::RendererCountersReply;

    async fn handle(
        &mut self,
        _msg: RendererCounters,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let (surfaces, shared) = self
            .engine
            .renderer_counters()
            .await
            .map_err(|error| BridgeError::engine(error.to_string()))?;
        Ok(BridgeRendererCountersReport {
            recording: self.state.renderer_counters_enabled,
            surfaces: surfaces.iter().map(renderer_surface_row).collect(),
            audio_analysis_deliveries: shared_value(
                &shared,
                RendererSharedCounterKind::AudioAnalysisDeliveries,
            ),
            audio_accepted_frames: shared_value(
                &shared,
                RendererSharedCounterKind::AudioAcceptedFrames,
            ),
            audio_active_consumers: self.audio_consumer_count(),
            // MoltenVK over a CAMetalLayer swapchain exposes no presentation
            // feedback here. Present requests are reported as requests; the
            // frames the compositor actually showed are not observable, and are
            // never approximated by the request count.
            presentation_feedback_available: false,
        })
    }
}

/// Maps one renderer surface's counters onto the reported row. Named fields
/// only: no caller outside this crate handles raw counter indices.
fn renderer_surface_row(counters: &RendererSurfaceCounters) -> BridgeRendererSurfaceCounters {
    use RendererCounterKind as K;
    BridgeRendererSurfaceCounters {
        display_id: counters.display_id.to_string(),
        surface_id: counters.handle.raw().to_string(),
        generation: counters.generation,
        source_id: match counters.value(K::VideoSourceInstance) {
            0 => "unknown".to_string(),
            instance => format!("instance:{instance}"),
        },
        source_path: counters.source_path.clone(),
        source_count: counters.value(K::VideoSourceCount),
        backend: "scene".to_string(),
        effective_pause_reasons: counters
            .pause_reasons()
            .into_iter()
            .map(|reason| reason.name().to_string())
            .collect(),
        paused: counters.paused,
        timer_wakeups: counters.value(K::TimerWakeups),
        draw_requests: counters.value(K::DrawRequests),
        draw_ticks_suppressed: counters.value(K::DrawTicksSuppressed),
        draws_executed: counters.value(K::DrawsExecuted),
        draws_dropped: counters.value(K::DrawsDropped),
        render_submissions: counters.value(K::RenderSubmissions),
        render_failures: counters.value(K::RenderFailures),
        present_requests: counters.value(K::PresentRequests),
        gpu_completions: counters.value(K::GpuCompletions),
        simulation_ticks: counters.value(K::SimulationTicks),
        tick_interval_micros: counters.value(K::TickIntervalMicros),
        content_period_micros: counters.value(K::ContentPeriodMicros),
        video_decode_outputs: counters.value(K::VideoDecodeOutputs),
        video_seeks: counters.value(K::VideoSeeks),
        video_frames_selected: counters.value(K::VideoFramesSelected),
        video_frames_reused: counters.value(K::VideoFramesReused),
        video_frames_skipped: counters.value(K::VideoFramesSkipped),
        video_selected_generation: counters.value(K::VideoSelectedGeneration),
        video_conversions: counters.value(K::VideoConversions),
        video_imports: counters.value(K::VideoImports),
        video_conversion_live_bytes: counters.value(K::VideoConversionLiveBytes),
        video_conversion_peak_live_bytes: counters.value(K::VideoConversionPeakLiveBytes),
    }
}

impl<E: EngineFacade + Clone> Message<SetPowerSource> for BridgeActor<E> {
    type Reply = messages::SetPowerSourceReply;

    async fn handle(
        &mut self,
        msg: SetPowerSource,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if msg.initial_sample && self.state.startup_power_sample_received {
            return Ok(self.all_snapshots());
        }
        if self.state.power_source != msg.source {
            self.state.power_source = msg.source;
            if msg.source == crate::power::PowerSource::Battery {
                self.state.battery_pause_suppressed = false;
            }
        }
        if msg.initial_sample {
            self.state.apply_startup_power_source(msg.source);
        }
        self.apply_power_policy().await?;
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<InitialFrameReady> for BridgeActor<E> {
    type Reply = messages::InitialFrameReadyReply;

    async fn handle(
        &mut self,
        _msg: InitialFrameReady,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.initial_frame_ready = true;
        if self.state.pending_battery_pause_after_initial_frame {
            self.state.pending_battery_pause_after_initial_frame = false;
            self.apply_power_policy().await?;
        }
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<EjectWallpaperFromDisplay> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::EjectWallpaperFromDisplayReply>;

    async fn handle(
        &mut self,
        msg: EjectWallpaperFromDisplay,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let selector = reply_try!(self.selector_for(&msg.display_id, &displays));
        let mut app_config = self.normalized_config(&displays);
        let Some(monitor) = app_config
            .monitors
            .iter_mut()
            .find(|monitor| monitor.selector == selector)
        else {
            return ctx.reply(Err(BridgeError::invalid_input(format!(
                "unknown display id {}",
                msg.display_id
            ))));
        };

        if monitor.wallpaper.as_deref() != Some(msg.wallpaper_id.as_str()) {
            return ctx.reply(Err(BridgeError::invalid_input(format!(
                "wallpaper {} is not active on display {}",
                msg.wallpaper_id, msg.display_id
            ))));
        }

        monitor.wallpaper = None;
        if monitor.selector == SerializedSelector::Primary {
            monitor.enabled = true;
            monitor.mode = INDEPENDENT_DISPLAY_MODE.to_string();
            monitor.mirror_target = None;
            if let Some(primary) = displays.first() {
                for alias in app_config.monitors.iter_mut().filter(|candidate| {
                    candidate.selector != SerializedSelector::Primary
                        && candidate
                            .selector
                            .to_selector()
                            .matches_primary(primary, &displays)
                }) {
                    if alias.wallpaper.as_deref() == Some(msg.wallpaper_id.as_str()) {
                        alias.wallpaper = None;
                    }
                }
            }
        }

        let display_settings = self.display_rows(&app_config, &displays);
        self.delegate_display(app_config, display_settings, ctx)
    }
}

impl<E: EngineFacade + Clone> Message<SetGlobalPlayback> for BridgeActor<E> {
    type Reply = messages::SetGlobalPlaybackReply;

    async fn handle(
        &mut self,
        msg: SetGlobalPlayback,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_playback(msg.playback_state, PlaybackChangeOrigin::Manual)
            .await?;
        Ok(self.all_snapshots())
    }
}

impl<E: EngineFacade + Clone> Message<Shutdown> for BridgeActor<E> {
    type Reply = messages::ShutdownReply;

    async fn handle(
        &mut self,
        _msg: Shutdown,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.mouse_polling.set_policy_enabled(false);
        let mut active_handles = Vec::new();
        for display in self.engine.display_snapshot() {
            let Some(handle) = display.handle else {
                continue;
            };
            if active_handles.contains(&handle) {
                continue;
            }
            active_handles.push(handle);
        }

        let result = async {
            for handle in active_handles {
                self.engine.set_audio_capture_enabled(handle, false).await?;
            }
            self.engine.close_all_scenes().await
        }
        .await;
        if result.is_err() {
            self.refresh_mouse_polling_policy();
        }
        result.map_err(|error| BridgeError::engine(error.to_string()))
    }
}

impl<E: EngineFacade + Clone> Message<SetVolume> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetVolume,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let volume = AudioVolume::try_from(msg.volume)
            .map_err(|error| BridgeError::invalid_input(error.to_string()))?;
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_volume_immediate(msg.volume)?;
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        for handle in self.wallpaper_handles(&msg.wallpaper_id, false) {
            self.engine
                .set_audio_volume(handle, volume)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetMuted> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetMuted,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_muted_immediate(msg.muted);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        for handle in self.wallpaper_handles(&msg.wallpaper_id, false) {
            self.engine
                .set_audio_muted(handle, msg.muted)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetAudioResponseEnabled> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::WallpaperMutationReply>;

    async fn handle(
        &mut self,
        msg: SetAudioResponseEnabled,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if self.pending_audio_changes.contains(&msg.wallpaper_id) {
            return ctx.reply(Err(BridgeError::invalid_input(
                "An audio response change is still in progress.",
            )));
        }
        let previous_enabled = match self.state.wallpaper_draft_mut(&msg.wallpaper_id) {
            Ok(draft) => draft.current().audio.response_enabled,
            Err(error) => return ctx.reply(Err(error)),
        };
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)
            .expect("wallpaper draft was validated")
            .set_audio_response_enabled_immediate(msg.enabled);
        if let Err(error) = self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config) {
            let _ = self
                .state
                .wallpaper_draft_mut(&msg.wallpaper_id)
                .expect("wallpaper draft was validated")
                .set_audio_response_enabled_immediate(previous_enabled);
            return ctx.reply(Err(error));
        }
        self.bump_generation();
        let handles = self.wallpaper_handles(&msg.wallpaper_id, true);
        if handles.is_empty() {
            return ctx.reply(self.wallpaper_bundle(msg.wallpaper_id));
        }
        self.pending_audio_changes.insert(msg.wallpaper_id.clone());
        let actor = ctx.actor_ref().clone();
        let engine = self.engine.clone();
        ctx.spawn(async move {
            let mut result = Ok(());
            for &handle in &handles {
                if let Err(error) = engine.set_audio_capture_enabled(handle, msg.enabled).await {
                    result = Err(BridgeError::engine(error.to_string()));
                    break;
                }
            }
            if result.is_err() {
                for handle in handles {
                    if let Err(error) = engine
                        .set_audio_capture_enabled(handle, previous_enabled)
                        .await
                    {
                        log::warn!("could not restore audio response after failed change: {error}");
                    }
                }
            }
            actor
                .ask(CompleteAudioResponse {
                    wallpaper_id: msg.wallpaper_id,
                    previous_enabled,
                    result,
                })
                .await
                .map_err(map_send_error)
        })
    }
}

impl<E: EngineFacade + Clone> Message<CompleteAudioResponse> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: CompleteAudioResponse,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.pending_audio_changes.remove(&msg.wallpaper_id);
        if let Err(error) = msg.result {
            let config = self
                .state
                .wallpaper_draft_mut(&msg.wallpaper_id)?
                .set_audio_response_enabled_immediate(msg.previous_enabled);
            self.save_wallpaper(msg.wallpaper_id, config)?;
            self.bump_generation();
            return Err(error);
        }
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetDisplayConfigEnabled> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetDisplayConfigEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let selector = self.selector_for(&msg.display_id, &displays)?;
        let enabled_displays = self.state.enabled_selectors(&msg.wallpaper_id);
        let mut selector_aliases = vec![selector.clone()];
        if let Some(display) = selector.to_selector().resolve_display(&displays) {
            if displays
                .first()
                .is_some_and(|primary| display.matches_primary(primary))
            {
                selector_aliases.push(SerializedSelector::Primary);
            }
            if let Some(identity_selector) = display.stable_identity_selector() {
                selector_aliases.push(identity_selector);
            }
            selector_aliases.dedup();
        }
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_display_aliases_enabled(&selector_aliases, msg.enabled, &enabled_displays);
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetScalingMode> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetScalingMode,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let selector = self.selector_for(&msg.display_id, &displays)?;
        let scaling_mode = ScalingMode::from(msg.mode);
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_scaling_mode_immediate(selector.clone(), scaling_mode);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        if let Some(handle) = self.display_handle(&msg.wallpaper_id, &selector) {
            self.engine
                .set_scaling_mode(handle, scaling_mode)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetScalingFactor> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetScalingFactor,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let selector = self.selector_for(&msg.display_id, &displays)?;
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_scaling_factor(selector.clone(), msg.factor)?;
        if let Some(handle) = self.display_handle(&msg.wallpaper_id, &selector) {
            self.engine
                .set_scaling_factor(handle, msg.factor)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<SetTargetFps> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: SetTargetFps,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let displays = self.engine.display_snapshot();
        let selector = self.selector_for(&msg.display_id, &displays)?;
        let source_display_id = self.source_display_id(&selector, &displays)?;
        let max_fps = displays
            .iter()
            .find(|display| display.desc.display_id == source_display_id)
            .map(|display| display.desc.refresh_rate_hz.max(1))
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown display id {source_display_id}"))
            })?;
        let target_fps = msg.fps.min(max_fps.max(1));
        let wallpaper_config = self
            .state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .set_target_fps_immediate(selector.clone(), msg.fps, max_fps);
        self.save_wallpaper(msg.wallpaper_id.clone(), wallpaper_config)?;
        if let Some(handle) = self.display_handle(&msg.wallpaper_id, &selector) {
            self.engine
                .set_fps(handle, target_fps)
                .await
                .map_err(|error| BridgeError::engine(error.to_string()))?;
        }
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<EditProperty> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: EditProperty,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let model = self.state.project_model(&msg.wallpaper_id)?.clone();
        let property = model
            .properties
            .iter()
            .find(|property| property.id == msg.property_id)
            .ok_or_else(|| {
                BridgeError::invalid_input(format!("unknown property id {}", msg.property_id))
            })?;
        match (&property.kind, &property.metadata, &msg.value) {
            (PropertyKind::Bool, _, BridgePropertyValue::Bool { .. })
            | (PropertyKind::TextInput, _, BridgePropertyValue::String { .. })
            | (PropertyKind::File, _, BridgePropertyValue::String { .. })
            | (PropertyKind::Directory, _, BridgePropertyValue::String { .. })
            | (PropertyKind::Texture, _, BridgePropertyValue::String { .. }) => {}
            (
                PropertyKind::Slider,
                PropertyMetadata::Slider { min, max, .. },
                BridgePropertyValue::Number { value },
            ) if value.is_finite() && (*min..=*max).contains(value) => {}
            (PropertyKind::Color, _, BridgePropertyValue::ColorRgb { red, green, blue })
                if is_color_channel_valid!(*red)
                    && is_color_channel_valid!(*green)
                    && is_color_channel_valid!(*blue) => {}
            (
                PropertyKind::Combo,
                PropertyMetadata::Combo { options },
                BridgePropertyValue::String { value },
            ) if options.iter().any(|option| option.value == *value) => {}
            _ => {
                return Err(BridgeError::invalid_input(format!(
                    "invalid value for property id {}",
                    property.id
                )));
            }
        }
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .edit_property(&model, &msg.property_id, PropertyValue::from(msg.value));
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<RestorePropertyDefault> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: RestorePropertyDefault,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let property_exists = self
            .state
            .project_model(&msg.wallpaper_id)?
            .properties
            .iter()
            .any(|property| property.id == msg.property_id);
        if !property_exists {
            return Err(BridgeError::invalid_input(format!(
                "unknown property id {}",
                msg.property_id
            )));
        }
        self.state
            .wallpaper_draft_mut(&msg.wallpaper_id)?
            .restore_property_default(&msg.property_id);
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<ApplyWallpaperOptions> for BridgeActor<E> {
    type Reply = DelegatedReply<messages::WallpaperMutationReply>;

    async fn handle(
        &mut self,
        msg: ApplyWallpaperOptions,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        macro_rules! reply_try {
            ($expr:expr) => {
                match $expr {
                    Ok(value) => value,
                    Err(error) => return ctx.reply(Err(error)),
                }
            };
        }

        let displays = self.engine.display_snapshot();
        let primary_identity_selector = displays
            .first()
            .and_then(DisplaySnapshotExt::stable_identity_selector);
        let candidates = reply_try!(
            self.state
                .apply_candidates(&msg.wallpaper_id, primary_identity_selector.as_ref())
        );
        let app_config = candidates.app_config.clone();
        let wallpaper_configs = candidates.wallpaper_configs.clone();
        let requires_reconcile = candidates.requires_reconcile;
        let paused = self.playback_paused();
        let suspended_displays = self.state.suspended_displays.clone();
        let predicted_scenes = reply_try!(
            requires_reconcile
                .then(|| {
                    ActivationInputs {
                        app_config: &app_config,
                        wallpapers: &wallpaper_configs,
                        displays: &displays,
                        paused,
                        suspended_displays: &suspended_displays,
                        paths: &self.paths,
                        force_shader_refresh: false,
                        project_models: &self.state.project_models,
                        native_video_enabled: app_config.video_backend == VideoBackendModeCfg::NativePreferred,
                        native_video_rejected: &self.state.native_video_rejected,
                    }
                    .build()
                })
                .transpose()
        );
        let project_models = self.state.configured_project_models(&app_config);

        if requires_reconcile {
            let generation = self.reserve_reconcile();
            let actor = ctx.actor_ref().clone();
            let engine = self.engine.clone();
            let wallpaper_id = msg.wallpaper_id;
            let native_video_rejected_snapshot = self.state.native_video_rejected.clone();
            let quality = self.quality_runtime();
            let paths = self.paths.clone();
            return ctx.spawn(async move {
                let scenes = match reconcile_with(
                    engine,
                    app_config,
                    wallpaper_configs,
                    project_models,
                    paused,
                    suspended_displays,
                    paths,
                    false,
                    native_video_rejected_snapshot,
                    quality,
                )
                .await
                {
                    Ok(scenes) => scenes,
                    Err(error) => {
                        let _ = actor
                            .ask(ReconcileFailed {
                                error: duplicate_error(&error),
                                generation,
                            })
                            .await;
                        return Err(error);
                    }
                };
                actor
                    .ask(CommitApplyAfterReconcile {
                        wallpaper_id,
                        candidates,
                        scenes,
                        generation,
                    })
                    .await
                    .map_err(map_send_error)
            });
        }

        reply_try!(self.save_configs(&candidates.app_config, &candidates.wallpaper_config,));
        reply_try!(
            self.state
                .commit_apply_candidates(msg.wallpaper_id.clone(), candidates, false)
        );
        self.state.refresh_active_ids();
        if let Some(predicted_scenes) = predicted_scenes.as_deref() {
            self.state.set_active_ids_from_scenes(predicted_scenes);
        }

        self.bump_generation();
        ctx.reply(self.wallpaper_bundle(msg.wallpaper_id))
    }
}

impl<E: EngineFacade + Clone> Message<CommitApplyAfterReconcile> for BridgeActor<E> {
    type Reply = messages::CommitApplyAfterReconcileReply;

    async fn handle(
        &mut self,
        msg: CommitApplyAfterReconcile,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.reconcile_current(msg.generation) {
            self.stale_reconcile(msg.generation, ctx.actor_ref().clone());
            return self.wallpaper_bundle(msg.wallpaper_id);
        }

        if let Err(error) =
            self.save_configs(&msg.candidates.app_config, &msg.candidates.wallpaper_config)
        {
            // Reconciliation already changed the renderer. Publish its assignment even
            // when persistence fails, but keep the draft's committed property baseline.
            // A display refresh reconciles the saved wallpaper config; Apply can retry
            // the retained draft without reporting the old desktop as still active.
            self.state.app_config = msg.candidates.app_config;
            self.state.set_active_ids_from_scenes(&msg.scenes);
            self.finish_reconcile(msg.generation, ctx.actor_ref().clone());
            return Err(error);
        }
        self.state
            .commit_apply_candidates(msg.wallpaper_id.clone(), msg.candidates, false)?;
        self.state.set_active_ids_from_scenes(&msg.scenes);
        self.finish_reconcile(msg.generation, ctx.actor_ref().clone());
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}

impl<E: EngineFacade + Clone> Message<CommitDisplayAfterReconcile> for BridgeActor<E> {
    type Reply = messages::CommitDisplayAfterReconcileReply;

    async fn handle(
        &mut self,
        msg: CommitDisplayAfterReconcile,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.reconcile_current(msg.generation)
            || self.state.wallpaper_configs != msg.wallpaper_configs
        {
            self.stale_reconcile(msg.generation, ctx.actor_ref().clone());
            return Ok(self.display_bundle());
        }

        let generation = msg.generation;
        self.commit_display_settings(msg.app_config, msg.display_settings, msg.scenes)?;
        self.finish_reconcile(generation, ctx.actor_ref().clone());
        Ok(self.display_bundle())
    }
}

impl<E: EngineFacade + Clone> Message<CompleteRestoreAfterReconcile> for BridgeActor<E> {
    type Reply = messages::CompleteRestoreAfterReconcileReply;

    async fn handle(
        &mut self,
        msg: CompleteRestoreAfterReconcile,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        if !self.reconcile_current(msg.generation) {
            self.stale_reconcile(msg.generation, ctx.actor_ref().clone());
            return Ok(());
        }

        match msg.result {
            Ok(scenes) => {
                self.state.set_active_ids_from_scenes(&scenes);
                self.finish_reconcile(msg.generation, ctx.actor_ref().clone());
                Ok(())
            }
            Err(error) => {
                self.refresh_mouse_polling_policy();
                self.state.errors.push(error.message().to_string());
                Err(error)
            }
        }
    }
}

impl<E: EngineFacade + Clone> Message<ReconcileFailed> for BridgeActor<E> {
    type Reply = messages::ReconcileFailedReply;

    async fn handle(
        &mut self,
        msg: ReconcileFailed,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.reconcile_failure(msg.generation, msg.error, ctx.actor_ref().clone());
        Ok(())
    }
}

impl<E: EngineFacade + Clone> Message<CancelWallpaperOptions> for BridgeActor<E> {
    type Reply = messages::WallpaperMutationReply;

    async fn handle(
        &mut self,
        msg: CancelWallpaperOptions,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.state.wallpaper_draft_mut(&msg.wallpaper_id)?.cancel();
        self.bump_generation();
        self.wallpaper_bundle(msg.wallpaper_id)
    }
}
