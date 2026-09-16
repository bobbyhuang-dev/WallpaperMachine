#[cfg(test)]
use std::{sync::mpsc::Receiver, time::Duration};
use std::{
    sync::{
        Arc,
        mpsc::{self, Sender},
    },
    thread,
};

#[cfg(test)]
use arc_swap::ArcSwap;
#[cfg(test)]
use crossbeam_queue::SegQueue;
use futures_util::future::{BoxFuture, FutureExt};
#[cfg(test)]
use wallpaper_core::project::SceneTemplate;
use wallpaper_core::{
    DisplaySelector, DisplaySnapshotEntry, EngineError, FirstFrameCallback, WallpaperAssignment,
    WallpaperEngine,
    media::audio::{AudioCaptureController, AudioVolume, PlatformAudioCaptureBackend},
    project::{ScalingMode, SceneDesc, SceneHandle, SceneResult},
};

pub type EngineFuture<T> = BoxFuture<'static, Result<T, EngineError>>;

pub trait EngineFacade: Send + Sync + 'static {
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>>;
    fn refresh_displays(&self) -> EngineFuture<()>;
    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry>;
    fn close_all_scenes(&self) -> EngineFuture<()>;
    fn set_all_paused(&self, paused: bool) -> EngineFuture<()>;
    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()>;
    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()>;
    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()>;
    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()>;
    fn set_scaling_mode(&self, handle: SceneHandle, mode: ScalingMode) -> EngineFuture<()>;
    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()>;
    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()>;
    fn poll_mouse_position(&self) -> EngineFuture<()>;
    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()>;
    fn set_mouse_button(&self, handle: SceneHandle, button: u32, pressed: bool)
    -> EngineFuture<()>;
    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()>;
    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>>;
    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>>;
    fn set_first_frame_callback(&self, callback: FirstFrameCallback);
    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    );
    /// Globally suspends or resumes system-audio capture. Per-scene audio
    /// response settings are preserved across the transition.
    fn set_audio_capture_suspended(&self, suspended: bool) -> EngineFuture<()> {
        let _ = suspended;
        async move { Ok(()) }.boxed()
    }
}

#[derive(Clone)]
pub struct RealEngineFacade {
    engine: WallpaperEngine,
    audio_capture: AudioCaptureWorker,
    audio_mutation: Arc<tokio::sync::Mutex<()>>,
    ready_frames: Arc<std::sync::Mutex<std::collections::HashMap<SceneHandle, u64>>>,
    rendered_scenes: Arc<tokio::sync::Mutex<Vec<SceneDesc>>>,
}

impl RealEngineFacade {
    #[must_use]
    pub fn new(engine: WallpaperEngine) -> Self {
        Self {
            audio_capture: AudioCaptureWorker::spawn(engine.clone()),
            audio_mutation: Arc::default(),
            ready_frames: Arc::default(),
            rendered_scenes: Arc::default(),
            engine,
        }
    }
}

impl EngineFacade for RealEngineFacade {
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>> {
        let engine = self.engine.clone();
        let ready_frames = self.ready_frames.clone();
        let rendered_scenes = self.rendered_scenes.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let mut previous = rendered_scenes.lock().await;
            let before = ready_frames.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let changed: Vec<u32> = scenes.iter().filter(|scene| {
                !previous.iter().any(|old| old.display.display_id == scene.display.display_id
                    && old.same_wallpaper(scene) && old.display == scene.display)
            }).map(|scene| scene.display.display_id).collect();
            let results = {
                let _audio_guard = audio_mutation.lock().await;
                let results = engine.reconcile_scenes(scenes.clone()).await;
                audio_capture.retain_scenes().await.map_err(EngineError::Platform)?;
                results?
            };
            *previous = scenes;
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
            loop {
                let ready = {
                    let frames = ready_frames.lock().unwrap_or_else(|e| e.into_inner());
                    results.iter().filter(|r| changed.contains(&r.display_id)).all(|r| {
                        frames.get(&r.handle).copied().unwrap_or(0) > before.get(&r.handle).copied().unwrap_or(0)
                    })
                };
                if ready { break; }
                if std::time::Instant::now() >= deadline {
                    return Err(EngineError::Render("The wallpaper did not render a first frame within 20 seconds. Check the project files and shared scene assets; this wallpaper may use unsupported effects. Your previous configuration will be restored.".into()));
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
            Ok(results)
        }.boxed()
    }

    fn refresh_displays(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            let result = engine.refresh_displays().await;
            audio_capture
                .retain_scenes()
                .await
                .map_err(EngineError::Platform)?;
            result
        }
        .boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.engine.display_snapshot()
    }

