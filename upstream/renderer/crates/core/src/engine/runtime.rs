use std::sync::Arc;
use kameo::actor::WeakActorRef;

use serde_json::Value;

use crate::{
    DisplayDesc, EngineError, WallpaperWindow,
    display::state::DisplayKey,
    engine::{FirstFrameCallback, actor::EngineActor, messages::NativePointerInputChanged},
    media::audio::AudioVolume,
    owe::backend::{OweBackend, OweScene, PointerInputCallback},
    project::{ScalingMode, SceneDesc, SceneHandle, SerdeValudeExt},
    render::RendererSurfaceCounters,
    window::{MouseButtonEdges, NormalizedMousePosition},
};

/// The native looper only writes watch state; this task owns bounded delivery.
struct PointerInputRelay {
    renderer_instance: Arc<()>,
    task: tokio::task::JoinHandle<()>,
}

impl PointerInputRelay {
    fn new(actor: WeakActorRef<EngineActor>, handle: SceneHandle) -> Result<(Self, PointerInputCallback), EngineError> {
        let runtime = tokio::runtime::Handle::try_current().map_err(|error| {
            EngineError::Platform(format!("pointer input relay requires actor runtime: {error}"))
        })?;
        let renderer_instance = Arc::new(());
        let instance = renderer_instance.clone();
        let (sender, mut receiver) = tokio::sync::watch::channel(None);
        let callback: PointerInputCallback = Arc::new(move |value| { sender.send_replace(Some(value)); });
        let task = runtime.spawn(async move {
            while receiver.changed().await.is_ok() {
                let value = *receiver.borrow_and_update();
                let Some(accepts_pointer_input) = value else { continue; };
                let Some(actor) = actor.upgrade() else { break; };
                let result = actor.tell(NativePointerInputChanged {
                    handle,
                    renderer_instance: instance.clone(),
                    accepts_pointer_input,
                }).send().await;
                drop(actor);
                if result.is_err() { break; }
            }
        });
        Ok((Self { renderer_instance, task }, callback))
    }

    fn stop(&self) { self.task.abort(); }
}

impl Drop for PointerInputRelay {
    fn drop(&mut self) { self.stop(); }
}

#[derive(Default)]
struct MouseDeliveryState {
    position: Option<NormalizedMousePosition>,
    entered: Option<bool>,
}

impl MouseDeliveryState {
    fn set_position(&mut self, x: f64, y: f64, send: impl FnOnce(f64, f64) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(EngineError::InvalidInput("mouse coordinates must be finite".to_string()));
        }
        let next = NormalizedMousePosition { x, y };
        if self.position == Some(next) { return Ok(()); }
        self.position = None;
        send(x, y)?;
        self.position = Some(next);
        Ok(())
    }

    fn set_entered(&mut self, entered: bool, send: impl FnOnce(bool) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !entered { self.position = None; }
        if self.entered == Some(entered) { return Ok(()); }
        self.entered = None;
        send(entered)?;
        self.entered = Some(entered);
        Ok(())
    }

    fn invalidate(&mut self) { self.position = None; self.entered = None; }
}

struct NativePointerInputState {
    renderer_instance: Arc<()>,
    accepts_pointer_input: bool,
    button_baseline_pending: bool,
    delivery: MouseDeliveryState,
}

impl NativePointerInputState {
    fn new(renderer_instance: Arc<()>) -> Self {
        Self {
            renderer_instance,
            accepts_pointer_input: true,
            button_baseline_pending: true,
            delivery: MouseDeliveryState::default(),
        }
    }

    fn apply(&mut self, instance: &Arc<()>, accepts: bool) -> bool {
        if !Arc::ptr_eq(&self.renderer_instance, instance) { return false; }
        self.delivery.invalidate();
        self.button_baseline_pending = true;
        let changed = self.accepts_pointer_input != accepts;
        self.accepts_pointer_input = accepts;
        changed
    }

    fn set_position(&mut self, x: f64, y: f64, send: impl FnOnce(f64, f64) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(EngineError::InvalidInput("mouse coordinates must be finite".to_string()));
        }
        if !self.accepts_pointer_input { return Ok(()); }
        self.delivery.set_position(x, y, send)
    }

    fn set_button(&mut self, button: u32, pressed: bool, send: impl FnOnce(u32, bool) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if button > 31 {
            return Err(EngineError::InvalidInput("mouse button must be in range 0..31".to_string()));
        }
        if !self.accepts_pointer_input { return Ok(()); }
        send(button, pressed)
    }

    fn reconcile_button_baseline(&mut self, buttons: MouseButtonEdges, send: impl FnOnce(u32) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !self.accepts_pointer_input || !self.button_baseline_pending { return Ok(()); }
        send(buttons.pre_transition_down_mask())?;
        self.button_baseline_pending = false;
        Ok(())
    }

    fn set_entered(&mut self, entered: bool, send: impl FnOnce(bool) -> Result<(), EngineError>) -> Result<(), EngineError> {
        if !self.accepts_pointer_input { return Ok(()); }
        self.delivery.set_entered(entered, send)
    }
}

pub struct SceneRuntime {
    last_media: Option<crate::media::MediaPollResult>,
    /// Last descriptor used to configure the renderer scene.
    pub desc: SceneDesc,
    /// Stable handle used when reporting renderer lifecycle events.
    handle: SceneHandle,
    /// Engine-level callback invoked after OWE renders the first frame.
    first_frame_callback: FirstFrameCallback,
    /// Opaque Open Wallpaper Engine renderer object.
    renderer: OweScene,
    actor: WeakActorRef<EngineActor>,
    pointer_relay: PointerInputRelay,
    pointer_input: NativePointerInputState,
    /// Runtime override applied after descriptor defaults.
    scaling_mode: ScalingMode,
    /// Runtime override applied after descriptor defaults.
    scaling_factor: f64,
    /// Renderer-surface override. Changing this rebuilds the renderer object.
    render_resolution: Option<(u32, u32)>,
    /// Runtime audio-response state, preserved across scene reconciliation.
    audio_response_enabled: bool,
    /// Runtime media-integration state, preserved across scene reconciliation.
    media_integration_enabled: bool,
    /// Runtime playback state, preserved across scene reconciliation.
    paused: bool,
    /// Runtime scene-global audio volume, preserved across scene
    /// reconciliation.
    audio_volume: AudioVolume,
    /// Runtime scene-global audio mute state, preserved across scene
    /// reconciliation.
    audio_muted: bool,
    /// Flattened runtime property override, preserved across reconciliation.
    property_override_json: Option<String>,
    /// `AppKit` window that owns the `CAMetalLayer` passed to OWE.
    window: Option<WallpaperWindow>,
    /// Increments every time the renderer object is rebuilt. The renderer's
    /// counters live and die with that object, so two wallpapers that reused
    /// one display and one handle must not have their counts merged.
    generation: u64,
}

