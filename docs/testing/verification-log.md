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

## 2026-09-21 — engine.openUserShortcut existed nowhere, so every transport button threw

This wallpaper's play/pause, next and previous buttons each have a cursorDown handler whose only statement is engine.openUserShortcut("<property>"). That member was not registered on the engine object at all, so the call threw TypeError, the handler aborted, and the press did nothing -- which is the whole of the reported 切歌无效, not a missing media permission.

- The binding resolves the named property against the wallpaper\s own declared properties and queues the request with that property\s VALUE; the three properties here are usershortcut-typed with empty values, so acting on the name would be the host deciding for the user
- `OpenUserShortcutCarriesTheValueTheUserChose` — two presses arrive in order with their configured values, an unbound one still reports with nothing to run, and taking twice does not replay
- `OpenUserShortcutRefusesAPropertyTheWallpaperDoesNotDeclare` — naming a property the wallpaper does not declare raises a script error instead of passing silently
- `UndrainedShortcutRequestsKeepTheNewestPresses` — 40 requests with no drain keep at most 16, and the newest survives
- `scenescript_media_event_smoke` 19 passed; `scene_schema_tests` 74 passed plus the two known 5 s pointer timeouts

## 2026-09-21 — Corrected: two separate Metal divergences, and the blobs are not the clouds' negative space

The entry below overstated what was measured. It headlined the clouds pass while admitting the flattening pass was unknown; what was actually shown is that the clouds pass's INPUT is identical on both backends (white 6520x3460 card) -- its output was never read back on either. It also claimed the blob structure agrees and only tone differs, which no measurement supported.

- Measured now: metal-bright (>92nd percentile) against vulkan-dark (<8th) gives IoU 0.052, and against vulkan-bright 0.043 -- the shapes are disjoint, not the same clouds in another tone
- The one-run lodMaxClamp experiment splits it in two: clamping Metal to level 0 moves the mean from 81.7 to 100.8, onto Vulkan 98.8, so the mip level the shader asks for (g_CloudLOD=5, and clouds_256.tex ships 7 levels) is a real backend difference in overall tone
- But p99 stays 206 against Vulkan 121 under that clamp, so the bright regions are a second, independent defect that LOD does not explain
- Which backend is right is not settled: Wallpaper Engine exposes that LOD as "smoothness" and the author set it to the maximum, so honouring level 5 may be the correct behaviour and Compatibility the deviant one

## 2026-09-20 — The Metal cloud divergence is inside the clouds pass, not the blur chain

Dumping every render target on the Metal side found the clouds layer's own input (_rt_effect_pingpong_a, 6520x3460) at mean luma 255 -- and the Vulkan pass dump shows the same layer drawn from util/white with g_Color=[1,1,1], so both backends feed the clouds effect an identical white card. The difference is what the clouds pass makes of it: the shader computes mix(g_Color2, g_Color1, blend) with blend = smoothstep(0.08, 0.19, sampled noise) * 0.95, and BlendMode::Normal maps to One/Zero -- a replace -- on both backends, so wherever blend falls near zero the white card is written straight out.

- Metal keeps that contrast (p99 202); Vulkan lands on a flat mid grey (p99 121) with the same blob structure, so the noise scale agrees and only the tone does
- Ruled out additionally this round: mip availability (clouds_256.tex ships 7 levels, both backends size the image and the sampler from image_slot.mipmaps.size()), the alpha write mask (write_alpha is output != _rt_default on both), and the Normal blend factors (One/Zero on both)
- Still open: which pass compresses the range on Vulkan and not on Metal -- the post-processing layer runs blurprecise, bokeh_blur, blur, two color_grading instances and dithering
- `scripts/check_renderer.py` clean -- 10 generated cases, pixels_equal=True, diagnostics=0 -- confirming the probe texel-size change shifted no expectation; `metal_scene_draw_smoke` 33 passed

## 2026-09-20 — Native Metal draws this scene's cloud background wrong, and the harnesses were not comparable

The extra frosted shape beside the media card reproduces offscreen, and only on Native Metal. At a matched 5120x2160 raster the Metal background is huge bright blobs (p99 luma 202) where Vulkan is a smooth grey wash (p99 121); the scene's own media card and clock are correct on both. The two harnesses were not comparable until now: the Vulkan probe never set texel size, so every neighbour-tap effect it drew sampled at a 1920x1080 step, and the Metal smoke rasterized 960x540 against a 5120x2160 scene target.