    fn close_all_scenes(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            let result = engine.close_all_scenes().await;
            audio_capture
                .retain_scenes()
                .await
                .map_err(EngineError::Platform)?;
            result
        }
        .boxed()
    }

    fn set_all_paused(&self, paused: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_all_paused(paused).await }.boxed()
    }

    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_volume(handle, volume).await }.boxed()
    }

    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_muted(handle, muted).await }.boxed()
    }

    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_audio_response_enabled(handle, enabled).await }.boxed()
    }

    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        let engine = self.engine.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            // Capture ownership must be released even if its renderer has disappeared.
            if !enabled {
                audio_capture
                    .set_enabled(handle, false)
                    .await
                    .map_err(EngineError::Platform)?;
                if engine
                    .display_snapshot()
                    .iter()
                    .any(|display| display.handle == Some(handle))
                {
                    engine.set_audio_response_enabled(handle, false).await?;
                }
                return Ok(());
            }
            audio_capture
                .set_enabled(handle, true)
                .await
                .map_err(EngineError::Platform)?;
            if let Err(error) = engine.set_audio_response_enabled(handle, true).await {
                let _ = audio_capture.set_enabled(handle, false).await;
                return Err(error);
            }
            Ok(())
        }
        .boxed()
    }

    fn set_audio_capture_suspended(&self, suspended: bool) -> EngineFuture<()> {
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            audio_capture
                .set_suspended(suspended)
                .await
                .map_err(EngineError::Platform)
        }
        .boxed()
    }

    fn set_scaling_mode(&self, handle: SceneHandle, mode: ScalingMode) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_scaling_mode(handle, mode).await }.boxed()
    }

    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_scaling_factor(handle, factor).await }.boxed()
    }

    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_fps(handle, fps).await }.boxed()
    }

    fn poll_mouse_position(&self) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.poll_mouse_position().await }.boxed()
    }

    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_position(handle, x, y).await }.boxed()
    }

    fn set_mouse_button(
        &self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_button(handle, button, pressed).await }.boxed()
    }

    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()> {
        let engine = self.engine.clone();
        async move { engine.set_mouse_entered(handle, entered).await }.boxed()
    }

    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>> {
        let engine = self.engine.clone();
        async move { engine.create_window_for_display(selector).await }.boxed()
    }

    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>> {
        let engine = self.engine.clone();
        let audio_capture = self.audio_capture.clone();
        let audio_mutation = self.audio_mutation.clone();
        async move {
            let _audio_guard = audio_mutation.lock().await;
            let result = engine.set_wallpaper_for_display(selector, assignment).await;
            audio_capture
                .retain_scenes()
                .await
                .map_err(EngineError::Platform)?;
            result
        }
        .boxed()
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        let frames = self.ready_frames.clone();
        self.engine
            .set_first_frame_callback(Arc::new(move |handle| {
                *frames
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .entry(handle)
                    .or_default() += 1;
                callback(handle);
            }));
    }

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        self.engine.set_pointer_consumer_callback(callback);
    }
}

#[derive(Clone)]
struct AudioCaptureWorker {
    sender: Sender<AudioCaptureCommand>,
}

