# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. When it grows past that,
move the oldest entries verbatim into
[archive/verification-log-2026-09.md](archive/verification-log-2026-09.md)
(or a new dated archive file) first, and promote anything durable before it
goes. Trimming is allowed; editing an entry's recorded result is not.

## 2026-09-25 — Lucy renderer fix moved onto origin/main (first-seen displays, Discover animations) before push

- `git merge --ff-only origin/main` (aaed861 to e44b960), then the change set reapplied: conflicts only in `upstream/provenance.json`, where both sides prepended to the renderer note (both kept, newest first), and the two logs (entries kept in recording order, trimmed to ten by `scripts/log_verification.py`'s rule); the other 33 changed files matched their pre-move checksums
- `python3 scripts/build.py --renderer-only` — exit 0; regenerated `App/Bridge/Generated` unchanged
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not rerun on this tree: `scripts/check_renderer.py` and the C++ suites, since the two remote commits change no scene engine or shader code; the Release app built before the move lacks those two commits

## 2026-09-25 — Lucy renderer fix: parallax report restored per pass camera, playing-only demand; Release build

Revisits two items of the narrowing entry below, decided from the code. Without the kParallax report, frame reuse (on by default) left an otherwise still parallax wallpaper not following the cursor, and on-demand rendering never woke for it; the report is back, judged for the camera each pass draws through, so layer-local composites stay reusable. Stopped playbacks no longer count as demand, since only script commands restart one. Vulkan's upload order stays as at HEAD (Known limitations).

- `script_runtime_compat_test` 78 passed, 1 documented failure; `scene_schema_tests` 86 passed, 2 documented timeouts; `layer_texture_reference_test` 16/16; `static_subgraph_cache_test` 26/26
- Mutations fail their tests: no parallax report; layer-local camera ignored (updater and graph tests); the Vulkan call site dropping `camera_override` (graph test); stopped playbacks counted (camera intro test)
- `python3 scripts/build.py --renderer-only` then `python3 scripts/check_renderer.py` with 3521337568, 3292361861, 3605722997, 3632513108, 2887099508 — exit 1: 23 binaries exit 0, 10 generated cases pixel-equal with expected pixels, reload cycles 0; 3521337568, 3605722997 and 3632513108 pixel-equal with no diagnostics; 3292361861 differs only in its clock-text band (rows 346-394), and 2887099508 logs the same 8 script errors as the previous run
- `metal_scene_draw_smoke`, 3521337568: Native Metal, 120 frames drawn, zero translation failures, 53.0 render passes/frame with and without the report
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- `python3 scripts/build.py --configuration Release` — exit 0; delivered `build/Build/Products/Release/WallpaperMachine.app`; app and extension binaries linked 08:21, after the last renderer edit, and both contain the new `FrameVaryingUniforms` signature and `ExportKeywordAt`
- Not done: the app was not launched or restarted; no desktop run, no parallax under a real cursor, on-demand parallax easing still stops partway (known limitation), no power measurement of the lost reuse, no corpus visual check of the Compatibility upload order

## 2026-09-25 — Lucy renderer fix narrowed to its own regressions (upload order and parallax report withdrawn)

Narrows the follow-up entry below. Withdrawn and recorded under renderer.md Known limitations instead: Vulkan's constants-before-live-values upload order (with the generated-texel-size case) and the kParallax report; also recorded there: finished non-camera timelines still count as demand. Kept, narrowed: finished-playback demand covers camera-layer clocks only; ExportKeywordAt holds the one statement-boundary rule; QuickJS-compiled tests use U+00A0 only.

- `python3 scripts/build.py --renderer-only` then `python3 scripts/check_renderer.py` with 3521337568, 3292361861, 3605722997, 3632513108, 2887099508 — exit 1: 23 binaries exit 0, 10 generated cases pixel-equal with expected pixels, reload cycles 0; 3521337568, 3605722997 and 3632513108 pixel-equal with no diagnostics
- The exit 1 is the known pair: 3292361861 differs only in its clock text (at most 618 px in rows 346-393; `text-8` changes width) with the 7 diagnostics HEAD also logs; 2887099508 logs the same 8 script errors as the previous run
- 3632513108 in the check's environment: 0 of 10 renders (5 pooled, 5 isolated) show the alternate frame; an unmodified HEAD produced it in 1 of 2 pooled runs, so renderer.md records it as predating this work, allocation reuse not ruled out
- `script_runtime_compat_test` 77 passed, 1 documented failure; `scene_schema_tests` 86 passed, 2 documented timeouts; `layer_texture_reference_test` 16/16
- Mutations fail their tests: a stale non-zero link size folded at parse time (caught only under the constants-last order), no statement boundary in `ExportKeywordAt` (`reexport`, `module.export`), camera clocks counted while merely registered
- 3521337568: Vulkan past the intro at 3840x2160 has no non-cache errors and its centre registers with preview frame 40 (NCC 0.95; bands 0.93/0.97/0.99 at one shared offset); `metal_scene_draw_smoke` reports Native Metal, 120 frames drawn, zero translation failures
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not done: Release build, desktop run, live parallax under a real cursor, corpus-wide visual check of the Compatibility upload order (a known limitation, unchanged)

## 2026-09-25 — Lucy renderer fix: review follow-ups (upload order, parallax reuse, idle intros, export matcher)

Follow-ups to the Workshop 3521337568 entry below. Vulkan uploads parse-time constants before the value updater's live values (Metal's order), parallax is limited to 2D scenes and reported as cursor-varying, a finished single-play timeline stops asking for frames, script-bound shot origins wait for the first tick, the fullscreen canvas camera is 2D-only, compose cameras stay out of layer-local framing, the camera fold is one helper both backends call, and one ECMAScript-whitespace matcher serves the export rewrite and both update detections (the rewrite now erases only the keyword).

