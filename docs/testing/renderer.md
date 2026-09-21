# Renderer verification

Non-desktop verification of the vendored renderer in `upstream/renderer`: the
Rust crates, the C++ scene engine and its GPU probes. Nothing here creates a
window, swapchain, audio device, or screenshot, and nothing here inspects or
changes the desktop. Dated results live in
[verification-log.md](verification-log.md); this file is the working reference.

This file is long. Read the section you need rather than the whole file
(`rg -n '^##' docs/testing/renderer.md` gives the line numbers):

| Section | Read it when |
|---|---|
| [`scripts/check_renderer.py`](#scriptscheck_rendererpy) | Running or changing the renderer check itself |
| [Probes](#probes) | Driving `offscreen_scene_probe` and friends by hand; `WE_TEST_*` variables |
| [Regression areas that must stay covered](#regression-areas-that-must-stay-covered) | Before changing renderer behaviour: the table names the test that guards each area |
|  [Property bindings and alignment anchors](#property-bindings-and-alignment-anchors) | Property scripts, `origin`/`scale`/anchor maths |
|  [Native writes from scripts, puppet layers and cursor coverage](#native-writes-from-scripts-puppet-layers-and-cursor-coverage) | SceneScript side effects, puppets, cursor hit tests |
|  [Startup and staging buffers](#startup-and-staging-buffers), [Alpha compositing](#alpha-compositing) | First-frame, staging, blend modes |
|  [Vector material constant timelines](#vector-material-constant-timelines), [Scripted material constants](#scripted-material-constants-keep-their-component-count) | Material constants and their animation |
|  [Timeline events](#timeline-events), [Animation and puppets](#animation-and-puppets) | Event timelines, puppet animation layers |
|  [Cursor coordinates and presentation](#cursor-coordinates-and-presentation) | Pointer mapping across displays and scales |
|  [Text, fonts and clocks](#text-fonts-and-clocks) | Text layers, font fallback, clock formats |
|  [Textures, allocation and composition](#textures-allocation-and-composition) | Texture keys, allocation, composition layers |
|  [Frame timing](#frame-timing), [Frame pacing](#frame-pacing-follows-the-content-bounded-on-both-sides) | Pacing, throttling, battery behaviour |
|  [Continuous-playback work contracts](#continuous-playback-work-contracts), [Renderer work counters](#renderer-work-counters) | Work-per-frame contracts, `RuntimeCounters` |
|  [Video decode state machine and colour range](#video-decode-state-machine-and-colour-range) | Video playback in scenes |
|  [Shader pipeline](#shader-pipeline) | GLSL translation, uniform blocks, varyings |
| [Rust crates](#rust-crates) | `cargo test` commands and the configure-retry trap |
| [C++/CMake test binaries](#ccmake-test-binaries) | Building and filtering the gtest executables |
| [Known limitations](#known-limitations) | Before reporting a failure as a regression: the pre-existing ones are listed |

## `scripts/check_renderer.py`

```sh
python3 scripts/check_renderer.py
```

It assembles the Homebrew environment from `scripts/build.py`, then:

1. builds `cargo build -p shader --features ffi --release` **from
   `upstream/renderer`**, because rustup resolves that tree's
   `rust-toolchain.toml` (nightly) from the working directory, not from
   `--manifest-path`; running it from the repository root picks the default
   stable toolchain instead,
2. configures CMake over `upstream/renderer/external/open-wallpaper-engine` with
   `CMAKE_BUILD_TYPE=Release`, `BUILD_TESTS=ON`, `RUST_SHADER_FFI=ON`, and
   `RUST_SHADER_STATICLIB`
   pointing at `upstream/renderer/target/release/libshader.a`,
3. builds `offscreen_scene_probe`, `scene_reload_cycle_probe`,
   `render_target_lifetime_test`, `text_object_runtime_test` and
   `shader_cache_metadata_test`,
4. runs the three test binaries,
5. renders every case twice through `offscreen_scene_probe` — once pooled, once
   isolated (`WE_TEST_NO_REUSE=1`) — and compares `frame-2` byte for byte,
6. scans both logs for `ERROR` diagnostics (ignoring shader-cache misses),
7. checks independent known-pixel assertions for the generated cases, so two
   equally blank or corrupt outputs cannot both pass,
8. runs `scene_reload_cycle_probe` over the selected projects twice each.

| Flag | Effect |
| --- | --- |
| `--skip-build` | Reuse the existing binaries instead of rebuilding |
| `--project PATH` | Add a local scene `project.json`; repeatable |
| `--assets PATH` | Shared assets directory (default `~/Library/Application Support/mac-wallpaper-engine/SceneAssets`) |

Reports, SHA-256 hashes, logs, the generated synthetic fixtures and private GPU
output go under a fresh `artifacts/renderer/<run>/` directory, with
`report.json` as the summary; check binaries live in `artifacts/renderer/bin/`.
Imported wallpapers are read only. A nonzero exit means a test binary failed, a
pooled/isolated pair diverged, a generated case emitted diagnostics, or a
generated pixel assertion failed. `report.json` records
`full_compatibility_verified: false` on every case: there is no
authored-reference comparison, so rendering without a crash does not prove all
authored effects loaded.

The generated matrix is ten original synthetic scenes; it contains no workshop
identifiers and no workshop-specific rendering rules.

## Probes

All probes are explicitly invoked executables, not ctest cases or UI tests.
`offscreen_scene_probe` creates a surface-free Vulkan device and private render
targets, uses the production shader passes and batching plan, and writes PPM
images under `WE_TEST_OUTPUT`. Use a disposable output/cache directory. The
device requests the same extension set as the wallpaper renderer, including
`VK_EXT_metal_objects` on Apple, so a scene whose textures are video streams
imports its frames here instead of rendering empty texture slots.

```sh
WE_TEST_PROJECT="$HOME/Library/Application Support/mac-wallpaper-engine/Library/<id>/project.json" \
WE_TEST_ASSETS="$HOME/Library/Application Support/mac-wallpaper-engine/SceneAssets" \
WE_TEST_OUTPUT="$PWD/artifacts/renderer/scratch" \
artifacts/renderer/bin/tests/offscreen_scene_probe
```

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_PROJECT` | `offscreen_scene_probe`, `text_object_runtime_test` | Path to a scene `project.json` |
| `WE_TEST_PROJECTS` | `scene_reload_cycle_probe` | `;`-separated project list |
| `WE_TEST_ASSETS` | probes | Shared `SceneAssets` directory |
| `WE_TEST_OUTPUT` | probes | Output/cache directory (disposable) |
| `WE_TEST_CACHE` | `text_object_runtime_test` | Disposable shader cache directory |
| `WE_TEST_CYCLES` | `scene_reload_cycle_probe` | Reload cycles per project |
| `WE_TEST_NO_REUSE=1` | `offscreen_scene_probe` | Isolated texture allocation (no pooling) |
| `WE_TEST_FRAMES` | `offscreen_scene_probe` | Number of sampled frames |
| `WE_TEST_FRAME_STEP` | `offscreen_scene_probe` | Sampling interval, to look past an intro |
| `WE_TEST_DUMP_SOURCE=1` | `offscreen_scene_probe` | Write the packaged scene JSON beneath `WE_TEST_OUTPUT`; `nodes.txt` also records per-node visibility, translate and scale, which diffs layer placement between builds without comparing pixels |
| `WE_TEST_ASSET_PATH` | `offscreen_scene_probe` | Copy one asset from the mounted package to `asset.txt` under `WE_TEST_OUTPUT` for shader diagnosis; keep private asset output uncommitted |
| `WE_TEST_MEDIA_JSON` | `offscreen_scene_probe` | JSON array of synthetic media events dispatched to scene scripts; does not read system media |
| `WE_TEST_MEDIA_ARTWORK=1` | `offscreen_scene_probe` | Synthetic four-color 2x2 `$mediaThumbnail` texture; no player or audio device |
| `WE_TEST_DUMP_PASSES` | `offscreen_scene_probe` | Dump per-pass detail for the last sampled frame only: one image per custom pass, plus that pass's material slot, its live visibility and its full `constValues` appended to `passes.txt`. The prepare-time listing at the top of that file is a snapshot; only these `frame N` lines show what a sampled frame actually drew |
| `WE_TEST_PROPERTIES` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Flat JSON property overrides, in memory only. A layer gated on a saved property draws nothing without this, which is how both backends have to be driven to compare one |
| `WE_TEST_CLICK_LAYER` | `offscreen_scene_probe` | Image-layer ID to click |
| `WE_TEST_CLICK_COUNT` | `offscreen_scene_probe` | `1..10` synthetic clicks, no desktop input |
| `WE_TEST_CLICK_OFFSET` | `offscreen_scene_probe` | World-space `"dx dy"` added to the click layer's origin, to hit a covered or transparent texel instead of the centre |
| `WE_TEST_CLICK_VIEWPORT` | `offscreen_scene_probe` | `"<px_w>x<px_h>@<scale>:<fill\|fit\|stretch\|none>"`; maps the click the way a desktop does — the presented viewport is published and the cursor arrives window-normalized — instead of handing the runtime a world position, so hit testing is exercised against a real display's geometry |
| `WE_TEST_AUDIO_HZ` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Synthetic PCM at `0..6000` Hz; `0` means silence. The Metal gate submits one block per frame through the same analysis service the desktop tap feeds and enables audio response for the run. Band 0 of the 64-band spectrum covers roughly 0–94 Hz, so a shader reading only the lowest bands needs a bass tone, not 440 Hz |
| `WE_TEST_AUDIO_ENABLED=0` | `offscreen_scene_probe` | Exercise the disabled audio gate |
| `WE_TEST_MEDIA_EVENTS` | `offscreen_scene_probe` | JSON array of SceneScript media event objects, dispatched in order after the warm-up ticks. Enables media integration for the run, so a wallpaper that only draws its player while something is playing can be rendered without a system media source or Automation permission |
| `WE_TEST_MEDIA_ARTWORK` | `offscreen_scene_probe` | `<width>x<height>:<rrggbb>`; publishes one opaque cover through the same path the app uses, so `$mediaThumbnail` and `$mediaPreviousThumbnail` carry a colour that is legible in the rendered frame |
| `WE_TEST_RANDOM_SEED` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Seeds the particle random source before the scene is parsed, so the same project simulates the same particles on both renderers and their frames can be compared. The probe only steps the particle simulation when `WE_TEST_AUDIO_HZ` is set, and only advances time when `WE_TEST_FRAME_STEP` is |
| `WE_TEST_METAL_PROJECTS` | `metal_scene_draw_smoke` | Colon-separated `project.json` paths run through the production parser into the native backend offscreen. A fallback is printed with its reason and is not a failure; an accepted scene must prepare and draw 120 frames. With `WE_TEST_OUTPUT` set, the last frame is written there. Unset, the test skips |
| `WE_TEST_DUMP_TARGETS` | `offscreen_scene_probe` | Colon-separated render target names, or `*` for every target the scene declares; the last frame of each is written as `target-<name>.ppm`. Same meaning as the Metal harness's own knob, so a target can be held against its counterpart on the other backend |
| `WE_TEST_DUMP_PASSES=1` | `offscreen_scene_probe` | Writes every pass's output on the last frame plus a `passes.txt` naming each pass's material, bound textures and folded constants. Note the image is the whole pooled allocation, which can be larger than the target, and the constants listed are the parse-time ones |
| `WE_TEST_MEDIA_ARTWORK`, `WE_TEST_MEDIA_EVENTS` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | The now-playing state the app would deliver. Both harnesses take them with the same meaning, so a wallpaper whose background is drawn from the current cover can be held against the other backend -- without one it renders flat grey on both and the comparison says nothing |
| `WE_TEST_DUMP_ALPHA=1` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Writes each dumped target's alpha channel separately as grey. Effects that weight by coverage -- the bokeh downsample divides by the sum of its taps' alpha -- make different colour from the same RGB when alpha differs |
| `WE_TEST_METAL_SURFACE` | `metal_scene_draw_smoke` | `<width>x<height>` for the surface the native backend rasterizes; defaults to `960x540`. Screen-space shader inputs follow it, so comparing this backend's output with another's is only meaningful when both rasterize the same extent |
| `WE_TEST_SCENE_OPTIMIZATION=0` | `metal_scene_draw_smoke` | Turns static-result reuse off around the local-project loop, which is how a scene that looks wrong under it is compared with the same scene drawn every frame. Process-global, so it is restored afterwards |
| `WE_TEST_METAL_DUMP_TARGETS` | `metal_scene_draw_smoke` | Colon-separated render target names, or `*` for every target the scene declares. Each is reported with its size and mean luma and, with `WE_TEST_OUTPUT` set, written as a PPM. Target names carry a per-run suffix, so `*` is the only way to name one across two processes |
| `WE_TEST_EXPECT_WARM=1` | `text_object_runtime_test` | Assert zero shader compilations on a second run |
| `WE_TEST_DUMP_POSES=1` | `wpdump` | Dump sampled bone transforms |

Audio is submitted after GPU setup so shader compilation cannot expire its
live-input timeout. These options never initialize audio hardware. Keep all
probe output outside Git. If IDE ignore rules block reads under the repository's
ignored directories, write to a system temporary directory instead.

`offscreen_scene_probe` reports `startup parsed`, `prepared` and `first-frame`
timings. Use a fresh `WE_TEST_OUTPUT` for a cold shader-cache run and repeat the
same directory for a warm run. It resolves each project's entry/package version
and render dimensions and discovers text nodes instead of using fixed layer IDs.
It tests scene rendering only — not video or web projects, and not AppKit
presentation.

`scene_reload_cycle_probe` parses every selected project twice in one process,
each parse on a fresh thread with fresh VFS mounts, the way a wallpaper switch
builds a new `SceneWallpaper`. It catches per-process state that survives a
scene teardown and stalls the next load; a stall is reported as a probe timeout.
It covers scene parsing and script compilation only, not presentation.

`playback_gpu_test` is Apple-only and requires real Metal/MoltenVK
capabilities. It uses private images and synthetic IOSurface-backed inputs and
creates no window, surface, swapchain, audio device, or screenshot. Missing
required GPU capabilities fail explicitly rather than skipping. Run the built
executable directly from the renderer check build directory.

## Regression areas that must stay covered

| Area | Coverage |
| --- | --- |
| Camera zoom | `scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'`. Scene `general.zoom` may contain an authored scalar animation, not just a fixed camera scale. |
| Camera layers in 2D scenes | `SceneSchema.CameraObjectKeepsAnOrthographicSceneOnItsCanvas` next to `SceneSchema.DefaultCameraObjectBecomesActivePerspective` in `scene_schema_tests`. A scene with `orthogonalprojection` is projected by that canvas; a `camera` layer in one must not become the active perspective camera (see below). |
| Callback-only property scripts | `*CallbackOnly*` in `scene_schema_tests` and `script_runtime_compat_test` |
| Property-script feedback / hover easing | `ScriptRuntimeCompat.HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping` and `ScriptRuntimeCompat.PropertyFeedbackResumesFromExplicitUserValueChanges` in `script_runtime_compat_test` |
| Script-driven layer visibility | `SceneSchema.HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin` in `scene_schema_tests`. The authored `visible.value` is the script's initial value, never a permission to run it (see below). |
| Alignment anchors under dynamic transforms | `SceneSchema.ImageAlignmentAnchorSurvivesScriptedOriginAndScale` in `scene_schema_tests`, plus `nodes.txt` translate diffs from `offscreen_scene_probe` |
| SceneScript writes from `update()` | `ScriptRuntimeCompat.UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined` in `script_runtime_compat_test`: a `thisLayer.visible = …` written during `update()` survives the next reevaluation even when `update()` returns nothing (see below). |
| Video-controlled visibility and music scripts | `scenescript_media_event_smoke`: `getVideoTexture().isPlaying()` reflects shared runtime pause/play state, so scripts that hide a layer during init can reveal it during update; `Vec*.mix` and `MediaPlaybackEvent` constants are available. |
| Legacy effect shader interfaces | Shader `pipeline` tests: array varyings reserve all element locations; unambiguous user function parameters narrow wider vector arguments; custom scalar/vector uniforms across stages share a vector block with stage-local prefix views. Engine `g_*` uniform type conflicts remain errors. |
| Puppet animation layer control | `ScriptRuntimeCompat.PuppetAnimationLayer*` in `script_runtime_compat_test`: `getAnimationLayer(name).play()` restarts a finished single-shot layer on every copy of the shared state; a `visible` bound to a user property toggles the layer. |
| Cursor coverage masks | `ScriptRuntimeCompat.CursorHitTestRespectsCoverageMask` in `script_runtime_compat_test`: transparent texels of a cursor-scripted image layer do not hit. `offscreen_scene_probe` with `WE_TEST_CLICK_OFFSET` exercises real assets. |
| Cursor hit testing under scaling | `MouseInput.CursorViewportMapsWindowOntoTheCroppedSceneRectangle`, `MouseInput.LayerHitTestingFollowsWhereTheWallpaperIsPresented`, `MouseInput.LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge` in `mouse_input_test`, and `ScriptRuntimeCompat.HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper` (see below) |
| MDLS3 hierarchy/pivots | `MdlSchema.Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions` in `mdl_schema_tests`. Mesh format versions do not justify flattening an authored skeleton. |
| Large-scene first-frame startup | `offscreen_scene_probe` cold/warm startup timings; staging-buffer growth must stay geometric (see below) |
| JPEG/EXIF orientation | `tex_schema_tests`: all eight EXIF display transforms on asymmetric RGBA pixels, both TIFF byte orders, truncated JPEG/EXIF data, invalid IFD offsets |
| Translucent coverage / alpha compositing | the `generated-alpha` case in `scripts/check_renderer.py` |
| Vector material constant timelines | `SceneSchema.*VectorTimeline*` and `SceneSchema.SharedVectorTimelineWrapsOnlyOnTheParentClock` in `scene_schema_tests`, `ScriptRuntimeCompat.VectorMaterialTimelineDrivesEveryComponentSeparately` and `ScriptRuntimeCompat.ClonedTemplateLayersShareOneTimelineAndKeepEveryBinding` in `script_runtime_compat_test`, and the `generated-perspective-animation` case in `scripts/check_renderer.py` (see below) |
| Scripted vector material constants | `SceneSchema.ScriptedMaterialConstantsKeepTheComponentsTheShaderDeclares` in `scene_schema_tests`: a script that swaps a `vec2`'s components only produces the authored numbers when it is handed a vector (see below) |
| Timeline events | `ScriptRuntimeCompat.*Timeline*Event*`, `*Marker*`, `GlobalAnimationListenersRunOncePerMarkerWhateverIsBound`, `GlobalOnlyAnimationListenerSeesTheCurrentTickTime` and `SceneGetAnimationFindsATimelineOnAnotherLayer` in `script_runtime_compat_test`: crossing, `event.frame`, reverse travel and exact loop wraps, delivery after `init`, one global listener run per marker with zero and two bound scene scripts, a fresh host context for a global-only listener, and scene-wide `getAnimation` (see below) |
| Clock/text corruption | `render_target_lifetime_test`, `text_object_runtime_test`, `shader_cache_metadata_test` |
| Continuous-playback resource reuse | `playback_gpu_test` |
| Render-target reuse correctness | `static_subgraph_cache_test` (reuse verdicts, copy elision, alias resolution) and, on the native backend, `MetalSceneDraw.AnUnchangedTargetIsReusedAndProducesTheSamePixels` / `.TurningTheOptimisationOffDrawsEveryPassAgain` in `metal_scene_draw_smoke`. Reuse must be provable by readback, not by a counter alone: a skipped pass has to leave byte-identical pixels, and a changed input has to redraw. |
| Sprite-sheet stepping and reuse | `MetalSceneDraw.ASpriteSheetAdvancesOnItsOwnClockAndRedrawsOnlyWhenTheFrameChanges`. A sheet between frame changes may be reused, but its clock must keep running or the animation never reaches the next frame. |
| Per-frame geometry upload | `MetalSceneDraw.GeometryRebuiltEveryFrameIsUploadedAndDrawnFromItsOwnSlot`, across more frames than there are in-flight slots. Zero live particles must draw nothing rather than fail. |
| Native backend admission | `metal_backend_test`: every refused construct keeps its own distinct reason; plain sheets, sprite particles, sprite trails, thin and thick ropes, rope trails and a skinned mesh under a `g_Bones` shader are accepted by their actual layout; a sprite trail without velocity, a rope-marked sprite layout, a thin rope trail, a skinning shader on a mesh without bone weights and a bone stride that cannot hold a 4x4 matrix are refused; a puppet under an effect chain is judged by the chain's final mesh, and only on the chain's last node. An unused perspective camera does not reject; a supported layer that names a perspective camera, or an active perspective camera with supported layers, is accepted. |
| Perspective cameras on Metal | `MetalProjection.PerspectiveUsesFovAspectNearFarAndAHomogeneousDivide`, `.UnprojectingNdcHitsTheLayerPlane`, `.CameraAxesFollowTheAttachedNode` in `metal_backend_test`; `MetalSceneDraw.APerspectiveCameraDrawsThroughTheAuthoredShader` in `metal_scene_draw_smoke`. Projection is the scene camera's own FOV/aspect/near/far, not an orthographic scale; a rotated card must foreshorten. |
| Layer as texture | `layer_texture_reference_test` (CPU, in the gate): `_rt_imageLayerComposite_<id>[_a|_b]` forward refs, duplicate names, missing targets, cycles, history `_b`, file names vs layer names, invisible sources kept, producer-before-consumer graph order, and an effect-chain source linking from its composite rather than `_rt_default`. |
| Rope and rope-trail geometry | `particle_rope_geometry_test` (CPU, in the gate): pieces per instance and never across instances, dead particles skipped and neighbours joined, subdivision through the particles, coincident points without `NaN`, the rope-trail head, tail shrink and per-slot separation, and the simulation's history — birth point, growth to capacity, zero time step, respawn reset. Index width: packed 16-bit up to 16 384 quads, 32-bit past that, overflow-safe capacity math, and draw order across instances on a 32-bit mesh. |
| Skinning on the native backend | `MetalSceneDraw.APuppetIsSkinnedByItsOwnShaderFromThePoseTheRuntimeProduces`: a 64-byte reflected bone stride, the skinned quad translating by the distance its bone did with its width unchanged (what rules out a transposed matrix), the unskinned quad still, no reuse while the pose moves, `pause()` freezing and `play()` resuming. `.TheShippedImageShaderSkinsAPuppetThroughTheNativeBackend` repeats the translation and draw with the author's `genericimage2`, and skips without the shipped shaders. |
| Trail and rope layouts on the native backend | `MetalSceneDraw.ARopeLayoutMeshReachesTheTarget`, `.ASpriteTrailMeshReachesTheTarget`, and `.TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively`, which runs the editor's own preview projects through the real parser and shaders and skips without the shipped assets. |
| Scene optimisation applied at runtime | `MetalSceneDraw.TurningTheOptimisationBackOnDoesNotReuseAFrameDrawnWhileItWasOff` and `.AGraphCompiledWithTheOptimisationOffStartsReusingWhenItIsTurnedOn`. Turning the setting on must reach a graph that was compiled while it was off, on that graph's next frame, without reusing pixels no plan recorded. |
| Video consumption decided before import | `MetalVideoTexture.PlanesOnlyDemandEncodesNoConversion`, `.MixedDemandConvertsOnceAndStillPublishesThePlanes`, `.ADemandChangeReImportsTheSameGenerationInsteadOfWaiting`. A frame every consumer samples as planes must encode no conversion and allocate no destination; a mixed scene must convert exactly once. |
| Video pixel format decided per frame | `MetalVideoTexture.ABgraFrameIgnoresAPlaneDemand` and `.AFormatChangeSwitchesPathWithoutLosingTheTexture`. Software decode hands back BGRA and VideoToolbox hands back NV12 for the same file, either can take over mid-playback, and neither may reparse the scene or lose the picture. |
| Direct plane sampling, end to end | `MetalSceneDraw.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader` and `.AVideoLayerKeepsConvertingWhileTheSettingIsOff`: an ordinary parsed author material, a real decoded video, the variant compiled by the parser, bound through its own reflection and drawn. A test-only shader does not cover this. |
| Direct-versus-converted picture | `MetalSceneDraw.OneToOneSamplingProducesTheSamePictureOnBothPaths` (must agree to one code value) and `.ScaledSamplingStaysInsideTheClampExcursionTheStreamImplies` (see [performance](../features/performance.md)). The paths are exactly equivalent at a one-to-one mapping; under resampling they differ only where the stream carries codes outside the range it declares, bounded by that clamp's own excursion. |
| Plane variant refusals | `video_planes.rs` in `crates/shader`: an explicit-LOD sample, a size query, and any other use of the video slot refuses the variant instead of mistranslating it, and the ordinary program is unchanged by the option existing. |
| Text layers on the native backend | `MetalSceneDraw.ATextLayerIsParsedTranslatedAndDrawnByTheNativeBackend`: a parsed text object, the text program translated to Metal, the rasterised glyphs imported and the card drawn into the scene's own target. A text layer must reach the backend through the ordinary parser, not through a hand-built mesh. |
| Unchanged text costs nothing | `MetalSceneDraw.TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain`: twelve frames of an unchanged string measure nothing and upload nothing, a new string costs at most one upload per in-flight frame and reaches the drawn picture, and it then goes quiet again. The script keeps running throughout; "quiet" must never be achieved by stopping it. |
| Text layers under an effect chain | `MetalSceneDraw.ATextLayerWithAnEffectChainKeepsBothOfItsCards`: a text layer with effects has three meshes the relayout rewrites — its own card, the chain's final card and the node the chain resolves its last pass onto — and all of them have to be accepted and updated, or the scene falls back as a whole or freezes at its first layout. Use text whose glyphs differ, not more of the same word: the chain clips the card to its buffer, so a longer repetition can leave identical pixels. |
| Optional programs stay off the load path | `MetalSceneDraw.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader` asserts the parse compiled nothing optional before asking for it; `.AVideoLayerKeepsConvertingWhileTheSettingIsOff` asserts the program was never even claimed while the switch was off. Preparing an optional variant during a parse is a first-frame cost, not a free one. |
| Metal program reuse | `MetalSceneDraw.TheSameProgramIsCompiledOnceAndReusedByTheNextSurface`: a second renderer on the same device must not hand an identical translated program to the Metal compiler again. The pipeline key must identify the program by content, never by the address of the object holding it. |
| A scene with nothing left to do | `MetalSceneDraw.AStaticTextSceneRunsOutOfWorkToDo`, `.AStaticTextLayerUnderAnEffectChainAlsoRunsOutOfWork` and `.TextBoundToAUserPropertyIsEventDrivenRatherThanContinuous`: a static caption must reach zero demand reasons, having actually drawn, while the renderer still reports `EventMesh` and `RuntimeImage` — the reuse cache depends on both, and neither is a reason to keep the frame clock. Assert the reasons, not the frame rate. |
| Waking from idle, and not waking | `MetalSceneDraw.AChangedCaptionWakesTheSceneAndThenLetsItGoQuietAgain` and `TextObjectRuntime.PreparedTextWakesWhoeverOwnsTheFrameClock`: a changed caption brings the demand back, reaches the output and goes quiet again; the text worker asks for the frame that shows its result, because a scene that has already idled has no clock to notice; and rewriting the same string wakes nothing. A wallpaper that idles and then misses an update is worse than one that never idles. |
| Content that must never be called still | `MetalSceneDraw.TextProducedByAScriptIsNeverCalledStill`: a caption computed every tick keeps the clock on every frame, whatever the script returns. No script source is read, no repeated result is counted and no schedule is inferred. |
| Geometry rewritten on an event | `SceneDemandMapping.GeometryRewrittenOnAnEventIsNotAReasonToKeepDrawing` in `static_subgraph_cache_test`: `EventMesh` and `DynamicMesh` must both cost a target its cacheability and must differ at the scene level. Collapsing them back into one bit either stops static text idling or idles a particle system. |
| Optional programs across launches | `MetalSceneDraw.AnOptionalProgramTranslatedOnceIsRestoredFromDiskOnTheNextLaunch`: after the in-memory caches are cleared, the stored entry must reproduce the Metal source, the reflection *and* the per-stage binding plan without the compiler running; truncated entries must fall back to a normal compile. Restoring MSL alone is not a restored program. |
| Pipeline archive on the production path | `MetalSceneDraw.PipelinesThisProcessBuildsAreArchivedAndServeTheProductionPath`: pipelines are offered to the archive, published, reopened from disk and satisfied strictly, and a scene with no archive path still draws. A written archive that is never attached to a production descriptor proves nothing. |
| Download-speed sampling | `DownloadTelemetryTests` in `Tests/Unit/Workshop/`: real `nettop` streaming over a private PTY with local-socket traffic; CRLF and split line endings. LF-only fixtures do not verify live delivery. |
| Who owns the first frame | `MetalSceneDraw.ADrawnFrameIsReportedAsPresentedAndLeavesTheFirstFrameFlagAlone`: a backend must report presentation through `drawFrame`'s `presented` out-parameter and leave `Scene::first_frame_ok` to the frame handler. A backend that sets the flag satisfies the handler's own check before the handler runs, the host is never told the wallpaper started, and the startup deadline tears down a wallpaper that is drawing correctly. |
| Decoded frames carry real timestamps | `video_source_input_test` and `shared_video_session_test` against media the tests encode. A frame whose timestamp is always zero looks like playback for as long as frames keep arriving and then freezes, so a video regression here reads as "the picture stopped" rather than as a decode failure; the FFmpeg header/library check in `src/Video/FfmpegAbi.hpp` exists because the layout mismatch that produced it compiles cleanly. |
| One clock per shared decoder | `SharedVideoSessionTest.AFrameStaysValidAfterTheDecoderMovesOn` and `.PausingOneSurfaceLeavesTheOtherPlaying`: exactly one elected consumer moves a shared session's clock, so a test that advances the non-driving consumer observes nothing. Make the advancing consumer the driver rather than loosening the election. |

### Camera layers in 2D scenes

`orthogonalprojection` decides what a scene is. When it is present the scene is
projected by that canvas: `ParseCamera` makes `cameras["global"]` the active
orthographic camera at the canvas centre, and every 2D layer's card size,
`origin` and `alignment` is authored in that space. When it is null the scene is
projected by a camera, and a `camera` layer is the shot that camera plays.

`ParseCameraObj` used to apply the second reading to both. A visible layer with
`"camera": "default"` attached its node to `global_perspective`, forced that
camera's FOV to the layer's own and made it active — so a 2D wallpaper was
suddenly viewed through a perspective camera standing wherever the shot was
authored. The usual authored pose is a few hundred units off the canvas plane at
fov 50, which frames a few hundred units of a canvas thousands of units wide:
one magnified sliver of a corner, `general.clearcolor` everywhere else. Layers
with an effect chain render through their own effect camera and were unaffected,
which is why the symptom reads as "most of the wallpaper is missing" rather than
as a camera bug. Workshop 3605722997 and 3292361861 are both scenes of that
shape; their shot layers even disagree about whether the origin is a canvas
coordinate or an offset from its centre, which is the other reason not to honour
it.

So in an orthographic scene the shot layer is parsed, registered and bound like
any other node — scripts can still read and move it — but it does not touch
`scene.cameras` or `scene.activeCamera`. Panning and zooming a 2D scene from a
shot layer is not implemented; the canvas the wallpaper was authored against is
what gets projected. Scenes with `orthogonalprojection: null` keep the old
behaviour exactly, which is what `SceneSchema.DefaultCameraObjectBecomesActivePerspective`
holds down next to the new test.

### Property bindings and alignment anchors

A layer setting may carry `value`, `user` and `script` at once. `value` is the
initial value the property script receives; it does not decide whether the
script runs. The parser used to drop every dynamic binding of a layer whose
`visible` setting combined a script with a falsy `value`, which froze
day/night/weather switchers and any other layer authored hidden at rest — the
scene then rendered nothing but `general.clearcolor`. Scripts are now always
bound; `PropertyScriptProgram::Evaluate` already keeps the current value when a
script throws, returns `undefined`, or returns an object for a boolean, so a
hidden helper layer cannot be revealed by accident.

Alignment is an anchor, not a one-off offset. `SceneRuntimeContext` owns the
anchor for image and text layers and re-derives `origin + size * scale * 0.5`
for the named edges whenever the origin, scale or size changes. Baking the
offset into the node translate loses it as soon as a scripted or user-bound
origin writes the translate, and ignores scale. Center-aligned image layers
carry no offset and keep the direct path.

The anchor origin must survive re-registration. `RegisterNodeVisibility`,
`RegisterNodeTranslate`, `RegisterNodeScale` and `RegisterNodeRotation` each
call `RegisterNode` again for the same node, and `RegisterNode` seeds the anchor
from `node->Translate()`. Once an anchor is registered that translate already
contains the offset, so re-seeding it makes the next `ApplyNodeTransform` add a
second offset — visible only on layers whose scale or origin is dynamic, which
is why a static-origin/scripted-scale case is part of the regression test.
`RegisterNode` therefore re-seeds only when the bound node changes or no anchor
is registered yet, and `SetNodeAlignment` keeps the existing anchor mode instead
of forcing `size_anchor = false` on an already-anchored node.

### Native writes from scripts, puppet layers and cursor coverage

"Keep the current value when `update()` returns `undefined`" only works if the
current value includes what the script wrote. `ScriptedDynamicValue` used to
feed a private copy of the authored base value into `update(value)`; native
writes such as `thisLayer.visible = …`, `origin`, `scale` and `angles` arrive
through the typed `DynamicValue::update` overloads and never reached that
copy, so the authored `false` reverted the write on the next tick. Evaluation
now continues from the live dynamic value itself (see the property-feedback
entry above). The workshop "video texture controls" script (hide in `init()`,
`thisLayer.visible = alpha != 0` in `update()`, no return) is the canonical
victim: a layer authored `visible: false` never appeared.

Puppet animation layers are one shared playback state per image object
(`WPPuppetLayer` copies share it), registered with the runtime under the layer
name. `thisLayer.getAnimationLayer(name)` is backed by
`SceneRuntimeContext::PuppetAnimationControl`; it used to be a no-op stub, so
click-triggered puppet gestures never played. Authored layers start playing; a
single-shot layer holds its last frame and reports stopped, and `play()`
restarts it. `animationlayers[].visible/rate/blend` bound to user properties
follow the property like any other setting.

Cursor hit tests run in the layer's local plane (rotated and flipped buttons
keep their rectangle) and, for image layers whose scripts handle cursor events,
consult a coverage mask sampled from the albedo texture at parse time
(RGBA8/BC2/BC3, ≤256 texels per side, alpha ≥ 16 counts as covered). Two
interlocking triangle buttons whose rectangles overlap no longer fire together.
Puppets, videos, sprite sheets and opaque formats keep the rectangle test.

### Startup and staging buffers

Quadratic staging-buffer growth caused the original Sparkle apply timeout: each
fixed-size extension zeroed a temporary CPU vector and copied the entire
previous allocation twice. Geometric blocks plus direct replacement-buffer
copying preserve existing offsets and data without that repeated work. The
20-second Apply deadline and rollback behavior are unchanged.

### Alpha compositing

`SetBlend` used `VK_BLEND_FACTOR_SRC_ALPHA` for both the color and the alpha
factor of `BlendMode::Translucent`, so every translucent draw wrote
`As*As + Ad*(1-As)` instead of source-over's `As + Ad*(1-As)`. Partially covered
texels lost coverage on each composite and nested compose layers multiplied the
loss, which showed up as a thin saturated line along soft anti-aliased seams.
Color factors are unchanged, so opaque and fully transparent texels render
exactly as before. The `generated-alpha` case composites a half-covered source
over transparent, half-covered and opaque destinations inside a compose layer
and samples the composed alpha back as RGB: expected readback is 128/191/255,
and the pre-fix binary produces 64/96/191. It uses synthetic shaders only.

### Vector material constant timelines

`RegisterMaterialConstants` only resolved an animation when a constant had
exactly one component, and `ResolveScalarAnimation` only read `c0`. A `vec2`
book-page corner therefore lost its authored `c0`/`c1` curves, the group of
corners an author drives from one timeline through `options.parent.key` lost
that relation, and no `ScalarAnimationPlayback` was registered at all — so the
layer's own `thisObject.getAnimation(name).play()` found nothing to play.

On the local "猫猫的耳朵可以摸吗？" package that is the whole page-turn
interaction. Clicking `page首` runs the `cursorClick` export on its perspective
`point1` constant, which sets `thisLayer.visible = true` and plays the `900`
timeline. Without a registered timeline the page appeared with its corners
frozen, and the four homogeneous `w` terms of the authored `squareToQuad` were
`[1, 0.333, -0.819, -0.152]`: two corners behind the projection plane invert
the quad into a white spike that shoots off the top of the screen. With the
curves resolved the same corners measure `[1, 1.025, 1.069, 1.044]` on the
paused first key, `[1, 0.977, 0.965, 0.988]` mid-fold and `[1, 0.825, 0.469,
0.644]` on the authored last key — a valid quad for the whole fold.

Each component now resolves its own curve (`c0`–`c3`) and its own entry of the
initial value, and unanimated components keep that value. The constants of one
material pass are collected first, `options.parent.key` is walked to its root
with memoized results, and the whole group shares the root's single
`ScalarAnimationPlayback` — so `thisLayer.getAnimation(name)` still drives it,
and looping and restarting happen once, on the root. The sampled component
copies are single-shot, so a short child curve holds its last key instead of
wrapping on its own length. A missing parent, a parent without a usable
animation, or a cycle logs once and freezes that group on frame 0; relations
never cross material passes, so a corner of the same name elsewhere is a
different parameter.

The `generated-perspective-animation` case draws an original four-corner
homography mask whose third corner is animated from a paused parent timeline.
With the authored first key the page covers the centre and the margin stays
clear; with the static corner the page disappears and a wedge covers the
top-left margin instead. Both readings are asserted, so a blank frame and an
all-white frame fail too.

### Scripted material constants keep their component count

`MakeMaterialConstantDynamicValue` only treated a constant as a vector at three
or more components; everything else reached its property script through
`ResolveStringSetting`. A `vec2` corner was therefore handed to the script as
the text `[0.79139,0.44186]`, so `value.x` was `undefined` and the handler
returned `NaN`. On the local package that produced `g_Point2=[nan,nan,0]` on the
visible `workshop/2872021376/effects/perspective` pass of layer 503
`中-菜单-浮动`, and `g_Point1=[0]` — one component, parsed off a string that
starts with `[` — on the page-fold pass. Constants now resolve at the authored
component count: one component as a float, two and four through
`ResolveVectorSetting`, three unchanged through `ResolveVec3Setting`. A constant
with no authored value has no count to preserve and still resolves as a string.

### Timeline events

`options.events` is parsed into `ScalarAnimation::events`, and
`ScalarAnimationPlayback::Advance` queues every marker the playhead crosses as a
whole `ScalarAnimationEvent` — the authored `AnimationEvent` carries `frame`
beside `name`. Departure is exclusive and arrival inclusive, in both directions.
A loop runs on a circle, so the distance to each marker is measured along the
direction of travel: that makes a wrap, an exact landing on the seam and a
marker authored at the period the same point, and it keeps reverse travel
symmetric. Travelling at least a whole period reports each marker once rather
than once per lap, so a stalled frame cannot flood the queue. Markers arrive in
the order the playhead met them. Seeking is an explicit jump, not playback, so
`SetFrame` reports nothing.

`SceneRuntimeContext::Tick` drains the queue after advancing the clocks *and*
re-evaluating the scripted values, because a property script initializes lazily
on its first evaluation and a marker crossed by the very first tick must still
reach an initialized handler. Each queued marker calls the `animationEvent`
export on the property scripts and scene scripts bound to that timeline's layer.
The `engine.on`/`scene.on` list is global to the shared context, so the runtime
runs it once per marker instead of once per matching program — otherwise two
bound scene scripts would repeat every listener and none would silence them.
That runner also refreshes the `engine` object itself, because a global listener
can be a marker's only consumer and nothing else would have updated
`engine.runtime`/`engine.frametime` before it runs.
Handlers routinely create, hide or destroy layers, so every crossed marker is
collected before any handler runs and the script lists are re-checked while
dispatching.

`scene.getAnimation(name)` was missing: `getAnimation` existed only on the layer
object, so the authored `thisScene.getAnimation('111').play()` threw
`TypeError: not a function`. A null layer argument to `__animationControl` now
means "match this name across every registered timeline"
(`SceneRuntimeContext::FindAnimationByName`).

Together these complete the local package's two-phase page turn. Clicking
`page首` plays `900`; at frame 30 `houye` swaps the layers — `page首` goes
`visible=0`, `page` goes `visible=1` — and starts `111` on `page`; at frame 45
that second fold is mid-flight with its own corners moving; at frame 60 `yeshu`
hides `page` and the book is back at rest. The probe logs no `animationEvent`
errors, and the thin white sliver that used to be left at the page edge is gone.

### Cursor coordinates and presentation

Scene coordinates reach the window through two transforms: the global camera
rectangle fills the default render target, and `ComputeWallpaperScalingLayout`
places that target in the window, which `FILL` deliberately pushes outside the
window to crop. Cursor input arrives as a window fraction, so it has to be
mapped back through both (`ComputeWallpaperCursorMapping` →
`SceneRuntimeContext::SetCursorViewport`). Mapping it onto the raw canvas
instead only matches when the scene and the display share an aspect ratio;
otherwise every `cursorEnter`/`cursorLeave` box is squeezed toward the screen
centre. On the 7680×2160 local scene at the recorded 4112×2658 output, a
275-unit text layer answered the cursor across only about 4% of the window
width while it was drawn across about 9%, so hovering the ends of the text did
nothing.

The mapping also reports the drawn content rectangle. Coordinates keep
extrapolating past it — scripts read positions outside the canvas — but named
layers only take cursor events while the cursor is inside it. Without that,
`FIT` and scaled-down wallpapers would let letterbox bars trigger any layer
whose box crosses the canvas edge.

`engine.screenResolution` is a different quantity and has its own setter.
`SceneWallpaper::publishScreenResolution` reports the display's pixels on scene
attach and again whenever the surface is replaced. `RenderInitInfo::width`/
`height` already are those pixels — the host fills them from `DisplayDesc`, and
both backends divide by `display_scale_factor` when they want logical points —
so scaling them again would publish twice the resolution on every Retina panel. It used to be whatever the cursor mapping
published, which is the region of the scene's own world the window shows, so a
script sizing itself against the screen read the author's canvas back instead.
The rasterization size is not it either: internal quality may halve that, and a
quality setting must not move a script's layout.

### Text, fonts and clocks

Font decoding prefers valid authored bytes, then a usable installed family, then
a platform fallback; missing paths and malformed embedded fonts use the same
fallback for both measurement and rasterization. Coverage spans seven font
choices and three text samples including Chinese, plus missing/corrupt sources
and valid assets. The text regression checks actual glyph coverage rather than
just nonempty strings. C++ tests also cover persistent shader-cache metadata,
cache invalidation after include edits, corrupt-cache recovery, parent-aware
compose-background sampling, and SceneScript AM/PM sprite-frame selection;
these create no window and no Vulkan device.

`TextObjectRuntime.LonelyCatHeadlessRegression` in `text_object_runtime_test` is
an opt-in local-asset diagnostic. Set `WE_TEST_PROJECT`, `WE_TEST_ASSETS` and a
disposable `WE_TEST_CACHE`, then run with
`--gtest_filter=TextObjectRuntime.LonelyCatHeadlessRegression`; add
`WE_TEST_EXPECT_WARM=1` for a second run. It parses the package, ticks scripts
and constructs the render graph; it does not initialize playback, capture the
desktop, or modify the imported wallpaper.

### Textures, allocation and composition

- Texture lifetime tests check 32 generated multi-version graphs against a
  last-access oracle, plus nested composites with aliases, three sizes, visible
  and hidden parents, and background-copy enabled/disabled. Alias clears and
  readers must refer to the same canonical resource.
- Eight generated GPU scenes vary nested children, background-copy settings,
  visibility, dimensions, transforms and declaration order. Besides exact
  pooled/isolated pixel equality, known pixel assertions verify that empty
  inputs do not leak old pixels and that children actually render.
- Pooled targets are retained until every logical version has finished, and
  effect inputs are cleared explicitly when `copybackground=false`.
  `render_target_lifetime_test` asserts version lifetimes and a real transparent
  writer before an effect samples its empty input.

### Animation and puppets

- Puppet attachments use the animated bone affine each frame while preserving
  the child layer's authored/script transform. Character-sheet reference poses
  are decoded separately from cut-up bind geometry so additive and non-additive
  animations reassemble correctly. Synthetic regressions cover declaration
  order, animated translation/rotation/scale, repeated same-time samples and
  local edits.
- Scalar material timelines preserve paused first keys and authored Bezier
  handles; SceneScript named animation controls drive play, replay, pause, stop,
  seek and rate. Puppet animation deltas use the skeleton reference pose, not
  the first animation sample, preserving initially collapsed eyelids and
  authored rotations.
- Property-script `update(value)` receives the current value, including the
  previous frame's result and explicit property writes, rather than the
  original authored value on every tick. This preserves iterative hover easing,
  full authored enlargement, and continuous reversal on cursor leave/re-entry.
  JavaScript input conversion serializes only the value payload, without copying
  the live property's listener/subscription ownership. Callback-only scripts
  keep their existing no-writeback behavior.

### Frame timing

Frame timing keeps render cost separate from animation time. Dropped busy ticks
remain included in the elapsed delivered-frame delta; restarting excludes paused
time. `timer_tests` covers dropped ticks, restart, FPS changes and long gaps
without desktop surfaces or audio devices.

### Continuous-playback work contracts

- `playback_gpu_test` uses real private images for producer/consumer and
  overwrite synchronization, every generated mip, and recording/pipeline/
  framebuffer failures. The executor returns the first `VkResult` failure;
  failed recordings are reset and abandoned rather than submitted or waited on.
  Shader-read barriers are outside render passes and include vertex consumers.
- A prepared `PrePass` is skipped only when a same-image, same-view, single-mip,
  single-sample clear with bit-identical color is reached before any reader or
  non-custom pass. Visibility and actual active descriptors are reconsidered
  each frame. The standalone pass loop remains the reference path.
- Direct presentation requires exactly one graph shader pass writing the
  default target, a first clear, no depth/mip/MSAA or feedback, UNORM RGBA/BGRA,
  and identical graphics/present queue families. Each frame also requires the
  exact full-target viewport/scissor, matching extent, ready descriptors and no
  flip. Other frames render the normal intermediate plus `FinPass`. Both
  pipelines are prepared once; all paths retain frame/presentation waits.
  Private-target tests compare complete same-format bytes over poisoned target
  rotation, graph resize, transparency, fallback and error recovery; they never
  transition private images to `PRESENT_SRC_KHR`.
- Compiled script exports suppress only absent handlers. Initialization,
  scheduled callbacks, shared scene callbacks, live-value fallback and live
  alpha/geometry hit order remain covered by `script_runtime_compat_test` and
  `mouse_input_test`. Transform/material caches avoid recomputing sources but
  still repair changed destinations in the original phases; failed registration
  releases only its new subscriptions/values and restores existing mask/puppet
  identity.
- Puppet copies reuse a result buffer in their existing shared playback State
  for the exact same finite time until a control mutation. Fresh layers sharing
  an asset have independent results. Attachments still apply each frame. Audio
  uniforms borrow an owning packing buffer synchronously and read a fresh
  spectrum on every call; particle mouse inverses are skipped only when all
  current controlpoint link flags are off.

Core/bridge tests additionally cover bounded capability relay delivery,
renderer-instance replacement, serialized observer replay/publication, retained
held-button levels and discarded inactive taps, level-only native reconciliation,
single-turn samples and exact-success input deduplication. Native capability and
button tests initialize loopers only, not Vulkan, playback or audio hardware.

Performance probes remain disposable, with fixed simulation time, full output
checks outside timing, raw samples and per-block median/p95. C++ `new` counters
do not measure QuickJS `malloc`, worker-thread allocations or whole-process
memory. Pixel equality and Vulkan command traces are not synchronization-layer
validation, desktop equivalence, GPU residency or power measurements.

### Video decode state machine and colour range

`video_decode_pump_test` pins the libavcodec send/receive contract, and includes
reproductions of the order this project used before: feeding input before
draining output loses a packet the decoder rejected with `EAGAIN`, and seeking at
end of input instead of draining loses the reordered tail of every loop. A
change that reintroduces either order fails those two cases. The same file
covers cancellation during a drain, a bounded no-progress budget, and releasing
a held packet exactly once on seek, stop or failure.

`video_color_conversion_test` pins known pixels for BT.601/709/2020 in both
ranges, studio black and white with clamping, 75% colour bars round-tripped from
their RGB primaries, matrix separation, resolution-based inference for
unspecified metadata, and bit-depth scaling. Limited-range chroma has its own
224 code-value excursion; reading it as `sample - 0.5` desaturates every
studio-swing frame, and that specific regression has a case of its own.
`PlaybackGPU.MetalConversionMatchesTheCpuColorReference` compares the Metal
`nv12_to_bgra` kernel against the same CPU reference, so the two paths cannot
drift apart.

Video frame imports are owned by a lease that retains the Core Video texture
wrapper and the pixel buffer for as long as the frame can be sampled, not just
the vended `MTLTexture`. `playback_gpu_test` exercises pool reuse, generation
dedup, cache eviction and recording-discard recovery against it.

### Frame pacing follows the content, bounded on both sides

`timer_tests` pins the frame clock's content-rate pacing. A pushed
`FrameDemand.content_period` may only lengthen the tick interval: the configured
FPS stays the ceiling, so a 60 fps video cannot make a 30 fps wallpaper render at
60, and an unknown, zero, negative or absurdly long period cannot stall a
scene — one hour is clamped to the five-second gap the frame clock still treats
as continuous playback. Dropping the demand restores the fixed cadence rather
than inheriting the previous scene's, and pacing never changes how many draws may
be in flight.

Only the engine's own plain-video scene reports a period, and only because
`CreateVideoProjectScene` builds it with a single video texture, a copy shader, a
no-op shader value updater and no script, particle, audio or pointer input.
Authored scenes report nothing. A change that lets any other scene answer needs a
positive account of every dynamic render-graph input first; guessing freezes a
live wallpaper.

The period a source reports is evidence, not metadata. `avg_frame_rate` is an
average and `r_frame_rate` is an estimate, so neither describes a particular gap
in a variable-frame-rate clip. `video_frame_pacing_test` pins the rules that
replaced the metadata-only version: declared rates are an upper bound on the
period and never unlock pacing on their own; the shortest gap actually decoded
does, after enough samples; the result is monotonically non-increasing, so a
burst that appears once keeps the clock fast afterwards; deltas across a loop
seam or a seek are discarded because they describe the seam; and repeated,
rewound or non-finite timestamps are not counted as evidence at all, which
leaves the fixed cadence in place rather than pacing on a guess. Rational rates
keep their exact period (`24000/1001`, not `1/24`), and playback speed maps the
content's own timeline onto the wall clock, so a 2x wallpaper needs twice the
tick rate for the same clip.

A frame clock paced to its content also has to be told apart from a suspended
process. `timer_tests` covers the boundary: the suspension threshold scales with
the interval the clock is actually using and never drops below the five-second
floor, so an ordinary frame boundary at the pacing clamp reports its real
elapsed time instead of one ideal frame, while an eight-hour gap is still
treated as a resume. Before that change a scene paced at the clamp lost the
difference on every frame and fell steadily behind.

`MAC_WALLPAPER_ENGINE_DISABLE_CONTENT_PACING=1` switches pacing off in the same
binary so a comparison measures one strategy rather than two builds. The default
is the paced path; an unset or empty value never disables it.

### Renderer work counters

`OWE_RC_*` counters are incremented by the production paths that perform the
work: the frame clock's tick, the draw handler, the Vulkan submit, the present
request, the frame fence and the texture cache's video update. They are off by
default and read by pulling `owe_scene_wallpaper_counters`; nothing is pushed or
logged per frame. `timer_tests` asserts that a tick which found a draw still in
flight is counted as a suppressed tick rather than a request, that nothing is
counted while the switch is off, and — running the real thread timer against the
real callback — that a content period genuinely lowers how many draws the
scheduler posts. `video_frame_pacing_test` pins the generation accounting behind
`video_frames_selected`, `video_frames_reused` and `video_frames_skipped`: a gap
between two displayed generations is exactly the number of decoded frames that
never reached the screen, which is how a pacing regression is falsified while
the picture still moves.

`present_requests` counts requests. This backend has no presentation-feedback
source, so the frames a compositor actually displayed are reported as
unavailable and never approximated by the request count.

### Shader pipeline

The shader repair handles undersized cross-stage varying declarations,
conditional helper headers, source-defined `log10`, legacy scalar/vector
argument conversion, compound assignment narrowing, and scalar initializer
conversion. The pipeline revision is part of the cache key and is bumped
whenever codegen can produce different output for source that already
compiled; it is 8 now, and each bump invalidates previously compiled programs.

It also absorbs idioms author shaders inherit from the permissive path they
were written against, each of which otherwise drops a whole effect rather than
one expression: a texture annotation's `"default":""` means the slot has no
default; `CAST2`/`CAST3`/`CAST4` are vector constructors before
`legacy_builtins` renames them; mixed-width vector operands inside a call
argument truncate to that expression's narrowest operand, while sampler
coordinate arguments stay with the texture strategy that narrows them to the
sampler's dimensionality; and a parenthesized comparison used as an arithmetic
operand is converted with `float(...)`. Known and not handled: logical-not
applied to a float (`!someFloat`), which still rejects
`workshop/2800594362/effects/clipping_mask`.

One repair is a layout contract rather than a spelling: a scalar or
narrow-vector array in the generated uniform block is declared `vec4 name[N]`
and every subscripted read is swizzled back. std140 pads each element to 16
bytes, which is what the host packs and the reflection reports, while the MSL
backend emits the natural tight stride — so without it every member after such
an array is read from a different address on Metal than the host wrote it to.
The swizzle has to follow reads reached through `#define` aliases (written
inside `main` by the audio-bars shader family) and through array-parameter
specialization, not just direct ones.

A sampler slot's `combo` answers whether the **material** bound a texture
there, and that is not the same question as whether the slot is bound. An
annotation's `default` exists so an unused sampler still reads something sane;
`WPSceneParser` binds it, then reports the slot as unbound to the compiler so
the combo stays 0. Feeding the defaulted list back turned every
`{"combo":…,"default":…}` sampler permanently on — `rounded_mask` read its
corner radius from a white default instead of `u_Radius` and masked the layer
it was applied to into a circle. A slot the combo leaves unsampled is cleared
afterwards, so nothing holds a texture it never reads.

## Rust crates

Run from `upstream/renderer` with the Homebrew environment from
`scripts/build.py`. The first `cargo test` after that environment changes fails
in its CMake configure step and succeeds on an unchanged retry, so a single
configure failure is not a result:

```sh
cargo test --release -p wallpaper-core --lib
cargo test --release -p wallpaper-bridge --lib
cargo test --release -p wallpaper-core --lib audio
cargo test -p shader --test pipeline -- --nocapture
```

- `wallpaper-core` audio coverage: capture ownership and failures,
  mono/multichannel conversion, resampling including sample-rate changes.
- `wallpaper-bridge`: live audio toggle errors, rollback/persistence,
  nonblocking selection and mirror behavior; scene lifetime,
  presentation/manual pause precedence, failure rollback, disabled destruction,
  stalled single-flight mouse scenarios, and live handles remaining after
  reconciliation/audio errors; the lock-screen export regression for
  committed-versus-draft scaling, pause/resume and ejection; and
  `tests::property_snapshot` for combo selection, conditional rows after
  edits/default restoration/discard, hidden-value preservation, and
  malformed-condition fail-open behavior.
- `shader`'s `pipeline` test skips asset-dependent cases with a printed
  `skipping …` reason; read those lines before claiming shader coverage. See
  [wallpaper-corpus.md](wallpaper-corpus.md) for the asset roots.

## C++/CMake test binaries

Built into the renderer check build directory under `artifacts/renderer/bin/`:
`scene_schema_tests`, `mdl_schema_tests`, `tex_schema_tests`,
`script_runtime_compat_test`, `text_object_runtime_test`,
`render_target_lifetime_test`, `shader_cache_metadata_test`, `audio_tests`,
`mouse_input_test`, `particle_mouse_controlpoint_test`,
`particle_rope_geometry_test`, `layer_texture_reference_test`, `scene_mesh_tests`, `timer_tests`,
`playback_gpu_test`, `video_decode_pump_test`, `video_color_conversion_test`,
`video_frame_pacing_test`,
plus the `offscreen_scene_probe`, `scene_reload_cycle_probe` and `wpdump`
diagnostics. `scripts/check_renderer.py` builds and runs
`render_target_lifetime_test`, `text_object_runtime_test`,
`shader_cache_metadata_test`, `video_decode_pump_test`,
`video_color_conversion_test`, `video_frame_pacing_test`, `timer_tests` and
`playback_gpu_test`; a non-zero exit from any of them fails the check. The
native Metal backend adds `metal_backend_test` (capability and graph gate, no
device needed), `metal_scene_draw_smoke` (author shaders and same-frame
intermediates drawn and read back, plus target reuse, dynamic-geometry upload,
sprite-sheet stepping, text layers and their update dedup, direct video plane
sampling end to end and Metal program reuse across renderers), `metal_poster_capture_test` (on-request poster
readback, busy coalescing, invalidation) and `metal_video_texture_test` (BGRA
import and NV12 conversion against the CPU colour reference, from synthetic
frames); all four run in the check, draw only into private textures and skip
visibly without a Metal device.

Useful filters:

```sh
audio_tests --gtest_filter='AudioResponseMonoTest.*'
script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'
scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'
```

`audio_tests`, `particle_mouse_controlpoint_test` and
`script_runtime_compat_test` cover physical FFT frequency mapping including DC
and Nyquist, silent and stale input, box/sphere emission transitions, and typed
SceneScript views.

## Known limitations

- **Pre-existing failure:**
  `ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
  references undeclared `scriptProperties` and fails with the original
  `ScriptEngine.cpp` as well. It is not a regression; do not report it as one
  and do not claim it is fixed by excluding it.
- **Pre-existing failures:** `SceneSchema.PointerCapabilityFollowsActualCommitsWithoutFirstFrame`
  and `SceneSchema.MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch`
  in `scene_schema_tests` time out (`Wait`) waiting for a pointer-capability
  callback after a scene commit. Both were reproduced on an unmodified HEAD
  worktree, and both build a `Scene` by hand under the default Compatibility
  preference, where `SelectSceneBackend` returns before any capability code.
  `scene_schema_tests` is not in `scripts/check_renderer.py`; when you run it by
  hand, expect these two and do not attribute them to your change.
- **Stale decode cache, not a regression:** `video_source_input_test` shares
  `$TMPDIR/wallpaper-engine-video` with the app and with earlier runs.
  `ConcurrentPackagedOpensPublishExactlyOneFile` and
  `EvictingTheCacheDoesNotDisturbAnOpenSource` count published files, so
  leftovers from a previous run make them fail (`added.size()==2`). Delete that
  directory and re-run the same binary before investigating.
- **`tex_schema_tests` does not compile here.** `tests/tex_schema_tests.cpp`
  includes `<lz4.h>`, but `src/CMakeLists.txt` links `PkgConfig::LZ4` `PRIVATE`
  and `tests/CMakeLists.txt` does not link it for this executable, so the
  include directory never propagates. It is outside
  `scripts/check_renderer.py`'s target list, so the gate is unaffected; the
  JPEG/EXIF orientation coverage it owns is therefore unexercised until the
  target links LZ4 itself.
- Asset-dependent `shader` pipeline cases (for example `genericimage4` and a
  Workshop package) are excluded when their referenced files are absent.
- Some locally installed scenes emit pre-existing MDLA, Rust `light_map` compile
  and shader-value alias errors. Those predate current work; verify only that
  no *new* diagnostics appear. Named case seen so far: Wallpaper Engine's own
  `clipping_mask` fails to translate (`!float` in the translated vertex
  shader). A `ShaderValue: … not found in glsl` line is authored leftovers,
  not a binding failure. Music Visualizer | iOS Style's `gaussian`,
  `cutout_vignette` and `effects/refract` were listed here until the shader
  pipeline absorbed the three idioms they relied on; they compile now, and the
  Shader pipeline section above owns that list.
- `thisLayer.getParent()` is unimplemented in SceneScript. A layer whose script
  uses it logs `cannot read property … of undefined` once per update and keeps
  its authored value, so the picture is usually unaffected and the errors are
  not a regression.
- **3D content in a perspective scene is not drawn.** Models that parse, are
  effective-visible and sit in front of a perspective camera at small authored
  scales still produce no pixels; the 2D layers of the same scene render.
  Observed on Live Solar System – SYKM (`3662790108`) with its authored intro
  disabled: sampled frames are byte-identical, with no stars, orbits or bodies.
  The `engine.screenResolution` and active-camera fixes repaired that scene's
  scripts and 2D layers only; the perspective/scale path is a separate
  unfinished problem.
- GPU elapsed measurements vary substantially between repeated runs on this
  hardware. Treat them as samples, not as proof of a GPU-time improvement or
  regression, and never as power or battery measurements.
- Unimplemented non-audio scene features, including some script outputs, can
  still affect wallpaper compatibility even when every renderer check passes.
- **`offscreen_scene_probe` is Vulkan-only.** With
  `scene_renderer = "native_metal_preferred"` a scene the capability gate
  accepts runs on the native backend with nothing behind it, so a probe result
  describes a renderer that wallpaper may never use. Check the backend first —
  `metal_scene_draw_smoke` with `WE_TEST_METAL_PROJECTS` prints the decision
  per project — and repeat any comparison there before calling a difference
  backend-independent. The divergence that made this rule worth writing —
  `3799253558` rendering 70% black on Native Metal with a ring that ignored
  audio — was the uniform array layout above, and is fixed; the lesson is that
  a Vulkan-only measurement could not have found it.
- No renderer check proves desktop presentation, AppKit behavior, live audio
  capture, real input capture, or visual equivalence. Those need the authorized
  manual checks in [manual-smoke.md](manual-smoke.md).
