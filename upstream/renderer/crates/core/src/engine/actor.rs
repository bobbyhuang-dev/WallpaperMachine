use std::sync::Arc;

use kameo::{
    actor::{ActorRef, Spawn, WeakActorRef},
    message::{Context, Message},
};

#[cfg(test)]
use crate::engine::messages::{DisplayRecordCountForTest, SequenceForTest};
use crate::{
    DisplaySelector, EngineError, WallpaperAssignment,
    display::state::{DisplayKey, DisplayStateModel},
    engine::{
        EngineSnapshotPublisher, FirstFrameCallback,
        messages::{self, Ping},
        runtime::{RuntimeRefreshJob, RuntimeRefreshMode, SceneRuntime},
        state::{DisplayRuntimeRecord, EngineState},
    },
    owe::backend::OweBackend,
    project::{SceneDescSliceExt, SceneHandle},
};

#[derive(kameo::Actor)]
pub struct EngineActor {
    #[allow(dead_code)]
    backend: OweBackend,
    first_frame_callback: FirstFrameCallback,
    pub state: EngineState,
    snapshots: Arc<EngineSnapshotPublisher>,
    weak_self: WeakActorRef<EngineActor>,
    #[allow(dead_code)]
    display_callback: Option<()>,
    #[allow(dead_code)]
    refresh_running: bool,
    #[allow(dead_code)]
    refresh_pending: bool,
    #[cfg(test)]
    pub test_sequence: u64,
    #[cfg(test)]
    fail_next_refresh_displays: bool,
    #[cfg(test)]
    pointer_notifications: Vec<(Arc<()>, bool)>,
}

#[derive(Clone)]
pub struct EngineActorHandle {
    #[allow(dead_code)]
    actor: ActorRef<EngineActor>,
    #[allow(dead_code)]
    _runtime: Option<Arc<tokio::runtime::Runtime>>,
}

impl EngineActorHandle {
    #[allow(clippy::single_call_fn)]
    pub fn spawn(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        state: EngineState,
        snapshots: Arc<EngineSnapshotPublisher>,
    ) -> Result<Self, EngineError> {
        let prepared = EngineActor::prepare();
        let actor_ref = prepared.actor_ref().clone();
        let actor = EngineActor::new(backend, first_frame_callback, state, snapshots, actor_ref.downgrade());

        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            if matches!(
                handle.runtime_flavor(),
                tokio::runtime::RuntimeFlavor::CurrentThread
            ) {
                prepared.spawn(actor);
                return Ok(Self {
                    actor: actor_ref,
                    _runtime: None,
                });
            }

            let _guard = handle.enter();
            prepared.spawn_in_thread(actor);
            return Ok(Self {
                actor: actor_ref,
                _runtime: None,
            });
        }

        let runtime = Arc::new(
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .thread_name("wallpaper-engine-actor-runtime")
                .build()
                .map_err(|error| {
                    EngineError::Platform(format!("failed to start engine actor runtime: {error}"))
                })?,
        );
        {
            let _guard = runtime.enter();
            prepared.spawn_in_thread(actor);
        }

        Ok(Self {
            actor: actor_ref,
            _runtime: Some(runtime),
        })
    }

    pub fn actor(&self) -> &ActorRef<EngineActor> {
        &self.actor
    }
}

#[allow(clippy::single_call_fn)]
impl EngineActor {
    pub fn new(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        state: EngineState,
        snapshots: Arc<EngineSnapshotPublisher>,
        weak_self: WeakActorRef<EngineActor>,
    ) -> Self {
        Self {
            backend,
            first_frame_callback,
            state,
            snapshots,
            weak_self,
            display_callback: None,
            refresh_running: false,
            refresh_pending: false,
            #[cfg(test)]
            test_sequence: 0,
            #[cfg(test)]
            fail_next_refresh_displays: false,
            #[cfg(test)]
            pointer_notifications: Vec::new(),
        }
    }

