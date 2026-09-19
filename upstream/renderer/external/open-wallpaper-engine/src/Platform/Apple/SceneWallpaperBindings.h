#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "../../Core/RendererCounters.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Bindgen-safe renderer surface for wallpaper-core.
 *
 * wallpaper-core owns scene handles, reconciliation, windows, and mutable
 * runtime state. These functions only expose transparent operations on
 * wallpaper::SceneWallpaper and audio response helpers. Do not add a registry,
 * display map, runtime manager, or descriptor mirror here.
 */

/* Opaque wallpaper::SceneWallpaper owner. */
typedef struct owe_scene_wallpaper owe_scene_wallpaper;

typedef void (*owe_log_callback)(int level, const char* file, int line, const char* message);
typedef void (*owe_first_frame_callback)(void* user_data);
typedef void (*owe_first_frame_callback_drop)(void* user_data);
typedef void (*owe_pointer_input_callback)(void* user_data, bool accepts_pointer_input);
typedef void (*owe_pointer_input_callback_drop)(void* user_data);

void owe_set_log_callback(owe_log_callback callback);

/* Renderer lifetime. */
int owe_scene_wallpaper_new(owe_scene_wallpaper** out_scene);
int owe_scene_wallpaper_delete(owe_scene_wallpaper* scene);
int owe_scene_wallpaper_init(owe_scene_wallpaper* scene);
int owe_scene_wallpaper_shutdown(owe_scene_wallpaper* scene);

/*
 * Initializes the Vulkan renderer with a CAMetalLayer-backed surface.
 *
 * Render width/height may be 0/0 to use the output dimensions. A single zero is
 * invalid and rejected by the implementation.
 */
int owe_scene_wallpaper_init_metal_vulkan(owe_scene_wallpaper* scene, void* metal_layer,
                                          uint32_t width, uint32_t height, uint32_t render_width,
                                          uint32_t render_height, double display_scale_factor);

/*
 * Pauses rendering and releases the Vulkan surface + swapchain. The scene
 * graph, compiled shaders, render-graph non-present passes, textures, audio,
 * and runtime state remain loaded. After this returns, the caller may safely
 * destroy the CAMetalLayer that was passed to
 * owe_scene_wallpaper_init_metal_vulkan (or to a prior
 * owe_scene_wallpaper_finish_surface_reconfigure).
 *
 * Synchronous: blocks until the render thread confirms completion.
 * Returns 0 on success, non-zero on failure.
 */
int owe_scene_wallpaper_begin_surface_reconfigure(owe_scene_wallpaper* scene);

/*
 * Rebuilds the Vulkan surface + swapchain from a new CAMetalLayer and resumes
 * rendering. Dimensions replace those passed to init_metal_vulkan. The render
 * graph is rebuilt unconditionally.
 *
 * Preconditions: begin_surface_reconfigure must have returned 0 since the
 * last init/finish.
 *
 * Synchronous: blocks until the new surface is presentable.
 * Returns 0 on success, non-zero on failure.
 */
int owe_scene_wallpaper_finish_surface_reconfigure(owe_scene_wallpaper* scene, void* metal_layer,
                                                   uint32_t width, uint32_t height,
                                                   uint32_t render_width, uint32_t render_height,
                                                   double display_scale_factor);

/* Applies SceneWallpaperConfig fields without persisting a duplicate config. */
int owe_scene_wallpaper_apply_config(owe_scene_wallpaper* scene, const char* source,
                                     const char* assets, const char* cache_path, uint32_t fps,
                                     bool paused, bool force_shader_refresh,
                                     const char* project_property_override_json);

/* Direct SceneWallpaper::setTargetFps forwarding. */
int owe_scene_wallpaper_set_target_fps(owe_scene_wallpaper* scene, uint32_t fps);

/* Direct SceneWallpaper::setPaused forwarding for live playback control. */
int owe_scene_wallpaper_set_paused(owe_scene_wallpaper* scene, bool paused);

/*
 * Sets the internal rasterization scale in (0, 1]; values outside are clamped
 * to [0.25, 1.0]. 1.0 renders at the author's canvas size.
 *
 * This is not a window or presentation scale: output size, fit/fill, user zoom,
 * crop and cursor mapping are unchanged, and only the number of pixels the
 * scene is rasterized with differs. Applied live — the project is not reparsed,
 * uploaded images are kept and video decoders keep playing.
 *
 * Plain-video wallpapers ignore it: their one render target holds a frame that
 * was already decoded at its own resolution.
 *
 * Returns 0 on success, non-zero on failure.
 */
int owe_scene_wallpaper_set_render_scale(owe_scene_wallpaper* scene, double scale);

/* Direct first-frame notification forwarding from SceneWallpaper. */
int owe_scene_wallpaper_set_first_frame_callback(owe_scene_wallpaper* scene,
                                                 owe_first_frame_callback callback,
                                                 void* user_data,
                                                 owe_first_frame_callback_drop drop_user_data);

