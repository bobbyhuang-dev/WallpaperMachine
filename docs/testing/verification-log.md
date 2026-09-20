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

## 2026-09-20 — Quiet script output, doc archive and rg ignore, log helper, section index, test-file split

Agent-cost pass. `scripts/lib/xcode.py` streams xcodebuild/cargo output to `artifacts/` and echoes only errors, failing tests and a verdict (`--verbose` restores the stream; `xcodegen --quiet`); the two 250 KB plan/progress documents moved to `docs/archive/` and a repository `.ignore` keeps `rg` out of archives, generated bindings and `upstream/`; `scripts/log_verification.py` prepends log entries and archives overflow; `docs/testing/renderer.md` gained a section index; `DownloaderTests` and `ControlPanelLayoutTests` split into five suites each over shared base classes (same 88 test methods, none rewritten).

- `python3 scripts/test.py` — exit 0; 529 native tests: 518 passed, 11 skipped (asset/opt-in), 0 failed, 33 s; 99 Python script tests OK including new `test_xcode.py` (8) and `test_log_verification.py` (8).
- `python3 scripts/test.py --only ControlPanelSyncTests --only SteamCMDRuntimeValidationTests` — 14 passed; `--only AppThemeTests` after the runner change — 3 passed, three lines of output.
- Filter replayed over nine archived xcodebuild logs: green runs echo 0 lines, the two failing ones echo 7–8 (assertion, failed case, suite verdict).
- Not verified: Release build (no app code changed); desktop behaviour untouched.

## 2026-09-20 — Parallel native tests, opt-in live Steam cases, doc split, build-on-request

Follow-up to the tiered gate. Test classes now run in parallel worker processes
(`-parallel-testing-enabled YES`, `--serial` to diagnose interference); the two
`testLive…` Workshop cases became opt-in behind
`MAC_WALLPAPER_ENGINE_NETWORK_TESTS=1`; `scripts/test.py` keeps the five newest
result bundles; `scripts/build.py` also uses `xcodegen --use-cache`. Coverage
inventory moved to `docs/testing/coverage.md`, `docs/architecture.md` gained a
section index, and the Release build is now on request
(`.omp/rules/release-build-on-request.md`) rather than after every feature.

- `python3 scripts/tests/test_test.py` — 10 tests OK (identifiers, parallel flag,
  bundle pruning, opt-in variable list).
- `python3 scripts/test.py` — Python script tests OK; native 529 tests, 518 passed,
  11 skipped, 0 failures, 1m12 wall clock (was 2m41 serial). Three parallel runs,
  no interference; skips are 9 asset/media + the 2 live Steam cases.
- `MAC_WALLPAPER_ENGINE_NETWORK_TESTS=1 python3 scripts/test.py --only WorkshopTests`
  — 7 passed, 0 skipped; without the variable, 5 passed, 2 skipped.
- No Release build: tooling and docs only, no delivery requested.

## 2026-09-20 — Tiered verification: `scripts/test.py --only`, xcodegen cache, small-fix gate

Small bug fixes were paying the full gate twice plus a Release build (~20 min).
`AGENTS.md` now scales the gate to the change (`docs/testing/README.md`
"Verification tiers"); `scripts/test.py --only <Class[/method]>` narrows the
native run and `xcodegen generate --use-cache` keeps incremental builds alive.

- `python3 scripts/tests/test_test.py` — 5 tests OK (identifier and command shape).
- `python3 scripts/test.py --only AppLanguageTests` — 5 passed, 0 failures, ~2 s wall clock.
- `python3 scripts/test.py` — Python script tests OK; native 529 tests, 520 passed,
  9 skipped, 0 failures, test phase 157 s. No Release build (tooling/docs change).

## 2026-09-20 — Discover search button wrapped vertically in Chinese; panel tests pinned to English

`.search-form` let its submit button shrink, and a CJK label breaks between any
two characters, so 搜索 rendered one glyph per line and taller than the input.
`WebUI/panel.css` now gives `.search-form button` `flex: none; white-space:
nowrap`. The first gate run also exposed that panel tests reading English labels
used `AppLanguageStore.shared`, which follows the developer's in-app language
choice; they now pass `AppLanguageStore.english()` (`Tests/Unit/Support/`).

