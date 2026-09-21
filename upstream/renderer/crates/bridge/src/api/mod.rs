mod error;
mod types;

use std::{
    pin::Pin,
    sync::{Arc, Condvar, Mutex, MutexGuard},
};

pub use error::{BridgeError, BridgeErrorKind};
use futures_util::Future;
pub use types::{
    BridgeAppSnapshot, BridgeAudioSpectrum, BridgeComboOption, BridgeDirectoryMode,
    BridgeDisplayConfigRow, BridgeDisplayMode, BridgeDisplayMutationBundle,
    BridgeDisplaySettingsRow, BridgeFileFilter, BridgeLibraryScanStatus, BridgeLibrarySnapshot,
    BridgeLockScreenScene, BridgeLogLevel, BridgeLogStatus, BridgeMonitorInfoRow,
    BridgeNativeVideoWallpaper, BridgeMediaSnapshot,
    BridgeMonitorInformationSnapshot, BridgePlaybackState, BridgePropertyDescriptor,
    BridgePropertyKind, BridgePropertyValue, BridgeRendererCountersReport,
    BridgeRendererSurfaceCounters, BridgeScalingMode, BridgeSceneBackendReport,
    BridgeSceneUpdateModeReport, BridgeSettingsSnapshot, BridgeUserShortcut,
    BridgeSliderMetadata, BridgeSnapshotBundle, BridgeStorageStatus, BridgeVideoBackendReport,
    BridgeWallpaperEntry,
    BridgeWallpaperKind, BridgeWallpaperMutationBundle, BridgeWallpaperOptionsSnapshot,
    BridgeWebWallpaper,
};
use wallpaper_core::{
    DisplaySelector, FirstFrameCallback, WallpaperAssignment, WallpaperEngine,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneHandle, SceneResult},
};

#[cfg(test)]
use crate::actor::messages::{
    InjectDisplayForTest, InjectSceneProjectForTest, InjectSceneWallpaperConfigForTest,
    InjectWallpaperForTest, ReplaceLibraryForTest, ReplaceWallpaperConfigForTest, SetPowerSource,
};
#[cfg(test)]
use crate::config::WallpaperConfig;
#[cfg(test)]
use crate::engine::FakeEngineFacade;
use crate::{
    actor::{
        BridgeActorHandle,
        messages::{
            ApplyWallpaperOptions, Bootstrap, CancelWallpaperOptions, ClearShaderCache,
            EditProperty, EjectWallpaperFromDisplay, GetAllSnapshots, GetAppSnapshot,
            GetLibrarySnapshot, GetLockScreenScenes, GetMonitorInformationSnapshot,
            GetSettingsSnapshot, GetWallpaperOptionsSnapshot, GetWebWallpapers, InitialFrameReady,
            GetNativeVideoWallpapers, PollMousePosition, RejectNativeVideo, RendererCounters,
            RefreshDisplays, RefreshLibrary, RestorePropertyDefault, SelectWallpaper,
            SetAudioResponseEnabled, SetDisplayConfigEnabled, SetDisplayEnabled, SetDisplayMode,
            SetDisplayPresentationSuspended,
            SetFilter, SetGlobalPlayback, SetLaunchAtLogin, SetMirrorMuted, SetMirrorScalingFactor,
            SetMirrorScalingMode, SetMirrorTarget, SetMirrorTargetFps, SetMirrorVolume, SetMuted,
            SetBatteryQualityProfile, SetContentPacingEnabled, SetMediaIntegrationEnabled,
            SetPauseOnBatteryPower, SetPresentationSuspended, SetPropertyPath, SetRenderScale,
            SetRendererCountersEnabled, SetScalingFactor, SetScalingMode,
            SetSceneOnDemandEnabled, SetSceneOptimizationEnabled, SetSceneRenderer,
            SetSceneVideoPlaneSamplingEnabled, SetSharedVideoDecodeEnabled, SetTargetFps,
            SetVideoBackend, SetVolume,
            SetWebAudioSubscribed, Shutdown,
        },
        state::BridgeActorState,
    },
    config::{ConfigStore, SceneRendererModeCfg, VideoBackendModeCfg},
    engine::{EngineFacade, RealEngineFacade},
    login::LaunchAtLoginController,
    media::SystemMediaStore,
    paths::BridgePaths,
    power::{PowerSource, PowerWatcher, SystemPowerSource},
};

pub(crate) fn bridge_log_status(status: crate::logging::LogStatus) -> BridgeLogStatus {
    BridgeLogStatus {
        logs_root: status.logs_root.to_string_lossy().into_owned(),
        active_session: status.active_session,
        active_file: status.active_file.to_string_lossy().into_owned(),
        active_file_size_bytes: status.active_file_size_bytes,
    }
}

pub struct BridgeBuilder<E: EngineFacade> {
    engine: E,
    state: Option<BridgeActorState>,
    config_store: Option<ConfigStore>,
    launch_at_login: LaunchAtLoginController,
    paths: BridgePaths,
    mouse_polling_enabled: bool,
    power_watching_enabled: bool,
    startup_power_source: Option<PowerSource>,
}

impl<E: EngineFacade> BridgeBuilder<E> {
    #[allow(clippy::single_call_fn)]
    pub fn new(engine: E) -> Self {
        Self {
            engine,
            state: None,
            config_store: None,
            launch_at_login: LaunchAtLoginController::default(),
            paths: BridgePaths::new(),
            mouse_polling_enabled: true,
            power_watching_enabled: !cfg!(test),
            startup_power_source: None,
        }
    }

    #[cfg(test)]
    pub fn with_state(mut self, state: BridgeActorState) -> Self {
        self.state = Some(state);
        self
    }

    pub fn with_config_store(mut self, config_store: ConfigStore) -> Self {
        self.config_store = Some(config_store);
        self
    }

    pub fn with_paths(mut self, paths: BridgePaths) -> Self {
        self.paths = paths;
        self
    }

    #[cfg(test)]
    pub fn with_launch_at_login(mut self, launch_at_login: LaunchAtLoginController) -> Self {
        self.launch_at_login = launch_at_login;
        self
    }

    #[cfg(test)]
    pub fn with_mouse_polling_enabled(mut self, enabled: bool) -> Self {
        self.mouse_polling_enabled = enabled;
        self
    }

    #[cfg(test)]
    pub fn with_power_watching_enabled(mut self, enabled: bool) -> Self {
        self.power_watching_enabled = enabled;
        self
    }

    #[cfg(test)]
    pub fn with_startup_power_source(mut self, source: PowerSource) -> Self {
        self.startup_power_source = Some(source);
        self
    }