- Ruled out by measurement, not by reading: texel size (mean 82.2 vs 82.3 once the probe reports it honestly), static subgraph reuse (21k of 11M pixels differ with WE_TEST_SCENE_OPTIMIZATION=0), shader translation (every program compiles; the array varying `v_TexCoord[13]` reaches MSL with distinct taps at loc0..loc12), and the uniform values themselves
- Traced both backends at the clouds pass: g_Color1=[0,0,0], g_Color2=[0.141176,...], g_CloudScales=[1,1,1,0.5], g_Texture0Resolution=[6520,3460,...] agree exactly, and every one resolves to a real reflection member on Metal
- Repro: `WE_TEST_METAL_SURFACE=5120x2160 WE_TEST_METAL_PROJECTS=<project.json> metal_scene_draw_smoke --gtest_filter=*LocalProjectsNamed*` against `WE_TEST_FRAMES=120 offscreen_scene_probe`
- `metal_scene_draw_smoke` 33 passed; not yet isolated, so nothing is claimed fixed

## 2026-09-20 — The consent test now pins the clear it is named for

As first written, WithdrawingConsentDropsWhatWasRetained passed with the whole fix removed: while the setting is off both the replay and the runtime's own gate refuse to dispatch, so the assertion could not tell retention-with-clear from no retention at all.

- Re-sequenced to enable → event → disable → enable again → attach: retaining without clearing replays the stale event on the second enable, which is the only way that sequence can reveal the probe
- Verified by deleting just the `clear()` in `SET_MEDIA_INTEGRATION_ENABLED` — the test fails with "consent was withdrawn and what was playing then was replayed anyway" and passes with it restored
- `scene_schema_tests` — 74 passed, plus the two pre-existing 5 s pointer-capability timeouts recorded in renderer.md; neither gate builds this suite

## 2026-09-20 — Corrected: a settings change reloads on the same object, and the harness exists

Two claims in the entry below were wrong. A property change does not produce a new scene handle: set_property_override sets a property on the existing object and SceneWallpaper turns it into LOAD_SCENE on that same object, so the host's fedHandles diff is empty and there is no replay at all — the old runtime is discarded with the old Scene and the new one starts blank. The null-runtime window the entry described is the wallpaper-switch case. Retaining every live event and replaying on attach covers both, and depends on no host timing.

- Also wrong: a headless SceneWallpaper harness does exist — `SceneWallpaperInputTestAccess::PostScene` posts SET_SCENE with a parsed scene and no renderer
- `SceneSchema.MediaStateSurvivesTheSceneItArrivedBefore` — submits `mediaPlaybackChanged` before any scene, attaches a scene whose script reveals a node on it, asserts the node is visible. Fails on the previous commit with "a scene attached after the event never learned what was playing"
- `SceneSchema.MediaStateIsNotReplayedAfterConsentIsWithdrawn` — the same sequence with media integration turned off in between leaves the node hidden
- Still uncovered: publishing the surface size (`publishScreenResolution`), which needs a RenderInitInfo the harness does not supply

## 2026-09-20 — Retained media events across a scene rebuild; screenResolution is the display

Two fixes the reported symptoms pointed at. MEDIA_EVENT_JSON was dropped whenever the wallpaper had no scene or runtime — the window a settings change opens, and exactly when the host replays state because the rebuilt scene is a new handle. The artwork already survived it by being parked; the events did not, and this wallpaper's cover group is revealed by mediaPlaybackChanged. Separately engine.screenResolution followed the cursor viewport, which is the scene's own world extent.