enum AudioCaptureCommand {
    SetEnabled {
        handle: SceneHandle,
        enabled: bool,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    SetSuspended {
        suspended: bool,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    RetainScenes {
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
}

enum AudioCaptureRequest {
    Scene { handle: SceneHandle, enabled: bool },
    Suspend { suspended: bool },
}

impl AudioCaptureWorker {
    fn spawn(engine: WallpaperEngine) -> Self {
        let (sender, receiver) = mpsc::channel::<AudioCaptureCommand>();
        thread::Builder::new()
            .name("wallpaper-bridge-audio-capture".to_string())
            .spawn(move || {
                let mut controller = PlatformAudioCaptureBackend::new()
                    .map(|backend| AudioCaptureController::new(Arc::new(engine.clone()), backend))
                    .map_err(|error| error.to_string());
                while let Ok(command) = receiver.recv() {
                    let (request, reply) = match command {
                        AudioCaptureCommand::SetEnabled { handle, enabled, reply } =>
                            (Some(AudioCaptureRequest::Scene { handle, enabled }), reply),
                        AudioCaptureCommand::SetSuspended { suspended, reply } =>
                            (Some(AudioCaptureRequest::Suspend { suspended }), reply),
                        AudioCaptureCommand::RetainScenes { reply } => (None, reply),
                    };
                    let result = (|| {
                        let controller = controller.as_mut().map_err(|error| error.clone())?;
                        let handles: Vec<_> = engine.display_snapshot().iter()
                            .filter_map(|display| display.handle).collect();
                        controller.retain_scenes(&handles).map_err(|error| error.to_string())?;
                        match request {
                            Some(AudioCaptureRequest::Suspend { suspended }) => {
                                controller.set_suspended(suspended)
                                    .map_err(|error| error.to_string())?;
                            }
                            Some(AudioCaptureRequest::Scene { handle, enabled }) => {
                                if enabled {
                                    if !handles.contains(&handle) {
                                        return Err("The wallpaper is no longer active.".to_string());
                                    }
                                    // Core Audio performs the system authorization at capture startup.
                                    if !controller.has_permission().map_err(|error| error.to_string())?
                                        && !controller.request_permission().map_err(|error| error.to_string())? {
                                        return Err("System audio capture permission was not granted.".to_string());
                                    }
                                }
                                controller.set_scene_capturing(handle, enabled)
                                    .map_err(|error| format!("Audio response could not {}: {error}. Check MacWallpaperEngine in System Settings > Privacy & Security > Screen & System Audio Recording.", if enabled { "start" } else { "stop" }))?;
                            }
                            None => {}
                        }
                        Ok(())
                    })();
                    let _ = reply.send(result);
                }
            })
            .expect("audio capture worker thread should start");
        Self { sender }
    }

    async fn set_enabled(&self, handle: SceneHandle, enabled: bool) -> Result<(), String> {
        let (reply, response) = tokio::sync::oneshot::channel();
        self.sender
            .send(AudioCaptureCommand::SetEnabled {
                handle,
                enabled,
                reply,
            })
            .map_err(|error| format!("audio capture worker stopped: {error}"))?;
        response
            .await
            .map_err(|error| format!("audio capture worker did not reply: {error}"))?
    }

    async fn retain_scenes(&self) -> Result<(), String> {
        let (reply, response) = tokio::sync::oneshot::channel();
        self.sender
            .send(AudioCaptureCommand::RetainScenes { reply })
            .map_err(|error| format!("audio capture worker stopped: {error}"))?;
        response
            .await
            .map_err(|error| format!("audio capture worker did not reply: {error}"))?
    }

    async fn set_suspended(&self, suspended: bool) -> Result<(), String> {
        let (reply, response) = tokio::sync::oneshot::channel();
        self.sender
            .send(AudioCaptureCommand::SetSuspended { suspended, reply })
            .map_err(|error| format!("audio capture worker stopped: {error}"))?;
        response
            .await
            .map_err(|error| format!("audio capture worker did not reply: {error}"))?
    }
}

#[cfg(test)]
#[derive(Clone, Default)]
pub struct FakeEngineFacade {
    calls: Arc<ArcSwap<Vec<Vec<SceneDesc>>>>,
    rendered_scenes: Arc<ArcSwap<Vec<SceneDesc>>>,
    snapshot: Arc<ArcSwap<Vec<DisplaySnapshotEntry>>>,
    pointer_consumer: Arc<std::sync::Mutex<PointerConsumerObserver>>,
    snapshot_after_refresh: Arc<ArcSwap<Option<Vec<DisplaySnapshotEntry>>>>,
    refresh_failure: Arc<ArcSwap<Option<String>>>,
    paused_calls: Arc<ArcSwap<Vec<bool>>>,
    pause_failure: Arc<ArcSwap<Option<String>>>,
    suspend_failure: Arc<ArcSwap<Option<String>>>,
    disable_capture_failure: Arc<ArcSwap<Option<String>>>,
    close_failure: Arc<ArcSwap<Option<String>>>,
    audio_volume_calls: Arc<ArcSwap<Vec<(SceneHandle, f32)>>>,
    audio_muted_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    audio_response_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    audio_capture_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    audio_capture_suspend_calls: Arc<ArcSwap<Vec<bool>>>,
    audio_capture_suspended: Arc<ArcSwap<bool>>,
    audio_capture_block: Arc<SegQueue<ReconcileBlockGate>>,
    audio_capture_failure: Arc<ArcSwap<Option<String>>>,
    scaling_mode_calls: Arc<ArcSwap<Vec<(SceneHandle, ScalingMode)>>>,
    scaling_factor_calls: Arc<ArcSwap<Vec<(SceneHandle, f64)>>>,
    fps_calls: Arc<ArcSwap<Vec<(SceneHandle, u32)>>>,
    mouse_poll_calls: Arc<ArcSwap<Vec<()>>>,
    mouse_poll_block: Arc<SegQueue<ReconcileBlockGate>>,
    mouse_input: Arc<ArcSwap<(f64, f64)>>,
    mouse_samples: Arc<ArcSwap<Vec<(f64, f64)>>>,
    mouse_position_calls: Arc<ArcSwap<Vec<(SceneHandle, f64, f64)>>>,
    mouse_button_calls: Arc<ArcSwap<Vec<(SceneHandle, u32, bool)>>>,
    mouse_entered_calls: Arc<ArcSwap<Vec<(SceneHandle, bool)>>>,
    window_create_calls: Arc<ArcSwap<Vec<DisplaySelector>>>,
    wallpaper_calls: Arc<ArcSwap<Vec<(DisplaySelector, WallpaperAssignment)>>>,
    reconcile_failure: Arc<ArcSwap<Option<String>>>,
    reconcile_block: Arc<SegQueue<ReconcileBlockGate>>,
    reconcile_done: Arc<SegQueue<Sender<()>>>,
    first_frame_callback: Arc<ArcSwap<Option<FirstFrameCallback>>>,
}

#[cfg(test)]
#[derive(Default)]
struct PointerConsumerObserver {
    callback: Option<wallpaper_core::PointerConsumerCallback>,
    has_consumers: bool,
}

#[cfg(test)]
pub struct ReconcileBlock {
    blocked_rx: Receiver<()>,
    release_tx: Sender<()>,
}

#[cfg(test)]
pub struct ReconcileDone {
    done_rx: Receiver<()>,
}

#[cfg(test)]
struct ReconcileBlockGate {
    blocked_tx: Sender<()>,
    release_rx: Receiver<()>,
}

#[cfg(test)]
fn load_log<T: Clone>(log: &ArcSwap<Vec<T>>) -> Vec<T> {
    log.load_full().as_ref().clone()
}

#[cfg(test)]
fn push_log<T: Clone>(log: &ArcSwap<Vec<T>>, value: T) {
    log.rcu(|current| {
        let mut next = current.as_ref().clone();
        next.push(value.clone());
        next
    });
}

#[cfg(test)]
fn complete_reconcile_waiters(waiters: &SegQueue<Sender<()>>) {
    while let Some(waiter) = waiters.pop() {
        let _ = waiter.send(());
    }
}

#[cfg(test)]
impl ReconcileBlock {
    #[must_use]
    pub fn wait_until_blocked(&self, timeout: Duration) -> bool {
        self.blocked_rx.recv_timeout(timeout).is_ok()
    }

    pub fn release(&self) {
        let _ = self.release_tx.send(());
    }
}

#[cfg(test)]
impl ReconcileDone {
    #[must_use]
    pub fn wait(self, timeout: Duration) -> bool {
        self.done_rx.recv_timeout(timeout).is_ok()
    }
}

#[cfg(test)]
impl FakeEngineFacade {
    #[must_use]
    pub fn calls(&self) -> Vec<Vec<SceneDesc>> {
        load_log(&self.calls)
    }

    #[must_use]
    pub fn rendered_scenes(&self) -> Vec<SceneDesc> {
        self.rendered_scenes.load_full().as_ref().clone()
    }

    #[must_use]
    pub fn audio_capture_suspended(&self) -> bool {
        **self.audio_capture_suspended.load()
    }

    pub fn set_snapshot(&self, snapshot: Vec<DisplaySnapshotEntry>) {
        self.publish_snapshot(|_| snapshot);
    }

    fn publish_snapshot(&self, update: impl FnOnce(&[DisplaySnapshotEntry]) -> Vec<DisplaySnapshotEntry>) {
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        let snapshot = Arc::new(update(self.snapshot.load().as_ref()));
        let has_consumers = snapshot.iter().any(|display| {
            display.handle.is_some() && display.accepts_pointer_input
        });
        self.snapshot.store(snapshot);
        if observer.has_consumers != has_consumers {
            observer.has_consumers = has_consumers;
            if let Some(callback) = &observer.callback {
                callback(has_consumers);
            }
        }
    }

    pub fn set_snapshot_after_refresh(&self, snapshot: Vec<DisplaySnapshotEntry>) {
        self.snapshot_after_refresh.store(Arc::new(Some(snapshot)));
    }

    #[must_use]
    pub fn paused_calls(&self) -> Vec<bool> {
        load_log(&self.paused_calls)
    }

    #[must_use]
    pub fn audio_volume_calls(&self) -> Vec<(SceneHandle, f32)> {
        load_log(&self.audio_volume_calls)
    }

    #[must_use]
    pub fn audio_muted_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.audio_muted_calls)
    }

    #[must_use]
    pub fn audio_response_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.audio_response_calls)
    }

    #[must_use]
    pub fn audio_capture_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.audio_capture_calls)
    }

    #[must_use]
    pub fn audio_capture_suspend_calls(&self) -> Vec<bool> {
        load_log(&self.audio_capture_suspend_calls)
    }

    #[must_use]
    pub fn scaling_mode_calls(&self) -> Vec<(SceneHandle, ScalingMode)> {
        load_log(&self.scaling_mode_calls)
    }

    #[must_use]
    pub fn scaling_factor_calls(&self) -> Vec<(SceneHandle, f64)> {
        load_log(&self.scaling_factor_calls)
    }

    #[must_use]
    pub fn fps_calls(&self) -> Vec<(SceneHandle, u32)> {
        load_log(&self.fps_calls)
    }

    #[must_use]
    pub fn mouse_poll_calls(&self) -> Vec<()> {
        load_log(&self.mouse_poll_calls)
    }

    pub fn set_mouse_input(&self, x: f64, y: f64) {
        self.mouse_input.store(Arc::new((x, y)));
    }

    pub fn mouse_samples(&self) -> Vec<(f64, f64)> {
        load_log(&self.mouse_samples)
    }

    pub fn fail_next_pause(&self) {
        self.pause_failure
            .store(Arc::new(Some("pause failed".into())));
    }

    pub fn fail_next_suspend(&self) {
        self.suspend_failure
            .store(Arc::new(Some("audio suspend failed".into())));
    }

    pub fn fail_next_disable_capture(&self) {
        self.disable_capture_failure
            .store(Arc::new(Some("audio disable failed".into())));
    }

    pub fn fail_next_close(&self) {
        self.close_failure
            .store(Arc::new(Some("close failed".into())));
    }

    pub fn fail_next_refresh(&self) {
        self.refresh_failure
            .store(Arc::new(Some("refresh failed after partial commit".into())));
    }

    #[must_use]
    pub fn mouse_position_calls(&self) -> Vec<(SceneHandle, f64, f64)> {
        load_log(&self.mouse_position_calls)
    }

    #[must_use]
    pub fn mouse_button_calls(&self) -> Vec<(SceneHandle, u32, bool)> {
        load_log(&self.mouse_button_calls)
    }

    #[must_use]
    pub fn mouse_entered_calls(&self) -> Vec<(SceneHandle, bool)> {
        load_log(&self.mouse_entered_calls)
    }

    #[must_use]
    pub fn window_create_calls(&self) -> Vec<DisplaySelector> {
        load_log(&self.window_create_calls)
    }

    #[must_use]
    pub fn wallpaper_calls(&self) -> Vec<(DisplaySelector, WallpaperAssignment)> {
        load_log(&self.wallpaper_calls)
    }

    pub fn fail_reconcile_with(&self, message: impl Into<String>) {
        self.reconcile_failure.store(Arc::new(Some(message.into())));
    }

    pub fn fail_audio_capture_with(&self, message: Option<String>) {
        self.audio_capture_failure.store(Arc::new(message));
    }

    #[must_use]
    pub fn block_next_reconcile(&self) -> ReconcileBlock {
        let (blocked_tx, blocked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let gate = ReconcileBlockGate {
            blocked_tx,
            release_rx,
        };
        self.reconcile_block.push(gate);

        ReconcileBlock {
            blocked_rx,
            release_tx,
        }
    }

    #[must_use]
    pub fn block_next_audio_capture(&self) -> ReconcileBlock {
        let (blocked_tx, blocked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let gate = ReconcileBlockGate {
            blocked_tx,
            release_rx,
        };
        self.audio_capture_block.push(gate);

        ReconcileBlock {
            blocked_rx,
            release_tx,
        }
    }

    #[must_use]
    pub fn block_next_mouse_poll(&self) -> ReconcileBlock {
        let (blocked_tx, blocked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let gate = ReconcileBlockGate {
            blocked_tx,
            release_rx,
        };
        self.mouse_poll_block.push(gate);

        ReconcileBlock {
            blocked_rx,
            release_tx,
        }
    }

    #[must_use]
    pub fn wait_for_next_reconcile(&self) -> ReconcileDone {
        let (done_tx, done_rx) = mpsc::channel();
        self.reconcile_done.push(done_tx);

        ReconcileDone { done_rx }
    }

    fn update_direct_assignment(&self, handle: SceneHandle, update: impl Fn(&mut SceneTemplate)) {
        self.snapshot.rcu(|current| {
            let mut next = current.as_ref().clone();
            if let Some(WallpaperAssignment::Direct(template)) = next
                .iter_mut()
                .find(|entry| entry.handle == Some(handle))
                .and_then(|entry| entry.assignment.as_mut())
            {
                update(template);
            }
            next
        });
    }

    fn update_direct_assignment_after_refresh(
        &self,
        handle: SceneHandle,
        update: impl Fn(&mut SceneTemplate),
    ) {
        self.snapshot_after_refresh.rcu(|current| {
            let Some(current) = current.as_ref() else {
                return None;
            };
            let mut next = current.clone();
            if let Some(WallpaperAssignment::Direct(template)) = next
                .iter_mut()
                .find(|entry| entry.handle == Some(handle))
                .and_then(|entry| entry.assignment.as_mut())
            {
                update(template);
            }
            Some(next)
        });
    }

    pub fn trigger_first_frame(&self, handle: SceneHandle) {
        let callback = self.first_frame_callback.load_full().as_ref().clone();
        if let Some(callback) = callback {
            callback(handle);
        }
    }
}

#[cfg(test)]
impl EngineFacade for FakeEngineFacade {
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>> {
        let fake = self.clone();
        async move {
            push_log(&fake.calls, scenes.clone());
            if let Some(block) = fake.reconcile_block.pop() {
                let _ = block.blocked_tx.send(());
                let _ = block.release_rx.recv();
            }
            if let Some(message) = fake.reconcile_failure.load_full().as_ref().clone() {
                complete_reconcile_waiters(&fake.reconcile_done);
                return Err(EngineError::Render(message));
            }
            let results = scenes
                .iter()
                .enumerate()
                .map(|(index, scene)| {
                    SceneResult::new(
                        scene.display.display_id,
                        SceneHandle::new(index as u64 + 1),
                        0,
                    )
                })
                .collect();
            fake.rendered_scenes.store(Arc::new(scenes));
            complete_reconcile_waiters(&fake.reconcile_done);
            Ok(results)
        }
        .boxed()
    }

    fn refresh_displays(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            let refresh_snapshot = fake.snapshot_after_refresh.load_full().as_ref().clone();
            if let Some(snapshot) = refresh_snapshot {
                fake.set_snapshot(snapshot);
            }
            if let Some(message) = fake.refresh_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            Ok(())
        }
        .boxed()
    }

    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.snapshot.load_full().as_ref().clone()
    }

    fn close_all_scenes(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            if let Some(message) = fake.close_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            fake.publish_snapshot(|current| {
                let mut next = current.to_vec();
                for display in &mut next {
                    display.handle = None;
                    display.accepts_pointer_input = false;
                    display.assignment = None;
                }
                next
            });
            Ok(())
        }
        .boxed()
    }

    fn set_all_paused(&self, paused: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.paused_calls, paused);
            if let Some(message) = fake.pause_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            fake.rendered_scenes.rcu(|scenes| {
                let mut scenes = scenes.as_ref().clone();
                for scene in &mut scenes {
                    scene.paused = paused;
                }
                scenes
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_volume(&self, handle: SceneHandle, volume: AudioVolume) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.audio_volume_calls, (handle, f32::from(volume)));
            fake.update_direct_assignment(handle, |template| {
                template.audio_volume = volume;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.audio_volume = volume;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.audio_muted_calls, (handle, muted));
            fake.update_direct_assignment(handle, |template| {
                template.audio_muted = muted;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.audio_muted = muted;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.audio_response_calls, (handle, enabled));
            fake.update_direct_assignment(handle, |template| {
                template.audio_response_enabled = enabled;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.audio_response_enabled = enabled;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            if let Some(block) = fake.audio_capture_block.pop() {
                let _ = block.blocked_tx.send(());
                let _ = block.release_rx.recv();
            }
            if !enabled {
                if let Some(message) = fake.disable_capture_failure.swap(Arc::new(None)).as_ref() {
                    return Err(EngineError::Platform(message.clone()));
                }
            }
            if enabled {
                if let Some(message) = fake.audio_capture_failure.load_full().as_ref() {
                    return Err(EngineError::Platform(message.clone()));
                }
            }
            push_log(&fake.audio_capture_calls, (handle, enabled));
            push_log(&fake.audio_response_calls, (handle, enabled));
            fake.update_direct_assignment(handle, |template| {
                template.audio_response_enabled = enabled;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.audio_response_enabled = enabled;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_audio_capture_suspended(&self, suspended: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.audio_capture_suspend_calls, suspended);
            if let Some(message) = fake.suspend_failure.swap(Arc::new(None)).as_ref() {
                return Err(EngineError::Platform(message.clone()));
            }
            if !suspended {
                if let Some(message) = fake.audio_capture_failure.load_full().as_ref() {
                    return Err(EngineError::Platform(message.clone()));
                }
            }
            fake.audio_capture_suspended.store(Arc::new(suspended));
            Ok(())
        }
        .boxed()
    }

    fn set_scaling_mode(&self, handle: SceneHandle, mode: ScalingMode) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.scaling_mode_calls, (handle, mode));
            fake.update_direct_assignment(handle, |template| {
                template.scaling_mode = mode;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.scaling_mode = mode;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.scaling_factor_calls, (handle, factor));
            fake.update_direct_assignment(handle, |template| {
                template.scaling_factor = factor;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.scaling_factor = factor;
            });
            Ok(())
        }
        .boxed()
    }

    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.fps_calls, (handle, fps));
            fake.update_direct_assignment(handle, |template| {
                template.fps = fps;
            });
            fake.update_direct_assignment_after_refresh(handle, |template| {
                template.fps = fps;
            });
            Ok(())
        }
        .boxed()
    }

    fn poll_mouse_position(&self) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.mouse_poll_calls, ());
            push_log(&fake.mouse_samples, **fake.mouse_input.load());
            if let Some(block) = fake.mouse_poll_block.pop() {
                let _ = block.blocked_tx.send(());
                block
                    .release_rx
                    .recv_timeout(Duration::from_secs(2))
                    .map_err(|error| {
                        EngineError::Platform(format!("mouse poll release timed out: {error}"))
                    })?;
            }
            Ok(())
        }
        .boxed()
    }

    fn set_mouse_position(&self, handle: SceneHandle, x: f64, y: f64) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.mouse_position_calls, (handle, x, y));
            Ok(())
        }
        .boxed()
    }

    fn set_mouse_button(
        &self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.mouse_button_calls, (handle, button, pressed));
            Ok(())
        }
        .boxed()
    }

    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> EngineFuture<()> {
        let fake = self.clone();
        async move {
            push_log(&fake.mouse_entered_calls, (handle, entered));
            Ok(())
        }
        .boxed()
    }

    fn create_window_for_display(
        &self,
        selector: DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>> {
        let fake = self.clone();
        async move {
            push_log(&fake.window_create_calls, selector);
            if let Some(message) = fake.reconcile_failure.load_full().as_ref().clone() {
                return Err(EngineError::Render(message));
            }
            Ok(Some(SceneHandle::new(98)))
        }
        .boxed()
    }

    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>> {
        let fake = self.clone();
        async move {
            push_log(&fake.wallpaper_calls, (selector, assignment));
            if let Some(message) = fake.reconcile_failure.load_full().as_ref().clone() {
                return Err(EngineError::Render(message));
            }
            Ok(Some(SceneHandle::new(99)))
        }
        .boxed()
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        self.first_frame_callback.store(Arc::new(Some(callback)));
    }

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        let mut observer = self.pointer_consumer.lock().unwrap_or_else(|error| error.into_inner());
        observer.callback = callback;
        if let Some(callback) = &observer.callback {
            callback(observer.has_consumers);
        }
    }
}