    pub fn build(self) -> Result<WallpaperBridge, BridgeError> {
        let startup_power_source = if cfg!(test) {
            self.startup_power_source
        } else {
            Some(
                self.startup_power_source
                    .unwrap_or_else(SystemPowerSource::current),
            )
        };
        let loaded_store = if let Some(store) = &self.config_store {
            Some(store.load()?)
        } else {
            None
        };

        let mut state = self.state.unwrap_or_else(|| {
            if let Some(loaded_store) = loaded_store {
                BridgeActorState::from_app_config(loaded_store.config)
            } else {
                BridgeActorState::default()
            }
        });
        if let Some(source) = startup_power_source {
            state.apply_startup_power_source(source);
            log::info!("startup power source sampled: {source:?}");
        }

        let engine = ArcEngineFacade::new(self.engine);
        let mouse_polling = Arc::new(MousePollingControl::new());
        let weak_polling = Arc::downgrade(&mouse_polling);
        engine.set_pointer_consumer_callback(Some(Arc::new(move |has_consumers| {
            if let Some(control) = weak_polling.upgrade() {
                control.set_has_consumers(has_consumers);
            }
        })));
        let actor = BridgeActorHandle::spawn(
            state,
            engine.clone(),
            self.config_store.clone(),
            self.launch_at_login,
            self.paths,
            Arc::clone(&mouse_polling),
        )?;
        let first_frame_notifier = FirstFrameNotifier {
            actor: actor.clone(),
        };
        engine.set_first_frame_callback(first_frame_notifier.callback());
        let mouse_poller = if self.mouse_polling_enabled {
            Some(MousePoller::spawn(actor.clone(), mouse_polling))
        } else {
            None
        };
        let power_watcher = if self.power_watching_enabled {
            Some(PowerWatcher::spawn(actor.clone()))
        } else {
            None
        };

        // Small: a user cannot press faster than the app takes them, and a
        // backlog nobody has taken is presses already stopped being waited on.
        let (shortcut_sender, shortcut_receiver) = tokio::sync::mpsc::channel(8);
        engine.set_user_shortcut_callback(Some(Arc::new(move |handle, property, value| {
            let event = BridgeUserShortcut {
                scene_handle: handle.raw(),
                property,
                value,
            };
            if shortcut_sender.try_send(event).is_err() {
                log::warn!("dropped a user shortcut nobody had taken yet");
            }
        })));

        Ok(WallpaperBridge {
            actor,
            mouse_poller,
            power_watcher,
            system_media: SystemMediaStore::default(),
            engine,
            _config_store: self.config_store,
            user_shortcuts: tokio::sync::Mutex::new(shortcut_receiver),
        })
    }
}

struct MousePoller {
    control: Arc<MousePollingControl>,
    worker: Option<std::thread::JoinHandle<()>>,
}

struct MousePollingState {
    policy_enabled: bool,
    has_consumers: bool,
    stopped: bool,
}

impl MousePollingState {
    fn eligible(&self) -> bool {
        self.policy_enabled && self.has_consumers && !self.stopped
    }
}

pub(crate) struct MousePollingControl {
    state: Mutex<MousePollingState>,
    changed: Condvar,
}

impl MousePollingControl {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(MousePollingState {
                policy_enabled: false,
                has_consumers: false,
                stopped: false,
            }),
            changed: Condvar::new(),
        }
    }

    fn recover_poison<'a>(
        &self,
        mut state: MutexGuard<'a, MousePollingState>,
    ) -> MutexGuard<'a, MousePollingState> {
        if !state.stopped {
            log::error!("mouse polling control poisoned; stopping worker");
        }
        state.stopped = true;
        state.policy_enabled = false;
        state.has_consumers = false;
        self.changed.notify_all();
        state
    }

    fn lock(&self) -> MutexGuard<'_, MousePollingState> {
        self.state
            .lock()
            .unwrap_or_else(|error| self.recover_poison(error.into_inner()))
    }

    pub(crate) fn set_policy_enabled(&self, enabled: bool) {
        let mut state = self.lock();
        if state.stopped {
            return;
        }
        let was_eligible = state.eligible();
        state.policy_enabled = enabled;
        if state.eligible() != was_eligible {
            self.changed.notify_all();
        }
    }

    pub(crate) fn set_has_consumers(&self, has_consumers: bool) {
        let mut state = self.lock();
        if state.stopped {
            return;
        }
        let was_eligible = state.eligible();
        state.has_consumers = has_consumers;
        if state.eligible() != was_eligible {
            self.changed.notify_all();
        }
    }

    pub(crate) fn is_enabled(&self) -> bool {
        self.lock().eligible()
    }

    pub(crate) fn stop(&self) {
        self.lock().stopped = true;
        self.changed.notify_all();
    }

    pub(crate) fn wait_until_enabled(&self) -> bool {
        let mut state = self.lock();
        while !state.eligible() && !state.stopped {
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(|error| self.recover_poison(error.into_inner()));
        }
        !state.stopped
    }

    pub(crate) fn wait_interval(&self, interval: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + interval;
        let mut state = self.lock();
        while state.eligible() {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            state = match self.changed.wait_timeout(state, remaining) {
                Ok((state, _)) => state,
                Err(error) => self.recover_poison(error.into_inner().0),
            };
        }
        !state.stopped
    }
}

struct FirstFrameNotifier {
    actor: BridgeActorHandle<ArcEngineFacade>,
}

impl FirstFrameNotifier {
    fn callback(&self) -> FirstFrameCallback {
        let actor = self.actor.clone();
        Arc::new(move |handle| {
            log::info!("first frame ready for scene handle {}", handle.raw());
            let actor = actor.clone();
            let _ = std::thread::Builder::new()
                .name("wallpaper-bridge-first-frame".to_string())
                .spawn(move || {
                    let result: Result<BridgeSnapshotBundle, BridgeError> =
                        actor.blocking_ask(InitialFrameReady);
                    if let Err(error) = result {
                        log::debug!("initial-frame notification skipped: {error}");
                    }
                });
        })
    }
}

impl MousePoller {
    const INTERVAL: std::time::Duration = std::time::Duration::from_millis(16);

    #[allow(clippy::single_call_fn)]
    fn spawn(actor: BridgeActorHandle<ArcEngineFacade>, control: Arc<MousePollingControl>) -> Self {
        let worker_control = Arc::clone(&control);
        let worker = std::thread::Builder::new()
            .name("wallpaper-bridge-mouse-poller".to_string())
            .spawn(move || {
                while worker_control.wait_until_enabled() {
                    let poll_result: Result<(), BridgeError> =
                        actor.blocking_ask(PollMousePosition);
                    if let Err(error) = poll_result {
                        log::debug!("mouse poll skipped: {error}");
                    }
                    if !worker_control.wait_interval(Self::INTERVAL) {
                        break;
                    }
                }
            })
            .ok();

        Self { control, worker }
    }
}