- `python3 scripts/test.py` before the test fix, with the app set to 简体中文 —
  native 516 passed, 9 skipped, 4 failures, all Chinese labels or a JS lookup
  by English title in `ControlPanelLayoutTests`; none related to the CSS change.
- `python3 scripts/test.py` after — 73 Python tests OK; native 520 passed,
  9 skipped, 0 failures.
- `python3 scripts/build.py --swift-only --configuration Release` — exit 0,
  `** BUILD SUCCEEDED **`; bundled `Contents/Resources/WebUI/` matches `WebUI/`.
  Delivered `build/Build/Products/Release/MacWallpaperEngine.app`; not launched.
  The rendered Chinese button was not screenshotted (no desktop run).

## 2026-09-20 — In-app language picker, per-language panel catalogs, registry checks

Simplified Chinese was already translated but only reachable through macOS's
language settings. Settings → General now has **Language** (System (Auto),
English, 简体中文); the choice switches the panel in place and mirrors into the
app-domain `AppleLanguages` so native strings follow on the next launch. The
WebUI catalog moved to `WebUI/locales/zh-Hans.js` behind a registry in
`i18n.js`; `AppLanguage.supported` drives the picker and the served-file allow
list. Adding a language is documented in `docs/localization.md`.

- `python3 scripts/test.py` — 73 Python tests OK (catalog check now verifies
  Swift/i18n/locales/xcstrings registries agree, native keys all translated, key
  parity across catalogs); native 529 tests, 9 skipped, 0 failures. New:
  `AppLanguageTests` (5), `testLanguageSettingSwitchesThePanelInPlaceAndOffersEveryShippedLanguage`.
- `python3 scripts/build.py --swift-only --configuration Release` — succeeded;
  bundled `WebUI/` byte-identical to source, `locales/zh-Hans.js` and
  `zh-Hans.lproj` present. No renderer change, no desktop run; the picker's
  visual layout is unchecked on screen.

## 2026-09-20 — Verification log capped at ten entries; durable facts promoted

Documentation only. The log had grown to 106 entries in six days (260 KB, 30% of
`docs/`), and facts that were still true were only findable inside it. No source,
build or desktop change.

- Entries 11 and older moved verbatim into
  `docs/testing/archive/verification-log-2026-09.md`; only relative link depth
  changed. Checked byte-identical against `git show HEAD:…` before and after the
  split, so no recorded result was altered or lost.
- Promoted out of the log: the two `scene_schema_tests` pointer-case timeouts,
  the stale `$TMPDIR/wallpaper-engine-video` cache failures, `tex_schema_tests`
  not compiling (`lz4.h`; `PkgConfig::LZ4` is `PRIVATE` in `src/CMakeLists.txt`
  and the test target never links it), the `clipping_mask` / Music Visualizer
  shader-compile gaps, unimplemented `thisLayer.getParent()` and the unrendered
  perspective 3D content → `docs/testing/renderer.md`; the codesign xattr
  detritus failure and the first-configure cargo retry → `docs/build.md`.
- Entry format and the ten-entry retention rule are now in `docs/conventions.md`,
  `AGENTS.md` and `docs/testing/README.md`; the archive is indexed in
  `docs/README.md`.
- `python3 -m unittest discover -s scripts/tests -q` — 71 tests, OK. Relative
  Markdown links across `AGENTS.md`, `README.md`, `CONTRIBUTING.md`,
  `LICENSING.md` and all 24 `docs/**/*.md` resolve: 0 broken. No app build, no
  renderer gate, no desktop run — nothing outside `docs/` and `AGENTS.md` changed.

## 2026-09-20 — The cover was drawn at a composition layer's local coordinates

Follow-up to the entry below, on the same wallpaper. With the texture binding
fixed, the album art reached a draw but landed as a clipped blob against the
left edge of the canvas while the square the user looks at stayed untextured.
`WE_TEST_DUMP_PASSES` attributed both shapes: pass 11 (node 297 `Song Cover`,
`textures=[$mediaThumbnail]`) filled its whole 1024×1024 target with the
published cover, the blend and rounded-mask passes preserved it, and the screen
composite put it at x ∈ [0, 312] — never at the layer's world x.