#[derive(Clone)]
pub struct SceneRuntimeState {
    /// Mutable state that should survive replacing the scene descriptor.
    pub scaling_mode: ScalingMode,
    pub scaling_factor: f64,
    pub render_resolution: Option<(u32, u32)>,
    pub audio_response_enabled: bool,
    pub media_integration_enabled: bool,
    pub paused: bool,
    pub audio_volume: AudioVolume,
    pub audio_muted: bool,
    pub property_override_json: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DescriptorInheritance {
    PreserveRuntimeOverrides,
    UseDescriptorDefaults,
}

#[derive(Debug, PartialEq, Eq)]
enum PropertyOverrideUpdate<'a> {
    Unchanged,
    Apply(&'a str),
    Reset,
}

pub struct RuntimeRefreshJob {
    pub key: DisplayKey,
    pub handle: SceneHandle,
    pub desc: SceneDesc,
    pub runtime_state: SceneRuntimeState,
    pub existing_runtime: Option<SceneRuntime>,
    pub first_frame_callback: FirstFrameCallback,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeRefreshMode {
    Unchanged,
    OpenRuntime,
    UpdateWindowOnly,
    RebuildExistingRuntime,
    ReopenRuntime,
}

impl RuntimeRefreshMode {
    /// Classifies the transition between two scene descriptors.
    pub fn from_transition(current: Option<&SceneDesc>, desired: &SceneDesc) -> Self {
        let Some(current) = current else {
            return RuntimeRefreshMode::OpenRuntime;
        };
        if current.same_wallpaper(desired) && current.display == desired.display {
            return RuntimeRefreshMode::Unchanged;
        }
        if current.same_wallpaper(desired) {
            if current.display.has_same_render_surface(&desired.display) {
                return RuntimeRefreshMode::UpdateWindowOnly;
            }
            return RuntimeRefreshMode::ReopenRuntime;
        }
        RuntimeRefreshMode::RebuildExistingRuntime
    }

    /// Returns true if the transition requires a runtime refresh.
    pub fn is_required(self) -> bool {
        self != RuntimeRefreshMode::Unchanged
    }
}

impl SceneRuntime {
    pub fn open(
        backend: OweBackend,
        first_frame_callback: FirstFrameCallback,
        handle: SceneHandle,
        desc: &SceneDesc,
        state: SceneRuntimeState,
        actor: WeakActorRef<EngineActor>,
    ) -> Result<Self, EngineError> {
        let mut stored_desc = desc.clone();
        stored_desc.mark_shader_refresh_complete();
        let window = WallpaperWindow::builder(desc.display.clone()).open()?;
        let (pointer_relay, pointer_callback) = PointerInputRelay::new(actor.clone(), handle)?;
        let renderer = backend.open_scene(
            desc,
            window.metal_layer_ptr(),
            state.scaling_mode,
            state.scaling_factor,
            state.render_resolution,
            Some(Arc::new({
                let callback = first_frame_callback.clone();
                move || callback(handle)
            })),
            Some(pointer_callback),
        )?;
        let descriptor_state = SceneRuntimeState::try_from(desc)?;
        let mut runtime = Self {
            last_media: None,
            desc: desc.clone(),
            handle,
            first_frame_callback,
            renderer,
            pointer_input: NativePointerInputState::new(pointer_relay.renderer_instance.clone()),
            pointer_relay,
            actor,
            scaling_mode: state.scaling_mode,
            scaling_factor: state.scaling_factor,
            render_resolution: state.render_resolution,
            audio_response_enabled: state.audio_response_enabled,
            media_integration_enabled: state.media_integration_enabled,
            paused: state.paused,
            audio_volume: state.audio_volume,
            audio_muted: state.audio_muted,
            property_override_json: state.property_override_json,
            window: Some(window),
            generation: 1,
        };
        runtime.desc = stored_desc;
        runtime.apply_runtime_properties(&descriptor_state)?;
        // Published last, so a reader never sees a scene whose properties have
        // not been applied yet. Withdrawal is the scene's own responsibility
        // and happens on close and on drop.
        runtime.renderer.publish_runtime_state(
            &crate::SceneRegistry::shared(),
            handle.raw(),
            desc.display.display_id,
        );
        Ok(runtime)
    }

    /// Renderer work counters for this surface, with the identity needed to
    /// tell one surface's exclusive work from the source work it shares.
    pub fn counters(&self) -> Result<RendererSurfaceCounters, EngineError> {
        Ok(RendererSurfaceCounters {
            display_id: self.desc.display.display_id,
            handle: self.handle,
            generation: self.generation,
            source_path: self.desc.scene_path.clone(),
            paused: self.paused,
            values: self.renderer.counters()?,
        })
    }

    pub fn set_scaling_mode(&mut self, mode: ScalingMode) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        self.renderer.set_scaling_mode(mode)?;
        self.scaling_mode = mode;
        self.desc.scaling_mode = mode;
        Ok(())
    }

    pub fn set_scaling_factor(&mut self, factor: f64) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        self.renderer.set_scaling_factor(factor)?;
        self.scaling_factor = factor;
        self.desc.scaling_factor = factor;
        Ok(())
    }

    pub fn set_fps(&mut self, fps: u32) -> Result<(), EngineError> {
        self.renderer.set_target_fps(fps)?;
        self.desc.fps = fps;
        Ok(())
    }

    /// Live-updates this surface's internal rasterization scale.
    ///
    /// Deliberately not routed through [`Self::rebuild_for_desc`]: that
    /// reparses the project and reopens any video, which a quality control the
    /// user drags must never do. The renderer resizes its own targets in
    /// place.
    pub fn set_render_scale(&mut self, scale: f64) -> Result<(), EngineError> {
        self.renderer.set_render_scale(scale)
    }

