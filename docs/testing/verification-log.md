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

## 2026-09-20 — The halo was missing because the desktop draws that scene with Metal

`config.toml` sets `scene_renderer = "native_metal_preferred"` and the local-project gate reports 3799253558 as Native Metal, so every `offscreen_scene_probe` measurement of it described a backend it never runs on. The probe is Vulkan-only; check the backend before comparing.

- Same scene, same seed, audio the only difference — Vulkan: 7 668 590 px changed whole-frame, 129 471 in the ring annulus. Native Metal: 929 and 0
- Not a missing uniform: `g_AudioSpectrum64Left` is in that pass's Metal reflection and written every frame at offset 1120, stride 16, with a live band 0
- `metal_scene_draw_smoke`'s local-project gate now reads `WE_TEST_PROPERTIES` and `WE_TEST_AUDIO_HZ`; without them a property-gated, audio-driven layer could not be drawn there at all

## 2026-09-20 — Three author effects were rejected by the shader frontend

3280146735 failed to load Bokeh blur, Cutout Vignette and Refract on every launch, so it rendered with no depth-of-field, vignette or refraction. Four permissive-path idioms now absorbed; see [renderer.md](renderer.md).

- `effects/refract` — a texture annotation `"default":""` means the slot has no default, not an invalid request
- `workshop/2798319181/effects/gaussian` — `(depth < limit) * 6.0` converts with `float(...)`; a comparison that stays a condition is untouched
- `workshop/2138904733/effects/cutout_vignette` — mixed-width operands inside a call argument truncate to the narrowest; `CAST2`/`CAST3`/`CAST4` now classify as constructors
- Probe on 3280146735 — 3 `failed to load` and 3 `Rust shader compile failed` before, 0 and 0 after; 399 executed passes before, 432 after
- Installed corpus (10 scenes, Vulkan probe) — only 3292361861 still fails (4× `clipping_mask`, logical-not on a float, not addressed); no scene gained a failure
- 4 tests in `legalize_type_coercion.rs`, two per rule, each pinning the rewrite and its refusal; the rewriting two also compile through `NagaCompiler`

## 2026-09-20 — Full-window first-run guide with Steam sign-in

- Replaced the welcome card with a five-page full-window guide (WebUI/welcome.js + welcome.css): language & appearance (live, Skip restores), Steam sign-in, preferences (drafts), tips + GitHub, start.
- Native sign-in-only SteamCMD session: WorkshopDownloader.signIn (+login +quit, isSigningInOnly), WorkshopDownloadManager.signIn (id steam-sign-in), WorkshopStore.requestSignIn, steamSignIn panel action; snapshot titles for itemless jobs.
- python3 scripts/test.py --only DownloaderLifecycleTests/testSignInOnlySession… --only WorkshopDownloadIntentTests/testSignInRequest…: 3 passed.
- python3 scripts/test.py --only ControlPanelShellTests/testFirstRunGuideCoversTheWindowWalksFivePagesAndReturnsFromSettings: passed after splitting a click + setTimeout into separate JS calls (a combined call never resolved offscreen).
- python3 scripts/test.py (full gate): 523 passed, 0 failed, 11 skipped (opt-in media/network layers), Python checks OK incl. localization parity with welcome.js added to the scanned files.
- impeccable detect --json WebUI/welcome.js WebUI/welcome.css: no findings.
- Not done: no Release build, no desktop/visual check of the guide (offscreen DOM/state assertions only); zh-Hans strings added by hand, unreviewed by a native speaker.

## 2026-09-20 — First-run welcome guide

- Feature: one-screen first-run welcome over the panel content (not modal; tabs stay live). Three facts: browsing is free, downloading needs a Steam account that owns Wallpaper Engine (with Create a Steam account / Buy Wallpaper Engine links), nothing changes until Apply. Actions: Browse the Workshop, Import wallpapers, Skip; Escape, scrim and tab clicks dismiss. Replay from Settings → Library & Steam → Welcome guide.
- Native: welcomeSeen persisted in UserDefaults (WebPanelController.welcomeSeenKey), snapshot field welcomeSeen, action welcomeSeen. Both links pass allowedExternalURL.
- Localization: zh-Hans catalog extended; scripts/tests/test_panel_localization.py passes.
- python3 scripts/test.py (full gate, once): 520 passed, 0 failed, 11 skipped (the usual opt-in media/network skips). New test ControlPanelShellTests/testFirstRunWelcomeShowsOnceLinksToSteamAndReturnsFromSettings.
- Panel suites rerun after a test-only isolation fix (Shell/Library/Discover/Sync: 30 passed): every WebPanelController in tests now receives the test's own UserDefaults suite. Before that, test runs wrote welcomeSeen=1 into the real app.mac-wallpaper-engine domain; the key was deleted again with defaults delete.
- Visual: offscreen WKWebView.takeSnapshot captures (throwaway test, deleted) at 760×560 dark en, 960×640 dark zh-Hans, 1240×800 light en; one overflow at the minimum window fixed by widening the card and relaxing the step measure. impeccable detect: no findings.
- Not done: no Release build, no desktop run; the entrance animation and real-window focus were not observed live.
