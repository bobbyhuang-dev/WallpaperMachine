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

## 2026-09-20 — The renderer changes were never compiled; media consent, covers and AppleScript

The previous round's C++ and Rust edits were real but absent from the shipped
binary: the last delivery was `--swift-only`, so `libwescene-renderer.a` inside
the app still predated `engine.screenResolution` and the camera fix. `strings`
on the delivered Release app found no `screenResolution` at all. Everything
below was rebuilt with `--configuration Release`, and the delivered binary was
checked for the new symbols rather than assumed. Media integration now works
end to end; **SYKM's 3D content still does not render** — see the correction at
the end.

- **Consent, not a constant.** Desktop Scene templates took
  `media_integration_enabled(true)` unconditionally while the fan-out filtered
  on the saved setting, so the panel said "off" about a scene the engine had
  switched on. Activation now uses
  `context.wallpaper.media_integration_enabled`. New
  `WallpaperBridge::system_media_scene_handles()` names the consenting scenes;
  `AppDelegate.sceneMediaHandles` asks it instead of counting active scenes, so
  a machine with the setting off loads no MediaRemote, sends no Apple Event and
  is never asked for Automation permission.
- **Replay is keyed on the handle, not on aggregate demand.** `SceneMediaSink`
  used to replay only when demand went false→true, so swapping one opted-in
  Scene for another, or lighting a second display, left the new instance blank
  until the track changed. It now replays whenever a handle appears that it has
  not fed. `testAReplacementSceneIsToldTheUnchangedTrack` fails against the old
  condition and passes against the new one (verified by reverting it).
- **`NSAppleEventsUsageDescription`.** The app had only
  `NSAudioCaptureUsageDescription`, so every Apple Event to Music or Spotify
  would have been refused before the Automation prompt could appear — a runtime
  prerequisite no fake-runner test can see. The key is in
  `App/Resources/Info.plist` and was read back out of the built bundle. The app
  is not sandboxed (only `com.apple.security.get-task-allow`), so no
  `com.apple.security.automation.apple-events` entitlement is involved.
- **Two cover slots.** `RuntimeImageSource` seeds `$mediaThumbnail` and
  `$mediaPreviousThumbnail` and aliases the outgoing cover into the previous
  slot without copying pixels; `ApplySystemUserTextures` binds both and leaves
  any other `system` slot on its authored texture.
- **AppleScript source rewritten.** Players are chosen from
  `NSWorkspace.runningApplications` by bundle id, so nothing is launched and
  `System Events` is no longer involved; every `NSAppleScript` runs on one
  private serial queue instead of the main thread; Spotify's millisecond
  duration is converted where it is read; cover art is loaded once per track
  (Apple Events for Music, `artwork url` download for Spotify) rather than once
  a second. Music's script returns an empty artwork-URL field and
  `URL(string: "")` is *not* nil, so an unguarded parse sent Music down the
  download path and skipped its own cover entirely; the parser now treats an
  empty field as no URL. `FallbackSystemMediaProvider.availability` reads
  through to the live source instead of latching what was true at the switch.
- **MediaRemote on this machine.** A standalone probe resolved every symbol and
  `MRMediaRemoteGetNowPlayingInfo` replied nil — the entitlement gate. The
  AppleScript path is the only source here.

- `python3 scripts/test.py` — exit 0, 519 native tests, 510 passed, 9 skipped,
  0 failures. New: `AppleScriptMediaProviderTests` (running players only, first
  answering player, per-player duration units, artwork once per track, Music's
  empty artwork URL, empty reply), `SceneMediaSinkTests` (replacement scene,
  consent withdrawal) and `testAvailabilityFollowsTheLiveSourceAfterTheSwitch`.
- `cargo test -p wallpaper-bridge --release --lib` — 314 passed, including new
  `scene_media_handles_follow_consent_so_nothing_reads_the_player_without_it`.
  `cargo test -p wallpaper-core --release --lib` — 212 passed. Both need
  `scripts/build.py`'s environment; the first invocation after an environment
  change fails its CMake configure and succeeds on retry.
