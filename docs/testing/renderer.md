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

1. builds `cargo build -p shader --features ffi --release`,
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
images under `WE_TEST_OUTPUT`. Use a disposable output/cache directory.

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
| `WE_TEST_DUMP_SOURCE=1` | `offscreen_scene_probe` | Write the packaged scene JSON beneath `WE_TEST_OUTPUT`; also includes node visibility in `nodes.txt` |
| `WE_TEST_DUMP_PASSES` | `offscreen_scene_probe` | Dump per-pass detail |
| `WE_TEST_PROPERTIES` | `offscreen_scene_probe` | Flat JSON property overrides, in memory only |
| `WE_TEST_CLICK_LAYER` | `offscreen_scene_probe` | Image-layer ID to click |
| `WE_TEST_CLICK_COUNT` | `offscreen_scene_probe` | `1..10` synthetic clicks, no desktop input |
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
| MDLS3 hierarchy/pivots | `MdlSchema.Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions` in `mdl_schema_tests`. Mesh format versions do not justify flattening an authored skeleton. |
| Large-scene first-frame startup | `offscreen_scene_probe` cold/warm startup timings; staging-buffer growth must stay geometric (see below) |
| JPEG/EXIF orientation | `tex_schema_tests`: all eight EXIF display transforms on asymmetric RGBA pixels, both TIFF byte orders, truncated JPEG/EXIF data, invalid IFD offsets |
| Translucent coverage / alpha compositing | the `generated-alpha` case in `scripts/check_renderer.py` |
| Clock/text corruption | `render_target_lifetime_test`, `text_object_runtime_test`, `shader_cache_metadata_test` |
| Continuous-playback resource reuse | `playback_gpu_test` |
| Download-speed sampling | `DownloaderTests` in `Tests/Unit/Workshop/`: real `nettop` streaming over a private PTY with local-socket traffic; CRLF and split line endings. LF-only fixtures do not verify live delivery. |

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