- `python3 scripts/check_renderer.py` with 3521337568, 3292361861, 3605722997, 3632513108, 2887099508 — exit 1: all 23 binaries exit 0, all 11 generated cases (new generated-texel-size included) pixel-equal with expected pixels, reload cycles 0; 3521337568 and 3605722997 pixel-equal with no diagnostics
- The exit 1 is pre-existing only: 3292361861 differs by its live clock text and its 7 diagnostics also occur on HEAD; 3632513108's frame flips between two images on an unmodified HEAD build as well (now in renderer.md Known limitations); 2887099508's 8 script errors match HEAD's except stack-trace columns, shifted because a line-start `export ` keeps its space
- `scene_schema_tests` 86 passed, 2 documented timeouts; `script_runtime_compat_test` 78 passed, 1 documented failure; `layer_texture_reference_test` 16/16; `mouse_input_test` 12/12; `static_subgraph_cache_test` 26/26; `cargo test -p shader` 14 suites, 503 passed
- Mutation checks: each new or changed test fails with its fix reverted (keyword-only erase, Unicode update detection, composelayer order, kParallax report, finished-playback demand, pending bound origin, zero link resolution, compose not layer-local, puppet slot depth); generated-texel-size draws (51, 60, 0) with Vulkan's old upload order
- Metal, 3521337568 at 3840x2160 with its shot hidden: zero `metal translation … failed` lines, mean abs 0.58 against Vulkan at matched scene time; Vulkan after the 5 s intro registers with the preview
- `python3 scripts/build.py --renderer-only` then `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not done: Release build, desktop run, live parallax under a real cursor, the intro's opening framing (no reference), any 3D scene (none installed)

## 2026-09-25 — Workshop 3521337568 (Lucy) renders its intro, planet and effects on both backends

Renderer-only fix: 2D camera layers frame the canvas (zoom plus origin as an offset from the canvas centre, one timeline clock, last visible shot wins), parallax follows the cursor and depth only, layer composites draw through a layer-local camera, fullscreen layers through a canvas camera, static samples fold cameras, link-texture sizes are not folded as zero, cloudmotion's whole-vector assignment narrows, and `export` followed by U+00A0 is stripped. Offset semantics checked against 3605722997 (close-up and default shots, lens sliders) and 3292361861 (scripted lens, identical to HEAD at default settings).

- `python3 scripts/check_renderer.py` with local 3521337568, 3292361861, 3605722997, 3632513108 — exit 1: all 23 binaries exit 0, 10 generated cases pixel-equal with no diagnostics, reload cycles 0; 3292361861 pooled/isolated differ only in its live clock text (5,249 px) and reports 7 diagnostics, all also present on an unmodified HEAD build (clipping_mask, init TypeError)
- `scene_schema_tests` 85 passed, 2 failed (the documented pointer-capability timeouts); `script_runtime_compat_test` 75 passed, 1 failed (documented HostVectorUpdates…); `layer_texture_reference_test` 15/15; `mouse_input_test` 12/12; `static_subgraph_cache_test` 26/26
- `cargo test -p shader` — 14 suites, 503 passed
- Each new test fails with its fix reverted (composite camera, zero link resolution, fullscreen camera, static-sample camera, shot timeline, shot visibility, perspective framing, parallax formula, Unicode export, whole-vector narrowing)
- Offscreen: settled 3521337568 frame registers with every preview frame (background, planet, character); Metal and Vulkan agree at rest (mean abs 1.45 at 480x270) and at a zoom-1.5 shot once the puppet clock is matched (1.02); the intro ends on the rest frame on both backends
- `python3 scripts/build.py --renderer-only` then `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not done: Release build, desktop run, visual check of the live wallpaper, parallax under a real cursor; the running app still has the old renderer

