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

## 2026-09-22 — Solar layer name collision

Live Solar System's sun group and a hidden text readout are both named s. The readout registered second and took the name, so the simulation's getLayer("s").scale stretched that label into the full-height white bars and never resized the sun.

- Text labels that repeat a group, image or model name now keep __we_text_<id>; the earlier layer keeps the shared name.
- TextObjectRuntime.TextLabelDoesNotStealAnotherLayersName passed.
- Offscreen workshop 3662790108 with intro animation forced off: the white columns are gone (screen-right mean 12.5, was 255). Stars, the sun glow, one orbit arc and the HUD remain. View mode 3 still keeps most bodies small.
- python3 scripts/check_renderer.py — exit 0; evidence artifacts/renderer/adaptive-20260922-101020.
- The delivered app was not rebuilt.

## 2026-09-22 — Solar intro card alpha

- Image alpha update scripts now write g_Alpha. Workshop 3662790108's start-black card was stuck at opacity 1 and covered the star shell.
- Offscreen probe, intro property off: corner 400x200 max 255, 216/5000 samples above 4; full frame 16809/32400 samples above 4. Intro on, first frame, corners stay 0, which matches the card's 0–14s timeline.
- Saturn 3589454154 still draws: full-frame samples above 4 are 14483/129600, corner max 15.
- python3 scripts/check_renderer.py exit 0 in 67s. Evidence artifacts/renderer/adaptive-20260922-082842.
- Planets stay on the scene's own simulation script and can be hidden or sub-pixel at the start. The Release app was not rebuilt.

## 2026-09-22 — Perspective models draw and the apply wait is 90s

- Offscreen probe, 1920x1080, final renderer binary.
- Saturn 3589454154 first frame 3343ms. Sky corner has star pixels (max 27); rings are in the lower frame.
- Cause: a mat4 write into std140 g_NormalModelMatrix spilled into g_ViewProjectionMatrix. Writes are clamped to the reflected size. Front face stays counter-clockwise.
- Live Solar System 3662790108 still shows the HUD only. Several bodies are script-hidden or sub-pixel at the first frames; the star shell still contributes no pixels.
- Workshop 3588579284 first frame 25061ms cold and 24361ms with vk-pipeline-cache.bin present. Both exceed the old 20s wait and finish inside 90s.
- mdl_schema_tests 54 passed. python3 scripts/check_renderer.py exit 0 (artifacts/renderer/adaptive-20260922-014221).
- App was not rebuilt.

## 2026-09-22 — Re-verified and delivered on the renamed tree, with the LGPL FFmpeg

The trail fix was verified before the rename landed; rebasing onto it made both gates unrunnable because `Formula/mwe-ffmpeg.rb` was not installed. Installed with the user's authorization, then everything re-run on the rebased tree.

- `python3 scripts/install_ffmpeg.py` — exit 0 in 93s; `--check` reports mwe-ffmpeg 8.1.2 installed from the current formula
- `artifacts/renderer/bin` deleted first: its CMake cache still pointed at Homebrew ffmpeg@8, which is what made the pre-install test host abort with "search path '/opt/homebrew/opt/mwe-ffmpeg/lib' not found"
- `python3 scripts/test.py` — exit 0; 535 passed, 11 skipped of 546
- `python3 scripts/check_renderer.py --assets <old SceneAssets> --project 3605722997` — exit 0 in 156s; every gtest binary 0 including particle_mouse_controlpoint_test, 10 generated cases pixel-equal with 0 diagnostics, local project pooled+isolated exit 0 and pixels_equal=True, reload cycles 0
- `python3 scripts/build.py --configuration Release` — exit 0; ParticleSystem.cpp 23:43:31, its object 00:06:27, libwallpaper_bridge.a 00:06:56, app binary 00:07:34
- `build/Build/Products/Release/WallpaperMachine.app` — 42,039,392-byte arm64 Mach-O, ad-hoc signed, app.wallpapermachine 0.5.0 (16); otool shows libavcodec/libavformat/libavutil/libswscale resolved to /opt/homebrew/opt/mwe-ffmpeg, not Homebrew ffmpeg@8. Stale MacWallpaperEngine.* products removed from the Release directory
- Gap the rename leaves, not this change: nothing migrates ~/Library/Application Support/mac-wallpaper-engine to .../WallpaperMachine and the defaults domain moved from app.mac-wallpaper-engine to the empty app.wallpapermachine, so the new bundle starts with no library and default settings until the data is moved
- Not run: the app was not launched, no wallpaper applied, no desktop check. Trail and interaction behaviour on screen stay unverified

## 2026-09-21 — The mouse trail tracked the canvas, not the window

A particle system's mouse-linked control point derived its own scene coordinate as `pointerPosition * ortho` while the scripts used the presentation's cursor viewport. Reported as a trail that tracks in the middle of the screen and slides away toward the sides, on more than one wallpaper. `SetCursorInput` now publishes its mapped point to `Scene::pointerScenePosition` and the control point reads it.