    pub fn publish_snapshot(&self) {
        self.snapshots.publish(self.state.snapshot());
    }

    fn with_snapshot_update<T>(
        &mut self,
        update: impl FnOnce(&mut Self) -> Result<T, EngineError>,
    ) -> Result<T, EngineError> {
        let result = update(self);
        self.publish_snapshot();
        result
    }

    pub fn refresh_displays_now(&mut self) -> Result<(), EngineError> {
        let primary = crate::DisplayDesc::primary()?;
        let displays = crate::DisplayDesc::all()?;
        self.reconcile_display_descriptors(primary, displays)
    }

    pub fn reconcile_display_descriptors(
        &mut self,
        primary: crate::DisplayDesc,
        displays: Vec<crate::DisplayDesc>,
    ) -> Result<(), EngineError> {
        self.update_display_state(|model| {
            model.refresh_connected(primary, displays)?;
            Ok(())
        })
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn set_wallpaper_for(
        &mut self,
        selector: DisplaySelector,
        wallpaper: WallpaperAssignment,
    ) -> Result<Option<SceneHandle>, EngineError> {
        let key = DisplayKey::from_selector(&selector)?;
        self.update_display_state(|model| model.set_assignment(&selector, wallpaper))?;
        self.handle_for_key(&key)
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn create_window_for(
        &mut self,
        selector: DisplaySelector,
    ) -> Result<Option<SceneHandle>, EngineError> {
        let key = DisplayKey::from_selector(&selector)?;
        self.update_display_state(|model| model.set_window_active(&selector, true).map(|_| ()))?;
        self.handle_for_key(&key)
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn destroy_window_for(&mut self, selector: DisplaySelector) -> Result<(), EngineError> {
        self.update_display_state(|model| model.destroy_window(&selector).map(|_| ()))
    }

    #[allow(clippy::needless_pass_by_value)]
    pub fn reconcile_scenes(
        &mut self,
        scenes: Vec<crate::project::SceneDesc>,
    ) -> Result<Vec<crate::project::SceneResult>, EngineError> {
        self.update_display_state(|model| model.apply_reconcile(&scenes))?;

        let model = DisplayStateModel {
            records: self
                .state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };
        scenes.reconcile_results(&model, &self.state.handles_by_display)
    }

    pub fn close_all_scenes(&mut self) -> Result<(), EngineError> {
        self.state.close_all()
    }

    pub fn set_scaling_mode(
        &mut self,
        handle: SceneHandle,
        mode: crate::project::ScalingMode,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_scaling_mode(mode))
    }

    pub fn set_scaling_factor(
        &mut self,
        handle: SceneHandle,
        factor: f64,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_scaling_factor(factor))
    }

    pub fn set_fps(&mut self, handle: SceneHandle, fps: u32) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_fps(fps))
    }

    pub fn set_paused(&mut self, handle: SceneHandle, paused: bool) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_paused(paused))
    }

    pub fn set_mouse_position(
        &mut self,
        handle: SceneHandle,
        x: f64,
        y: f64,
    ) -> Result<(), EngineError> {
        self.state.scene_mut(handle)?.set_mouse_position(x, y)
    }

    pub fn set_mouse_button(
        &mut self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> Result<(), EngineError> {
        self.state.scene_mut(handle)?.set_mouse_button(button, pressed)
    }

    pub fn set_mouse_entered(
        &mut self,
        handle: SceneHandle,
        entered: bool,
    ) -> Result<(), EngineError> {
        self.state.scene_mut(handle)?.set_mouse_entered(entered)
    }

    pub fn set_all_paused(&mut self, paused: bool) -> Result<(), EngineError> {
        let handles: Vec<SceneHandle> = self.state.active_runtime_handles().collect();

        for handle in handles {
            self.set_paused(handle, paused)?;
        }

        Ok(())
    }

    pub fn set_render_resolution(
        &mut self,
        handle: SceneHandle,
        width: u32,
        height: u32,
    ) -> Result<(), EngineError> {
        let backend = self.backend;
        self.with_scene_mut(handle, |scene| {
            scene.set_render_resolution(backend, width, height)
        })
    }

    pub fn set_audio_response_enabled(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_audio_response_enabled(enabled))
    }

    pub fn set_audio_volume(
        &mut self,
        handle: SceneHandle,
        volume: crate::media::audio::AudioVolume,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_audio_volume(volume))
    }

    pub fn set_audio_muted(&mut self, handle: SceneHandle, muted: bool) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_audio_muted(muted))
    }

    pub fn set_property_override(
        &mut self,
        handle: SceneHandle,
        flat_json: String,
    ) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| {
            scene.set_property_override_json(Some(flat_json))
        })
    }

    pub fn reset_property_override(&mut self, handle: SceneHandle) -> Result<(), EngineError> {
        self.with_scene_mut(handle, |scene| scene.set_property_override_json(None))
    }

    pub fn update_display_state(
        &mut self,
        update: impl FnOnce(&mut DisplayStateModel) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        let mut runtimes_to_close = Vec::new();
        let mut model = DisplayStateModel {
            records: self
                .state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };
        update(&mut model)?;

        self.state.apply_display_model(&model)?;

        for index in 0..self.state.display_records.len() {
            let mut resolved_model = self.state.display_records[index].model.clone();
            resolved_model.assignment = model.resolved_assignment(&resolved_model.key)?;
            if !resolved_model.should_have_runtime() {
                let record = &mut self.state.display_records[index];
                record.store_runtime_snapshot();
                record.model.runtime_open = false;
                let key = record.model.key.clone();
                let runtime = record.runtime.take();
                let handle = record.handle;
                self.state.sync_handle_reservation(key, handle);
                if let Some(runtime) = runtime {
                    runtimes_to_close.push(runtime);
                }
            }
        }
        for mut runtime in runtimes_to_close {
            runtime.close()?;
        }

        self.open_or_rebuild_required_runtimes()
    }

    #[allow(clippy::unnecessary_wraps)]
    pub fn handle_for_key(&self, key: &DisplayKey) -> Result<Option<SceneHandle>, EngineError> {
        Ok(self.state.handles_by_display.get(key).copied())
    }

    pub fn with_scene_mut(
        &mut self,
        handle: SceneHandle,
        operation: impl FnOnce(&mut SceneRuntime) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        let runtime = self.state.scene_mut(handle)?;
        operation(runtime)?;
        self.state.record_runtime_state(handle)
    }

    pub fn open_or_rebuild_required_runtimes(&mut self) -> Result<(), EngineError> {
        let mut jobs = Vec::new();
        let model = DisplayStateModel {
            records: self
                .state
                .display_records
                .iter()
                .map(|record| record.model.clone())
                .collect(),
        };

        for index in 0..self.state.display_records.len() {
            let mut runtime_model = self.state.display_records[index].model.clone();
            runtime_model.assignment = model.resolved_assignment(&runtime_model.key)?;
            let runtime_record = DisplayRuntimeRecord {
                model: runtime_model,
                handle: None,
                runtime: None,
                last_runtime_state: None,
            };
            if !runtime_record.should_have_runtime() {
                continue;
            }
            let Some(desc) = runtime_record.scene_desc()? else {
                continue;
            };
            let current_desc = self.state.display_records[index]
                .runtime
                .as_ref()
                .map(|runtime| &runtime.desc);
            if !RuntimeRefreshMode::from_transition(current_desc, &desc).is_required()
                && self.state.display_records[index].handle.is_some()
            {
                self.state.display_records[index].model.runtime_open = true;
                continue;
            }
            let key = self.state.display_records[index].model.key.clone();
            let handle = self.state.reserve_handle_for_key(key.clone());
            let runtime_state = self.state.display_records[index].runtime_state_for_desc(&desc)?;
            let existing_runtime = self.state.display_records[index].runtime.take();
            self.state.display_records[index].handle = Some(handle);
            self.state.display_records[index].model.runtime_open = false;
            jobs.push(RuntimeRefreshJob {
                key,
                handle,
                desc,
                runtime_state,
                existing_runtime,
                first_frame_callback: self.first_frame_callback.clone(),
            });
        }

        let mut first_error = None;
        for job in jobs {
            if let Err(error) = self.run_runtime_refresh_job(job) {
                first_error.get_or_insert(error);
            }
        }

        if let Some(error) = first_error {
            return Err(error);
        }

        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    pub fn run_runtime_refresh_job(&mut self, job: RuntimeRefreshJob) -> Result<(), EngineError> {
        let RuntimeRefreshJob {
            key,
            handle,
            desc,
            runtime_state,
            existing_runtime,
            first_frame_callback,
        } = job;

        let mut runtime = match existing_runtime {
            Some(mut runtime) => {
                match RuntimeRefreshMode::from_transition(Some(&runtime.desc), &desc) {
                    RuntimeRefreshMode::Unchanged => runtime,
                    RuntimeRefreshMode::OpenRuntime => {
                        unreachable!("existing runtime cannot require initial open")
                    }
                    RuntimeRefreshMode::UpdateWindowOnly => {
                        let before_display = runtime.desc.display.clone();
                        match runtime.update_window_display(desc.display.clone()) {
                            Ok(()) => {
                                log::debug!(
                                    "[wallpaper-core display] updated runtime window in place: \
                                     key={key:?} before_display={before_display:?} \
                                     after_display={:?}",
                                    desc.display
                                );
                                runtime
                            }
                            Err(error) => {
                                self.restore_failed_runtime_refresh(&key, handle, Some(runtime))?;
                                return Err(error);
                            }
                        }
                    }
                    RuntimeRefreshMode::ReopenRuntime => {
                        let before_display = runtime.desc.display.clone();
                        let reconfigure_result =
                            runtime.reconfigure_for_display(self.backend, desc.display.clone());
                        match reconfigure_result {
                            Ok(()) => {
                                log::debug!(
                                    "[wallpaper-core display] reconfigured runtime surface in \
                                     place: key={key:?} before_display={before_display:?} \
                                     after_display={:?}",
                                    desc.display
                                );
                                runtime
                            }
                            Err(reconfigure_error) => {
                                log::warn!(
                                    "[wallpaper-core display] fast surface reconfigure failed, \
                                     falling back to full rebuild: key={key:?} \
                                     before_display={before_display:?} after_display={:?} \
                                     error={reconfigure_error}",
                                    desc.display
                                );
                                match SceneRuntime::open(
                                    self.backend,
                                    first_frame_callback.clone(),
                                    handle,
                                    &desc,
                                    runtime_state,
                                    self.weak_self.clone(),
                                ) {
                                    Ok(replacement) => {
                                        if let Err(error) = runtime.close() {
                                            log::warn!(
                                                "[wallpaper-core display] failed to close \
                                                 replaced display runtime: {error}"
                                            );
                                        }
                                        replacement
                                    }
                                    Err(error) => {
                                        self.restore_failed_runtime_refresh(
                                            &key,
                                            handle,
                                            Some(runtime),
                                        )?;
                                        return Err(error);
                                    }
                                }
                            }
                        }
                    }
                    RuntimeRefreshMode::RebuildExistingRuntime => {
                        let rebuild_result = if runtime.desc.same_wallpaper(&desc) {
                            runtime.resize_or_rebuild(self.backend, desc.display.clone())
                        } else {
                            runtime.replace_wallpaper(self.backend, &desc)
                        };
                        if let Err(error) = rebuild_result {
                            self.restore_failed_runtime_refresh(&key, handle, Some(runtime))?;
                            return Err(error);
                        }
                        runtime
                    }
                }
            }
            None => match SceneRuntime::open(
                self.backend,
                first_frame_callback,
                handle,
                &desc,
                runtime_state,
                self.weak_self.clone(),
            ) {
                Ok(runtime) => runtime,
                Err(error) => {
                    self.restore_failed_runtime_refresh(&key, handle, None)?;
                    return Err(error);
                }
            },
        };

        if let Some(index) = self.state.record_index(&key) {
            self.state.display_records[index].model.runtime_open = true;
            self.state.display_records[index].handle = Some(handle);
            self.state.display_records[index].runtime = Some(runtime);
            self.state.display_records[index].store_runtime_snapshot();
            self.state.handles_by_display.insert(key.clone(), handle);
            self.state.displays_by_handle.insert(handle, key);
        } else {
            runtime.close()?;
        }

        Ok(())
    }

    pub fn restore_failed_runtime_refresh(
        &mut self,
        key: &DisplayKey,
        handle: SceneHandle,
        runtime: Option<SceneRuntime>,
    ) -> Result<(), EngineError> {
        let Some(mut runtime) = runtime else {
            if let Some(index) = self.state.record_index(key) {
                self.state.display_records[index].model.runtime_open = false;
            }
            return Ok(());
        };

        if let Some(index) = self.state.record_index(key) {
            self.state.display_records[index].model.runtime_open = true;
            self.state.display_records[index].handle = Some(handle);
            self.state.display_records[index].runtime = Some(runtime);
            self.state.display_records[index].store_runtime_snapshot();
            self.state.handles_by_display.insert(key.clone(), handle);
            self.state.displays_by_handle.insert(handle, key.clone());
        } else {
            runtime.close()?;
        }

        Ok(())
    }
}