- **`SceneNode::AppendChild` set the parent without dirtying the child.**
  `UpdateTrans()` returns early on a clean node, so a node whose matrix had
  already been computed while it was unparented kept that matrix for good. A
  composition layer builds its camera and effect chain during parsing, before
  `AttachLayerNode` wires the graph, so node 208
  (`Livello di composizione regolabile`) reported `world=(0, 1085)` — its own
  local translate — instead of `(2560, 1085)`, and its children `38` and `297`
  inherited that origin. Every other layer in the scene was parented before
  anything asked for its transform, which is why only this subtree moved.
  `AppendChild` now calls `MarkTransDirty()` on the child, the same invariant
  `SetTranslate` / `SetScale` / `SetRotation` / `SetAttachmentTransform`
  already keep.
- Measured on the real project with the user's display geometry
  (`WE_TEST_CLICK_VIEWPORT=4112x2658@2.0:fill`, 40 frames at
  `WE_TEST_FRAME_STEP=0.0166`): node 208 now reports `world=(2560, 1085)`, and
  two runs differing only in artwork colour now differ **inside the cover
  square** — a 20 px patch at frame fraction (0.50, 0.47) reads `(27, 0, 0)`
  for `ff0000` and `(0, 27, 0)` for `00ff00`, with the artwork's bounding box
  centred at (0.500, 0.497). The left-edge blob is gone. The user confirmed the
  cover on the desktop afterwards.
- **The cover was then dimmed to 12%, and that was ours too.** All four
  `Song Cover` / `Song Cover SMALL` layers carry a constant
  `"color": "0.11765 0.11765 0.11765"`, and `genericimage4.frag` line 93 is
  `texSample2D(g_Texture0, v_TexCoord.xy) * g_Color4`, so the artwork drew at
  ~12% — pure `ff0000` measured `(27, 0, 0)`, one multiply, not two. The
  author's own recordings, linked from the wallpaper's description
  (`i.imgur.com/KOEcClx.gif`, not the 256×256 iOS mock-up in `preview.gif`),
  show that cover at full strength with white highlights. They are a montage —
  85 frames, several tracks, the clock pinned at Apple's 9:41 — so not one
  continuous capture, and the per-track blurred backgrounds in them do not
  match the shipped scene, which tints from the palette instead: these are
  recordings of an earlier build. What carries is that every state draws a
  different cover matching its own title and artist at full strength, which is
  engine output rather than hand-painted. Two further arguments point the same
  way inside the shipped content: another scene paints a background layer
  `0 0 0` behind a `scenetexture` binding, and this one exposes a separate
  "Image Brightness" slider for dimming. That colour paints the `util/white`
  placeholder the shared model material ships; once a runtime image is
  substituted into the slot there is nothing left for it to describe.
  `WPImageObject::FromJson` now drops it in
  exactly that case, and only that case: a binding that names a project
  property (`"usertextures":["bg"]`, `["backgroundimage"]`) substitutes nothing,
  so those layers — one of which is authored `0 0 0` — keep their colour.
  `IsSystemUserTexture` is now the single definition the substitution and this
  rule share. Measured after: node 297 draws with `g_Color4=[1,1,1,1]` and the
  square reads `(227, 0, 0)`, while node 38 — the same authored colour, no
  runtime image — still draws its dark card at `g_Color4=[0.11765,…]`.
  `SceneSchema.InstanceColourSurvivesUnlessARuntimeImageTakesTheSlot` pins both
  directions.
- `SceneSchema.AttachingAParentRefreshesAWorldTransformThatWasAlreadyComputed`
  covers the fix at three levels: compute a child's transform, attach a parent,
  and the world origin must follow, including for a subtree attached later. It
  fails with the `MarkTransDirty()` call removed and passes with it.
- The probe's node dump now records `world=`, `rendered=` and `override=` next
  to the local transform, which is what separated "positioned wrong" from
  "textured wrong" in one run.
- `python3 scripts/test.py` — exit 0. Counts read back from
  `Tests-20260920-150006-694596.xcresult` rather than the console tail:
  `result: Passed`, 523 tests, 514 passed, 0 failed, 9 skipped, no
  `testFailures`.