- `python3 scripts/check_renderer.py` — exit 0, `adaptive-20260920-112242`: 10
  generated cases `pixels_equal=true`, 0 diagnostics, 8 projects × 2 reload
  cycles clean. `media_thumbnail_texture_smoke` 13 passed (new previous-cover
  and unknown-system-slot cases); `scenescript_media_event_smoke` 15 passed.
- **Probe text pump fixed before trusting any label evidence.**
  `offscreen_scene_probe` never called `PumpTextLayerCache` inside its frame
  loop, which production DRAW does, so layouts finished by the text worker were
  never collected. It now pumps every frame and drains after media injection
  the way the warm-up does. The difference is visible in the probe's own
  report: `Canzone BIG … size=85.5 108` (unlaid-out) before, `size=391 108`
  after.
- New probe hooks `WE_TEST_MEDIA_EVENTS` / `WE_TEST_MEDIA_ARTWORK` rendered
  Music Visualizer with an injected track. With the pump fixed, the composited
  5120×2160 frame shows "Bohemian Rhapsody" and "Queen" drawn on the player
  widget, with the progress bar, transport, cover square and a background
  tinted from the injected palette. Re-run with a pure green cover, every
  sampled pixel followed it.
- **Correction — SYKM is not fixed.** The earlier claim in this entry's first
  draft ("240 frames show it animating") covered the title page only.
  Re-rendered with the authored intro disabled
  (`WE_TEST_PROPERTIES='{"newproperty48":false}'`), frames 0, 60 and 149 are
  byte-identical (mean 61.25) and still show only the 2D title/HUD layers plus
  a full-height white band artifact. The brightest pixels in the dark two
  thirds all sit on that band's edge: no stars, no orbits, no bodies.
  `nodes.txt` shows the 3D nodes exist and are effective-visible (`skybox1`
  scale 10000, `轨道显示内层/外层`, `sun-1`, `sun-4`, `SUN`, `s2`,
  `Solar system行星1-6`) at authored scales of 1e-4 … 0.1 against the
  perspective camera at `0 0 0.454`. So the `engine.screenResolution` fix is
  real — the script `TypeError`s are gone and the 2D layers now lay out — but
  the perspective/scale path that should draw the system is a separate,
  unfinished renderer problem.
- Other known gaps, unchanged: three effects in Music Visualizer still fail to
  compile — `gaussian` (`float *= bool * 6.0`), `cutout_vignette`
  (`vec3 - vec2`, HLSL-style truncation) and `effects/refract` (empty default
  texture) — so its cover blur is not authored-accurate. `usershortcut`
  transport is still unimplemented. `ShaderValue: … not found in glsl` on SYKM
  is authored leftovers, not a binding failure.
- `python3 scripts/build.py --configuration Release` — exit 0, `** BUILD
  SUCCEEDED **`. Delivered
  `build/Build/Products/Release/MacWallpaperEngine.app` carries
  `NSAppleEventsUsageDescription` in its `Info.plist` and contains
  `screenResolution`, `mediaPreviousThumbnail`, `systemMediaSceneHandles` and
  `applescript-now-playing`. No desktop run, no Peekaboo, no `--ui`; the app
  was not launched. Whether Music or Spotify actually reach SceneScript needs a
  requested desktop check after quit/reopen, with the per-wallpaper *Media
  integration* toggle turned on and Automation permission granted.

## 2026-09-20 — Launch crash: MediaRemote copied a non-escaping reply block

Applying a desktop Scene wallpaper now starts the shared media session. On
this machine that calls `MRMediaRemoteGetNowPlayingInfo`, which copies the
reply block. The Swift wrapper typed that block as non-escaping
(`@convention(block)` without `@escaping`), so the runtime trapped
(`EXC_BREAKPOINT`, `non-escaping closure has escaped`) on the main thread
during `FallbackSystemMediaProvider.addConsumer` →
`MediaRemoteMediaProvider.probe`. The C function types now mark the reply
as escaping. A unit test retains the block the way MediaRemote does and
delivers the dictionary after return. No desktop / Peekaboo / `--ui`;
whether Music or Spotify now reach SceneScript still needs a requested
desktop check after quit/reopen.