impl Drop for MousePoller {
    fn drop(&mut self) {
        self.control.stop();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[derive(uniffi::Object)]
pub struct WallpaperBridge {
    actor: BridgeActorHandle<ArcEngineFacade>,
    #[allow(dead_code)]
    mouse_poller: Option<MousePoller>,
    #[allow(dead_code)]
    power_watcher: Option<PowerWatcher<ArcEngineFacade>>,
    /// Last known system media state, held for replay into pages that load
    /// after the fact. Process-wide, like the system player it describes, so
    /// it is deliberately not actor state.
    system_media: SystemMediaStore,
    /// The engine the actor drives, kept here so the process-wide audio
    /// analysis can be read without an actor round trip on every poll.
    engine: ArcEngineFacade,
    _config_store: Option<ConfigStore>,
    /// Requests waiting for `next_user_shortcut`. Bounded, and outside the
    /// actor: awaiting one inside a message handler would stall the mailbox for
    /// every other request while nobody is pressing anything.
    user_shortcuts: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<BridgeUserShortcut>>,
}

#[derive(Clone)]
struct ArcEngineFacade(Arc<dyn EngineFacade>);

impl ArcEngineFacade {
    #[allow(clippy::single_call_fn)]
    fn new<E: EngineFacade>(engine: E) -> Self {
        Self(Arc::new(engine))
    }
}

impl EngineFacade for ArcEngineFacade {
    fn update_media(&self, handle: wallpaper_core::project::SceneHandle, enabled: bool,
        state: wallpaper_core::media::MediaPollResult) -> futures_util::future::BoxFuture<'static, Result<(), wallpaper_core::EngineError>> {
        self.0.update_media(handle, enabled, state)
    }
    fn reconcile_scenes(
        &self,
        scenes: Vec<wallpaper_core::project::SceneDesc>,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<SceneResult>, wallpaper_core::EngineError>> + Send>>
    {
        self.0.reconcile_scenes(scenes)
    }

    fn refresh_displays(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.refresh_displays()
    }

    fn display_snapshot(&self) -> Vec<wallpaper_core::DisplaySnapshotEntry> {
        self.0.display_snapshot()
    }

    fn close_all_scenes(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.close_all_scenes()
    }

    fn set_all_paused(
        &self,
        paused: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_all_paused(paused)
    }

    fn set_display_paused(
        &self,
        display_id: u32,
        paused: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_display_paused(display_id, paused)
    }

    fn set_renderer_counters_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_renderer_counters_enabled(enabled)
    }

    fn set_content_pacing_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_content_pacing_enabled(enabled)
    }

    fn set_shared_video_decode_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_shared_video_decode_enabled(enabled)
    }

    fn set_scene_optimization_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_optimization_enabled(enabled)
    }

    fn set_scene_on_demand_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_on_demand_enabled(enabled)
    }

    fn set_scene_video_plane_sampling_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_video_plane_sampling_enabled(enabled)
    }

    fn set_scene_renderer_preference(
        &self,
        preference: wallpaper_core::SceneRendererPreference,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_renderer_preference(preference)
    }

    fn scene_runtime_reports(&self) -> Vec<crate::engine::SceneRuntimeReport> {
        self.0.scene_runtime_reports()
    }

    fn current_audio_spectrum(
        &self,
    ) -> Result<Option<wallpaper_core::AudioSpectrum128>, wallpaper_core::EngineError> {
        self.0.current_audio_spectrum()
    }

    fn video_pipeline_state(&self) -> crate::engine::RendererVideoPipelineState {
        self.0.video_pipeline_state()
    }

    fn renderer_counters(
        &self,
    ) -> Pin<
        Box<
            dyn Future<
                    Output = Result<
                        (
                            Vec<wallpaper_core::render::RendererSurfaceCounters>,
                            Vec<u64>,
                        ),
                        wallpaper_core::EngineError,
                    >,
                > + Send,
        >,
    > {
        self.0.renderer_counters()
    }

    fn set_audio_volume(
        &self,
        handle: SceneHandle,
        volume: AudioVolume,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_volume(handle, volume)
    }

    fn set_audio_muted(
        &self,
        handle: SceneHandle,
        muted: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_muted(handle, muted)
    }

    fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_response_enabled(handle, enabled)
    }

    fn set_media_integration_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_media_integration_enabled(handle, enabled)
    }

    fn submit_media_event_json(
        &self,
        handle: SceneHandle,
        json: String,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.submit_media_event_json(handle, json)
    }

    fn apply_system_media_artwork(
        &self,
        handle: SceneHandle,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0
            .apply_system_media_artwork(handle, width, height, rgba)
    }

    fn set_audio_capture_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_capture_enabled(handle, enabled)
    }

    fn set_audio_capture_suspended(
        &self,
        suspended: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_capture_suspended(suspended)
    }

    fn set_scaling_mode(
        &self,
        handle: SceneHandle,
        mode: ScalingMode,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_scaling_mode(handle, mode)
    }

    fn set_scaling_factor(
        &self,
        handle: SceneHandle,
        factor: f64,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_scaling_factor(handle, factor)
    }

    fn set_fps(
        &self,
        handle: SceneHandle,
        fps: u32,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_fps(handle, fps)
    }

    fn set_render_scale(
        &self,
        handle: SceneHandle,
        scale: f32,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_render_scale(handle, scale)
    }

    fn poll_mouse_position(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.poll_mouse_position()
    }

    fn set_mouse_position(
        &self,
        handle: SceneHandle,
        x: f64,
        y: f64,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_mouse_position(handle, x, y)
    }

    fn set_mouse_button(
        &self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_mouse_button(handle, button, pressed)
    }

    fn set_mouse_entered(
        &self,
        handle: SceneHandle,
        entered: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_mouse_entered(handle, entered)
    }

    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> Pin<
        Box<dyn Future<Output = Result<Option<SceneHandle>, wallpaper_core::EngineError>> + Send>,
    > {
        self.0.create_window_for_display(selector)
    }

    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> Pin<
        Box<dyn Future<Output = Result<Option<SceneHandle>, wallpaper_core::EngineError>> + Send>,
    > {
        self.0.set_wallpaper_for_display(selector, assignment)
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        self.0.set_first_frame_callback(callback);
    }

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        self.0.set_pointer_consumer_callback(callback);
    }

    fn set_user_shortcut_callback(
        &self,
        callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
        self.0.set_user_shortcut_callback(callback);
    }
}