impl Message<Ping> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(&mut self, _msg: Ping, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        Ok(())
    }
}

impl Message<messages::RefreshDisplays> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        _msg: messages::RefreshDisplays,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| {
            #[cfg(test)]
            if actor.fail_next_refresh_displays {
                actor.fail_next_refresh_displays = false;
                return Err(EngineError::Platform("test display refresh failure".to_string()));
            }
            actor.refresh_displays_now()
        })
    }
}

impl Message<messages::RefreshDisplayDescriptors> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::RefreshDisplayDescriptors,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.reconcile_display_descriptors(msg.primary, msg.displays))
    }
}

impl Message<messages::ReconcileScenes> for EngineActor {
    type Reply = messages::ReconcileReply;

    async fn handle(
        &mut self,
        msg: messages::ReconcileScenes,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.reconcile_scenes(msg.scenes))
    }
}

impl Message<messages::CreateWindowForDisplay> for EngineActor {
    type Reply = messages::SceneHandleReply;

    async fn handle(
        &mut self,
        msg: messages::CreateWindowForDisplay,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.create_window_for(msg.selector))
    }
}

impl Message<messages::DestroyWindowForDisplay> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::DestroyWindowForDisplay,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.destroy_window_for(msg.selector))
    }
}

impl Message<messages::SetWallpaperForDisplay> for EngineActor {
    type Reply = messages::SceneHandleReply;