- `python3 scripts/test.py` — exit 0, 511 native tests, 502 passed, 9
  skipped, 0 failures (new
  `testCopyingTheMediaRemoteReplyBlockDoesNotTrap`).
- `python3 scripts/build.py --swift-only --configuration Release` — first
  attempt failed CodeSign (`resource fork, Finder information, or similar
  detritus not allowed` on the existing Release `.app` /
  `.appex`, `com.apple.FinderInfo` + File Provider xattrs). Cleared those
  with `xattr -cr` and the same command exited 0, `** BUILD SUCCEEDED **`.
  Delivered binary `build/Build/Products/Release/MacWallpaperEngine.app`.
  The app was not launched.

## 2026-09-20 — Applied Scene wallpapers were still blank: wrong camera, no screenResolution

The previous round instantiated SYKM's 73 models and a perspective camera, but
the first frames stayed almost black (max 8). Music Visualizer still had no
now-playing on the desktop. Cause was not "models discarded":

- SYKM's playing camera is object 705 (`camera: "default"`, origin
  `0 0 0.454`). The parser created that camera and left `activeCamera` on the
  editor `scene.camera` LookAt pose (`0.11 2.23 -1.48` looking at a nearby
  empty point). A visible `default` camera object now rebinds
  `global_perspective` and becomes `activeCamera`. Models in a perspective
  scene use that camera even without `perspective: true`.
- 96 SceneScript sites read `engine.screenResolution.x`. That property did not
  exist, so `getScreenSize` threw and HUD / shared rotation init aborted.
  `engine.screenResolution` is now a Vec2 (presentation size, else canvas).
- Desktop Scene templates now enable media integration on apply, and the host
  starts the shared session for any active Scene. MediaRemote that never
  answers still falls through to Music/Spotify after the probe. Lock screen
  still forces media off.

- `python3 scripts/test.py` — exit 0, 510 native tests, 501 passed, 9 skipped,
  0 failures (new fallback probe-timeout case).
- New gtests `DefaultCameraObjectBecomesActivePerspective` and
  `EngineScreenResolutionIsAReadableVec2` passed. Existing leaf-model and
  null-ortho perspective cases still pass.
- `python3 scripts/check_renderer.py` — exit 0,
  `adaptive-20260920-020721`: 10 generated cases `pixels_equal=true`, 0
  diagnostics, 8 projects × 2 reload cycles clean.
- `offscreen_scene_probe` on local `3662790108`: first-frame 9267 ms. Composite
  frames now have real content (`frame-0` 126523 nonzero, max 255, mean 3.42;
  previously 4399 nonzero, max 8). Camera node 705 sits at `0 0 0.454`.
  `engine.screenResolution.x` TypeErrors are gone; leftover `toFixed` of
  undefined remains on a few HUD scripts. No desktop / Peekaboo / `--ui`.
- `python3 scripts/build.py --configuration Release` — exit 0, `** BUILD
  SUCCEEDED **`. Delivered binary
  `build/Build/Products/Release/MacWallpaperEngine.app`. The app was not
  launched.

## 2026-09-20 — Scene now-playing fan-out, and leaf models plus a perspective camera for SYKM

Two Scene workshop packages were blank or mute for different reasons: Music
Visualizer | iOS Style (`3280146735`) never received SceneScript media events
because only Web wallpapers were wired to now-playing; Live Solar System - SYKM
(`3662790108`) parsed 73 `.mdl` objects and a perspective camera but discarded
both, so Compatibility cleared to black. No desktop run, no Peekaboo, no
`--ui`, no live Steam login. Whether planets actually fill a display and
whether album art tracks Music or Spotify still needs a requested desktop
check after quit/reopen.