- `offscreen_scene_probe` WE_TEST_CLICK_VIEWPORT=4112x2658@2.0:fill on 3605722997 — the window shows canvas x [166.3, 2394.2] of 2560, so the old product was wrong by 165.8 scene units (~306 physical px, 7.4% of width) at either edge and exact at the centre. Under :fit the same display letterboxes to y [-107.1, 1547.7]
- `particle_mouse_controlpoint_test` — exit 0, 39 tests; new `MouseControlpointFollowsTheCroppedPresentation` fails on the pre-fix branch with x=200 vs 160 and x=0 vs 40 while its centre assertion passes, which is the reported symptom as numbers
- `mouse_input_test` — exit 0, 11 tests; the viewport mapping the fix consumes is unchanged
- `python3 scripts/check_renderer.py --project 3605722997` — every binary 0, 10 generated cases pixel-equal with 0 diagnostics, local project exit 0 and pixels_equal=True, reload cycles 0. `particle_mouse_controlpoint_test` added to the gate so the new case actually runs
- `python3 scripts/test.py` — exit 0; 535 passed, 11 skipped of 546
- `python3 scripts/build.py --configuration Release` — exit 0 in 64s; ParticleSystem.cpp edited 23:27:58, its object 23:40:21, libwallpaper_bridge.a 23:40:50, app binary 23:41:21
- Not covered: nothing exercises SceneWallpaper's message loop offscreen, so the host half — polling the pointer, publishing the viewport — is still only unit-covered. On-screen trail behaviour unverified until the user reopens the app

## 2026-09-21 — Renamed the project from MacWallpaperEngine to WallpaperMachine

The rename was half applied and was rebased onto the nineteen renderer/media commits already on origin/main, so the incoming work had to be carried onto the new name as well.

- Zero occurrences of MacWallpaperEngine / MacWallpaperExtension / mac-wallpaper-engine / MAC_WALLPAPER_ENGINE remain in the tracked tree (build output and artifacts/ excluded)
- Runtime breaks the partial rename had left: upstream/renderer/crates/bridge/src/paths.rs read MAC_WALLPAPER_ENGINE_* while ClientPaths exports WALLPAPER_MACHINE_*, and SceneWallpaperBindings.mm observed MacWallpaperEngine.requestDesktopPoster while the host posts WallpaperMachine.requestDesktopPoster; both boundaries now pair on every name
- Also renamed in the vendored tree: BUNDLE_IDENTIFIER app.wallpapermachine, WALLPAPER_MACHINE_CONTENT_PACING in VideoFramePacing.cpp, the SceneAssets fallback in metal_scene_draw_smoke.mm, the shader pipeline test overrides, and the audio-permission message; recorded in upstream/provenance.json
- docs/testing/renderer.md claimed MAC_WALLPAPER_ENGINE_DISABLE_CONTENT_PACING=1 disables pacing off a paced default; no such variable exists. Corrected to WALLPAPER_MACHINE_CONTENT_PACING=1 enabling pacing over a fixed-cadence default, matching VideoFramePacing.cpp and power-benchmark.md
- DownloadTelemetryTests nettop fixtures used the 15-character truncation MacWallpaperEng.42; now WallpaperMachin.42
- WallpaperMachine.xcodeproj regenerated with xcodegen after the rebase; this dropped SceneMediaCoordinator.swift, which origin had removed in 9cd8719 and the pre-rebase project still referenced
- The stale prebuilt bridge library failed to link system_media_consent_handles (added by the incoming commits); python3 scripts/build.py --renderer-only rebuilt it and left App/Bridge/Generated/ unchanged
- python3 scripts/test.py — 535 passed, 0 failed, 11 skipped of 546
- python3 scripts/check_renderer.py — 21 gtest binaries, 0 failures, 408 assertions; 10 probe cases pooled+isolated exit 0, pixels_equal=True, 0 diagnostics; reload cycles 0
- artifacts/renderer/bin held a CMake cache pinned to the old directory name and had to be deleted before the renderer could configure; that is what the rename costs an existing checkout
- Not rebuilt: no Release build was requested, so build/Build/Products/Release still holds the old bundle

## 2026-09-21 — GPL licensing and commercial distribution policy

- Replaced Homebrew GPLv3 FFmpeg with Formula/mwe-ffmpeg.rb (8.1.2, LGPL-2.1-or-later); installed formula and brew test passed; actual avcodec_license/configuration and otool dependencies verified.
- python3 scripts/build.py --renderer-only passed; python3 scripts/check_renderer.py passed ten generated pooled/isolated scenes, reload cycles and renderer suites; three local-fixture tests skipped.
- python3 scripts/test.py: 529 passed, 0 failed, 11 skipped; Python script tests passed.
- python3 scripts/package.py --configuration Debug --check passed; existing GPLv3 Release input rejected without mutation. Disposable Debug copy fully packaged and codesign verified; GPL and keg notices checked; repackaging refused; temporary app/archive removed.
- Installer idempotence and interrupted-reinstall receipt recovery exercised. No desktop launch, install, Developer ID signing or notarization performed; Release app not rebuilt.
- Public binary CI blocked: GPL-2.0-only with Apache-2.0 Vulkan/shader dependencies still requires copyright-holder permissions or compatible replacements. Selling signed binaries and priority support does not override GPL recipient/source rights.

