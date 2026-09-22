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

## 2026-09-22 — Chinese for service-layer and lock-screen extension messages

- Wrapped user-facing messages in String(localized:): Workshop downloader/queue errors and statuses, import errors, library deletion, scene-assets locator, lock-screen service statuses and errors, media relay reason, SteamCMD setup/lock status fallbacks.
- Messages that named removed buttons (Retry Steam sign-in, Install scene assets…, Refresh in Library) now name the current ones.
- New Extension/Localizable.xcstrings (26 keys); WallpaperRuntime.failure takes String.LocalizationValue, failure(detail:) carries renderer text as-is; appex now ships en.lproj and zh-Hans.lproj.
- Catalogs equal the compiler-extracted key sets (SWIFT_EMIT_LOC_STRINGS=YES): app 385, extension 26, every key with zh-Hans.
- Left in English on purpose: SteamCMD output patterns, logs, diagnostics report fields, native-video admission reasons (logged), desktop poster sync errors (NSLog), identifiers and paths.
- test_panel_localization.py now also checks Extension/Localizable.xcstrings; LockScreenWallpaperServiceTests compare with String(localized:) instead of English text.
- python3 scripts/test.py: 537 passed, 0 failed, 11 skipped.
- Not checked: messages rendered in a running app or System Settings (no desktop run); no Release build.

## 2026-09-22 — UI copy rewrite, native localization gaps and catalog cleanup

- Rewrote AI-sounding panel copy in English and zh-Hans (WebUI/panel.js, settings.js, welcome.js, locales/zh-Hans.js).
- Localized native confirm dialogs, open-panel titles/messages, action errors, SteamCMD setup status, import progress and menus (AppDelegate menuItem now takes String.LocalizationValue).
- Import panel message no longer claims web projects cannot play.
- Native catalog synced to compiler-extracted keys (SWIFT_EMIT_LOC_STRINGS=YES build): 65 missing keys added with zh-Hans, 361 unused keys removed; 293 keys now, equal to the extracted set.
- Panel catalog: 3 unreferenced keys removed; dynamic keys (shortcut actions, '(standard)' resolutions) kept; Steam password/Steam Guard code labels now go through t().
- Docs: localization.md gains the catalog sync procedure; workshop-downloads.md points at current labels.
- python3 scripts/test.py: 537 passed, 0 failed, 11 skipped (after xattr -cr on the Debug app for the known CodeSign detritus failure).
- Not checked: rendered dialogs/menus in a running app (no desktop run); no Release build.

## 2026-09-22 — Loose-asset origin, texture fallback and pointer mapping under zoom

Follow-ups to the same change. Deciding where to read a loose asset from by std::filesystem::is_absolute() was wrong: a mounted candidate is /assets/materials/foo.png, absolute too, so every packaged loose picture and video went to the host filesystem. The origin now travels on LooseAssetCandidate. A texture property is only taken when the file it names opens now, so a moved or sandbox-denied pick keeps the authored texture instead of a name that decodes to nothing. Pointer mapping in both backends and the probe read SceneCamera::VisibleWidth/VisibleHeight, the extent the ortho projection is built from, so clicks and mouse-linked particles follow a zoomed 2D scene.

- `python3 scripts/check_renderer.py` — 10 generated cases pixel-equal, 0 diagnostics, reload cycles 0
- `tex_schema_tests` 19 passed; `media_thumbnail_texture_smoke` 20 passed; `mouse_input_test` 12 passed
- `scene_schema_tests` 83 passed / 2 pre-existing failures; `script_runtime_compat_test` 71 passed / 1 pre-existing failure
- Counter-checks: `TexSchema.PackagedLooseImageStillLoadsFromTheMount` fails when LoadLooseAssetPayload decides by is_absolute(); `MouseInput.HitTestingFollowsACameraObjectZoomAcrossAResize` fails when cursor mapping is given Width()/Height(). Both pass after
- Swift gate not re-run: nothing outside `upstream/renderer` changed since it passed at 537/0/11, and `cargo build --workspace --release` links the new renderer
- Not rebuilt for Release and never launched; on-screen behaviour of 3588579284 and 3632513108 stays unverified