#[uniffi::export]
impl WallpaperBridge {
    #[uniffi::constructor]
    /// # Errors
    ///
    /// Returns an error when the native engine cannot start or persisted
    /// configuration cannot load.
    pub fn new() -> Result<Self, BridgeError> {
        let paths = BridgePaths::new();
        crate::logging::ApplicationLogger::install(&paths)?;
        let engine =
            WallpaperEngine::new().map_err(|error| BridgeError::engine(error.to_string()))?;

        BridgeBuilder::new(RealEngineFacade::new(engine))
            .with_config_store(ConfigStore::open(ConfigStore::default_root()))
            .with_paths(paths)
            .build()
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce an app snapshot.
    pub async fn app_snapshot(&self) -> Result<BridgeAppSnapshot, BridgeError> {
        self.actor.ask(GetAppSnapshot).await
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce a library
    /// snapshot.
    pub async fn library_snapshot(&self) -> Result<BridgeLibrarySnapshot, BridgeError> {
        self.actor.ask(GetLibrarySnapshot).await
    }

    /// Returns committed active scenes for the currently connected displays.
    /// Draft options and the library selection do not affect these inputs.
    ///
    /// # Errors
    ///
    /// Returns an error when scene resolution or renderer-input conversion fails.
    pub async fn lock_screen_scenes(&self) -> Result<Vec<BridgeLockScreenScene>, BridgeError> {
        self.actor.ask(GetLockScreenScenes).await
    }

    /// Returns committed web wallpapers for the currently connected displays.
    /// The host renders these in web views; the scene engine never opens a
    /// window for them. Draft options do not affect these inputs.
    ///
    /// # Errors
    ///
    /// Returns an error when a web project has no entry file or its path
    /// cannot be resolved.
    pub async fn web_wallpapers(&self) -> Result<Vec<BridgeWebWallpaper>, BridgeError> {
        self.actor.ask(GetWebWallpapers).await
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce monitor
    /// information.
    pub async fn monitor_information_snapshot(
        &self,
    ) -> Result<BridgeMonitorInformationSnapshot, BridgeError> {
        self.actor.ask(GetMonitorInformationSnapshot).await
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce settings.
    pub async fn settings_snapshot(&self) -> Result<BridgeSettingsSnapshot, BridgeError> {
        self.actor.ask(GetSettingsSnapshot).await
    }

    /// # Errors
    ///
    /// Returns an error when GUI log emission cannot be accepted.
    #[allow(clippy::needless_pass_by_value)]
    pub fn emit_gui_log(
        &self,
        level: BridgeLogLevel,
        file: String,
        line: u32,
        message: String,
    ) -> Result<(), BridgeError> {
        let level = match level {
            BridgeLogLevel::Trace => log::Level::Trace,
            BridgeLogLevel::Debug => log::Level::Debug,
            BridgeLogLevel::Info => log::Level::Info,
            BridgeLogLevel::Warn => log::Level::Warn,
            BridgeLogLevel::Error => log::Level::Error,
        };
        crate::logging::ApplicationLogger::emit_gui_log(level, &file, line, &message);
        Ok(())
    }

    /// # Errors
    ///
    /// Returns an error when the logger has not been installed.
    pub fn log_folder_path(&self) -> Result<String, BridgeError> {
        crate::logging::ApplicationLogger::logs_root()
            .map(|path| path.to_string_lossy().into_owned())
            .ok_or_else(|| BridgeError::Error {
                kind: BridgeErrorKind::Io,
                message: "application logger is not installed".to_string(),
            })
    }

    /// # Errors
    ///
    /// Returns an error when a new log session cannot be created.
    pub fn clear_logs(&self) -> Result<BridgeLogStatus, BridgeError> {
        crate::logging::ApplicationLogger::clear().map(bridge_log_status)
    }

    /// # Errors
    ///
    /// Returns an error when the shader cache cannot be cleared or active
    /// scenes cannot be rebuilt.
    pub async fn clear_shader_cache(&self) -> Result<BridgeSettingsSnapshot, BridgeError> {
        self.actor.ask(ClearShaderCache).await
    }

    /// # Errors
    ///
    /// Returns an error when any snapshot in the bundle cannot be produced.
    pub async fn all_snapshots(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(GetAllSnapshots).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or its options cannot
    /// be read.
    pub async fn wallpaper_options_snapshot(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperOptionsSnapshot, BridgeError> {
        self.actor
            .ask(GetWallpaperOptionsSnapshot { wallpaper_id })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the library cannot be scanned.
    pub async fn refresh_library(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(RefreshLibrary).await
    }

    /// # Errors
    ///
    /// Returns an error when display refresh, library refresh, config load, or
    /// reconciliation fails.
    pub async fn bootstrap(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(Bootstrap).await
    }

    /// # Errors
    ///
    /// Returns an error when display refresh fails.
    pub async fn refresh_displays(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(RefreshDisplays).await
    }

    /// # Errors
    ///
    /// Returns an error when host pointer state cannot be forwarded to active
    /// wallpaper scenes.
    pub async fn poll_mouse_position(&self) -> Result<(), BridgeError> {
        self.actor.ask(PollMousePosition).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or selection cannot be
    /// committed.
    pub async fn select_wallpaper(&self, id: String) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SelectWallpaper { id }).await
    }

    /// # Errors
    ///
    /// Returns an error when filter state cannot be persisted.
    pub async fn set_filter(
        &self,
        kind: BridgeWallpaperKind,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetFilter { kind, enabled }).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown, the volume is
    /// invalid, or persistence fails.
    pub async fn set_volume(
        &self,
        wallpaper_id: String,
        volume: f32,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetVolume {
                wallpaper_id,
                volume,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or persistence fails.
    pub async fn set_muted(
        &self,
        wallpaper_id: String,
        muted: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetMuted {
                wallpaper_id,
                muted,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or persistence fails.
    pub async fn set_audio_response_enabled(
        &self,
        wallpaper_id: String,
        enabled: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetAudioResponseEnabled {
                wallpaper_id,
                enabled,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown.
    pub async fn set_display_config_enabled(
        &self,
        wallpaper_id: String,
        display_id: String,
        enabled: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetDisplayConfigEnabled {
                wallpaper_id,
                display_id,
                enabled,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown, or
    /// persistence fails.
    pub async fn set_scaling_mode(
        &self,
        wallpaper_id: String,
        display_id: String,
        mode: BridgeScalingMode,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetScalingMode {
                wallpaper_id,
                display_id,
                mode,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown, the
    /// scaling factor is invalid, or live engine update fails.
    pub async fn edit_scaling_factor(
        &self,
        wallpaper_id: String,
        display_id: String,
        factor: f64,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetScalingFactor {
                wallpaper_id,
                display_id,
                factor,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown, or
    /// persistence fails.
    pub async fn set_target_fps(
        &self,
        wallpaper_id: String,
        display_id: String,
        fps: u32,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetTargetFps {
                wallpaper_id,
                display_id,
                fps,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown or the display update
    /// fails.
    pub async fn set_display_enabled(
        &self,
        display_id: String,
        enabled: bool,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetDisplayEnabled {
                display_id,
                enabled,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown or the mode update
    /// fails.
    pub async fn set_display_mode(
        &self,
        display_id: String,
        mode: BridgeDisplayMode,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetDisplayMode { display_id, mode }).await
    }

    /// # Errors
    ///
    /// Returns an error when the display id, target display id, or mirror graph
    /// is invalid.
    pub async fn set_mirror_target(
        &self,
        display_id: String,
        target_display_id: String,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetMirrorTarget {
                display_id,
                target_display_id,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, or
    /// the display update fails.
    pub async fn set_mirror_scaling_mode(
        &self,
        display_id: String,
        mode: BridgeScalingMode,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetMirrorScalingMode { display_id, mode })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, the
    /// factor is invalid, or the display update fails.
    pub async fn set_mirror_scaling_factor(
        &self,
        display_id: String,
        factor: f64,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetMirrorScalingFactor { display_id, factor })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, or
    /// the display update fails.
    pub async fn set_mirror_target_fps(
        &self,
        display_id: String,
        fps: u32,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetMirrorTargetFps { display_id, fps }).await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, the
    /// volume is invalid, or the display update fails.
    pub async fn set_mirror_volume(
        &self,
        display_id: String,
        volume: f32,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetMirrorVolume { display_id, volume }).await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, or
    /// the display update fails.
    pub async fn set_mirror_muted(
        &self,
        display_id: String,
        muted: bool,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetMirrorMuted { display_id, muted }).await
    }

    /// # Errors
    ///
    /// Returns an error when launch at login is unavailable or
    /// `ServiceManagement` rejects the update.
    pub async fn set_launch_at_login(
        &self,
        enabled: bool,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetLaunchAtLogin { enabled }).await
    }

    /// # Errors
    ///
    /// Returns an error when the setting cannot be persisted or an immediate
    /// power-policy playback transition fails.
    pub async fn set_pause_on_battery_power(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetPauseOnBatteryPower { enabled }).await
    }

    /// Suspends or resumes rendering and system-audio capture for every
    /// wallpaper without changing the user-visible playback state. Used for
    /// conditions where no wallpaper pixel can reach a display: screens asleep,
    /// session locked, or every wallpaper window fully occluded.
    ///
    /// # Errors
    ///
    /// Returns an error when the actor rejects the update or the engine fails
    /// to apply the pause.
    pub async fn set_presentation_suspended(&self, suspended: bool) -> Result<(), BridgeError> {
        self.actor.ask(SetPresentationSuspended { suspended }).await
    }

    /// Suspends or resumes rendering for one display without touching the
    /// others or the user-visible playback state. Used for conditions that are
    /// specific to a screen, such as a window fully covering that wallpaper:
    /// one display being hidden must not stop a display that is still visible.
    ///
    /// # Errors
    ///
    /// Returns an error when the display id is not a known display, or the
    /// engine fails to apply the pause.
    pub async fn set_display_presentation_suspended(
        &self,
        display_id: String,
        suspended: bool,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(SetDisplayPresentationSuspended {
                display_id,
                suspended,
            })
            .await
    }

    /// Turns renderer work counting on or off for the whole process.
    ///
    /// Off is the default. Enabling adds one relaxed atomic increment per
    /// counted event; it starts no thread, no timer and no output stream, and
    /// counters are only ever read by an explicit `renderer_counters` call.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    pub async fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), BridgeError> {
        self.actor.ask(SetRendererCountersEnabled { enabled }).await
    }

    /// Reads renderer work counters for every open scene.
    ///
    /// This is the evidence half of the per-surface suspension work: it answers
    /// whether a hidden surface actually stopped submitting and presenting,
    /// rather than whether a suspend decision was delivered to it.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    pub async fn renderer_counters(&self) -> Result<BridgeRendererCountersReport, BridgeError> {
        self.actor.ask(RendererCounters).await
    }

    /// Chooses which renderer plays plain local videos.
    ///
    /// `"compatibility"` keeps everything on the scene engine, which supports
    /// every wallpaper. `"native_preferred"` hands a video to the platform
    /// player where its project and options fall inside the supported subset;
    /// everything else, and anything the host refuses, stays on the scene
    /// engine. The snapshot's `video_backends` reports what each display
    /// actually got.
    ///
    /// # Errors
    ///
    /// Returns an error when `mode` is not one of the two names, or when the
    /// scene list cannot be rebuilt for the new routing, in which case the
    /// previous backend keeps running.
    pub async fn set_video_backend(
        &self,
        mode: String,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        let mode = match mode.as_str() {
            "compatibility" => VideoBackendModeCfg::Compatibility,
            "native_preferred" => VideoBackendModeCfg::NativePreferred,
            other => {
                return Err(BridgeError::invalid_input(format!(
                    "unknown video backend mode {other}"
                )));
            }
        };
        self.actor.ask(SetVideoBackend { mode }).await
    }

    /// Turns the experimental native video backend on or off.
    ///
    /// # Errors
    ///
    /// Returns an error when the scene list cannot be rebuilt for the new
    /// routing, in which case the previous backend keeps running.
    pub async fn set_native_video_backend_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        let mode = if enabled {
            VideoBackendModeCfg::NativePreferred
        } else {
            VideoBackendModeCfg::Compatibility
        };
        self.actor.ask(SetVideoBackend { mode }).await
    }

    /// Sets the internal rasterization scale the user prefers.
    ///
    /// Clamped to the range the renderer honours. This is a preference: while
    /// a power profile is in force the running scale is that profile's, and
    /// the snapshot reports both.
    ///
    /// # Errors
    ///
    /// Returns an error when the preference cannot be saved or a running
    /// scene rejects the new scale.
    pub async fn set_render_scale(
        &self,
        scale: f32,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetRenderScale { scale }).await
    }

    /// Sets the quality profile used while the machine is on battery power.
    ///
    /// Disabling it restores the user's saved render scale and per-display
    /// target rates immediately, rather than waiting for the next power
    /// transition. It never changes playback, so a pause the user asked for
    /// survives.
    ///
    /// # Errors
    ///
    /// Returns an error when the profile cannot be saved or a running scene
    /// rejects the resulting scale or rate.
    pub async fn set_battery_quality_profile(
        &self,
        enabled: bool,
        render_scale: f32,
        target_fps: u32,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetBatteryQualityProfile {
                enabled,
                render_scale,
                target_fps,
            })
            .await
    }

    /// Turns content pacing on or off for the renderer process.
    ///
    /// Off by default.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_content_pacing_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetContentPacingEnabled { enabled }).await
    }

    /// Turns shared video decoding on or off for the renderer process.
    ///
    /// Off by default. Turning it on permits sharing; it does not by itself
    /// mean any decode is shared. The snapshot's session and consumer counts
    /// are where that shows up.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_shared_video_decode_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetSharedVideoDecodeEnabled { enabled }).await
    }

    /// Turns the scene renderer's static-subgraph caching and redundant
    /// copy-pass elimination on or off for the renderer process.
    ///
    /// On by default, and applied to running scenes in place: it changes how a
    /// frame is built, never what the scene is, so nothing is rebuilt and no
    /// wallpaper restarts.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_scene_optimization_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetSceneOptimizationEnabled { enabled }).await
    }

    /// Turns whole-scene on-demand updating on or off for the renderer
    /// process.
    ///
    /// Off by default. With it on, a scene the renderer can prove has no
    /// continuing reason to redraw stops its periodic tick and wakes on
    /// events; a scene it cannot prove that about keeps running. It is not a
    /// frame-rate cap, and it is not the scene optimisation setting: that one
    /// changes how a frame is built, this one changes whether one is built at
    /// all. The snapshot's `scene_update_modes` reports what each running
    /// scene actually settled on.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_scene_on_demand_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetSceneOnDemandEnabled { enabled }).await
    }

    /// Lets a native Metal scene's materials sample a video's NV12 planes
    /// directly instead of one pre-converted colour image.
    ///
    /// Off by default, and experimental. It selects between two programs that
    /// were both compiled with the scene's graph, so a running scene picks it
    /// up at its next frame boundary without being reparsed or restarted. A
    /// material with no usable plane variant, and any frame that is not 8-bit
    /// NV12, keeps converting whatever this says; nothing here changes which
    /// backend draws a scene. The snapshot's `scene_renderers` reports the
    /// path each running scene's video textures actually took.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_scene_video_plane_sampling_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetSceneVideoPlaneSamplingEnabled { enabled })
            .await
    }

    /// Chooses which renderer draws scene wallpapers.
    ///
    /// `"compatibility"` keeps every scene on the established Vulkan/MoltenVK
    /// path. `"native_metal_preferred"` asks for the native Metal backend
    /// where the whole scene falls inside the subset it can draw, and falls
    /// back as a whole scene otherwise. Independent of the video backend: a
    /// scene is not a plain video. The snapshot's `scene_renderers` reports
    /// what each display actually got.
    ///
    /// # Errors
    ///
    /// Returns an error when `mode` is not one of the two names, or when the
    /// scene list cannot be rebuilt for the new routing, in which case the
    /// previous renderer keeps running.
    pub async fn set_scene_renderer(
        &self,
        mode: String,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        let mode = match mode.as_str() {
            "compatibility" => SceneRendererModeCfg::Compatibility,
            "native_metal_preferred" => SceneRendererModeCfg::NativeMetalPreferred,
            other => {
                return Err(BridgeError::invalid_input(format!(
                    "unknown scene renderer mode {other}"
                )));
            }
        };
        self.actor.ask(SetSceneRenderer { mode }).await
    }

    /// The most recent process-wide audio analysis, or `None` when none has
    /// been produced. `None` and a spectrum with `stereo` false are different
    /// states: nothing has been analysed yet, versus a mono capture.
    ///
    /// 128 bins: 0..=63 the left channel, 64..=127 the right, low index meaning
    /// low frequency. `stereo` reports how the signal was captured, not whether
    /// the halves differ; see [`BridgeAudioSpectrum`].
    ///
    /// Synchronous on purpose: this is polled at the page's callback rate and
    /// reads a process-wide buffer that no actor owns.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the read.
    pub fn web_audio_spectrum(&self) -> Result<Option<BridgeAudioSpectrum>, BridgeError> {
        let spectrum = self
            .engine
            .current_audio_spectrum()
            .map_err(|error| BridgeError::engine(error.to_string()))?;

        Ok(spectrum.map(|spectrum| BridgeAudioSpectrum {
            generation: spectrum.generation,
            stereo: spectrum.stereo,
            bins: spectrum.bins.to_vec(),
        }))
    }

    /// Records or withdraws one web page as a live consumer of the system
    /// audio capture.
    ///
    /// A web wallpaper has no renderer scene, so without this the capture tap
    /// stays shut for a display showing only web wallpapers. Withdrawing the
    /// last consumer closes the tap again. Mute and volume are unrelated: a
    /// silenced wallpaper still analyses what the system is playing.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the capture change.
    pub async fn set_web_audio_subscribed(
        &self,
        wallpaper_id: String,
        display_id: u32,
        subscribed: bool,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(SetWebAudioSubscribed {
                wallpaper_id,
                display_id,
                subscribed,
            })
            .await
    }

    /// Turns system media integration on or off for one wallpaper.
    ///
    /// Off by default. This is the user's consent to look for a system media
    /// source, not a promise that one exists.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or the setting cannot
    /// be saved.
    pub async fn set_media_integration_enabled(
        &self,
        wallpaper_id: String,
        enabled: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetMediaIntegrationEnabled {
                wallpaper_id,
                enabled,
            })
            .await
    }

    /// Records one system media event so a page loading later can be brought
    /// up to date.
    ///
    /// The bridge neither reads the system player nor delivers to any page:
    /// the host owns both ends and this only remembers the latest event of
    /// each kind, verbatim. An event carrying a `generation` older than one
    /// already stored is dropped rather than overwriting newer state, which is
    /// what makes a late artwork fetch harmless.
    ///
    /// # Errors
    ///
    /// Returns an error when `json` is not an object or its `type` is not a
    /// media event tag.
    pub async fn submit_system_media_event(&self, json: String) -> Result<(), BridgeError> {
        let _ = self.system_media.submit(&json)?;
        self.actor
            .ask(crate::actor::messages::FanOutSystemMediaEvent { json })
            .await
    }

    /// Uploads `$mediaThumbnail` RGBA to every opted-in desktop scene.
    ///
    /// # Errors
    ///
    /// Returns an error when the payload is not `width * height * 4` bytes or
    /// the renderer rejects the upload.
    pub async fn apply_system_media_artwork(
        &self,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(crate::actor::messages::FanOutSystemMediaArtwork {
                width,
                height,
                rgba,
            })
            .await
    }

    /// Which applied desktop scenes have consented to now-playing.
    ///
    /// The host starts and stops its system media source from this, so a
    /// machine whose wallpapers all have the setting off is never asked for
    /// Automation permission and nothing reads what is playing. A handle that
    /// was not in the previous answer is a scene with no media state yet, which
    /// is what tells the host to replay what it already knows.
    ///
    /// # Errors
    ///
    /// Returns an error when the bridge actor is gone.
    /// Waits for the next `engine.openUserShortcut` request from a wallpaper
    /// whose user has consented to media integration.
    ///
    /// Long-polls rather than returning immediately: a press is rare, and a
    /// caller that had to ask repeatedly would burn wakeups finding nothing.
    /// The wait happens outside the actor, so it stalls no other request.
    ///
    /// Requests from wallpapers without that consent are dropped here rather
    /// than handed on -- a wallpaper the user has not let near their media must
    /// not reach a media player through this.
    ///
    /// # Errors
    ///
    /// Returns an error when the engine has shut the channel.
    pub async fn next_user_shortcut(&self) -> Result<BridgeUserShortcut, BridgeError> {
        loop {
            let event = {
                let mut receiver = self.user_shortcuts.lock().await;
                receiver.recv().await
            };
            let Some(event) = event else {
                log::warn!("the user shortcut channel closed: every sender was dropped");
                return Err(BridgeError::engine("the engine stopped reporting user shortcuts"));
            };
            // Consent, not liveness: this asks whether the user allowed this
            // wallpaper near their media, which does not stop being true
            // because playback is paused or a display went dark.
            // A momentary failure to read consent is not a reason to stop
            // taking presses; the caller would have to treat it as the channel
            // having closed, which is permanent.
            let consented = match self.system_media_consent_handles().await {
                Ok(handles) => handles,
                Err(error) => {
                    log::warn!("could not read media consent for a user shortcut: {error}");
                    continue;
                }
            };
            if consented.contains(&event.scene_handle) {
                return Ok(event);
            }
            // A press is rare and deliberate, and being dropped here is
            // indistinguishable from never having been reported at all.
            log::info!(
                "ignored user shortcut {} from scene handle {}, which has no media consent; consented: {:?}",
                event.property,
                event.scene_handle,
                consented
            );
        }
    }

    pub async fn system_media_scene_handles(&self) -> Result<Vec<u64>, BridgeError> {
        self.actor
            .ask(crate::actor::messages::GetSystemMediaSceneHandles)
            .await
    }

    /// Handles whose user allowed media integration, whether or not they are
    /// currently being fed. Use `system_media_scene_handles` to decide whether
    /// to consume at all.
    ///
    /// # Errors
    ///
    /// Returns an error when the bridge actor is gone.
    pub async fn system_media_consent_handles(&self) -> Result<Vec<u64>, BridgeError> {
        self.actor
            .ask(crate::actor::messages::GetSystemMediaConsentHandles)
            .await
    }

    /// Every retained media event as a JSON array, in replay order, or `None`
    /// when nothing has been submitted yet.
    #[must_use]
    pub fn current_system_media_state(&self) -> Option<String> {
        self.system_media.current_state_json()
    }

    /// Running scene wallpapers whose users enabled music information.
    pub async fn scene_media_wallpaper_ids(&self) -> Result<Vec<String>, BridgeError> {
        self.actor.ask(crate::actor::messages::GetSceneMediaWallpapers).await
    }

    /// Publishes a bounded player snapshot; delivery rechecks per-wallpaper consent.
    pub async fn update_scene_media(&self, wallpaper_id: String, snapshot: BridgeMediaSnapshot) -> Result<(), BridgeError> {
        let state = snapshot.into_state()?;
        self.actor.ask(crate::actor::messages::UpdateSceneMedia { wallpaper_id, state }).await
    }

    /// Stores the path the host staged for a file or directory property, or
    /// clears it when `path` is `None`.
    ///
    /// The value is persisted exactly as given and reaches the page's
    /// `applyUserProperties` unchanged. The host decides what a page can open,
    /// so nothing here rewrites, resolves or escapes the path. Refused for any
    /// other property kind, including texture pickers, which name scene assets
    /// rather than paths.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper or property id is unknown, the
    /// property is not a file or directory property, or the value cannot be
    /// saved.
    pub async fn set_property_path(
        &self,
        wallpaper_id: String,
        property_id: String,
        path: Option<String>,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetPropertyPath {
                wallpaper_id,
                property_id,
                path,
            })
            .await
    }

    /// Plain local videos the host should play natively. Empty while the
    /// backend is off.
    ///
    /// # Errors
    ///
    /// Returns an error when a media path cannot be represented.
    pub async fn native_video_wallpapers(
        &self,
    ) -> Result<Vec<BridgeNativeVideoWallpaper>, BridgeError> {
        self.actor.ask(GetNativeVideoWallpapers).await
    }

    /// Hands a wallpaper back to the scene engine because the native player
    /// cannot honour it — an unsupported target frame rate, for example.
    ///
    /// `admission_key` is the key of the descriptor the host judged. The
    /// refusal is recorded against that key and holds for the rest of the
    /// session, so a wallpaper cannot oscillate between the two backends; it
    /// stops applying as soon as the configuration it describes changes. A key
    /// that already does not match the live configuration is a refusal that
    /// lost a race with the user and is dropped.
    ///
    /// # Errors
    ///
    /// Returns an error when the scene list cannot be rebuilt.
    pub async fn reject_native_video(
        &self,
        wallpaper_id: String,
        admission_key: u64,
        reason: String,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(RejectNativeVideo {
                wallpaper_id,
                admission_key,
                reason,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id, property id, or value is
    /// invalid.
    pub async fn edit_property(
        &self,
        wallpaper_id: String,
        property_id: String,
        value: BridgePropertyValue,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(EditProperty {
                wallpaper_id,
                property_id,
                value,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or property id is unknown.
    pub async fn restore_property_default(
        &self,
        wallpaper_id: String,
        property_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(RestorePropertyDefault {
                wallpaper_id,
                property_id,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when pending options cannot be applied or persisted.
    pub async fn apply_wallpaper_options(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor.ask(ApplyWallpaperOptions { wallpaper_id }).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown.
    pub async fn cancel_wallpaper_options(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(CancelWallpaperOptions { wallpaper_id })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when pending options cannot be applied or persisted.
    pub async fn ok_wallpaper_options(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.apply_wallpaper_options(wallpaper_id).await
    }

    /// # Errors
    ///
    /// Returns an error when the engine cannot pause all scenes.
    pub async fn pause_all(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetGlobalPlayback {
                playback_state: BridgePlaybackState::Paused,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the engine cannot resume all scenes.
    pub async fn play_all(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetGlobalPlayback {
                playback_state: BridgePlaybackState::Playing,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display update cannot be committed.
    pub async fn eject_wallpaper_from_display(
        &self,
        display_id: String,
        wallpaper_id: String,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(EjectWallpaperFromDisplay {
                display_id,
                wallpaper_id,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the engine cannot shut down active scenes.
    pub async fn shutdown(&self) -> Result<(), BridgeError> {
        self.actor.ask(Shutdown).await
    }
}

#[cfg(test)]
impl WallpaperBridge {
    /// # Panics
    ///
    /// Panics if the test bridge actor cannot be spawned.
    #[must_use]
    pub fn new_for_test() -> Self {
        BridgeBuilder::new(FakeEngineFacade::default())
            .build()
            .expect("tokio runtime and config load for wallpaper bridge")
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test wallpaper injection.
    pub async fn inject_wallpaper_for_test(
        &self,
        id: &str,
        title: &str,
        kind: BridgeWallpaperKind,
    ) {
        self.actor
            .ask(InjectWallpaperForTest {
                id: id.to_string(),
                title: title.to_string(),
                kind,
            })
            .await
            .expect("test wallpaper injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test scene wallpaper config injection.
    pub async fn inject_scene_wallpaper_config_for_test(&self, id: &str, title: &str) {
        self.actor
            .ask(InjectSceneWallpaperConfigForTest {
                id: id.to_string(),
                title: title.to_string(),
            })
            .await
            .expect("test scene wallpaper config injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test scene project injection.
    pub async fn inject_scene_project_for_test(&self, id: &str, title: &str, project_json: &str) {
        self.actor
            .ask(InjectSceneProjectForTest {
                id: id.to_string(),
                title: title.to_string(),
                project_json: project_json.to_string(),
            })
            .await
            .expect("test scene project injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test display injection.
    pub async fn inject_display_for_test(&self, display_id: &str, title: &str) {
        self.actor
            .ask(InjectDisplayForTest {
                display_id: display_id.to_string(),
                title: title.to_string(),
            })
            .await
            .expect("test display injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test library replacement.
    pub async fn replace_library_for_test(&self, entries: Vec<BridgeWallpaperEntry>) {
        self.actor
            .ask(ReplaceLibraryForTest { entries })
            .await
            .expect("test library replacement should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test wallpaper config replacement.
    pub async fn replace_wallpaper_config_for_test(&self, id: &str, config: WallpaperConfig) {
        self.actor
            .ask(ReplaceWallpaperConfigForTest {
                id: id.to_string(),
                config,
            })
            .await
            .expect("test wallpaper config replacement should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test power source update.
    pub async fn set_power_source_for_test(&self, source: crate::power::PowerSource) {
        self.actor
            .ask(SetPowerSource {
                source,
                initial_sample: false,
            })
            .await
            .expect("test power source update should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test initial power source update.
    pub async fn set_initial_power_source_for_test(&self, source: crate::power::PowerSource) {
        self.actor
            .ask(SetPowerSource {
                source,
                initial_sample: true,
            })
            .await
            .expect("test initial power source update should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test initial-frame readiness update.
    pub async fn initial_frame_ready_for_test(&self) {
        self.actor
            .ask(InitialFrameReady)
            .await
            .expect("test initial-frame readiness update should succeed");
    }
}

impl From<&crate::library::WallpaperEntry> for BridgeWallpaperEntry {
    fn from(entry: &crate::library::WallpaperEntry) -> Self {
        Self {
            id: entry.workshop_id.clone(),
            title: entry.title.clone(),
            kind: BridgeWallpaperKind::from(entry.project_type),
            supported: entry.supported,
            active: false,
            selected: false,
            preview_path: entry
                .preview_path
                .as_ref()
                .map(|path| path.to_string_lossy().to_string()),
        }
    }
}

impl From<BridgeScalingMode> for ScalingMode {
    fn from(value: BridgeScalingMode) -> Self {
        match value {
            BridgeScalingMode::None => Self::None,
            BridgeScalingMode::Stretch => Self::Stretch,
            BridgeScalingMode::Match => Self::Fit,
            BridgeScalingMode::Fill => Self::Fill,
        }
    }
}

impl From<ScalingMode> for BridgeScalingMode {
    fn from(value: ScalingMode) -> Self {
        match value {
            ScalingMode::None => Self::None,
            ScalingMode::Stretch => Self::Stretch,
            ScalingMode::Fit => Self::Match,
            ScalingMode::Fill => Self::Fill,
        }
    }
}

impl From<&crate::project::PropertyKind> for BridgePropertyKind {
    fn from(value: &crate::project::PropertyKind) -> Self {
        match value {
            crate::project::PropertyKind::Slider => Self::Slider,
            crate::project::PropertyKind::Combo => Self::Combo,
            crate::project::PropertyKind::Bool => Self::Bool,
            crate::project::PropertyKind::Color => Self::Color,
            crate::project::PropertyKind::TextInput => Self::TextInput,
            crate::project::PropertyKind::Text => Self::Text,
            crate::project::PropertyKind::Group => Self::Group,
            crate::project::PropertyKind::File => Self::File,
            crate::project::PropertyKind::Directory => Self::Directory,
            crate::project::PropertyKind::Texture => Self::Texture,
            crate::project::PropertyKind::Unknown(_) => Self::Unknown,
        }
    }
}

impl From<crate::project::PropertyValue> for BridgePropertyValue {
    fn from(value: crate::project::PropertyValue) -> Self {
        match value {
            crate::project::PropertyValue::Bool(value) => Self::Bool { value },
            crate::project::PropertyValue::Number(value) => Self::Number { value },
            crate::project::PropertyValue::String(value) => Self::String { value },
            crate::project::PropertyValue::ColorRgb(red, green, blue) => Self::ColorRgb {
                red: f64::from(red),
                green: f64::from(green),
                blue: f64::from(blue),
            },
            crate::project::PropertyValue::Null => Self::Empty,
        }
    }
}

#[allow(clippy::cast_possible_truncation)]
impl From<BridgePropertyValue> for crate::project::PropertyValue {
    fn from(value: BridgePropertyValue) -> Self {
        match value {
            BridgePropertyValue::Bool { value } => Self::Bool(value),
            BridgePropertyValue::Number { value } => Self::Number(value),
            BridgePropertyValue::String { value } => Self::String(value),
            BridgePropertyValue::ColorRgb { red, green, blue } => {
                Self::ColorRgb(red as f32, green as f32, blue as f32)
            }
            BridgePropertyValue::Empty => Self::Null,
        }
    }
}

#[cfg(test)]
mod mouse_polling_tests {
    use super::MousePollingControl;
    use std::sync::{Arc, Barrier, mpsc};
    use std::time::Duration;

    #[test]
    fn policy_and_consumer_changes_never_overwrite_each_other() {
        let control = MousePollingControl::new();
        control.set_policy_enabled(true);
        assert!(!control.is_enabled());
        control.set_has_consumers(true);
        assert!(control.is_enabled());
        control.set_policy_enabled(false);
        control.set_has_consumers(false);
        control.set_has_consumers(true);
        assert!(!control.is_enabled());
        control.set_policy_enabled(true);
        assert!(control.is_enabled());
        control.set_has_consumers(false);
        control.set_policy_enabled(false);
        control.set_policy_enabled(true);
        assert!(!control.is_enabled());
        control.stop();
        control.set_has_consumers(true);
        control.set_policy_enabled(true);
        assert!(!control.is_enabled());
        assert!(!control.wait_until_enabled());
        assert!(!control.wait_interval(Duration::from_millis(16)));
    }

    #[test]
    fn consumer_arrival_wakes_waiter_and_stop_wakes_ineligible_waiter() {
        for activate in [false, true] {
            let control = Arc::new(MousePollingControl::new());
            control.set_policy_enabled(true);
            let started = Arc::new(Barrier::new(2));
            let (send, receive) = mpsc::channel();
            let worker_control = control.clone();
            let worker_started = started.clone();
            let worker = std::thread::spawn(move || {
                worker_started.wait();
                send.send(worker_control.wait_until_enabled()).unwrap();
            });
            started.wait();
            if activate {
                control.set_has_consumers(true);
            } else {
                control.stop();
                control.set_has_consumers(true);
            }
            assert_eq!(receive.recv_timeout(Duration::from_secs(1)).unwrap(), activate);
            worker.join().unwrap();
        }
    }

    #[test]
    fn poisoned_control_fails_closed_and_rejects_late_callbacks() {
        let control = Arc::new(MousePollingControl::new());
        control.set_policy_enabled(true);
        control.set_has_consumers(true);
        let poisoned = control.clone();
        assert!(std::thread::spawn(move || {
            let Ok(_guard) = poisoned.state.lock() else {
                panic!("control was already poisoned");
            };
            panic!("injected control poison");
        }).join().is_err());
        assert!(!control.is_enabled());
        control.set_has_consumers(true);
        control.set_policy_enabled(true);
        assert!(!control.wait_until_enabled());
        assert!(!control.wait_interval(Duration::from_millis(16)));
    }
}