    pub fn set_paused(&mut self, paused: bool) -> Result<(), EngineError> {
        if self.paused != paused {
            self.pointer_input.delivery.invalidate();
        }
        self.renderer.set_paused(paused)?;
        self.paused = paused;
        Ok(())
    }

    pub fn set_mouse_position(&mut self, x: f64, y: f64) -> Result<(), EngineError> {
        self.pointer_input.set_position(x, y, |x, y| self.renderer.set_mouse_position(x, y))
    }

    pub fn set_mouse_button(&mut self, button: u32, pressed: bool) -> Result<(), EngineError> {
        self.pointer_input.set_button(button, pressed, |button, pressed| self.renderer.set_mouse_button(button, pressed))
    }

    pub fn reconcile_mouse_button_baseline(&mut self, buttons: MouseButtonEdges) -> Result<(), EngineError> {
        self.pointer_input.reconcile_button_baseline(buttons, |down| self.renderer.set_mouse_button_baseline(down))
    }

    pub fn set_mouse_entered(&mut self, entered: bool) -> Result<(), EngineError> {
        self.pointer_input.set_entered(entered, |entered| self.renderer.set_mouse_entered(entered))
    }

    pub fn accepts_pointer_input(&self) -> bool { self.pointer_input.accepts_pointer_input }

    pub fn apply_pointer_input_capability(&mut self, instance: &Arc<()>, accepts: bool) -> bool {
        if self.window.is_none() { return false; }
        self.pointer_input.apply(instance, accepts)
    }

    pub fn set_render_resolution(
        &mut self,
        backend: OweBackend,
        width: u32,
        height: u32,
    ) -> Result<(), EngineError> {
        self.rebuild_for_desc(backend, &self.desc.clone(), Some((width, height)))
    }

    fn rebuild_for_desc(
        &mut self,
        backend: OweBackend,
        desc: &SceneDesc,
        render_resolution: Option<(u32, u32)>,
    ) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        let mut state = self.runtime_state();
        let current_descriptor_state = SceneRuntimeState::try_from(&self.desc)?;
        let descriptor_state = SceneRuntimeState::try_from(desc)?;
        let mut stored_desc = desc.clone();
        stored_desc.mark_shader_refresh_complete();
        let inheritance = if self.desc.same_wallpaper(desc) {
            DescriptorInheritance::PreserveRuntimeOverrides
        } else {
            DescriptorInheritance::UseDescriptorDefaults
        };
        state.inherit_descriptor_defaults(
            &current_descriptor_state,
            &descriptor_state,
            inheritance,
        );
        let old_display = self.desc.display.clone();
        let first_frame_callback = self.renderer_first_frame_callback();
        let (pointer_relay, pointer_callback) = PointerInputRelay::new(self.actor.clone(), self.handle)?;
        let window = self.window.as_mut().ok_or_else(|| {
            EngineError::Platform("wallpaper window is already closed".to_string())
        })?;

        // Swap the CAMetalLayer BEFORE creating the new OWE scene so that
        // each SceneWallpaper's VkSurface references its own CAMetalLayer.
        // If we reused the old layer via `update_display`, the new VkSurface
        // would be created on the same CAMetalLayer that the old VkSurface
        // still references (it's destroyed only in `old_renderer.close()`
        // below), violating the VK_EXT_metal_surface invariant that only
        // one VkSurfaceKHR can be associated with a CAMetalLayer at a time.
        //
        // The old CAMetalLayer remains alive via MoltenVK's retain through
        // the old VkSurface, and is deallocated when `old_renderer.close()`
        // destroys that surface.
        let metal_layer = window.update_layer(desc.display.clone())?;