/*
 * Reports committed scene pointer capability on the native main looper, with
 * an immediate replay there when installed. Requires an initialized scene.
 * Success transfers user_data ownership to drop_user_data; failure does not.
 * Replacing/clearing keeps old userdata alive until its last queued/in-flight
 * callback is released. A null callback clears notifications.
 */
int owe_scene_wallpaper_set_pointer_input_callback(
    owe_scene_wallpaper* scene, owe_pointer_input_callback callback, void* user_data,
    owe_pointer_input_callback_drop drop_user_data);

/* Direct mouse/pointer forwarding to SceneWallpaper. Coordinates are normalized canvas space. */
int owe_scene_wallpaper_mouse_input(owe_scene_wallpaper* scene, double x, double y);
int owe_scene_wallpaper_mouse_button(owe_scene_wallpaper* scene, int button, bool pressed);
int owe_scene_wallpaper_mouse_enter(owe_scene_wallpaper* scene, bool entered);

/* Reconciles held levels without creating or clearing pending edges. Requires initialization. */
int owe_scene_wallpaper_set_mouse_button_baseline(owe_scene_wallpaper* scene, uint32_t down);

/* Direct property forwarding to SceneWallpaper::setProperty*. */
int owe_scene_wallpaper_set_property_bool(owe_scene_wallpaper* scene, const char* name, bool value);
int owe_scene_wallpaper_set_property_int32(owe_scene_wallpaper* scene, const char* name,
                                           int32_t value);
int owe_scene_wallpaper_set_property_float(owe_scene_wallpaper* scene, const char* name,
                                           float value);
int owe_scene_wallpaper_set_property_string(owe_scene_wallpaper* scene, const char* name,
                                            const char* value);

/*
 * Scene-global audio controls.
 *
 * These are thin wrappers only. The actual audio mixer state remains owned by
 * SceneWallpaper and the higher-level renderer stack.
 */
int owe_scene_wallpaper_set_audio_volume(owe_scene_wallpaper* scene, float volume);
int owe_scene_wallpaper_set_audio_muted(owe_scene_wallpaper* scene, bool muted);

/*
 * Media integration boundary.
 *
 * These wrappers only expose primitive property/event submission. System media
 * ownership, event polling, and thumbnail updates stay above this C ABI.
 */
int owe_scene_wallpaper_submit_media_event_json(owe_scene_wallpaper* scene, const char* event_json);
int owe_scene_wallpaper_apply_system_media_artwork(owe_scene_wallpaper* scene, uint32_t width,
                                                   uint32_t height, const uint8_t* rgba,
                                                   uintptr_t rgba_len);

/*
 * Upstream property-name accessors. Rust uses these instead of duplicating
 * string literals that must match SceneWallpaper.hpp.
 */
const char* owe_property_scaling_mode(void);
const char* owe_property_scaling_factor(void);
const char* owe_property_horizontal_flip(void);
const char* owe_property_audio_response_enabled(void);
const char* owe_property_media_integration_enabled(void);
const char* owe_property_force_shader_refresh(void);
const char* owe_property_project_property_override_json(void);
const char* owe_property_project_property_reset(void);

/*
 * Process-wide playback options, applied to every renderer scene.
 *
 * `content_pacing` is the experimental content-demand frame scheduler; it stays
 * off unless explicitly enabled. Setting these replaces the corresponding
 * environment-variable overrides for new scenes and takes effect on the next
 * scene that reads them.
 */
void owe_set_content_pacing_enabled(bool enabled);
bool owe_content_pacing_enabled(void);

/*
 * Shared video decode: one decoder instance serving several display surfaces
 * that show equivalent video content. Off by default.
 *
 * The counts describe live sharing right now: `session_count` is the number of
 * distinct decoder instances currently held by the registry, and
 * `consumer_count` is the number of surfaces consuming them. Equal counts mean
 * nothing is actually being shared.
 */
void owe_set_shared_video_decode_enabled(bool enabled);
bool owe_shared_video_decode_enabled(void);
uint32_t owe_shared_video_decode_session_count(void);
uint32_t owe_shared_video_decode_consumer_count(void);

/* Audio-response sample submission shared by all renderer scenes. */
int owe_audio_submit_mono_frames(uint32_t sample_rate, uint32_t frame_count,
                                 const float* pcm_frames);
int owe_audio_submit_frames(uint32_t sample_rate, uint32_t frame_count, const float* pcm_frames);
int owe_audio_current_spectrum_128(float* out_bins, uintptr_t out_len, uint64_t* out_generation);
/*
 * Whether the analysis behind `owe_audio_current_spectrum_128` genuinely
 * carried two channels. Returns 1 for stereo, 0 for a mono source whose
 * left and right halves are therefore equal, and -1 when no analysis has run.
 * A mono source is never reported as stereo.
 */
