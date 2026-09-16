# Renderer verification

Non-desktop verification of the vendored renderer in `upstream/renderer`: the
Rust crates, the C++ scene engine and its GPU probes. Nothing here creates a
window, swapchain, audio device, or screenshot, and nothing here inspects or
changes the desktop. Dated results live in
[verification-log.md](verification-log.md); this file is the working reference.

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
   `CMAKE_BUILD_TYPE=Release`, `BUILD_TESTS=ON`, `BUILD_QML=OFF`,
   `BUILD_WAYWALLEN=OFF`, `RUST_SHADER_FFI=ON`, and `RUST_SHADER_STATICLIB`
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

The generated matrix is nine original synthetic scenes; it contains no workshop
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
| `WE_TEST_DUMP_PASSES` | `offscreen_scene_probe` | Dump per-pass detail |
| `WE_TEST_PROPERTIES` | `offscreen_scene_probe` | Flat JSON property overrides, in memory only |
| `WE_TEST_CLICK_LAYER` | `offscreen_scene_probe` | Image-layer ID to click |
| `WE_TEST_CLICK_COUNT` | `offscreen_scene_probe` | `1..10` synthetic clicks, no desktop input |
| `WE_TEST_CLICK_OFFSET` | `offscreen_scene_probe` | World-space `"dx dy"` added to the click layer's origin, to hit a covered or transparent texel instead of the centre |
| `WE_TEST_AUDIO_HZ` | `offscreen_scene_probe` | Synthetic PCM at `0..6000` Hz; `0` means silence |
| `WE_TEST_AUDIO_ENABLED=0` | `offscreen_scene_probe` | Exercise the disabled audio gate |
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
| Callback-only property scripts | `*CallbackOnly*` in `scene_schema_tests` and `script_runtime_compat_test` |
| Property-script feedback / hover easing | `ScriptRuntimeCompat.HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping` and `ScriptRuntimeCompat.PropertyFeedbackResumesFromExplicitUserValueChanges` in `script_runtime_compat_test` |
| Script-driven layer visibility | `SceneSchema.HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin` in `scene_schema_tests`. The authored `visible.value` is the script's initial value, never a permission to run it (see below). |
| Alignment anchors under dynamic transforms | `SceneSchema.ImageAlignmentAnchorSurvivesScriptedOriginAndScale` in `scene_schema_tests`, plus `nodes.txt` translate diffs from `offscreen_scene_probe` |
| SceneScript writes from `update()` | `ScriptRuntimeCompat.UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined` in `script_runtime_compat_test`: a `thisLayer.visible = …` written during `update()` survives the next reevaluation even when `update()` returns nothing (see below). |
| Puppet animation layer control | `ScriptRuntimeCompat.PuppetAnimationLayer*` in `script_runtime_compat_test`: `getAnimationLayer(name).play()` restarts a finished single-shot layer on every copy of the shared state; a `visible` bound to a user property toggles the layer. |
| Cursor coverage masks | `ScriptRuntimeCompat.CursorHitTestRespectsCoverageMask` in `script_runtime_compat_test`: transparent texels of a cursor-scripted image layer do not hit. `offscreen_scene_probe` with `WE_TEST_CLICK_OFFSET` exercises real assets. |
| Cursor hit testing under scaling | `MouseInput.CursorViewportMapsWindowOntoTheCroppedSceneRectangle`, `MouseInput.LayerHitTestingFollowsWhereTheWallpaperIsPresented`, `MouseInput.LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge` in `mouse_input_test`, and `ScriptRuntimeCompat.HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper` (see below) |
| MDLS3 hierarchy/pivots | `MdlSchema.Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions` in `mdl_schema_tests`. Mesh format versions do not justify flattening an authored skeleton. |
| Large-scene first-frame startup | `offscreen_scene_probe` cold/warm startup timings; staging-buffer growth must stay geometric (see below) |
| JPEG/EXIF orientation | `tex_schema_tests`: all eight EXIF display transforms on asymmetric RGBA pixels, both TIFF byte orders, truncated JPEG/EXIF data, invalid IFD offsets |
| Translucent coverage / alpha compositing | the `generated-alpha` case in `scripts/check_renderer.py` |
| Clock/text corruption | `render_target_lifetime_test`, `text_object_runtime_test`, `shader_cache_metadata_test` |
| Continuous-playback resource reuse | `playback_gpu_test` |
| Download-speed sampling | `DownloaderTests` in `Tests/Unit/Workshop/`: real `nettop` streaming over a private PTY with local-socket traffic; CRLF and split line endings. LF-only fixtures do not verify live delivery. |

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

### Shader pipeline

The shader repair handles undersized cross-stage varying declarations,
conditional helper headers, source-defined `log10`, legacy scalar/vector
argument conversion, compound assignment narrowing, and scalar initializer
conversion. Shader pipeline revision 4 invalidates previously compiled programs.

## Rust crates

Run from `upstream/renderer` with the Homebrew environment from
`scripts/build.py`:

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
`mouse_input_test`, `particle_mouse_controlpoint_test`, `timer_tests`,
`playback_gpu_test`, plus the `offscreen_scene_probe`,
`scene_reload_cycle_probe` and `wpdump` diagnostics.

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
- Asset-dependent `shader` pipeline cases (for example `genericimage4` and a
  Workshop package) are excluded when their referenced files are absent.
- Some locally installed scenes emit pre-existing MDLA, Rust `light_map` compile
  and shader-value alias errors. Those predate current work; verify only that
  no *new* diagnostics appear.
- GPU elapsed measurements vary substantially between repeated runs on this
  hardware. Treat them as samples, not as proof of a GPU-time improvement or
  regression, and never as power or battery measurements.
- Unimplemented non-audio scene features, including some script outputs, can
  still affect wallpaper compatibility even when every renderer check passes.
- No renderer check proves desktop presentation, AppKit behavior, live audio
  capture, real input capture, or visual equivalence. Those need the authorized
  manual checks in [manual-smoke.md](manual-smoke.md).