- `python3 scripts/check_renderer.py` — exit 0, `adaptive-20260920-150236`: 10
  generated cases `pixels_equal=true`, 0 diagnostics, 8 projects × 2 reload
  cycles clean.
- OWE suites, which neither gate builds: `mouse_input_test` 11,
  `media_thumbnail_texture_smoke` 14, `scenescript_media_event_smoke` 16,
  `scenescript_sound_layer_smoke` 8, `layer_texture_reference_test` 10,
  `scene_mesh_tests` 16 — all passed. `scene_schema_tests` 72 passed with the
  same two pre-existing pointer-capability timeouts recorded below.
- `python3 scripts/build.py --configuration Release` — exit 0,
  `** BUILD SUCCEEDED **`, twice: once for the re-parenting fix (binary
  14:43:10) and again after the instance-colour fix (binary 15:05:28, newer
  than every source edit in this entry). Delivered
  `build/Build/Products/Release/MacWallpaperEngine.app`. The app was not
  launched and no desktop state was changed.
- Still open on this wallpaper: `engine.openUserShortcut` (transport buttons),
  the `getLayer(…).play()` throw for its press sounds, the per-frame
  `lookAt` TypeError in its debug overlay, and `engine.screenResolution` being
  published as the cursor viewport's world extent rather than display pixels.

## 2026-09-20 — `$mediaThumbnail` reaches solid instance layers; the media buttons are inert by design gap

Reported against "Music Visualizer | iOS Style (Media Integration)" (`3280146735`,
a Scene wallpaper): no song data, no cover, and the transport buttons do nothing.
Three separate findings. Only the texture binding is fixed here, and it is not
by itself proof that the user's cover square fills in.

- **Now Playing itself works; the per-wallpaper switch was off.** The saved
  `wallpapers/3280146735.json` had `media_integration_enabled: false`, so the
  host started no provider. The pinned adapter answers on this machine: running
  the bundled `mediaremote-adapter.pl` against the Release bundle's
  `MediaRemoteAdapter.framework` printed the live Spotify track (`get`) and a
  `{"type":"data","diff":false,…}` stream envelope with `title`, `artist`,
  `album`, `artworkData`, `duration`, `elapsedTime`, ISO `timestamp` and
  `playing` — exactly what `AdapterSystemMediaProvider.receive` decodes. With
  the switch on, the user's desktop showed title, artist, timeline and tinting.
- **The album cover never reached the layer.** A scene object's `instance`
  block — the per-layer override a *solid instance* layer carries next to its
  shared model material — was parsed into `WPImageObject::Instance` and then
  used by nothing. `Song Cover` therefore kept `materials/util/solidlayer_instance_4.json`'s
  placeholder `util/white` and the authored `$mediaThumbnail` user texture was
  dropped. `WPImageObject::FromJson` now merges that block into the layer's
  material through the existing `WPMaterial::MergePass`, and the dead struct is
  gone. Offscreen evidence on the real project: `passes.txt` slot 0 for node 297
  goes from `util/white` to `$mediaThumbnail`, and that pass now samples the
  published cover (`e8503a` × the layer's `g_Color` 0.1176 = `27,9,7`) instead
  of white. `SceneSchema.ImageAbsorbsDependenciesInstanceAnimationLayersAndBindings`
  asserts the merged material instead of the unused struct; it fails with the
  merge removed (`unordered_map::at: key not found`) and passes with it.
- **Whether that cover becomes visible on this wallpaper is unverified.** Two
  probe runs differing only in artwork colour, with the user's display
  published through `WE_TEST_CLICK_VIEWPORT=4112x2658@2.0:fill` and 120 frames
  at `WE_TEST_FRAME_STEP=0.0166` so the blur and fade chains advance, differ on
  screen only in a left-edge blob and its blur halo (`ff0000` → a red disc,
  `00ff00` → a green one). The square the user looks at stays the same dark
  brown in both, and the page-wide tint follows the `mediaThumbnailChanged`
  colours, not the artwork. So the texture reaches a draw, but nothing offline
  shows it reaching the cover square. Two leads, neither chased here: this
  wallpaper's layout is script-driven and its live session logs a per-frame
  `ScriptEngine[update]: TypeError: not a function` at
  `lookAt (<property-script-factory>:45:30)`; and `SetCursorViewport` publishes
  `screen_resolution` as the cursor viewport's **world** extent (3341.8×2160
  here), not the display's pixels, so any layout computed from
  `engine.screenResolution` is working from scene units.