int owe_audio_spectrum_is_stereo(void);

/*
 * Scene render optimisation, process-wide.
 *
 * Reuses the previous frame's pixels for render targets whose inputs have not
 * changed, and removes copy passes proven to have no consumer or to duplicate
 * an image nothing rewrites. It does not change output resolution, frame rate
 * or animation timing. Enabled by default; turning it off makes every pass
 * execute every frame so the two paths can be compared directly.
 */
void owe_set_scene_optimization_enabled(bool enabled);
bool owe_scene_optimization_enabled(void);
/*
 * Passes executed and passes skipped since the counters were last reset, plus
 * copies removed at compile time and the size the pinned targets are estimated
 * to occupy. The byte figure is derived from extent and mip count, not queried
 * from the allocator, so it bounds the cache rather than measuring residency.
 */
void owe_scene_optimization_stats(uint64_t* out_executed_passes, uint64_t* out_skipped_passes,
                                  uint64_t* out_elided_copies, uint64_t* out_pinned_bytes);

/*
 * Whole-scene on-demand updating, process-wide. Off by default.
 *
 * When a scene can be shown to have nothing that advances on its own — no
 * script, animation, particle emitter, video, audio-reactive shader, time
 * uniform, animated sprite, puppet, bound text, sound or unaccounted input —
 * its frame clock stops entirely instead of ticking at the configured rate.
 * The last presented frame stays on screen and events restart the clock.
 *
 * This is not a frame-rate setting and does not lower quality. A scene that
 * cannot be shown to be still keeps its existing cadence.
 */
void owe_set_scene_on_demand_enabled(bool enabled);
bool owe_scene_on_demand_enabled(void);

/*
 * How one scene is currently being updated, and why.
 *
 * Pull-only and unaffected by whether renderer counting is enabled: this is
 * live state a settings pane displays, not instrumentation.
 *
 * `owe_scene_wallpaper_update_mode` returns an `owe_scene_update_mode`, or -1
 * when the scene pointer is null. -1 means "not observed" and must not be
 * shown as any real state. `owe_scene_wallpaper_demand_reasons` returns a
 * bitmask of `owe_scene_demand_reason`; zero alongside a continuous mode means
 * on-demand updating is switched off rather than that no reason exists.
 */
int      owe_scene_wallpaper_update_mode(void* scene);
uint32_t owe_scene_wallpaper_demand_reasons(void* scene);

/*
 * Scene renderer preference, process-wide. Compatibility by default.
 *
 * A preference, not an outcome. A scene the native backend cannot draw falls
 * back to the compatibility backend and says why; the preference is never
 * reported as the backend in use.
 */
typedef enum owe_scene_renderer_preference {
    OWE_SCENE_RENDERER_COMPATIBILITY = 0,
    OWE_SCENE_RENDERER_NATIVE_METAL_PREFERRED = 1
} owe_scene_renderer_preference;

typedef enum owe_scene_backend {
    OWE_SCENE_BACKEND_LEGACY_VULKAN = 0,
    OWE_SCENE_BACKEND_NATIVE_METAL = 1
} owe_scene_backend;

void owe_set_scene_renderer_preference(int preference);
int  owe_current_scene_renderer_preference(void);

/*
 * Which backend actually drew this scene, or -1 when nothing has been observed.
 *
 * `owe_scene_wallpaper_backend_fallback_reason` writes a NUL-terminated reason
 * into `out` and returns the length excluding the terminator; passing a null
 * `out` or a zero `out_len` reports the length that would be needed. Zero means
 * the active backend is the preferred one.
 */
int    owe_scene_wallpaper_backend(void* scene);
size_t owe_scene_wallpaper_backend_fallback_reason(void* scene, char* out, size_t out_len);

/*
 * Renderer work counters.
 *
 * Counting is off by default and costs one relaxed atomic load per counted
 * event when enabled. Reading is pull-only: nothing is pushed, logged, or
 * written to disk, and enabling does not start a thread or a timer.
 *
 * `owe_scene_wallpaper_counters` writes at most `out_len` values in
 * `owe_renderer_counter` order and reports how many it wrote, so a caller
 * built against a shorter list stays correct. Values are read individually,
 * so a snapshot is a set of live readings rather than one instant.
 */
int owe_renderer_counters_set_enabled(bool enabled);
bool owe_renderer_counters_enabled(void);
int owe_scene_wallpaper_counters(owe_scene_wallpaper* scene, uint64_t* out_values,
                                 uintptr_t out_len, uintptr_t* out_written);
/* Process-wide counters, in `owe_renderer_shared_counter` order. */
int owe_renderer_shared_counters(uint64_t* out_values, uintptr_t out_len, uintptr_t* out_written);

/* Thread-local error text for the last non-zero-returning call on this thread. */
const char* owe_last_error(void);

#ifdef __cplusplus
}
#endif