    async fn handle(
        &mut self,
        msg: messages::SetWallpaperForDisplay,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_wallpaper_for(msg.selector, msg.wallpaper))
    }
}

impl Message<messages::SetScalingMode> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetScalingMode,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_scaling_mode(msg.handle, msg.mode))
    }
}

impl Message<messages::SetScalingFactor> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetScalingFactor,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_scaling_factor(msg.handle, msg.factor))
    }
}

impl Message<messages::SetFps> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetFps,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_fps(msg.handle, msg.fps))
    }
}

impl Message<messages::SetPaused> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetPaused,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_paused(msg.handle, msg.paused))
    }
}

impl Message<messages::SetAllPaused> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAllPaused,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_all_paused(msg.paused))
    }
}

impl Message<messages::SetMousePosition> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMousePosition,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_position(msg.handle, msg.x, msg.y)?;
        Ok(())
    }
}

impl Message<messages::SetMouseButton> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMouseButton,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_button(msg.handle, msg.button, msg.pressed)?;
        Ok(())
    }
}

impl Message<messages::SetMouseEntered> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetMouseEntered,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.set_mouse_entered(msg.handle, msg.entered)?;
        Ok(())
    }
}

impl Message<messages::SetRenderResolution> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetRenderResolution,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_render_resolution(msg.handle, msg.width, msg.height))
    }
}