- **The transport buttons are not implemented, and that is the whole reason
  they do nothing.** Clicks do reach the layers: with the user's authorization,
  a one-shot `lldb` breakpoint on `owe_scene_wallpaper_mouse_input` caught a
  live delivery from `PollMouseState` (`d0=0.458 d1=0.393`),
  `owe_scene_wallpaper_mouse_button` caught `button=0 pressed=1`, and
  `CursorHitsLayer` runs from `DispatchCursorFrameEvents` every frame. The
  session log then shows `ScriptEngine[cursorDown]: TypeError: not a function`
  at `<property-script-factory>:28:9` for every press — the wallpaper calls
  `engine.openUserShortcut("nextsongbutton")`, and no such function exists in
  the script engine. The press sound fails separately: `getLayer(…).play()` is
  supported (`scenescript_sound_layer_smoke`, 8 passed, covers exactly that
  call) and this scene does declare `button_press` / `button_release` sound
  layers, yet the same throw appears at `:35:9` — an open, unexplained gap.
  Nothing was implemented for either
  in this round. The buttons' own scale script reacts to `cursorDown`, not to
  hover, so "hover does nothing" is the wallpaper's design, not a defect.
- The offscreen probe can now map a click the way a desktop does —
  `WE_TEST_CLICK_VIEWPORT="<px_w>x<px_h>@<scale>:<mode>"` publishes the
  presented viewport and feeds a window-normalized cursor instead of a world
  position. It leaves the camera exactly as `ParseCamera` built it, because
  nothing in the app sends `PROPERTY_FILLMODE` and a running wallpaper
  therefore never reaches `UpdateCameraFillMode`; cropping comes only from the
  scaling layout. On the user's geometry the window covers world
  x ∈ [889, 4231] and the button at (2738.6, 448.4) maps to normalized
  (0.553, 0.792), where `cursorDown` dispatches — which matches the live log
  and is how the renderer side was cleared before the live check.

- `python3 scripts/test.py` — exit 0, 523 native tests, 9 skipped, 0 failures;
  Python suites green. The first two attempts failed to code-sign
  (`resource fork, Finder information, or similar detritus not allowed`) until
  `xattr -cr` was run over `build/`; that is disposable output, not a code fault.
- `python3 scripts/check_renderer.py` — exit 0, `adaptive-20260920-132818`: 10
  generated cases `pixels_equal=true`, 0 diagnostics, 8 projects × 2 reload
  cycles clean. `media_thumbnail_texture_smoke` 14 passed,
  `scenescript_media_event_smoke` 16 passed, `layer_texture_reference_test` 10
  passed, `scene_schema_tests` 70 passed.
- **Pre-existing failures, not from this change:**
  `SceneSchema.PointerCapabilityFollowsActualCommitsWithoutFirstFrame` and
  `SceneSchema.MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch`
  both time out (`Wait(2)` / `Wait(3)` return false after 5 s). They fail
  identically with this round's renderer edits stashed, and neither
  `scripts/test.py` nor `scripts/check_renderer.py` runs them.
- `python3 scripts/build.py --configuration Release` — exit 0,
  `** BUILD SUCCEEDED **`. Delivered
  `build/Build/Products/Release/MacWallpaperEngine.app`; its binary (13:37:33)
  links a `libwescene-renderer.a` rebuilt at 13:35:27, after the parser edit at
  13:34:04. The app was not launched, and no wallpaper, display or audio state
  was changed.

## 2026-09-20 — Fast-forward local main to GitHub `ffd3c76` and rebuild