## 2026-09-22 — Scene textures, camera zoom, layer parents and scripted alpha

Three renderer gaps behind wallpaper 3588579284 and 3632513108. A usertextures entry naming a scenetexture property was never substituted, so eight 'choose your own picture' slots always showed packaged artwork; WPTexImageParser now also reads an absolute host path, and the package probe is skipped for one so it stops logging a missing .tex per slot. A camera object's zoom is applied when the ortho projection is built (SceneCamera::SetZoom) rather than by writing camera width/height, which ApplyCameraFillMode rewrites on every resize. thisLayer.getParent() and a layer alpha that reaches g_UserAlpha fix 3632513108's dock, which threw 'cannot read property visible of undefined' once a frame. Camera path/queuemode stay parse-only: 3588579284 ships scripts/camera_paths_1297271.json containing {"paths": []}.

- `python3 scripts/test.py` — exit 0; 537 passed, 0 failed, 11 skipped of 548
- `python3 scripts/check_renderer.py` — 10 generated cases pixel-equal, 0 diagnostics, reload cycles 0
- `media_thumbnail_texture_smoke` 19 passed; `tex_schema_tests` 17 passed (suite now links PkgConfig::TEST_LZ4; it did not compile before)
- `script_runtime_compat_test` 71 passed, 1 failed — pre-existing HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors, reproduced with ScriptEngine.cpp stashed
- `scene_schema_tests` 83 passed, 2 failed — the documented pre-existing PointerCapability/MouseButtonCommit timeouts
- `offscreen_scene_probe` on 3588579284 (3840x2160, 1 frame): WE_TEST_PROPERTIES setting the eight scenetexture slots to a magenta PNG changed 6284367/8294400 pixels (75.8%), max channel delta 255, sampled (237,255,255)->(255,0,255); a rerun logged 0 VFS misses for that path
- `offscreen_scene_probe` on 3588579284 with newproperty30=2.0 (its camera object's user-bound zoom): 8020854 pixels (96.7%) differ from the baseline frame, max channel delta 255
- Not rebuilt for Release: no delivery requested, so the running app still has the old renderer and panel.

## 2026-09-22 — Property labels reduced to words; wordless rows dropped

Workshop authors write property labels as HTML — colour tags, breaks, rules and 2000x1 image strips from image boards. A label that stripped to nothing fell back to the property id, and the Wallpaper Engine editor derives ids from that same markup, so the panel printed multi-line 'imgsrchttpphotogzphotostore…' names (seen on 3588579284, 3632513108, 3292361861, 2887099508, 3605722997 — 33 such labels across the local library). plainLabel now turns breaks and block ends into spaces, decodes the editor's entities with &amp; last, resolves the editor's ui_browse_properties_scheme_color token, and returns empty for decoration; the page drops a wordless text row, names a wordless control 'Unnamed option', and omits an empty properties section.

- `python3 scripts/test.py` — exit 0; 537 passed, 0 failed, 11 skipped of 548
- `python3 scripts/test.py --only WebPanelPropertyLabelTests` — exit 0; 2 passed (snapshot label reduction; page naming and omission through a real offscreen WKWebView)
- First gate run failed in CodeSign: 'resource fork, Finder information, or similar detritus not allowed' on build/…/Debug/WallpaperMachine.app (com.apple.FinderInfo + com.apple.fileprovider.fpfs#P from the synced checkout). `xattr -c` on the bundle cleared it; unrelated to the change.
- Not rebuilt for Release: no delivery requested, so the running app still shows the old labels.
- Renderer untouched, so `scripts/check_renderer.py` was not run.

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