- **Shared session, not a Web-only provider.** `DesktopMediaSession` owns one
  `FallbackSystemMediaProvider` (MediaRemote first, Music.app / Spotify
  AppleScript only after `noReply`) and fans events to Web plus opted-in
  desktop scenes. JSON is submitted verbatim (`submitSystemMediaEvent`); RGBA
  artwork is uploaded (`applySystemMediaArtwork`) before
  `mediaThumbnailChanged`. SceneScript now sees `MediaPlaybackEvent` 0/1/2 and
  Vec3 media colors. Lock-screen `apply_config` is followed by a forced
  media-off. The inspector toggle is shown for Scene as well as Web.
- **3D path is Compatibility only.** Leaf models enter `layer_nodes` with
  normals/tangents; `orthogonalprojection: null` / `isOrtho == false` activates
  `global_perspective`; `_rt_default` gets a depth attachment; material
  depth/cull reach Vulkan; authored lights stay; LDR bloom still builds when
  `hdr: true`. Native Metal still refuses perspective, dynamic lights and a
  depth target as a whole scene. Live `g_EyePosition` / `g_View*` are written
  only from a perspective camera so 2D sprite-trail billboards do not collapse
  (that regression failed
  `TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively`
  once, then passed after the restriction).
- `python3 scripts/test.py` — exit 0, 500 native tests, 491 passed, 9 skipped,
  0 failures; Python suites green.
- Cargo `--release --lib` for `wallpaper-core` and `wallpaper-bridge` — 212 and
  313 passed, including `scene_descriptor_can_enable_media_integration` and
  `scene_media_events_fan_out_only_to_opted_in_handles`.
- `python3 scripts/check_renderer.py` (after the eye-uniform fix; later
  `--skip-build`) — exit 0. `report.json` for
  `adaptive-20260920-013721`: every listed test binary 0, 10 generated cases
  `pixels_equal=true` in pooled and isolated mode, 0 diagnostics,
  `desktop_automation: false`, `gpu_surface: false`.
- Targeted gtests: `ParserInstantiatesLeafModel`,
  `OrthogonalprojectionNullActivatesPerspective`, lights/view uniforms, HDR
  bloom still emits bloom passes, `GenMeshIncludesNormals`, and 14
  `scenescript_media_event_smoke` cases passed. Full `scene_schema_tests` was
  69 passed / 2 failed —
  `PointerCapabilityFollowsActualCommitsWithoutFirstFrame` and
  `MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch` (5 s Wait
  timeouts). Those two are pre-existing and already in this log; they are not
  claimed as this change.
- `offscreen_scene_probe` on the local Library packages (SceneAssets on the
  probe `PATH`). `3662790108`: 73 `"model"` objects, `general.hdr` and
  `general.bloom` true, bloom passes present in the graph, camera node at the
  authored eye. Shader cache on the recorded run was warm (`hits=1711
  compiled=0`). Startup `parsed=6818` / `prepared=8732` / `first-frame=8803` ms
  — under the 20 s first-frame deadline. Composite `frame-0` / `frame-1` are
  almost black (6 220 800 bytes, 4399 nonzero, max 8); text-layer dumps have
  real glyphs. SceneScript repeatedly throws `TypeError` reading `.x` /
  `toFixed` from an undefined camera (`getScreenSize` / `getResolutionScale`)
  — `thisScene.camera` and `lookAt` remain known gaps, as does 2D
  `input.cursorWorldPosition`. `3280146735`: `parsed=2340` / `prepared=5601` /
  `first-frame=5786` ms; both composite frames fully nonzero (mean ~36–41).
  One SceneScript `lookAt` TypeError; effects `ui_editor_effect_refract_title`
  (empty default texture), workshop gaussian and cutout vignette failed to
  load and were logged, not treated as whole-scene failure. The probe does not
  pump now-playing, so media script smoke on this package is host-side only.
- `python3 scripts/build.py --configuration Release` — exit 0, `** BUILD
  SUCCEEDED **`. Delivered binary
  `build/Build/Products/Release/MacWallpaperEngine.app` (Mach-O mtime 2026-09-20
  01:40). The app was not launched.