Local `main` was two commits behind `origin/main` (`f2cf701` vs `ffd3c76`).
Working tree was clean; `git pull --ff-only origin main` brought HEAD to
`ffd3c76baa17e9c688327cc606f387e80cffeede`. First `python3 scripts/test.py`
failed to link because `libwallpaper_bridge.a` predated
`apply_system_media_artwork` / `system_media_scene_handles`. Rebuilt the
renderer, then re-ran the gate. Uniffi regeneration added extra unused Swift
wrappers (`sceneMediaWallpaperIds`, `updateSceneMedia`); those generated files
were restored so the source tree matches GitHub. No desktop or Now Playing
session was started.

- `python3 scripts/test.py` — exit 0, 523 native tests, 514 passed, 9 skipped,
  0 failures. Python suites green.
- `python3 scripts/check_renderer.py` — generated cases 10/10
  `pixels_equal=true`, 0 diagnostics, 8 projects × 2 reload cycles clean
  (`adaptive-20260920-145931`). `video_source_input_test` first failed
  `ConcurrentPackagedOpensPublishExactlyOneFile` and
  `EvictingTheCacheDoesNotDisturbAnOpenSource` (`added.size()==2`) against a
  leftover `$TMPDIR/wallpaper-engine-video` cache; after clearing that
  directory the same binary passed 11/11.
- `python3 scripts/build.py --configuration Release` — exit 0,
  `** BUILD SUCCEEDED **`. Delivered
  `build/Build/Products/Release/MacWallpaperEngine.app` (Mach-O mtime
  2026-09-20 15:00). Bundled `Contents/Resources/WebUI/panel.js` matches
  `WebUI/panel.js`. The binary contains `ffd3c76`,
  `submit_system_media_event`, `apply_system_media_artwork`,
  `system_media_scene_handles`, `$mediaThumbnail`, `$mediaPreviousThumbnail`,
  `AdapterSystemMediaProvider`, `AppleScriptMediaProvider`,
  `DesktopMediaSession`, `SceneMediaSink`, `mediaIntegrationEnabled` and
  `screenResolution`. `Info.plist` still has `NSAppleEventsUsageDescription`.
  The app was not launched.

## 2026-09-20 — Rebase of scene-media plumbing onto native Now Playing

`e342a31` (`feat(media): integrate scene media support and enhance media handling`)
was rebased onto `f2cf701` (`feat(media): native now-playing integration and Leon
scene fixes`) as `51a0e90`. The host keeps one `DesktopMediaSession`: adapter
Now Playing is primary, AppleScript is fallback, web uses the shared relay, and
scenes are fed only by `SceneMediaSink`. After the rebase,
`MediaThumbnailTextureSmoke.PreviousThumbnailKeepsTheCoverItReplaced` failed
because `SetRgbaImage` auto-promote stamped the new version onto the outgoing
cover; the previous slot now keeps that image's own version so `Version()` and
`Image::key` agree when `AliasRuntimeImage` also runs. That C++ fix and the
provenance note are still uncommitted on top of `51a0e90`. No desktop or
Now Playing session was started.

- `python3 scripts/test.py` — exit 0, 523 native tests, 514 passed, 9 skipped,
  0 failures. Python suites green.
- `python3 scripts/check_renderer.py` — exit 0, `adaptive-20260920-114535`:
  10 generated cases `pixels_equal=true`, 0 diagnostics, 8 projects × 2 reload
  cycles clean.
- `media_thumbnail_texture_smoke` 14 passed;
  `scenescript_media_event_smoke` 16 passed.
  `cargo test -p wallpaper-core --release --lib` 213 passed;
  `cargo test -p wallpaper-bridge --release --lib` 316 passed.
- `python3 scripts/build.py --configuration Release` — exit 0,
  `** BUILD SUCCEEDED **`. Delivered
  `build/Build/Products/Release/MacWallpaperEngine.app`. Bundled
  `Contents/Resources/WebUI/panel.js` matches `WebUI/panel.js`. The binary
  contains `submit_system_media_event`, `apply_system_media_artwork`,
  `system_media_scene_handles`, `$mediaThumbnail`, `$mediaPreviousThumbnail`,
  `AdapterSystemMediaProvider`, `AppleScriptMediaProvider`,
  `DesktopMediaSession`, `SceneMediaSink` and `mediaIntegrationEnabled`.
  `Info.plist` still has `NSAppleEventsUsageDescription`. The app was not
  launched.