        let mut renderer = match backend.open_scene(
            desc,
            metal_layer,
            state.scaling_mode,
            state.scaling_factor,
            render_resolution,
            Some(first_frame_callback),
            Some(pointer_callback),
        ) {
            Ok(renderer) => renderer,
            Err(error) => {
                // Best-effort geometry rollback. The layer swap is not reversible
                // without creating yet another new layer, so we restore the
                // NSWindow/NSView frames to the old display's geometry instead.
                let _ = window.update_display(old_display);
                return Err(error);
            }
        };
        if let Err(error) = state.apply_to(&mut renderer, &descriptor_state) {
            let _ = renderer.close();
            let _ = window.update_display(old_display);
            return Err(error);
        }
        let mut old_renderer = std::mem::replace(&mut self.renderer, renderer);
        self.last_media = None;
        self.generation = self.generation.saturating_add(1);
        let old_relay = std::mem::replace(&mut self.pointer_relay, pointer_relay);
        self.pointer_input = NativePointerInputState::new(self.pointer_relay.renderer_instance.clone());
        old_relay.stop();
        self.desc = stored_desc;
        self.scaling_mode = state.scaling_mode;
        self.scaling_factor = state.scaling_factor;
        self.render_resolution = render_resolution;
        self.audio_response_enabled = state.audio_response_enabled;
        self.media_integration_enabled = state.media_integration_enabled;
        self.audio_volume = state.audio_volume;
        self.audio_muted = state.audio_muted;
        self.property_override_json = state.property_override_json;
        old_renderer.close()
    }

    pub fn replace_wallpaper(
        &mut self,
        backend: OweBackend,
        desc: &SceneDesc,
    ) -> Result<(), EngineError> {
        self.rebuild_for_desc(backend, desc, self.render_resolution)
    }

    pub fn resize_or_rebuild(
        &mut self,
        backend: OweBackend,
        display: DisplayDesc,
    ) -> Result<(), EngineError> {
        if self.desc.display == display {
            return Ok(());
        }
        // Note: the fast surface-reconfigure transaction lives in
        // `run_runtime_refresh_job`'s `ReopenRuntime` branch, not here. This
        // method is reached only from `RebuildExistingRuntime`, which by
        // construction means wallpaper-defining fields have changed and a
        // full scene rebuild is required.
        let mut desc = self.desc.clone();
        desc.display = display;
        self.rebuild_for_desc(backend, &desc, self.render_resolution)
    }

    pub fn update_window_display(&mut self, display: DisplayDesc) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        let window = self.window.as_mut().ok_or_else(|| {
            EngineError::Platform("scene runtime has no window during display update".to_string())
        })?;
        window.update_display(display.clone())?;
        self.desc.display = display;
        Ok(())
    }

    /// Fast-path display reconfiguration. Preserves scene, shaders, render
    /// graph, audio, and runtime state; only the Vulkan surface, swapchain,
    /// and presentation passes are rebuilt.
    ///
    /// On any failure, returns `Err`; the caller should fall back to
    /// `rebuild_for_desc`.
    pub fn reconfigure_for_display(
        &mut self,
        backend: OweBackend,
        display: DisplayDesc,
    ) -> Result<(), EngineError> {
        self.pointer_input.delivery.invalidate();
        let _ = backend; // retained in signature for symmetry with rebuild_for_desc
        let start = std::time::Instant::now();
        let runtime_state = self.runtime_state();

        // 1. Pause rendering and release the renderer-side surface.
        self.renderer.begin_surface_reconfigure()?;

        // 2. Swap the CAMetalLayer under the existing NSWindow.
        let window = self.window.as_mut().ok_or_else(|| {
            EngineError::Platform("scene runtime has no window during reconfigure".to_string())
        })?;
        let metal_layer = window.update_layer(display.clone())?;

        // 3. Compute render resolution from the new display, or keep explicit override
        //    if one was set.
        let (render_width, render_height) = self
            .render_resolution
            .unwrap_or((display.width, display.height));

        // 4. Rebuild the Vulkan surface + swapchain + presentation passes from the new
        //    layer, and resume rendering.
        self.renderer.finish_surface_reconfigure(
            metal_layer,
            display.width,
            display.height,
            render_width,
            render_height,
            display.scale_factor,
        )?;

        // 5. OWE resumes after finishing the surface transaction. Preserve an
        //    already-paused runtime by restoring that state before returning.
        if runtime_state.paused {
            self.renderer.set_paused(true)?;
        }

        // 6. Commit the new descriptor.
        self.desc.display = display;
        log::debug!(
            "[wallpaper-core engine] display reconfigure completed in {:?}",
            start.elapsed()
        );
        Ok(())
    }

    pub fn set_audio_response_enabled(&mut self, enabled: bool) -> Result<(), EngineError> {
        self.renderer.set_audio_response_enabled(enabled)?;
        self.audio_response_enabled = enabled;
        self.desc.audio_response_enabled = enabled;
        Ok(())
    }

    pub fn update_media(&mut self, enabled: bool, state: &crate::media::MediaPollResult) -> Result<(), EngineError> {
        self.renderer.set_media_integration_enabled(true)?;
        if let Some(artwork) = &state.artwork
            && self.last_media.as_ref().and_then(|previous| previous.artwork.as_ref()) != Some(artwork) {
            self.renderer.apply_system_media_artwork(artwork)?;
        }
        for event in state.changed_events(self.last_media.as_ref()) {
            self.renderer.submit_media_event(event)?;
        }
        self.renderer.set_media_integration_enabled(enabled)?;
        self.last_media = Some(state.clone());
        Ok(())
    }

    pub fn set_media_integration_enabled(&mut self, enabled: bool) -> Result<(), EngineError> {
        self.renderer.set_media_integration_enabled(enabled)?;
        self.media_integration_enabled = enabled;
        self.desc.media_integration_enabled = enabled;
        Ok(())
    }

    pub fn submit_media_event_json(&mut self, json: &str) -> Result<(), EngineError> {
        if !self.media_integration_enabled {
            return Ok(());
        }
        self.renderer.submit_media_event_json(json)
    }

    pub fn apply_system_media_artwork(
        &mut self,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Result<(), EngineError> {
        if !self.media_integration_enabled {
            return Ok(());
        }
        let artwork = crate::media::MediaThumbnailRgba::new(width, height, rgba)
            .map_err(|error| EngineError::InvalidInput(error.to_string()))?;
        self.renderer.apply_system_media_artwork(&artwork)
    }

    pub fn set_audio_volume(&mut self, volume: AudioVolume) -> Result<(), EngineError> {
        self.renderer.set_audio_volume(volume)?;
        self.audio_volume = volume;
        self.desc.audio_volume = volume;
        Ok(())
    }

    pub fn set_audio_muted(&mut self, muted: bool) -> Result<(), EngineError> {
        self.renderer.set_audio_muted(muted)?;
        self.audio_muted = muted;
        self.desc.audio_muted = muted;
        Ok(())
    }

    pub fn set_property_override_json(
        &mut self,
        flat_json: Option<String>,
    ) -> Result<(), EngineError> {
        if let Some(json) = flat_json.as_deref() {
            self.renderer.set_property_override(json)?;
        } else {
            self.renderer.reset_property_override()?;
        }
        self.property_override_json = flat_json;
        Ok(())
    }

    pub fn close(&mut self) -> Result<(), EngineError> {
        self.pointer_relay.stop();
        let backend_result = self.renderer.close();
        if let Some(mut window) = self.window.take() {
            window.close();
        }
        backend_result
    }

    pub fn runtime_state(&self) -> SceneRuntimeState {
        SceneRuntimeState {
            scaling_mode: self.scaling_mode,
            scaling_factor: self.scaling_factor,
            render_resolution: self.render_resolution,
            audio_response_enabled: self.audio_response_enabled,
            media_integration_enabled: self.media_integration_enabled,
            paused: self.paused,
            audio_volume: self.audio_volume,
            audio_muted: self.audio_muted,
            property_override_json: self.property_override_json.clone(),
        }
    }

    pub(crate) fn runtime_state_for_desc(
        &self,
        desc: &SceneDesc,
    ) -> Result<SceneRuntimeState, EngineError> {
        let mut state = self.runtime_state();
        state.inherit_descriptor_transition(&self.desc, desc)?;
        Ok(state)
    }

    fn apply_runtime_properties(
        &mut self,
        descriptor_state: &SceneRuntimeState,
    ) -> Result<(), EngineError> {
        let state = self.runtime_state();
        state.apply_to(&mut self.renderer, descriptor_state)
    }

    fn renderer_first_frame_callback(&self) -> crate::owe::backend::FirstFrameCallback {
        Arc::new({
            let callback = self.first_frame_callback.clone();
            let handle = self.handle;
            move || callback(handle)
        })
    }
}