## 2026-09-21 — Release build delivered with the camera-layer fix

Supersedes the "Not rebuilt" line of the previous entry: the Release build was requested afterwards. Renderer change, so the full build, not --swift-only. Nothing was launched, no wallpaper changed.

- `python3 scripts/build.py --configuration Release` — exit 0 in 54s; cargo workspace, uniffi-bindgen, xcodegen, xcodebuild all clean (14 + 26 warning lines in the logs)
- Contains the change: WPSceneParser.cpp edited 22:48:40, its object under `target/release/build/wallpaper-core/*/open_wallpaper_engine/build` recompiled 23:07:06, `libwallpaper_bridge.a` 23:07:16, app binary 23:07:47 — each newer than the last
- `build/Build/Products/Release/WallpaperMachine.app` — 42,069,648-byte arm64 Mach-O, ad-hoc signed, app.wallpapermachine 0.5.0 (16)
- No tracked file moved: `App/Bridge/Generated/` and the Xcode project are unchanged by the regeneration, so the bridge API is the same
- Not run: the app was not launched or quit, no wallpaper was applied, no screenshot or desktop check. On-screen behaviour of 3605722997 and 3292361861 stays unverified until the user reopens the app

## 2026-09-21 — Camera layers stop reframing 2D scenes

A visible `camera` layer in a scene with `orthogonalprojection` used to become the active perspective camera at the authored shot pose, framing a few hundred units of a canvas thousands of units wide: workshop 3605722997 rendered one magnified sliver of its top-right corner over `general.clearcolor`, on both backends. `ParseCameraObj` now leaves `scene.cameras`/`activeCamera` alone for orthographic scenes. Local wallpapers are personal copies; only IDs and measurements are recorded.

- `offscreen_scene_probe` 3605722997 — before: non-clear pixels only in x[1280,2559] y[0,719], coverage 0.250; after: full canvas, matches the authored preview.gif composition
- `offscreen_scene_probe` 3292361861 — before: ~9x perspective crop; after: full canvas with clock, media and FPS widgets in place
- `metal_scene_draw_smoke` WE_TEST_METAL_PROJECTS — 3605722997 and 3292361861 accepted as Native Metal, 120 frames each; before coverage 0.250, after full canvas, matching the Vulkan probe
- `scene_schema_tests --gtest_filter=SceneSchema.*Camera*` — exit 0, 9 tests; new `CameraObjectKeepsAnOrthographicSceneOnItsCanvas` fails on the pre-fix branch (active camera perspective, canvas centre at NDC 0.772) and passes after
- `python3 scripts/check_renderer.py --project 3605722997 --project 3292361861` — 10 generated cases pixel-equal with 0 diagnostics, both local projects exit 0, reload cycles 0. 3292361861 reports pixels_equal=False (543 px, its live clock row) and 25 diagnostics that are byte-identical with the camera layer removed: pre-existing workshop clipping-mask shader and property-script gaps, not this change
- `python3 scripts/test.py` — exit 0; 535 passed, 11 skipped of 546
- Not rebuilt: no Release build was requested, so the installed app still has the old renderer

## 2026-09-21 — The flat background: a blur was dividing its step by a 2x2 placeholder

Compatibility flattened this wallpaper's cloud layer. Traced by dumping every pass and reading the constants each one was given.

- A target that follows the screen is registered with placeholder dimensions while the scene parses, because the output size is not known yet. g_TextureNResolution is folded into the material at that same moment, and nothing refreshed it afterwards
- blur_gaussian steps by 1/g_Texture0Resolution.zw, so it divided by two: its 13 taps spanned six times the whole texture, every one clamped to the edge, and the output was the edge colour everywhere
- Fixed by re-baking those constants in ResolveScreenBoundRenderTargetSizes, after the real size is known. Effect-chain nodes hang off the camera rather than the scene graph, so they are walked separately -- they are exactly the passes this matters for
- Result on the reported wallpaper: the cloud layer comes back, final-frame contrast 15.0 -> 30.8, matching what Native Metal already drew
- New RenderScale.AScreenBoundTargetsResolutionReachesTheMaterialThatSamplesIt: fails without the fix (2 where 480 and 270 are expected), passes with it. It asserts all four components, since the existing resolution test only ever checked the first two and a blur divides by the last two
- Two false starts recorded so they are not repeated: passes.txt lists parse-time constants rather than live uniform values, and a pass dump is the whole pooled allocation rather than the target
- scripts/test.py 535 passed / 0 failed / 11 skipped of 546; check_renderer.py 10 cases pixels_equal=True; render_scale_test 9; metal_backend_test 35; metal_scene_draw_smoke 33; scene_schema_tests 80 with the two pre-existing pointer timeouts. rendergraph_smoke segfaults with and without this change -- pre-existing
- Release rebuilt