- SceneWallpaper retains the latest media event per type in first-arrival order and replays them on scene attach; withdrawing media consent clears them
- `SceneRuntimeContext::SetScreenResolution` is now its own setter; `SetCursorViewport` no longer moves it. SceneWallpaper publishes `RenderInitInfo::width`/`height`, which are already physical pixels (host fills them from `DisplayDesc`; both backends divide by the scale factor for logical points)
- `SceneScriptMediaEventSmoke.EngineScreenResolutionIsAReadableVec2` now asserts the viewport does NOT move the value, that the display resolution does, and that a zero is refused — it fails on the old coupling
- `scenescript_media_event_smoke` 16, `mouse_input_test` 11, `layer_texture_reference_test` 11 — passed. `script_runtime_compat_test` fails only on the pre-existing `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
- Installed corpus (10 scenes, probe) — 4 pre-existing failures in 3292361861, every other scene 0
- `python3 scripts/test.py` — 523 passed, 0 failed, 11 skipped of 534. The first run failed `ControlPanelShellTests.testFirstRunGuideCovers…`, which passes 10/10 targeted both with and without these changes and is flaky under the new parallel runner, not a regression here
- `python3 scripts/check_renderer.py` — exit 0, adaptive-20260920-215805; `python3 scripts/build.py --configuration Release` — exit 0
- Not covered by an automated test: the SceneWallpaper half of both fixes (retain/replay, and publishing the surface size). No harness constructs SceneWallpaper with a surface and a runtime — the binding tests never load a scene and the Metal smoke drives MetalRender directly

## 2026-09-20 — Attributing the per-scene diffs behind the annotation-default fix

The entry below reported three scenes changing and called them wall-clock text. Re-measured with both probe binaries built first and run back to back, which is the only way the clock and the async text layout hold still.

- 3665954520 — text layers identical, 0.509% changed at max delta 9 (sub-perceptual); the 5.39% first measured was a minute roll plus that scene`s time-varying grain
- 3662790108 — not the clock: the same binary run twice changes 0.531% at max 765 and its text layers still disagree on raster size for identical strings, so that scene is unstable run to run through the text layout worker
- 2998757800 — 205 px, a clock digit
- Unchanged: 6 of 10 scenes byte-identical; the only attributable change is 3280146735`s cover at 0.54%
- `layer_texture_reference_test` — 11 passed. The regression test now pins both halves: with the combo off the authored slot 0 survives and the defaulted slot 1 is left unbound. It fails on both assertions with the parser change reverted

## 2026-09-20 — An annotation default was claiming the author bound that texture slot

3280146735's album cover rendered as a circle. WPSceneParser's default-texture stabilisation loop feeds the defaulted list back as the compiler's texture presence, so every sampler with both a combo and a default had that combo forced to 1; rounded_mask then read its radius from a white default instead of u_Radius. The default still binds for sampling — only what the combo reports changed.

- Probe on 3280146735 — the cover goes from an inscribed circle (fill 0.790 ≈ π/4) to the authored rounded square; same crop, same seed
- Same-seed frames for all 10 installed scenes, before and after: 6 byte-identical; 3662790108, 2998757800 and 3665954520 differ only in their wall-clock text (a same-binary back-to-back rerun of 3665954520 changes 5.33% against the 5.39% measured, so that scene is noise)
- The only change outside those clocks is the cover itself: 0.54% of 3280146735
- `LayerTextureReference.AnnotationDefaultBindsItsSlotWithoutClaimingTheAuthorBoundIt` — 11 tests pass; it fails with the change reverted
- `metal_scene_draw_smoke` local gate on 3280146735 — still Native Metal, 120 frames, no `metal translation of … failed`
- `python3 scripts/check_renderer.py` — exit 0, adaptive-20260920-204029: 10 generated cases `pixels_equal=true`, 0 diagnostics
- `python3 scripts/test.py` — exit 0, Tests-20260920-210253-762337.xcresult: 519 passed, 0 failed, 11 skipped of 530

## 2026-09-20 — A scalar uniform array had two different layouts

std140 pads every array element to 16 bytes — what the host packs and the reflection reports — while the MSL backend emits the natural tight stride, so `float g_AudioSpectrum64Left[64]` moved every member after it by 768 bytes on Native Metal only. Narrow array members are now declared `vec4 name[N]` with reads swizzled back; see [renderer.md](renderer.md). `ShaderPipelineRevision` 6 → 8.

- Four read paths: direct, array-parameter specialization, `#define` aliases written inside `main` (this one broke five installed wallpapers before it was covered), and local array aliases
- 3799253558 on Metal, audio vs silence — 929 → 11 428 244 px whole-frame, 0 → 66 995 in the ring annulus; frame 30.0% → 99.8% non-black, its background, flowers and fog back
- Metal gate over all 10 installed scenes, before and after — backend decisions identical, `metal translation of … failed` 11 → 8, exactly the three repaired shaders
- Installed corpus (Vulkan probe) — 4 pre-existing failures in 3292361861 before and after; every other scene 0
- `cargo test -p shader` — 14 binaries, 0 failed; `metal_scene_draw_smoke` — 34 tests, 33 passed, 1 skipped (local gate skips without `WE_TEST_METAL_PROJECTS`)
- Re-run after rebasing onto `d6e9b78`, which reworked the test runner: `python3 scripts/check_renderer.py` — exit 0, `adaptive-20260920-195302`: 10 generated cases `pixels_equal=true`, 0 diagnostics, 8 projects × 2 reload cycles clean
- `python3 scripts/test.py` — exit 0, `Tests-20260920-195139-287781.xcresult`: 519 passed, 0 failed, 11 skipped of 530
- `python3 scripts/build.py --configuration Release` — exit 0; app not launched, no desktop state changed
