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

## 2026-09-21 — A wallpaper's shortcut press now reaches the host, gated on the user's media consent

The engine pushes each request to an installed observer instead of holding it, because a request no host has taken is a press the user already stopped waiting for. WallpaperBridge::next_user_shortcut long-polls a bounded channel outside the actor, so waiting for a rare press stalls no other request and costs no idle wakeup, and it drops requests from wallpapers missing from system_media_scene_handles.

- `usershortcut` parses as Combo carrying the actions this host can carry out -- none, play/pause, next, previous -- rather than a new property kind, so the panel needs no new control and validation and effective-value come from the paths that already exist
- `user_shortcut_offers_the_actions_this_host_can_carry_out` — asserts the kind and the four option values; deleting just the usershortcut arm in the manifest parser fails it with "a shortcut the user cannot bind is a button that does nothing"
- Also corrected: `cargo_environment()` derives the pin from the popped value instead of repeating the literal
- Measured across the release archives: the C++ engine is `minos 26.0` on all 39 objects, and nothing anywhere exceeds the app minimum
- `cargo test --release -p wallpaper-core --lib` 213 passed; `-p wallpaper-bridge --lib` 317 passed

## 2026-09-21 — Corrected: the deployment target had to move, not disappear

The fix below dropped MACOSX_DEPLOYMENT_TARGET from cargo's environment outright. That variable is also what cmake-rs turns into CMAKE_OSX_DEPLOYMENT_TARGET for the C++ engine, so dropping it silently rebuilt the engine against the SDK default instead of the app's minimum. The 55 s build that looked like a success had reused C++ objects from an earlier run built with the pin.

- Measured on a clean build of the renderer crate: with the variable the engine archive reports `minos 26.0`, without it `minos 27.0`
- The pin is renamed rather than removed -- `cargo_environment()` exports `OWE_MACOSX_DEPLOYMENT_TARGET`, and the crate build script passes it as CMAKE_OSX_DEPLOYMENT_TARGET with rerun-if-env-changed, so the host proc-macro dylibs stay loadable and the engine keeps the app\s minimum
- `cargo clean --release` then `cargo build --release --workspace` — clean build passes, archive at minos 26.0
- `scripts/check_renderer.py` clean — 10 generated cases pixels_equal=True; `scripts/tests` 99 passed

## 2026-09-21 — A pinned deployment target was breaking every release renderer build

scripts/build.py handed cargo a MACOSX_DEPLOYMENT_TARGET. Cargo builds proc-macro crates and build scripts for the host and then dlopens them in the running compiler, and the pinned host dylibs this toolchain produces are rejected at load with "mis-aligned LINKEDIT" -- which rustc reports as `can't find crate for <macro>`, so arc-swap, tokio, zerocopy, miette, futures-util and uniffi_meta all failed to compile. Any renderer release build was dead; --swift-only hid it by skipping cargo.

- Isolated by rebuilding one proc-macro under the environment minus each variable in turn and dlopening the result: without SDKROOT it still fails, without MACOSX_DEPLOYMENT_TARGET it loads
- Cargo steps in `build.py` and `check_renderer.py` now use `cargo_environment()`; Xcode still sets its own deployment target for the app, and the crates ship a staticlib the app links
- `cargo test --release -p wallpaper-core --lib` 213 passed, `-p wallpaper-bridge --lib` 316 passed — the bridge compiles core, so this also covers the open_scene arity change
- `scripts/check_renderer.py` clean — 10 generated cases, pixels_equal=True, 0 diagnostics, 8 reload cycles

## 2026-09-21 — The shortcut request reaches the FFI boundary; the host chain above it does not exist yet

SceneWallpaper drains the runtime's requests after the tick that produced them and reports each on the native main looper, and owe_scene_wallpaper_set_user_shortcut_callback follows the pointer-callback contract exactly. OweScene::set_user_shortcut_callback installs the Rust sink. The buttons are still dead: nothing above the FFI consumes these yet, the three properties hold empty values, and no send path to a media player exists.

- Remaining, in order: a bounded channel per scene in core (the pointer relay uses a watch, which coalesces -- wrong for presses, where play/pause followed by next must not lose one), an actor message tagged with the SceneHandle, a PropertyKind::UserShortcut carrying Combo metadata so the user picks the action, and a Swift consumer that sends it to whichever provider is currently answering
- Enabling that send changes the bundled adapter from read-only to control, which the mediaremote-adapter provenance note currently states is not done -- that note has to change with it
- `scripts/test.py` — 523 passed, 0 failed, 11 skipped of 534
- First run failed on CodeSign with "resource fork, Finder information, or similar detritus not allowed" on the Debug app; `xattr -cr` on the product cleared it, unrelated to any change here

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
