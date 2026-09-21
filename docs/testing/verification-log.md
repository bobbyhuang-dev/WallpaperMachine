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

## 2026-09-21 — Corrected: Native Metal never dropped the album cover, and my fix took the clouds away

Reported as the clouds suddenly disappearing. They did, and I caused it: the album-cover rejection I added earlier forced this wallpaper onto Compatibility, which is the backend that flattens them.

- The finding it rested on was wrong. InjectSystemMediaForMetal was defined but never called -- an edit dropped the call site -- so every Metal render was made with no cover and no thumbnail colours, and the flat grey that produced was read as the backend dropping them
- With the call restored: Native Metal reports the runtime image source, publishes the cover, and its background keeps the clouds -- stddev 13.5 against Compatibility 6.7 on the same events
- The rejection and its test are withdrawn. The Metal harness now prints whether it could publish the cover, because a run that could not looks exactly like a backend that dropped it
- The real remaining defect is the other way round: Compatibility flattens the cloud layer. Contrast falls from 17.0 at the bokeh output to 3.8 after the blur effect. Ruled out with measurements: combo delivery (both variants compiled, one with VERTICAL=1), target allocation (1280x540), the wallpaper parameters (scale "1 1"), scene optimisation (A/B identical), varying locations (SPIR-V decoded, vertex outputs 0-12 match fragment inputs 0-12), and the bound resolution (1280x540 on both blur passes, traced in passes.txt)
- scripts/test.py 535 passed / 0 failed / 11 skipped of 546; metal_backend_test 35; metal_scene_draw_smoke 33; check_renderer.py 10 cases pixels_equal=True
- Release rebuilt

## 2026-09-21 — Native Metal never saw the album cover, and the wallpaper has no cover background

Reported as the background not looking like the official example. Two separate things, established by rendering both backends against the same injected now-playing state.

- metal_scene_draw_smoke now takes WE_TEST_MEDIA_ARTWORK and WE_TEST_MEDIA_EVENTS the same way the probe does. Without them a media-driven wallpaper renders flat grey on both backends and the comparison says nothing
- With the same cover and colours: Compatibility background chroma 29.2 and the cover drawn; Native Metal chroma 0.00 and no cover at all. The native backend uploads an image when it prepares and never sees the runtime republish it, so it drew the transparent placeholder the media slots start with
- A scene binding a system cover slot now falls back whole, reporting "the wallpaper draws the album cover, which the runtime republishes". Narrowed to $media* on purpose: text layers are runtime-published too and the backend does keep those current -- rejecting all runtime images broke 9 text tests
- New MetalCapability.ARuntimeRepublishedImageSendsTheWholeSceneBack pins it; the live wallpaper now reports Compatibility with that reason
- Separately, and not a defect: this wallpaper has no album-art background. Only objects 297 and 295 bind $mediaThumbnail as a texture, both cover displays; every background layer is util/white tinted from the event colours. The blurred-cover background in the official shot comes from its Use Custom Background option
- scripts/test.py 535 passed / 0 failed / 11 skipped of 546; metal_backend_test 36; metal_scene_draw_smoke 33; check_renderer.py 10 cases pixels_equal=True
- Release rebuilt

## 2026-09-21 — A trait default swallowed the sink that kept the shortcut channel open

The instrumented build logged 'Stopped waiting for wallpaper shortcuts' at startup, before any press, which placed the fault in the bridge rather than anywhere downstream.

- EngineFacade::set_user_shortcut_callback carried a default no-op body. ArcEngineFacade, which BridgeBuilder::build wraps every facade in, never overrode it, so the callback was dropped on the floor
- That callback owned the only sender for the shortcut channel. Dropping it closed the channel immediately, so the very first next_user_shortcut returned "the engine stopped reporting user shortcuts" and the loop gave up before the user touched anything
- The default body is removed; the method is now required, and the compiler found ArcEngineFacade plus three test fakes. FakeEngineFacade keeps the callback and gained report_user_shortcut so a test can report a press the way the engine does
- New a_reported_press_comes_back_out_of_the_bridge: fails with the forwarder removed ("the bridge never installed its sink"), passes with it
- Two robustness fixes alongside: a failed consent lookup no longer kills the loop permanently, and the Swift loop retries five times with backoff and logs the actual error instead of discarding it
- scripts/test.py 535 passed / 0 failed / 11 skipped of 546; wallpaper-bridge 322 passed
- Release rebuilt

## 2026-09-21 — Nothing was waiting at the end of the shortcut chain

Presses still did nothing after the value fix. Instrumenting each hop and reading the user's log settled it in one press instead of another round of reasoning.

- Log evidence: `openUserShortcut nextsongbutton -> "media:next"` and `user shortcut reported: request=1 callback=1 value="media:next"` both appear, so the value fix works and the request crosses the main looper
- Neither the consent-drop line nor the carried-out line appears, which places the break after the engine and before anything acts
- Cause: SceneMediaCoordinator, which owned the nextUserShortcut long poll, was never constructed. It appeared only in two stop() calls. The class was dead code, so the whole Swift half of the chain never ran
- The wait now belongs to SceneMediaSink, the object that already holds the one live DesktopMediaSession and is actually constructed; DesktopMediaSession gained send(_:). The dead coordinator is deleted rather than started, which would have double-subscribed the provider
- Verified the last link directly against the machine before changing anything: the bundled adapter toggled Spotify False -> True -> False, so send was never the problem
- New testAPressReachesThePlayer: three presses in, two commands out, and a binding this host cannot carry out never reaches the player
- scripts/test.py 535 passed / 0 failed / 11 skipped of 546; SceneMediaSinkTests 7 passed
- Release rebuilt

## 2026-09-21 — The bound shortcut never reached the scene engine

The button pressed and released correctly after the capture fix, but the player still did not skip. The default bound in the last change only existed on the panel side.

- The scene engine parses project.json itself, where all three usershortcut values are empty. The bridge sent only explicit property_overrides, and the user has none, so openUserShortcut resolved to an empty value and the press was correctly dropped
- ProjectProperty now records default_is_host_supplied, set exactly where an unbound usershortcut is given the action its name states. Scene activation sends those defaults with the overrides, user overrides applied on top
- New an_unbound_transport_shortcut_reaches_the_scene_engine asserts the scene receives {"nextsongbutton":"media:next","playpausebutton":"media:playpause"} with no user overrides, that an unguessable name stays out of it, and that choosing no action still sends the empty string
- scripts/test.py 534 passed / 0 failed / 11 skipped of 545; wallpaper-bridge 321 passed
- Release rebuilt