impl Drop for SceneRuntime {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

impl SceneRuntimeState {
    pub(crate) fn inherit_descriptor_transition(
        &mut self,
        current_desc: &SceneDesc,
        next_desc: &SceneDesc,
    ) -> Result<(), EngineError> {
        let current_descriptor_state = Self::try_from(current_desc)?;
        let next_descriptor_state = Self::try_from(next_desc)?;
        let inheritance = if current_desc.same_wallpaper(next_desc) {
            DescriptorInheritance::PreserveRuntimeOverrides
        } else {
            DescriptorInheritance::UseDescriptorDefaults
        };
        self.inherit_descriptor_defaults(
            &current_descriptor_state,
            &next_descriptor_state,
            inheritance,
        );
        Ok(())
    }

    fn apply_to(
        &self,
        renderer: &mut OweScene,
        descriptor_state: &SceneRuntimeState,
    ) -> Result<(), EngineError> {
        if self.paused != descriptor_state.paused {
            renderer.set_paused(self.paused)?;
        }
        if self.audio_response_enabled != descriptor_state.audio_response_enabled {
            renderer.set_audio_response_enabled(self.audio_response_enabled)?;
        }
        if self.media_integration_enabled != descriptor_state.media_integration_enabled {
            renderer.set_media_integration_enabled(self.media_integration_enabled)?;
        }
        if self.audio_volume != descriptor_state.audio_volume {
            renderer.set_audio_volume(self.audio_volume)?;
        }
        if self.audio_muted != descriptor_state.audio_muted {
            renderer.set_audio_muted(self.audio_muted)?;
        }
        match self.property_override_update(descriptor_state) {
            PropertyOverrideUpdate::Unchanged => {}
            PropertyOverrideUpdate::Apply(json) => renderer.set_property_override(json)?,
            PropertyOverrideUpdate::Reset => renderer.reset_property_override()?,
        }
        Ok(())
    }

    fn property_override_update<'a>(
        &'a self,
        descriptor_state: &SceneRuntimeState,
    ) -> PropertyOverrideUpdate<'a> {
        match (
            self.property_override_json.as_deref(),
            descriptor_state.property_override_json.as_deref(),
        ) {
            (runtime, descriptor) if runtime == descriptor => PropertyOverrideUpdate::Unchanged,
            (Some(json), _) => PropertyOverrideUpdate::Apply(json),
            (None, Some(_)) => PropertyOverrideUpdate::Reset,
            (None, None) => PropertyOverrideUpdate::Unchanged,
        }
    }

    fn inherit_descriptor_property_override(
        &mut self,
        current_descriptor_state: &SceneRuntimeState,
        next_descriptor_state: &SceneRuntimeState,
    ) {
        if self.property_override_json == current_descriptor_state.property_override_json {
            self.property_override_json
                .clone_from(&next_descriptor_state.property_override_json);
        }
    }

    fn inherit_descriptor_defaults(
        &mut self,
        current_descriptor_state: &SceneRuntimeState,
        next_descriptor_state: &SceneRuntimeState,
        inheritance: DescriptorInheritance,
    ) {
        self.inherit_descriptor_property_override(current_descriptor_state, next_descriptor_state);

        if inheritance == DescriptorInheritance::UseDescriptorDefaults {
            self.scaling_mode = next_descriptor_state.scaling_mode;
            self.scaling_factor = next_descriptor_state.scaling_factor;
            self.audio_response_enabled = next_descriptor_state.audio_response_enabled;
            self.media_integration_enabled = next_descriptor_state.media_integration_enabled;
            self.audio_volume = next_descriptor_state.audio_volume;
            self.audio_muted = next_descriptor_state.audio_muted;
        }
    }
}

impl TryFrom<&SceneDesc> for SceneRuntimeState {
    type Error = EngineError;