impl Message<messages::SetAudioResponseEnabled> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAudioResponseEnabled,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_audio_response_enabled(msg.handle, msg.enabled))
    }
}

impl Message<messages::SetAudioVolume> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAudioVolume,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_audio_volume(msg.handle, msg.volume))
    }
}

impl Message<messages::SetAudioMuted> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetAudioMuted,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_audio_muted(msg.handle, msg.muted))
    }
}

impl Message<messages::SetPropertyOverride> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::SetPropertyOverride,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.set_property_override(msg.handle, msg.flat_json))
    }
}

impl Message<messages::ResetPropertyOverride> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        msg: messages::ResetPropertyOverride,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.reset_property_override(msg.handle))
    }
}

impl Message<messages::CloseAllScenes> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        _msg: messages::CloseAllScenes,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.with_snapshot_update(|actor| actor.close_all_scenes())
    }
}

impl Message<messages::NativePointerInputChanged> for EngineActor {
    type Reply = ();

    async fn handle(&mut self, msg: messages::NativePointerInputChanged, _ctx: &mut Context<Self, Self::Reply>) {
        #[cfg(test)]
        self.pointer_notifications.push((msg.renderer_instance.clone(), msg.accepts_pointer_input));
        let changed = self.state.scene_mut(msg.handle).is_ok_and(|runtime| {
            runtime.apply_pointer_input_capability(&msg.renderer_instance, msg.accepts_pointer_input)
        });
        if changed { self.publish_snapshot(); }
    }
}