## 2026-09-24 — First-seen displays start enabled with the primary wallpaper

- Change: bridge MonitorCfg::for_connected_display enables never-configured displays with the primary's wallpaper (mirror kept); enabled_selectors skips mirror monitors.
- cargo test --release -p wallpaper-bridge --lib: 323 passed (baseline 322).
- New test first_seen_display_starts_with_primary_wallpaper_and_keeps_opt_out_after_reconnect fails on HEAD rows.rs (enabled=false), passes after.
- native_video_routing mirror-group tests failed with only the default change (apply flipped mirror back to independent); pass after the enabled_selectors mirror filter.
- python3 scripts/test.py: 572 passed, 0 failed, 11 skipped (Swift links the previously built bridge lib; no Swift change).
- python3 scripts/check_renderer.py: 10 generated cases pooled/isolated exit 0, pixels_equal, reload cycles 0.
- Not run: wallpaper-core suite (core unchanged); Release build not requested, running app unchanged.
- Gap: configs saved by 0.5.0 with enabled=false for auto-added displays are not migrated.

## 2026-09-24 — Release rebuild at aaed861; lock screen activated on the private puppet scene

- `python3 scripts/build.py --configuration Release` — exit 0 from a clean tree at `aaed861` (= origin/main); delivered `build/Build/Products/Release/WallpaperMachine.app`, binaries linked 20:12 after the last renderer edit (20:03), 17 `TexturePrefetch` symbols in the extension
- Runtime, user-launched previous build (d81942d-era renderer): extension started 12:06:29 UTC, `Frame ready display=1 pixels=4112x2658` and `Acquired` at 12:06:37 (about 8 s, under WallpaperAgent's ~31 s limit); `ready-1.json` matches the published revision with no error
- The running lock-screen extension exited when the bundle was rebuilt; the app was not quit or relaunched, so the new binaries are not yet running
- Not verified: lock-screen visuals and power; whether the old build would have missed 30 s in this host was not measured

## 2026-09-24 — Release build: lock-screen texture prefetch and acquire-failure reporting

- `python3 scripts/build.py --configuration Release` — exit 0; delivered `build/Build/Products/Release/WallpaperMachine.app`
- Bundle check: app and extension binaries each contain 17 `TexturePrefetch` symbols, linked 19:43 after the last renderer edit (19:35); the extension contains the new `Acquire failed display=` diagnostic
- After review, `TexturePrefetch` keeps the workers that started when a thread fails to start; `texture_prefetch_test` — 7 passed (new `WithoutWorkersEveryImageIsLeftToTheCallerAtOnce`), 3 runs
- Not run: the app was not launched and the lock screen was not re-enabled; Debug and Release copies of the extension are both still registered

## 2026-09-24 — Lock screen: parallel texture decode at pass preparation; extension reports acquire failures

Animate Lock Screen failed for a private 943 MB puppet scene (122 embedded PNG textures). Confirmed: WallpaperAgent abandoned the extension's acquire after about 31 s with no frame. Likely contributor, not measured inside the extension: the offscreen probe needs 15.6 s to its first frame, dominated by single-threaded stb_image PNG decode. The extension sent no readiness error, so the app showed its generic 'macOS did not load' message.

- `python3 scripts/check_renderer.py` — exit 0; 25 binaries including new `texture_prefetch_test` (6 tests); 10 generated cases pooled/isolated pixels equal, 0 diagnostics; reload cycles 8x2 clean; no `--project` corpus; asset checks skipped: `MetalSceneDraw.LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend` (no `WE_TEST_METAL_PROJECTS`), `TextObjectRuntime.LonelyCatHeadlessRegression` (no local fixture), `TextObjectRuntime.Workshop3409533530FullSceneKeepsClockRenderPassAndTexture` (package absent)
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped of 585
- `offscreen_scene_probe` on the private scene, warm shader cache — first frame 15.6 s before, 14.7 s with the `FindTex` check, 3.6 s with `TexturePrefetch`; frame SHA-256 identical; peak RSS about 0.8 to 1.1 GB
- Mutation: admitting past the byte budget fails `HoldsDecodingAndUntakenImagesWithinTheBudget` and `AdmitsAnImageLargerThanTheBudgetOnItsOwn`
- `python3 scripts/build.py --renderer-only` — exit 0; `libwallpaper_bridge.a` contains `TexturePrefetch`
- Not run: lock-screen activation through WallpaperAgent (changes the system wallpaper; not authorized) and a Release build (not requested); first-frame time inside the extension is unmeasured

## 2026-09-24 — Requested full Release rebuild after equal-quality and remote integration

- Requested a new build after committing/pushing the equal-quality work and integrating the remote parallax and Workshop download-concurrency changes. Used the full renderer/bridge build, not --swift-only.
- Prebuild python3 scripts/test.py: exit 0; 152 Python cases passed, native 574 passed, 0 failed, 11 opt-in skipped of 585 (9 native media, 2 live Workshop). No desktop UI or opt-in network/audio-hardware run.
- python3 scripts/build.py --configuration Release: exit 0; Cargo workspace rebuilt, Swift/FFI bindings regenerated, XcodeGen and Release app/extension build succeeded. Delivered build/Build/Products/Release/WallpaperMachine.app, version 0.5.0 (16).
- Complete current source-input SHA-256 d9600b9b572197f6d1627ac05d6977be82354ed454137f0d2bbb0b56526137a0, covering 1036 source/config/test files including relevant untracked files. Before/after manifests show no source drift during the gate and build. New executable SHA-256 173c1d51889243657a5d4990bd5b6d43e176abde45abfc6d7e5127a7abca7cbf.
- All 15 bundled Contents/Resources/WebUI files byte-match the current WebUI sources, including the new download-concurrency settings row. codesign --verify --deep --strict build/Build/Products/Release/WallpaperMachine.app: exit 0.
- No install, ordinary app launch/quit/restart, desktop visual check or power measurement. User must quit and reopen the delivered app. Earlier power results refer to executable c03902bfae6dddf9cdd929a2dfc73056280dfbe82b7241478d4e86bf048aadbc, not this rebuilt executable.