    fn try_from(desc: &SceneDesc) -> Result<Self, Self::Error> {
        // Descriptor values seed runtime state only for first open. Later
        // reconciliations keep explicit API changes such as property overrides.
        Ok(Self {
            scaling_mode: desc.scaling_mode,
            scaling_factor: desc.scaling_factor,
            render_resolution: None,
            audio_response_enabled: desc.audio_response_enabled,
            media_integration_enabled: desc.media_integration_enabled,
            paused: desc.paused,
            audio_volume: desc.audio_volume,
            audio_muted: desc.audio_muted,
            property_override_json: desc
                .property_override_json
                .as_deref()
                .map(|json| {
                    let flat_json = serde_json::from_str::<Value>(json)
                        .map_err(|e| EngineError::InvalidInput(e.to_string()))?
                        .flatten()?;
                    serde_json::to_string(&flat_json)
                        .map_err(|e| EngineError::InvalidInput(e.to_string()))
                })
                .transpose()?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::window::MouseButtonTracker;

    #[derive(Debug, PartialEq, Eq)]
    enum ButtonDelivery {
        Baseline(u32),
        Transition(u32, bool),
    }

    fn deliver_sample_buttons(state: &mut NativePointerInputState, buttons: MouseButtonEdges) -> Vec<ButtonDelivery> {
        let mut sent = Vec::new();
        state.reconcile_button_baseline(buttons, |down| {
            sent.push(ButtonDelivery::Baseline(down));
            Ok(())
        }).unwrap();
        for edge in buttons.transitions() {
            state.set_button(edge.button, edge.pressed, |button, pressed| {
                sent.push(ButtonDelivery::Transition(button, pressed));
                Ok(())
            }).unwrap();
        }
        sent
    }

    #[test]
    fn released_during_video_reconciles_stale_native_down_without_replaying_release() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let mut tracker = MouseButtonTracker::new();
        tracker.set_button(0, true);
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Baseline(0), ButtonDelivery::Transition(0, true),
        ]);
        assert!(state.apply(&token, false));
        tracker.set_button(0, false);
        // The publisher discards all-video edges, retaining only the level.
        let _ = tracker.consume_edges();
        assert!(state.apply(&token, true));
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Baseline(0),
        ]);
    }

    #[test]
    fn video_held_level_has_no_press_and_its_next_release_survives() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let mut tracker = MouseButtonTracker::new();
        assert!(state.apply(&token, false));
        tracker.set_button(31, true);
        let _ = tracker.consume_edges();
        state.reconcile_button_baseline(tracker.consume_edges(), |_| panic!("video baseline")).unwrap();
        assert!(state.apply(&token, true));
        let held = tracker.consume_edges();
        assert!(held.transitions().next().is_none());
        assert_eq!(deliver_sample_buttons(&mut state, held), vec![ButtonDelivery::Baseline(1 << 31)]);
        tracker.set_button(31, false);
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Transition(31, false),
        ]);
    }

    #[test]
    fn activation_tap_and_first_sample_release_keep_their_transitions() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let mut tracker = MouseButtonTracker::new();
        assert!(state.apply(&token, false));
        tracker.set_button(1, true);
        let _ = tracker.consume_edges();
        assert!(state.apply(&token, true));
        // Both changes are after activation but before the first sample.
        tracker.set_button(1, false);
        tracker.set_button(0, true);
        tracker.set_button(0, false);
        assert_eq!(deliver_sample_buttons(&mut state, tracker.consume_edges()), vec![
            ButtonDelivery::Baseline(2),
            ButtonDelivery::Transition(0, true),
            ButtonDelivery::Transition(0, false),
            ButtonDelivery::Transition(1, false),
        ]);
    }

    #[test]
    fn same_bool_commit_reconciles_once_and_old_token_or_delivery_reset_does_not() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        let held = MouseButtonEdges::from_masks(1, 0, 0);
        assert_eq!(deliver_sample_buttons(&mut state, held), vec![ButtonDelivery::Baseline(1)]);
        assert!(!state.apply(&Arc::new(()), false));
        state.delivery.invalidate();
        assert!(deliver_sample_buttons(&mut state, held).is_empty());
        assert!(!state.apply(&token, true));
        assert_eq!(deliver_sample_buttons(&mut state, held), vec![ButtonDelivery::Baseline(1)]);
        // An already accepted press must not cause another same-scene baseline
        // before a later release; native retains both until its next draw.
        assert_eq!(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(3, 2, 0)), vec![
            ButtonDelivery::Transition(1, true),
        ]);
        assert_eq!(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(1, 0, 2)), vec![
            ButtonDelivery::Transition(1, false),
        ]);
        let mut replacement = NativePointerInputState::new(Arc::new(()));
        assert_eq!(deliver_sample_buttons(&mut replacement, held), vec![ButtonDelivery::Baseline(1)]);
    }

    #[test]
    fn failed_baseline_retries_using_latest_sample_and_preserves_direct_delivery() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token);
        let held = MouseButtonEdges::from_masks(1, 0, 0);
        assert!(state.reconcile_button_baseline(held, |_| Err(EngineError::Platform("baseline".into()))).is_err());
        // Direct setters remain direct even while sampled reconciliation is
        // pending. The later baseline must not clear this accepted native edge.
        let mut sent = Vec::new();
        state.set_button(2, true, |button, pressed| {
            sent.push(ButtonDelivery::Transition(button, pressed));
            Ok(())
        }).unwrap();
        sent.extend(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(4, 0, 1)));
        assert_eq!(sent, vec![
            ButtonDelivery::Transition(2, true),
            ButtonDelivery::Baseline(5),
            ButtonDelivery::Transition(0, false),
        ]);
        assert!(deliver_sample_buttons(&mut state, MouseButtonEdges::from_masks(4, 0, 0)).is_empty());
    }

    #[test]
    fn video_gate_validates_input_and_never_deduplicates_buttons() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        assert!(state.apply(&token, false));
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(matches!(state.set_position(invalid, 0.0, |_, _| panic!("video native call")), Err(EngineError::InvalidInput(_))));
        }
        for invalid in [32, u32::MAX] {
            assert!(matches!(state.set_button(invalid, true, |_, _| panic!("video native call")), Err(EngineError::InvalidInput(_))));
        }
        state.set_position(0.5, 0.5, |_, _| panic!("video native call")).unwrap();
        state.set_button(0, true, |_, _| panic!("video native call")).unwrap();
        state.set_entered(true, |_| panic!("video native call")).unwrap();
        assert!(state.apply(&token, true));
        let mut positions = Vec::new();
        state.set_position(0.5, 0.5, |x, y| { positions.push((x, y)); Ok(()) }).unwrap();
        state.set_position(0.5, 0.5, |_, _| panic!("duplicate position")).unwrap();
        assert_eq!(positions, vec![(0.5, 0.5)]);
        let mut buttons = Vec::new();
        for pressed in [true, true, false, false] {
            state.set_button(0, pressed, |button, pressed| { buttons.push((button, pressed)); Ok(()) }).unwrap();
        }
        assert_eq!(buttons, vec![(0, true), (0, true), (0, false), (0, false)]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn replacement_ignores_delayed_same_handle_instance() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let handle = SceneHandle::new(9);
        let (old_relay, old_callback) = PointerInputRelay::new(actor_ref.downgrade(), handle).unwrap();
        let (new_relay, new_callback) = PointerInputRelay::new(actor_ref.downgrade(), handle).unwrap();
        let mut state = NativePointerInputState::new(new_relay.renderer_instance.clone());
        let join = prepared.spawn(actor);
        new_callback(false);
        let token = wait_pointer_notification(&actor_ref, false).await;
        assert!(state.apply(&token, false));
        old_callback(true);
        let stale_token = wait_pointer_notification(&actor_ref, true).await;
        assert!(!state.apply(&stale_token, true));
        assert!(!state.accepts_pointer_input);
        new_callback(true);
        let token = wait_pointer_notification(&actor_ref, true).await;
        assert!(state.apply(&token, true));
        new_callback(false);
        let token = wait_pointer_notification(&actor_ref, false).await;
        assert!(state.apply(&token, false));
        drop(old_relay);
        drop(new_relay);
        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[test]
    fn delivery_retries_failures_and_reentry_without_rounding() {
        let mut delivery = MouseDeliveryState::default();
        let mut received = Vec::new();
        delivery.set_position(0.5, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        delivery.set_position(0.5, 0.5, |_, _| panic!("duplicate delivery")).unwrap();
        let tiny = f64::from_bits(0.5f64.to_bits() + 1);
        delivery.set_position(tiny, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        assert!(delivery.set_position(0.2, 0.5, |_, _| Err(EngineError::Platform("send".into()))).is_err());
        delivery.set_position(tiny, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        delivery.set_entered(true, |_| Ok(())).unwrap();
        delivery.set_entered(true, |_| panic!("duplicate enter")).unwrap();
        assert!(delivery.set_entered(false, |_| Err(EngineError::Platform("leave".into()))).is_err());
        delivery.set_entered(true, |_| Ok(())).unwrap();
        delivery.set_position(tiny, 0.5, |x, y| { received.push((x, y)); Ok(()) }).unwrap();
        assert_eq!(received, vec![(0.5, 0.5), (tiny, 0.5), (tiny, 0.5), (tiny, 0.5)]);
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(delivery.set_position(invalid, 0.0, |_, _| panic!("invalid native input")).is_err());
        }
    }

    #[test]
    fn native_commit_identity_and_same_value_invalidate_delivery() {
        let token = Arc::new(());
        let mut state = NativePointerInputState::new(token.clone());
        state.delivery.set_position(0.2, 0.3, |_, _| Ok(())).unwrap();
        let old = Arc::new(());
        assert!(!state.apply(&old, false));
        state.delivery.set_position(0.2, 0.3, |_, _| panic!("stale commit changed cache")).unwrap();
        assert!(!state.apply(&token, true));
        let mut sent = false;
        state.delivery.set_position(0.2, 0.3, |_, _| { sent = true; Ok(()) }).unwrap();
        assert!(sent);
        assert!(state.apply(&token, false));
        assert!(!state.accepts_pointer_input);
        assert!(state.apply(&token, true));
        assert!(state.accepts_pointer_input);
        state.delivery.set_entered(true, |_| Ok(())).unwrap();
        state.delivery.invalidate();
        let mut entered_sent = false;
        state.delivery.set_entered(true, |_| { entered_sent = true; Ok(()) }).unwrap();
        assert!(entered_sent);
    }

    fn prepared_empty_actor() -> (kameo::actor::PreparedActor<EngineActor>, EngineActor) {
        use kameo::actor::Spawn;
        let prepared = EngineActor::prepare();
        let state = crate::engine::state::EngineState::default();
        let snapshots = Arc::new(crate::engine::EngineSnapshotPublisher::new(
            state.snapshot(),
            Arc::new(std::sync::Mutex::new(crate::window::MouseButtonTracker::new())),
        ));
        let actor = EngineActor::new(OweBackend, Arc::new(|_| {}), state, snapshots, prepared.actor_ref().downgrade());
        (prepared, actor)
    }

    async fn wait_pointer_notification(actor: &kameo::actor::ActorRef<EngineActor>, value: bool) -> Arc<()> {
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let notifications = actor.ask(crate::engine::messages::TakePointerNotificationsForTest).await.unwrap();
                if let Some((instance, _)) = notifications.into_iter().find(|(_, accepts)| *accepts == value) {
                    return instance;
                }
                tokio::task::yield_now().await;
            }
        }).await.expect("relay should deliver without mailbox loss")
    }

    #[tokio::test(flavor = "current_thread")]
    async fn relay_replays_before_commit_and_survives_full_bounded_mailbox() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let (relay, callback) = PointerInputRelay::new(actor_ref.downgrade(), SceneHandle::new(7)).unwrap();
        // Fill the real default mailbox before the actor has started.
        let mut count = 0;
        loop {
            match actor_ref.tell(crate::engine::messages::Ping).try_send() {
                Ok(()) => count += 1,
                Err(kameo::error::SendError::MailboxFull(_)) => break,
                Err(error) => panic!("unexpected mailbox error: {error}"),
            }
        }
        assert_eq!(count, 64);
        callback(true);
        tokio::task::yield_now().await;
        // The first notification is blocked; the native callback remains synchronous.
        callback(false);
        callback(true);
        callback(false);
        let join = prepared.spawn(actor);
        let delivered = wait_pointer_notification(&actor_ref, false).await;
        assert!(Arc::ptr_eq(&delivered, &relay.renderer_instance));
        callback(true);
        let delivered = wait_pointer_notification(&actor_ref, true).await;
        assert!(Arc::ptr_eq(&delivered, &relay.renderer_instance));
        relay.stop();
        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        drop(join.await.unwrap().unwrap());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn relay_drop_aborts_full_mailbox_and_releases_actor_owner() {
        let (prepared, actor) = prepared_empty_actor();
        let actor_ref = prepared.actor_ref().clone();
        let weak = actor_ref.downgrade();
        let (relay, callback) = PointerInputRelay::new(weak.clone(), SceneHandle::new(1)).unwrap();
        while actor_ref.tell(crate::engine::messages::Ping).try_send().is_ok() {}
        callback(false);
        tokio::task::yield_now().await;
        let aborted = relay.task.abort_handle();
        drop(relay);
        callback(true);
        tokio::task::yield_now().await;
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while !aborted.is_finished() { tokio::task::yield_now().await; }
        }).await.expect("aborted relay should release its pending mailbox send");
        drop(actor_ref);
        drop(actor);
        drop(prepared);
        assert!(weak.upgrade().is_none());
        // The native forwarder holds only the watch sender, not an engine owner.
        callback(false);
    }

    #[test]
    fn relay_without_runtime_returns_error() {
        let (prepared, _actor) = prepared_empty_actor();
        assert!(PointerInputRelay::new(prepared.actor_ref().downgrade(), SceneHandle::new(1)).is_err());
    }

    #[test]
    fn scene_runtime_state_initial_uses_descriptor_pause_state() {
        let desc = crate::project::SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/project.json",
        )
        .assets_path("/tmp/assets")
        .paused(true)
        .build()
        .expect("scene should build");

        let state = SceneRuntimeState::try_from(&desc).expect("state should build");

        assert!(state.paused);
    }

    #[test]
    fn property_override_delta_keeps_matching_empty_override_unchanged() {
        let state = runtime_state(None);
        let descriptor_state = runtime_state(None);

        assert!(matches!(
            state.property_override_update(&descriptor_state),
            PropertyOverrideUpdate::Unchanged
        ));
    }

    #[test]
    fn property_override_delta_resets_only_when_descriptor_supplies_override() {
        let state = runtime_state(None);
        let descriptor_state = runtime_state(Some(r#"{"enabled":true}"#));

        assert!(matches!(
            state.property_override_update(&descriptor_state),
            PropertyOverrideUpdate::Reset
        ));
    }

    #[test]
    fn property_override_delta_applies_runtime_override_when_different() {
        let state = runtime_state(Some(r#"{"enabled":false}"#));
        let descriptor_state = runtime_state(Some(r#"{"enabled":true}"#));

        assert!(matches!(
            state.property_override_update(&descriptor_state),
            PropertyOverrideUpdate::Apply(r#"{"enabled":false}"#)
        ));
    }

    #[test]
    fn descriptor_property_override_change_is_not_reset_when_runtime_matches_current_descriptor() {
        let mut state = runtime_state(None);
        let current_descriptor_state = runtime_state(None);
        let next_descriptor_state = runtime_state(Some(r#"{"newproperty24":false}"#));

        state.inherit_descriptor_property_override(
            &current_descriptor_state,
            &next_descriptor_state,
        );

        assert_eq!(
            state.property_override_json.as_deref(),
            Some(r#"{"newproperty24":false}"#)
        );
        assert!(matches!(
            state.property_override_update(&next_descriptor_state),
            PropertyOverrideUpdate::Unchanged
        ));
    }

    #[test]
    fn explicit_runtime_property_reset_still_overrides_descriptor_refresh() {
        let mut state = runtime_state(None);
        let current_descriptor_state = runtime_state(Some(r#"{"newproperty24":true}"#));
        let next_descriptor_state = runtime_state(Some(r#"{"newproperty24":false}"#));

        state.inherit_descriptor_property_override(
            &current_descriptor_state,
            &next_descriptor_state,
        );

        assert_eq!(state.property_override_json, None);
        assert!(matches!(
            state.property_override_update(&next_descriptor_state),
            PropertyOverrideUpdate::Reset
        ));
    }

    #[test]
    fn different_wallpaper_rebuild_uses_next_descriptor_render_defaults() {
        let mut state = runtime_state(None);
        state.scaling_mode = ScalingMode::Fill;
        state.scaling_factor = 1.25;
        state.audio_response_enabled = true;
        let mut current_descriptor_state = runtime_state(None);
        current_descriptor_state.scaling_mode = ScalingMode::Fill;
        current_descriptor_state.scaling_factor = 1.25;
        current_descriptor_state.audio_response_enabled = true;
        let mut next_descriptor_state = runtime_state(None);
        next_descriptor_state.scaling_mode = ScalingMode::Stretch;
        next_descriptor_state.scaling_factor = 2.0;
        next_descriptor_state.audio_response_enabled = false;

        state.inherit_descriptor_defaults(
            &current_descriptor_state,
            &next_descriptor_state,
            DescriptorInheritance::UseDescriptorDefaults,
        );

        assert_eq!(state.scaling_mode, ScalingMode::Stretch);
        assert!(
            (state.scaling_factor - 2.0).abs() <= f64::EPSILON,
            "expected scaling factor {} to be within f64::EPSILON of 2.0",
            state.scaling_factor
        );
        assert!(!state.audio_response_enabled);
    }

    #[test]
    fn live_runtime_transition_state_for_new_wallpaper_uses_descriptor_scaling_defaults() {
        let current_desc = SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/current/project.json",
        )
        .assets_path("/tmp/assets")
        .scaling_mode(ScalingMode::Fill)
        .scaling_factor(1.25)
        .build()
        .expect("current scene should build");
        let next_desc = SceneDesc::builder(
            crate::DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            "/tmp/next/project.json",
        )
        .assets_path("/tmp/assets")
        .scaling_mode(ScalingMode::Fit)
        .scaling_factor(1.0)
        .build()
        .expect("next scene should build");
        let mut state =
            SceneRuntimeState::try_from(&current_desc).expect("current state should build");

        state
            .inherit_descriptor_transition(&current_desc, &next_desc)
            .expect("transition should build");

        assert_eq!(state.scaling_mode, ScalingMode::Fit);
        assert!(
            (state.scaling_factor - 1.0).abs() <= f64::EPSILON,
            "expected descriptor scaling factor 1.0, got {}",
            state.scaling_factor
        );
    }

    #[test]
    fn same_wallpaper_rebuild_preserves_explicit_runtime_render_overrides() {
        let mut state = runtime_state(None);
        state.scaling_mode = ScalingMode::Fill;
        state.scaling_factor = 1.25;
        state.audio_response_enabled = false;
        let current_descriptor_state = runtime_state(None);
        let mut next_descriptor_state = runtime_state(None);
        next_descriptor_state.scaling_mode = ScalingMode::Stretch;
        next_descriptor_state.scaling_factor = 2.0;
        next_descriptor_state.audio_response_enabled = true;

        state.inherit_descriptor_defaults(
            &current_descriptor_state,
            &next_descriptor_state,
            DescriptorInheritance::PreserveRuntimeOverrides,
        );

        assert_eq!(state.scaling_mode, ScalingMode::Fill);
        assert!(
            (state.scaling_factor - 1.25).abs() <= f64::EPSILON,
            "expected scaling factor {} to be within f64::EPSILON of 1.25",
            state.scaling_factor
        );
        assert!(!state.audio_response_enabled);
    }

    #[test]
    fn paused_runtime_requires_pause_restore_after_surface_reconfigure() {
        let mut state = runtime_state(None);
        state.paused = true;

        assert!(state.paused);
    }

    #[test]
    fn running_runtime_does_not_require_pause_restore_after_surface_reconfigure() {
        let state = runtime_state(None);

        assert!(!state.paused);
    }

    fn runtime_state(property_override_json: Option<&str>) -> SceneRuntimeState {
        SceneRuntimeState {
            scaling_mode: ScalingMode::Fit,
            scaling_factor: 1.0,
            render_resolution: None,
            audio_response_enabled: true,
            media_integration_enabled: false,
            paused: false,
            audio_volume: AudioVolume::try_from(1.0).expect("volume should be valid"),
            audio_muted: false,
            property_override_json: property_override_json.map(ToOwned::to_owned),
        }
    }
}