impl Message<messages::PollMouseState> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(&mut self, msg: messages::PollMouseState, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        if !msg.state.point.x.is_finite() || !msg.state.point.y.is_finite() {
            return Err(EngineError::InvalidInput("mouse coordinates must be finite".to_string()));
        }
        let current = self.snapshots.load();
        let snapshot = super::DisplaySnapshot { entries: &current.displays };
        for entry in snapshot.entries {
            let Some(handle) = entry.handle else { continue; };
            // Keep the complete snapshot available while resolving mirror geometry.
            let update = snapshot.mouse_update_for_entry(msg.state, entry);
            let Ok(runtime) = self.state.scene_mut(handle) else { continue; };
            if !runtime.accepts_pointer_input() { continue; }
            runtime.set_mouse_entered(update.entered)?;
            if let Some(position) = update.position {
                runtime.set_mouse_position(position.x, position.y)?;
            }
            runtime.reconcile_mouse_button_baseline(update.buttons)?;
            for button in update.buttons.transitions() {
                runtime.set_mouse_button(button.button, button.pressed)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
impl Message<DisplayRecordCountForTest> for EngineActor {
    type Reply = Result<usize, EngineError>;

    async fn handle(
        &mut self,
        _msg: DisplayRecordCountForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.state.display_records.len())
    }
}

#[cfg(test)]
impl Message<SequenceForTest> for EngineActor {
    type Reply = Result<u64, EngineError>;

    async fn handle(
        &mut self,
        msg: SequenceForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.test_sequence += 1;
        assert_eq!(self.test_sequence, msg.expected);
        Ok(self.test_sequence)
    }
}

#[cfg(test)]
impl Message<messages::FailNextRefreshDisplaysForTest> for EngineActor {
    type Reply = Result<(), EngineError>;

    async fn handle(
        &mut self,
        _msg: messages::FailNextRefreshDisplaysForTest,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        self.fail_next_refresh_displays = true;
        Ok(())
    }
}

#[cfg(test)]
impl Message<messages::TakePointerNotificationsForTest> for EngineActor {
    type Reply = Vec<(Arc<()>, bool)>;

    async fn handle(&mut self, _msg: messages::TakePointerNotificationsForTest, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        std::mem::take(&mut self.pointer_notifications)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        DisplayDesc, WallpaperAssignment,
        display::state::{DisplayKey, DisplayRecord, DisplayStateModel},
        engine::{
            runtime::SceneRuntimeState,
            snapshot::EngineSnapshotPublisher,
            state::{EngineState, StoredSceneRuntimeState},
        },
        project::{ScalingMode, SceneDesc, SceneTemplate},
    };

    #[test]
    fn failed_partial_update_still_publishes_committed_state() {
        let prepared = EngineActor::prepare();
        let state = EngineState::with_display_model(DisplayStateModel { records: vec![DisplayRecord {
            key: DisplayKey::Primary,
            live_display: Some(DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0)),
            assignment: None,
            window_active: true,
            runtime_open: false,
            primary_inheritance_consumed: false,
        }] });
        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::new(std::sync::Mutex::new(crate::window::MouseButtonTracker::new()))));
        let mut actor = EngineActor::new(OweBackend, Arc::new(|_| {}), state, snapshots.clone(), prepared.actor_ref().downgrade());
        let result: Result<(), EngineError> = actor.with_snapshot_update(|actor| {
            actor.state.display_records[0].model.window_active = false;
            Err(EngineError::Platform("later operation failed".into()))
        });
        assert!(matches!(result, Err(EngineError::Platform(message)) if message == "later operation failed"));
        assert!(!snapshots.load().displays[0].window_active);
    }

    #[test]
    fn runtime_refresh_job_for_new_wallpaper_uses_descriptor_scaling_defaults() {
        let display = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let previous_desc = SceneDesc::builder(display.clone(), "/tmp/fill/project.json")
            .assets_path("/tmp/assets")
            .scaling_mode(ScalingMode::Fill)
            .build()
            .expect("previous scene should build");
        let next_template = SceneTemplate::builder("/tmp/fit/project.json")
            .assets_path("/tmp/assets")
            .scaling_mode(ScalingMode::Fit)
            .build()
            .expect("next scene should build");
        let mut state = EngineState::with_display_model(DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(display),
                assignment: Some(WallpaperAssignment::Direct(next_template)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
            }],
        });
        state.display_records[0].last_runtime_state = Some(StoredSceneRuntimeState::new(
            previous_desc.clone(),
            SceneRuntimeState::try_from(&previous_desc).expect("previous state should build"),
        ));
        let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), Arc::new(std::sync::Mutex::new(crate::window::MouseButtonTracker::new()))));
        let prepared = EngineActor::prepare();
        let actor = EngineActor::new(OweBackend, Arc::new(|_handle| {}), state, snapshots, prepared.actor_ref().downgrade());
        let runtime_state = actor
            .state
            .display_records
            .first()
            .expect("primary record should exist")
            .runtime_state_for_desc(
                &actor
                    .state
                    .display_records
                    .first()
                    .expect("primary record should exist")
                    .scene_desc()
                    .expect("next scene should build")
                    .expect("assigned scene should exist"),
            )
            .expect("runtime state should build");

        assert_eq!(runtime_state.scaling_mode, ScalingMode::Fit);
        assert!(
            (runtime_state.scaling_factor - 1.0).abs() <= f64::EPSILON,
            "expected descriptor scaling factor 1.0, got {}",
            runtime_state.scaling_factor
        );
    }
}
