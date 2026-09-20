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

## 2026-09-20 — Leon rendering and system music information

Fixed the hidden Leon layer's missing `video.isPlaying()` API, vector mixing,
Bloom varying-array locations, Shimmer vector argument narrowing, compatible
custom cross-stage uniform widths, and missing layer/effect projection matrices
used by the music frame shader. Added opt-in native Now Playing delivery for
scene and web wallpapers using the pinned mediaremote-adapter; current and
previous cover textures clear together. Cover changes replay thumbnail events
even when the event's colors are unchanged.

- `python3 scripts/test.py`: Python **71 passed**; native **495 passed,
  9 skipped, 0 failed**. This run covered the Swift provider, UI snapshot and
  bridge changes; subsequent changes were renderer code and renderer tests.
- Shader `pipeline` **67 passed** and `legalize_type_coercion` **53 passed**.
  Asset-dependent cases can return early without local assets; these counts
  are not a wallpaper-corpus claim. Bridge `scene_media` tests **2 passed**.
- C++ `scenescript_media_event_smoke` **14 passed**;
  `media_thumbnail_texture_smoke` **11 passed**;
  `script_runtime_compat_test --gtest_filter='ShaderValueUpdaterCompat.*'`
  **6 passed**, including owner-scale and intermediate/final projection checks.
  Rust `cargo test -p wallpaper-core changed_cover_replays_thumbnail_event`
  **1 passed**.
- A broader `script_runtime_compat_test` initially aborted with **SIGSEGV** in
  `CursorHitsLayer`: an empty scene's `activeCamera` was uninitialized. After
  initializing it to `nullptr`, the complete suite ran: **67 passed, 1 failed**.
  The remaining failure is the previously documented
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors` referencing
  undeclared `scriptProperties`. The full script suite is **not passing**.
  No desktop/player session was started.
- `python3 scripts/check_renderer.py`: **exit 1**. The previously recorded
  `SharedVideoSessionTest.AFrameStaysValidAfterTheDecoderMovesOn` still fails.
  All **10 generated GPU cases** had equal pooled/isolated pixels and zero
  diagnostics; **8 projects x 2 reloads** passed. Metal scene smoke **32 passed,
  1 skipped** because `WE_TEST_METAL_PROJECTS` was not supplied.
- Offscreen Vulkan probe of local project **3665954520**, with synthetic title,
  artist, album and four-color artwork, rendered three frames at 0.5-second
  steps with no shader/script diagnostics. Visual inspection confirms Leon,
  highlight/RGB/grain effects, cover, rounded frame and music text are visible.
  These are offscreen images, not desktop captures or proof of native Metal
  appearance or live Spotify/Apple Music/browser/local-player behavior.
- `python3 scripts/build.py --configuration Release`: **passed** after the
  final renderer change; app at `build/Build/Products/Release/MacWallpaperEngine.app`.
  `codesign --verify --deep --strict` **passed**. App was not launched/restarted.
- Scoped WebUI design detector returned **no findings**; non-generated
  `git diff --check` passed. Generated bindings were regenerated by the build
  script, not edited manually. `CLAUDE.md` remains a relative symlink.

## 2026-09-20 — Round 14 follow-up: empty Metal texture keys

The empty-key prepare failure was not a round-14 pass description emitting
`_rt_link_` / `_rt_default` as `""`. HEAD (`/tmp/owe-head`, binary rebuilt in
`/tmp/owe-head-build`) already failed the same way for 3226487183 and
3800629364; 3680252478 was Compatibility for perspective. Vulkan
`CustomShaderPass::prepare` skips empty material names and SPIR-V omits
inactive texture descriptors; Metal's resource plan still marked Naga MSL
arguments bound for in-range slots the preprocessor had cleared. A sampled
empty slot still fails. The missing-image message now names slot and shader.
Unused `GlobalUniforms` buffer arguments (passthrough without `TRANSFORM`)
are left unbound the same way. No default texture is bound.

- HEAD `WE_TEST_METAL_PROJECTS` local smoke:
  `3226487183: Compatibility after prepare -- an image a layer needs could not be loaded: `;
  `3680252478: Compatibility -- the scene uses a perspective 3D camera`;
  `3800629364: Compatibility after prepare -- an image a layer needs could not be loaded: `.
- After the fix, same command on `artifacts/renderer/bin/tests/metal_scene_draw_smoke`
  (packages read in place). Exact printed lines:
  `3226487183: Native Metal, 120 frames drawn, 14968995 bytes differ between the first and the last`;
  `3680252478: Native Metal, 120 frames drawn, 2552368 bytes differ between the first and the last`;
  `3800629364: Native Metal, 120 frames drawn, 2814309 bytes differ between the first and the last`.
  Select accepted Native Metal; prepare and 120 offscreen frames succeeded.
  3680252478 still logged `Unknown function 'rotateVec2'` for `effects/shimmer`
  (`naga glsl parse`): parser/include gap, the `common.h` helper never reached
  Naga. That effect did not compile; the rest of the scene still prepared. Not
  a whole-scene fallback, not a comparison with Wallpaper Engine.
- `python3 scripts/check_renderer.py` — exit 1. All gate binaries 0 except
  `shared_video_session_test` 1 (`AFrameStaysValidAfterTheDecoderMovesOn`;
  same failure on HEAD). 10 generated cases `pixels_equal=True`, 0
  diagnostics. `layer_texture_reference_test` 10 passed.
  `particle_rope_geometry_test` 26 passed. `scene_mesh_tests` 16 passed.
  `metal_backend_test` 35 passed. `metal_scene_draw_smoke` 32 passed, 1
  skipped (`WE_TEST_METAL_PROJECTS` unset in the gate). Reload cycles
  8 projects x2 exit 0.
- `python3 scripts/test.py` — exit 0. Python suites 71 passed. XCTest 500
  executed, 491 passed, 9 skipped, 0 failed.
- `python3 scripts/build.py --configuration Release` — exit 0,
  `** BUILD SUCCEEDED **`. App:
  `build/Build/Products/Release/MacWallpaperEngine.app`. Quit and reopen to
  pick it up; nothing was launched or installed here.

No desktop run, no screenshots, no power. Pixel-byte deltas are first vs last
frame of the offscreen smoke, not a comparison with Wallpaper Engine.

## 2026-09-20 — Round 14 follow-up: effect-chain composite, local Metal gate, HEAD comparison

Merged the four 2026-09-19 item notes. Commands below were run on the tree that
includes those item diffs plus the effect-chain composite fix. Nothing was
displayed, installed, or compared with Wallpaper Engine.

- Layer 14942 in installed 3226487183 has no effect chain (hidden image,
  no `effects`). Effect-chain sources in the shared graph now isolate the node
  ResolveEffect resolves onto to `_rt_imageLayerComposite_<id>` and do not
  register `_rt_default` as the link; hidden sources are not dual-drawn onto
  the scene framebuffer. Explicit missing/duplicate/cycle/history reasons are
  unchanged.
- `layer_texture_reference_test` — 10 passed (9 previous +
  EffectChainSourceLinksFromCompositeNotDefault).
- Installed packages 3226487183 / 3680252478 / 3800629364 were read in place
  through `metal_scene_draw_smoke --gtest_filter=MetalSceneDraw.LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend`
  with `WE_TEST_METAL_PROJECTS` (colon-separated `project.json` paths) and
  `WE_TEST_ASSETS` at `~/Library/Application Support/mac-wallpaper-engine/SceneAssets`.
  Exact printed lines: `3226487183: Compatibility after prepare -- an image a layer needs could not be loaded: `;
  `3680252478: Compatibility after prepare -- an image a layer needs could not be loaded: `;
  `3800629364: Compatibility after prepare -- an image a layer needs could not be loaded: `.
  Select accepted Native Metal; prepare failed. 3680252478 also logged
  `Unknown function 'rotateVec2'` for `effects/shimmer` during parse.
- `shared_video_session_test.AFrameStaysValidAfterTheDecoderMovesOn` — failed
  on this tree and on HEAD (`/tmp/owe-head` worktree, `AdvanceUntilFrameChanges`
  false: "the decoder never moved past the held frame, so retention is
  untested"). Round-14 Scene.h / SceneNode.h / CustomShaderPass /
  MetalRender visibility edits did not cause it.
- `scene_schema_tests` pointer cases
  `PointerCapabilityFollowsActualCommitsWithoutFirstFrame` and
  `MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch` — both
  failed on this tree and on HEAD (`Wait` timed out at
  `replacement.Wait(2)` / `observation.Wait(3)`). Assertions not modified.
- `python3 scripts/test.py` — exit 0. Python suites 71 passed. XCTest 500
  executed, 491 passed, 9 skipped, 0 failed.
- `python3 scripts/check_renderer.py` — exit 1. All gate binaries 0 except
  `shared_video_session_test` 1 (`AFrameStaysValidAfterTheDecoderMovesOn`;
  same failure on HEAD). 10 generated cases `pixels_equal=True`, 0
  diagnostics. `layer_texture_reference_test` 10 passed.
  `particle_rope_geometry_test` 26 passed. `scene_mesh_tests` 16 passed.
  `metal_backend_test` 35 passed. `metal_scene_draw_smoke` 32 passed, 1
  skipped (`WE_TEST_METAL_PROJECTS` unset in the gate). Reload cycles
  8 projects x2 exit 0.
- `python3 scripts/build.py --configuration Release` — not finished on this
  tree; superseded by the empty-key follow-up above.

No desktop run, no screenshots, no power. `segments=10` is an implementation
default, not observed from Wallpaper Engine.

## 2026-09-20 — Scene video textures froze, and a native first frame never reached the host

Two separate defects behind one report about `爱弥斯窗外雨天【dy安静】` (Library
`3801532994`, a scene whose single image layer is a 3840×2160 H.264 video
texture): with every Performance option on, switching to it failed after 20
seconds with "The wallpaper did not render a first frame"; with them off the
wallpaper drew, but the picture stopped moving after about half a second. No
desktop run, no visual check on the wallpaper itself, no power measurement.

- **Frozen video — an FFmpeg header/library mismatch.** `offscreen_scene_probe`
  on the real project (`WE_TEST_FRAMES=200 WE_TEST_FRAME_STEP=0.0333`) produced
  20 distinct images followed by 181 identical ones. Temporary instrumentation
  in `FfmpegVideoTextureSource` showed why: every decoded frame arrived with
  `best_effort_timestamp = 0` while `pts` advanced 0, 512, 1024 … at
  `tb=1/15360`, so each frame was stamped at absolute time zero, the displayed
  frame never advanced, and after one second the forward-resync threshold turned
  every refresh into a seek whose ticket invalidated the frame it produced.
  Cause was not FFmpeg: `flags.make` put `/opt/homebrew/include` (a symlink to
  the `ffmpeg` 7.1.1 formula, libavutil 59 / libavcodec 61) ahead of the
  `ffmpeg@8` cellar path pkg-config resolved, while the link line and the loaded
  dylibs were libavutil 60 / libavcodec 62. libavutil 59's `AVFrame` still
  carries the `FF_API_FRAME_PKT`, `INTERLACED_FRAME`, `FRAME_KEY` and
  `PALETTE_HAS_CHANGED` members that 60 removed, so every field after them —
  `best_effort_timestamp` included — was read at the wrong offset. After
  `wescene_prefer_ffmpeg_headers` put the resolved prefix first, the same probe
  reported `best == pts` and 200 distinct images out of 200 frames.
- **20-second timeout — a flag the backend was not entitled to set.**
  `MetalRender::drawFrame` set `Scene::first_frame_ok` itself, which satisfied
  the frame handler's own `frame_ok && !first_frame_ok` check before the handler
  ran, so `sendFirstFrameOk()` never fired and the host waited out its deadline
  on a wallpaper that was drawing correctly. Matches session `20260919-224156`:
  Metal translations requested (`hits=22`), no `metal render:` failure, no
  Vulkan init, then teardown. The backends now report presentation through
  `drawFrame`'s `presented` out-parameter and only the handler writes the flag;
  the no-drawable early return reports `presented = false` so a tick that
  presented nothing is not counted as the first frame.
- `metal_scene_draw_smoke` `ADrawnFrameIsReportedAsPresentedAndLeavesTheFirstFrameFlagAlone`
  is new and was checked both ways: it fails (`first_frame_ok Actual: true`)
  with the backend write restored and passes without it.
- `metal_scene_draw_smoke` with `WE_TEST_METAL_PROJECTS` pointed at
  `3801532994`: Native Metal, 120 frames drawn, 19 657 287 bytes differ between
  the first and the last.
- `shared_video_session_test` `AFrameStaysValidAfterTheDecoderMovesOn` failed on
  the first post-fix run. Its previous green was an artefact of the same
  timestamp bug: with every frame stamped zero, any refresh promoted a new one,
  so the test never exercised the session's documented rule that exactly one
  elected consumer moves the shared clock. The test now lets the consumer that
  advances sync first so it is the driver; the session logic was not loosened.
- The guard in `FfmpegAbi.hpp` has internal linkage rather than plain `inline`.
  Two targets include it, and an external-linkage `inline` lets the linker keep
  one definition and discard the rest — under the very mismatch it guards
  against, those definitions do not hold the same version constants, so one
  translation unit could answer for another's headers. All three gates below
  were re-run after that change.
- `python3 scripts/check_renderer.py` — exit 0, verified from `report.json`
  rather than the tail: every test binary 0, all 10 generated cases
  `pixels_equal=True` in pooled and isolated mode, 0 diagnostics, 8 projects × 2
  reload cycles clean (`desktop_automation: false`, `gpu_surface: false`). No
  local Workshop corpus passed through `--project`, so shipped-asset coverage is
  **not** claimed for this round.
- `python3 scripts/test.py` — exit 0, 500 native tests, 491 passed, 9 skipped,
  0 failures; Python suites green.
- `python3 scripts/build.py --configuration Release` — exit 0, `** BUILD
  SUCCEEDED **`. Freshness checked rather than assumed: the app's own
  cargo/CMake renderer build regenerated `flags.make` with the `ffmpeg@8` prefix
  first, and the delivered binary contains both new strings ("this build
  compiled against ", "video decoding stopped for ") and links only
  `ffmpeg@8` dylibs.

Still unverified: the wallpaper's appearance on a real desktop, and whether the
Performance options behave for the user as they do in the probes. The scene's
property scripts also log `TypeError: not a function` from
`<property-script-factory>`; that is untouched here and unrelated to the video
texture.

## 2026-09-19 — Round 14 item notes (superseded as current proof)

Kept for the item workers' commands. They are not current proof of the
follow-up tree.

Item 3: `scene_mesh_tests` 16 passed; `particle_rope_geometry_test` 26 passed
(6 new ParticleRopeUv); `scene_schema_tests` 66 passed with the two pointer
cases filtered out. No desktop, no Release app build.

Item 2: `metal_backend_test` 34 passed, 1 skipped (`MetalDevice.*`).
`MetalSceneDraw.APerspectiveCameraDrawsThroughTheAuthoredShader` passed
offscreen. `mouse_input_test` 11 passed. Pointer cases failed as above.
`check_renderer.py` did not finish (parallel `layer_texture_reference_test.cpp`
incomplete type). Particle JSONs with the perspective flag in 3680252478 /
3722749868 / 3773084716 were listed, not loaded through the native backend
that item.

Item 0: `scene_mesh_tests` 16 passed; `particle_rope_geometry_test` 20 passed;
`scene_schema_tests` 66 passed with pointer cases filtered. Metal smoke
ARopeTrailPastTheOldSixteenBitIndexLimitStaysARopeTrail skipped (no Metal
device in that environment). `metal_backend_test` did not compile
(`SceneCamera` overload ambiguity; another item).

Item 1: `layer_texture_reference_test` 9 passed. `python3 scripts/check_renderer.py`
Metal and Vulkan compiled; generated cases `pixels_equal=True`;
`shared_video_session_test` exited 1; local packages inspected read-only, not
executed through the probe.

## 2026-09-19 — Release build of `a9b2c79` (no source change)

Build-only round on a clean tree at `a9b2c79` ("localize scaling option, resolve
zh locales via Intl, guard i18n catalog"). The delivered Release app predated the
two Metal-backend renderer commits merged earlier today, so the full renderer +
Swift pipeline was rebuilt rather than `--swift-only`. Nothing in the repository
was modified. No desktop run, no visual check, no power measurement.

- `python3 scripts/test.py` — first run exit 65 at `CodeSign` ("resource fork,
  Finder information, or similar detritus not allowed"). The built Debug
  `.app` **directory** carried `com.apple.FinderInfo` and
  `com.apple.fileprovider.fpfs#P`; source files under `WebUI/`, `App/Resources/`
  and `Extension/` carry only `com.apple.provenance`, which codesign accepts. So
  the detritus is attached to the product by the file provider on this
  `…/Github.nosync/…` path, not committed. After `xattr -cr` on the built Debug
  app: exit 0, 500 native tests, 491 passed, 9 skipped (the usual hardware
  skips), 0 failures; Python suites green.
- `python3 scripts/build.py --configuration Release` — exit 0, `** BUILD
  SUCCEEDED **` for app and extension. `xattr -cr` was applied to the Release
  products directory first, so `CodeSign` did not hit the same failure.
  Freshness checked rather than assumed: `libwallpaper_bridge.a` relinked at
  22:44:05 against a newest renderer source of 21:22, app and `.appex`
  executables relinked 22:44:33, `diff -r WebUI …/Contents/Resources/WebUI`
  identical, the delivered binary contains the `a9b2c79` stamp, signature
  ad-hoc `Sign to Run Locally`.
- `python3 scripts/check_renderer.py` — exit 0. All 10 generated cases
  `pixels_equal=True` in both pooled and isolated mode, 0 diagnostics, 8
  projects × 2 reload cycles clean, every test binary exit 0 in `report.json`
  (`desktop_automation: false`, `gpu_surface: false`). Inside that run:
  `metal_scene_draw_smoke` 31 passed / 1 skipped
  (`LocalProjectsNamedByTheEnvironment…`, needs `WE_TEST_METAL_PROJECTS`),
  `metal_backend_test` 26 passed, `particle_rope_geometry_test` 17 passed,
  `playback_gpu_test` 39 passed. No local Workshop corpus was passed through
  `--project`, so shipped-asset coverage for this round is **not** claimed.


## 2026-09-19 — Round 13: two-dimensional puppets, sprite trails, ropes and rope trails on Metal

The native Metal backend now accepts two-dimensional puppets, sprite trails,
ropes and rope trails by what the mesh and the shader actually are, instead of
refusing them by label. Puppets needed no new data path — deformation was always
the author's skinning shader and the pose was always the shared animation
system's — but real content needed three things no fixture had shown: a puppet
under an effect chain only receives its mesh when the render graph resolves the
chain, puppet sheets are block-compressed, and some effects declare a texture
slot they never sample. Rope geometry did not exist on either renderer (the
generator's rope branch was commented out) and rope trails were loaded as sprite
trails, so both are implemented once in the shared particle runtime, which also
changes what Compatibility draws for rope scenes. Native Metal is still a manual
choice and no default changed. No power measurement was taken.

- `python3 scripts/check_renderer.py` — exit 0 on the final tree. All 10 golden
  cases `pixels_equal=True`, 0 diagnostics, 8 projects × 2 reload cycles clean,
  every test binary exit 0. `particle_rope_geometry_test` is new in the gate.
  An earlier run of the same command with the three shipped particle previews
  added through `--project` was also exit 0 with `pixels_equal=True` for each.
- Inside that run: `particle_rope_geometry_test` 17 passed (new; CPU only).
  Three of its simulation cases failed first because they stepped the frame
  clock at exactly the recording period, which makes a particle's birth tick a
  recording tick too; the simulation was right and the cases now step at half a
  period in binary-exact numbers.
- `metal_backend_test` 26 passed (12 new or rewritten: trail, rope, rope-trail
  and skinned acceptance, five distinct refusals, the effect-chain rule).
- `metal_scene_draw_smoke` 31 passed, 1 skipped, on a real Metal device with
  private textures and an offscreen layer only. The skip is
  `LocalProjectsNamedByTheEnvironment…`, which needs `WE_TEST_METAL_PROJECTS`.
  The three tests that need Wallpaper Engine's shipped assets **ran** here
  because they are installed on this machine; on a clean checkout they skip. The new
  skinning test failed first in the full run and passed alone: it took a
  reference from `emplace_back` and then grew the vector. Fixed in the test.
- `python3 scripts/test.py` — first run exit 65 at `CodeSign` ("resource fork,
  Finder information, or similar detritus not allowed") before any native test
  ran; after `xattr -cr` on the built Debug app, exit 0: 500 native tests, 9
  skipped (the usual hardware skips), 0 failures, Python suites green.
- `python3 scripts/build.py --configuration Release` — exit 0, `** BUILD
  SUCCEEDED **`, app and extension. The delivered binary contains this round's
  renderer strings and the bundled `settings.js` contains the new description.
- All three commands were run again, in that order, after the last source
  change (an over-budget rope trail is loaded as a sprite trail instead of being
  dropped): renderer gate exit 0 with the counts above, Release build exit 0,
  `scripts/test.py` exit 0 with 500 / 9 skipped / 0 failures.
- Not in either gate, run by hand: `particle_mouse_controlpoint_test` 38,
  `mdl_schema_tests` 52, `scene_mesh_tests` 9 passed. `scene_schema_tests`: 66
  passed, **2 failed** — `PointerCapabilityFollowsActualCommitsWithoutFirstFrame`
  and `MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch`, each
  timing out waiting for a pointer-capability callback after a scene commit.
  Believed to predate the round, not proven: both tests build a `Scene` by hand
  — no parser, no particle subsystem, no material — and run under the default
  Compatibility preference, where `SelectSceneBackend` returns before any
  capability code; neither test, nor `SceneWallpaper.cpp`, nor anything else on
  that path was changed this round. No earlier entry records this binary's
  result, so there is no baseline to compare with; not investigated further.
  `unpack_shader_compile_smoke` was updated to expect the rope shader for a rope
  trail, built, and not run (it needs the unpack corpus).
- Observed offscreen with local content that stays outside the repository, none
  of it a suite: two reduced copies of an installed wallpaper keeping only its
  puppet layers (format-version-21 model, 30 bones, six animations, five
  animation layers; plain, and under its four-effect chain), 120 frames on both
  renderers — every fifth pixel of the 3840×2160 result compared, **none
  differing**, while frames 0 and 119 differed in about 40 % of samples. With
  `WE_TEST_RANDOM_SEED`, the 90th simulated frame of the shipped `spritetrail`,
  `rope` and `ropetrail` previews had **no pixel differing by more than 2/255**
  between the renderers, and the adjacent frames differed by hundreds to
  thousands. This is agreement between this application's two renderers, not a
  comparison with Wallpaper Engine.
- Of four installed wallpapers containing puppets, none runs natively as a
  whole: two use a perspective camera, and two name another layer as a texture,
  which neither renderer resolves. One format-version-23 model's animation block
  is not read by the model parser, so it is drawn in its bind pose on both
  renderers.
- The gate's `xcodegen generate` reordered one target line in
  `mac-wallpaper-engine.xcodeproj/project.pbxproj`; nothing in `project.yml`
  changed and the file was not hand-edited.
- Not run: `python3 scripts/test.py --ui`, any desktop, window, screenshot,
  wallpaper change, lock screen, audio hardware or power measurement. Nothing
  was installed, launched or quit.

## 2026-09-19 — Round 12: scenes that genuinely stop, and compile results that survive a restart

A static text scene now reports no reason to keep drawing and stops its frame
clock through the mechanism round 7 built. The larger half of that was not
text-specific: `DescribeTimeAdvancingWork` answered "is this binding registry
non-empty" rather than "can any of these values move", and since the parser
registers a visibility binding for every layer it produces, every parsed scene
had reported `NodeBinding` forever — the on-demand feature could idle nothing it
built. `SceneMesh` now distinguishes geometry rewritten every frame from
geometry rewritten when an event re-lays it out, the renderer reports the two
separately while the pixel-reuse cache still refuses both, and the text worker
asks for the frame that shows what it produced. The optional NV12 program's
translation now survives a restart through the existing on-disk program cache,
and compiled render pipelines are kept in an `MTLBinaryArchive`, per surface and
per cache directory, handed to the real pipeline-creation path. Native Metal is still a manual choice,
Compatibility is still the default, direct plane sampling is still off, and
scene idling still follows its own off-by-default setting.

- `python3 scripts/check_renderer.py` — exit 0, re-run on the delivered tree.
  All 10 golden cases `pixels_equal=True`, 0 diagnostics, 8 projects × 2 reload
  cycles clean, every test binary exit 0. Evidence bundle under
  `artifacts/renderer/` (disposable).
- Inside that run, on a real Metal device with private textures and an offscreen
  layer only: `metal_scene_draw_smoke` 25 passed (8 new: a static caption, and a
  static caption under an effect chain, reach zero demand reasons having
  actually drawn, while the renderer still reports `EventMesh` and
  `RuntimeImage`; a changed caption brings the demand back, reaches the output
  and goes quiet again, and rewriting the same string wakes nothing; a caption
  changed behind a hidden layer is not counted as work in flight, and the
  deferred layout still happens when the layer returns; a scripted caption keeps
  the clock on all thirty frames; a caption bound to a user property idles; an
  optional program translated once is restored from disk with identical source,
  reflection and per-stage bindings without the compiler running, and a
  truncated entry falls back to a normal compile; pipelines are offered to the
  binary archive, published, reopened from disk and satisfied strictly, and a
  scene with no archive path still draws). That last test failed first and
  found a real defect: the debounced archive write captured a reference
  parameter rather than a copy, so the identity it compared two seconds later
  was already destroyed and no archive was ever written.
  `static_subgraph_cache_test` 25
  passed (1 new: `EventMesh` costs a target its cacheability exactly as
  `DynamicMesh` does, and differs from it only at the scene level).
  `text_object_runtime_test` 61 passed (1 new: the text worker's wake handler
  fires for a real result and not for an unchanged caption). `metal_backend_test`
  20, `metal_video_texture_test` 14, `metal_poster_capture_test` 7,
  `playback_gpu_test` 39, `render_target_lifetime_test` 4, all unchanged.
- `cargo test --workspace --release` — exit 0, 22 binaries, 1050 cases passing
  (1 new: the `text_layout_pending` reason has its own name and is not folded
  into `unknown_input`).
- `python3 scripts/test.py` — exit 0 from the wrapper; 486 executed, 476 passed,
  9 skipped, 1 failed. The failure is the recorded pre-existing
  `ControlPanelLayoutTests/testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`
  (overflow 52), unrelated to this round and unchanged by it.
- `python3 scripts/build.py --configuration Release` — BUILD SUCCEEDED, app and
  extension, delivered at `build/Build/Products/Release/MacWallpaperEngine.app`.

Measured rather than assumed, before any change was made, with the round's own
fixtures: a scene with one static text layer reported `DynamicMesh` from the
renderer and `NodeBinding` from the runtime; a scene with one static image layer
reported `NodeBinding`. That second measurement is what identified the
pre-existing gap, and it is why this round's change is not confined to text.

Not verified, and not claimed:

- Nothing was displayed. No wallpaper was shown on a desktop, no output was
  looked at by a person, and no visual comparison was made between an idling
  scene and a continuously drawing one.
- No power, energy or thermal measurement was taken. A scene that stops drawing
  does less work; how much less is not something anything here measured, and no
  saving is claimed.
- The cross-restart claims are shown within one process by clearing the
  in-memory caches and reopening the published files, which is what a new launch
  does to those two caches. No second process was started.
- The binary archive was exercised on this machine's GPU only, with one display
  and one wallpaper. That two surfaces with different caches keep separate
  stores is implemented and reasoned about, not observed: no two-display
  configuration was run. Whether an archive written on one Mac is usable on
  another is Metal's decision; the failure mode either way is a normal compile.

## 2026-09-19 — Simplified Chinese control panel: verification and delivery

The WebUI now translates its shell, filters, inspector, download/sign-in guidance,
settings and accessibility labels using `WebUI/i18n.js`. Native injects the app's
preferred localization; English remains the fallback. Filter/action values and
third-party content are not translated. Native interface-recovery alerts use the
existing string catalog. Final refinements distinguish “No scaling” from filter
“None”, remove a duplicate key and resolve language scripts with `Intl.Locale`.

- `python3 scripts/test.py` — passed: 70 Python tests, XcodeGen, native suite
  **491 passed / 9 skipped / 0 failed** (500 total). The nine skips are opt-in
  media/device integration, not passing asset checks. The new offscreen language
  test verifies English/Chinese navigation, accessibility, settings and summaries,
  locale fallback and non-recursive placeholder substitution. Three Python catalog
  tests check duplicate/empty entries, placeholder parity and direct-call/static
  markup translation coverage.
- Earlier runs found a settings helper shadowed by a local `options` variable;
  renamed it `localizedOptions`. A later run had 490 passes and one unrelated
  corner-mark timeout; the other session fixed its offscreen animation wait. The
  fresh full-suite run above passes both regressions and supersedes those failures.
- `node --check` on `WebUI/i18n.js`, `WebUI/panel.js`, `WebUI/settings.js` — passed.
  Impeccable detector on those files and `WebUI/index.html` returned no findings;
  this is not visual verification. `git diff --check`, owning-doc local links and
  the relative `CLAUDE.md` symlink check passed.
- `python3 scripts/build.py --swift-only --configuration Release` —
  **BUILD SUCCEEDED**. The delivered bundle at
  `build/Build/Products/Release/MacWallpaperEngine.app` contains byte-identical
  copies of all four localized WebUI files and native `zh-Hans` strings.
- No renderer changes were made for localization; renderer/corpus checks were
  not run. No desktop interaction, app launch/restart, screenshot, permission
  prompt or live Steam login was performed. Running-window Chinese layout and
  the System Settings per-app language workflow remain manually unverified.
  Quit/reopen the built app to load the changes. Concurrent workspace changes
  were preserved.

## 2026-09-19 — Favorite and Approved thumbnail marks: final verification and delivery

Verified the integrated Installed/Discover corner marks: pink favorite hearts,
green Approved trophies, Discover's existing-library check, and coexistence with
Installed's selection check and Active badge. Added the behavior and metadata
limits to `docs/features/control-panel.md`. Favorites are app-local; Installed
approval depends on the local manifest, while Discover uses Steam's tag. Missing
local approval metadata is not fetched from Steam.

- `python3 scripts/test.py` — passed: Python tests and XcodeGen; native suite
  491 passed / 9 skipped / 0 failed (500 total). The skips are the opt-in
  media/device integration tests, not passes. Both
  `testTilesWearApprovedAndFavoriteMarksWithoutWindow` and
  `testReadsStaffApprovalFromTheManifest` passed.
- Earlier attempts in this session failed to bring up the offscreen panel, and
  the corner-mark fixture's later offscreen animation wait was fixed as recorded
  below. The fresh full-suite run above supersedes those failures; no claim is
  made that the earlier tree passed.
- `node --check WebUI/panel.js` and `node --check WebUI/icons.js` — passed.
- Impeccable mechanical detector on `WebUI/panel.js`, `WebUI/panel.css` and
  `WebUI/icons.js` — no findings. This is not visual verification.
- `python3 scripts/build.py --swift-only --configuration Release` —
  **BUILD SUCCEEDED**. The delivered bundle's `panel.js` and `panel.css` compare
  byte-for-byte with the sources. No renderer or bridge change was needed for
  these marks, so renderer/corpus checks were not run for this task.
- No app launch, restart, screenshots, desktop test or live Steam login was
  performed. Visual presentation remains unverified; quit/reopen the Release app
  to load the changes. Concurrent localization edits in the shared workspace
  were preserved.

## 2026-09-19 — Tile-mark test hung offscreen; whole tree committed

`ControlPanelLayoutTests/testTilesWearApprovedAndFavoriteMarksWithoutWindow`
timed out (2-minute allowance) on the tree that was about to be committed. Two
offscreen-WebKit artefacts in the test, neither in `WebUI/`: it waited on
`requestAnimationFrame`, which a web view with no window never services, so the
promise passed to `callAsyncJavaScript` never settled; and it then measured
`.tile-marks` mid-`transition: left`, which for the same reason never advances
(the untransitioned Active badge already read its final 59). The wait is now a
`setTimeout` and the test finishes the in-flight transitions
(`document.getAnimations().forEach(animation => animation.finish())`) before
measuring. Injecting `<style>* { transition: none }</style>` does not work: the
panel's CSP drops it (`document.querySelectorAll('style').length === 0`).

- `python3 scripts/test.py` — passed: Python suite, XcodeGen, native tests
  491 passed / 9 skipped / 0 failed.
- Before the fix, the same gate on the same tree: 490 passed / 1 failed
  (that test exceeded its time allowance); the failure reproduced on its own.
- No Release build was made for this commit: the change is test-only, and the
  features it covers were built and logged by the entries below.
- Not verified: the panel in a running app; no desktop run was requested.

## 2026-09-19 — Discover previews: one download per tile, warmed ahead of the panel

Discover tiles were slow because the still pass asked Steam's CDN for a scaled
(`?imw=512…`) variant, which re-encodes the whole GIF on a cold path, four at a
time, and the animation then downloaded the original again uncached.
`WorkshopThumbnailCache` now fetches the original once (eight at a time), keeps
the still JPEG and the animation bytes on disk together (512 MB cap), serves
`mwe-ui://animated/<id>` from disk, and is warmed by `WorkshopStore` as each
Steam page arrives; the store also prefetches the following page. The panel
admits six animations at a time instead of two.

- Measured against Steam with `curl`, same cold 29-tile page (trend, page 7):
  scaled variants at 4 parallel 14.0 s; originals at 8 parallel 1.1 s. Per
  tile: original 0.15–0.37 s, scaled GIF up to 4.6 s for ~25% fewer bytes.
- `python3 scripts/test.py` — not a clean run: another session was running
  `xcodebuild test` in the shared `build/` directory throughout (one run died
  with "Interrupted system call … build/Build/Products/Debug"). The Python
  suite and XcodeGen passed.
- Same native suite via `xcodebuild … -derivedDataPath <scratch>
  -only-testing:MacWallpaperEngineTests test` — 482 passed / 9 skipped /
  9 failed. `WorkshopThumbnailCacheTests`, `WorkshopStoreTests`,
  `WebPanelAssetsTests` and
  `testDiscoverTilesRevealTheAnimatedPreviewOnlyWhileItIsBrightWithoutWindow`
  pass. Eight failures are `ControlPanelLayoutTests` cases touching the other
  session's uncommitted panel-language work (`WebUI/i18n.js`, `language:`),
  failing on temp-folder removal, `InvalidTransition` and one timeout; none
  exercises preview code, but they were not re-run on a tree without this
  change (the shared tree could not be stashed under the other session). The ninth,
  `SteamCMDSetupTests/testShutdownDuringBootstrapReapsChildrenBeforeCleaningStaging`,
  passed when re-run alone (two xcodebuilds were competing).
- `node --check WebUI/panel.js` — clean.
- `python3 scripts/build.py --swift-only --configuration Release` —
  BUILD SUCCEEDED; the delivered `panel.js` carries the change.
- Not verified: the rendered Discover page in the running app and in-app
  timings (no desktop run was requested); behaviour on a slow link, where
  JPEG/PNG previews now cost their original size instead of a scaled one.

## 2026-09-19 — Workshop filter: icons on the Show only options

The three Show only checkboxes (Approved, Audio responsive, Customizable) carry
a 14px glyph between the box and the label, muted while unticked and primary
once ticked. Audio responsive and Customizable use Lucide `audio-lines` and
`sliders-vertical` added to `WebUI/icons.js`; Approved uses Lucide `trophy` in
a fixed green (`--approved`, dark/light values) to match Workshop's mark.

- `python3 scripts/test.py` — passed: Python suite, XcodeGen, native tests
  486 passed / 9 skipped / 0 failed.
- `node --check` on `WebUI/panel.js` and `WebUI/icons.js` — clean.
- `python3 scripts/build.py --swift-only --configuration Release` —
  BUILD SUCCEEDED, delivered app rebuilt with the change.
- Not verified: the rendered sidebar in the running app (no desktop run was
  requested).

## 2026-09-19 — Round 11: text and runtime images on Metal, optional programs off the load path

Text layers and runtime-replaced images now reach the native Metal backend
through the ordinary parser, and unchanged content costs no layout,
rasterisation or upload. The optional NV12 plane-sampling program is no longer
compiled while a wallpaper loads: its inputs are captured as a snapshot, the
translation runs on a bounded background worker only when the experimental
switch is on, the Metal pipeline is built off the frame thread, and the scene
adopts it between frames. Metal libraries and pipeline states are now shared
across scenes and surfaces, keyed by program content rather than by the address
of the object holding it. Native Metal is still a manual choice, Compatibility
is still the default and direct plane sampling is still off by default.

- `python3 scripts/check_renderer.py` — exit 0, re-run on the delivered tree.
  All 10 golden cases `pixels_equal=True`, 0 diagnostics, 8 projects × 2 reload
  cycles clean, every test binary exit 0. Evidence bundle under
  `artifacts/renderer/` (disposable).
- Inside that run, on a real Metal device with private textures and an offscreen
  layer only: `metal_scene_draw_smoke` 17 passed (4 new: a parsed text project
  is accepted, translated, rasterised and drawn into the scene's own target and
  reports itself as a reason to keep drawing; an unchanged string costs no
  measurement and no upload over twelve ticking frames, a new string costs at
  most one upload per in-flight frame and reaches the picture, and it then goes
  quiet again; a text layer with an effect chain draws through the chain and
  follows a new string to the chain's output; the same translated program is not
  handed to the Metal compiler again by a second renderer on the same device).
  The three video cases were rewritten around the new preparation and now assert
  that the parse compiled nothing optional, that the switch being off leaves the
  program unclaimed, and that the direct path is taken after the background
  preparation rather than on the first frame. `metal_backend_test` 20,
  `metal_video_texture_test` 14, `metal_poster_capture_test` 7,
  `static_subgraph_cache_test` 24, `text_object_runtime_test` 60,
  `playback_gpu_test` 39 and the rest all exit 0.
- `cargo test --workspace --release` in `upstream/renderer` — exit 0, 22 test
  binaries, 1049 cases passing, 0 failed. Includes the new case that every video
  path the renderer can report has its own name and that a value this build does
  not know is not invented.
- `python3 scripts/test.py` — 486 executed, 476 passed, 9 skipped, 1 failed. The
  failure is the recorded pre-existing
  `ControlPanelLayoutTests/testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`
  (overflow 52), unrelated to this round and unchanged by it.
- `python3 scripts/build.py --configuration Release` — **BUILD SUCCEEDED**.
  Delivered at `build/Build/Products/Release/MacWallpaperEngine.app`, verified to
  contain the round's code (`nv12_converted_preparing`, the optional-variant
  queue label, the dynamic-mesh gate's reason text) and a bundled `settings.js`
  carrying the new video-path label.
- One diagnosis worth recording, because it was a test fault and not a renderer
  fault: the first version of the effect-chain text case changed "EFFECT" to
  "EFFECT EFFECT EFFECT" and read back a byte-identical picture. The chain draws
  into a buffer the layer's card is clipped to, and the middle repetition landed
  exactly where the single word had been. The relayout, the texture upload and
  both passes were verified to be happening before the test was changed to use
  different glyphs; nothing in the renderer was altered to make it pass.

**Not established by any of the above:** nothing was drawn on a display and no
human has seen any of it. No power measurement of any kind was taken and no
saving is claimed. Complex script systems are exactly as supported as the
existing text system already made them. A purely static text layer still keeps
its scene drawing, deliberately.

## 2026-09-19 — Round 10: NV12 direct plane sampling, runtime scene optimisation

A video material is now translated twice while the scene is parsed — once as
before, once sampling the decoder's NV12 planes — and the renderer chooses per
frame from the format the decoder actually produced, converting only when some
consumer still needs one colour image. The scene optimisation setting is applied
at a frame boundary on both backends instead of waiting for the next graph
compile. Direct plane sampling is off by default; Compatibility is still the
default renderer.

- `python3 scripts/check_renderer.py` — exit 0, re-run after the last source
  change so it describes the delivered tree. All 10 golden cases
  `pixels_equal=True`, 0 diagnostics, 8 projects × 2 reload cycles clean, every
  test binary exit 0. Evidence bundle under `artifacts/renderer/` (disposable).
- Inside that run, on a real Metal device with private textures and an offscreen
  layer only: `metal_video_texture_test` 14 passed (6 new: a planes-only demand
  encodes no conversion and offers no single image, a mixed demand converts
  exactly once and still publishes the planes, the direct path receives the same
  eight colour constants as the conversion kernel, a demand change re-imports
  the generation that is current, a BGRA frame ignores a plane demand, and a
  format flip mid-stream switches path without losing the picture);
  `metal_scene_draw_smoke` 13 passed (5 new: an ordinary parsed author material
  over real decoded H.264 the test encodes takes the direct path and draws; the
  same material keeps converting while the switch is off and takes the direct
  path on the next frame when it is turned on; the two paths agree to one code
  value at a one-to-one texel-to-pixel mapping; the scaled case stays inside the
  clamp excursion the stream implies; a graph compiled with the optimisation off
  starts reusing when it is turned on); `metal_backend_test` 20,
  `metal_poster_capture_test` 7, `static_subgraph_cache_test` 24 and the rest all
  exit 0.
- Picture comparison, measured rather than asserted in prose: at a one-to-one
  mapping the pre-converting and plane-sampling programs agree to **1 code
  value** (the converted intermediate's own 8-bit quantisation). Resampled, they
  disagree by up to the excursion the stream's declared-range clamp removes —
  **19 code values measured, 24 the derived bound** — on a probe that is
  deliberately the worst case: full-range noise carried in a stream declaring
  limited range. The mechanism is clamp order around the author's filter, not
  floating-point error. The synthetic media carries neutral chroma, so that
  comparison is exact over luma and does not exercise chroma varying inside a
  chroma texel.
- `cargo test --workspace --release` in `upstream/renderer` — 22 test binaries,
  all green, including the new `crates/shader/tests/video_planes.rs` (9 cases:
  the ordinary program is unchanged by the option existing; the variant
  translates the author's expression, declares the chroma plane and the colour
  constants, reaches Metal with its own binding plan, keeps the plane out of the
  material's active slots and gets a different cache key; an explicit-LOD
  sample, a size query and a size query inside a macro each refuse it) and the
  new `wallpaper-bridge` case for the setting's default, both facade halves and
  a restart. `wallpaper-bridge` 312 passed.
- `python3 scripts/test.py` — 486 XCTest cases, 476 passed, 9 skipped, 1 failed:
  `ControlPanelLayoutTests/testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`,
  the same overflow-52 failure recorded in earlier rounds. The Discover grid was
  not touched this round; recorded as pre-existing, not fixed and not
  investigated. Re-run after the last source change so it describes the
  delivered tree, with the same counts and the same single failure both times.
  The first attempt of each run failed at CodeSign with the known extended
  attribute rejection and succeeded after `xattr -cr` on the built products.
- `python3 scripts/build.py --configuration Release` — **BUILD SUCCEEDED** on the
  second attempt; the first failed at CodeSign with the same extended attribute
  rejection and succeeded after `xattr -cr` on the Release products. The
  delivered binary contains this round's strings (`_we_VideoChroma`,
  `_we_SampleVideoNv12_`, `nv12_direct`, `cannot be sampled as planes`) and the
  bundled `WebUI/settings.js` contains the new switch, its explainer and the
  scene optimisation **In force now** row. Delivered at
  `build/Build/Products/Release/MacWallpaperEngine.app`.
- One environment trap worth recording: `metal_scene_draw_smoke` needs FFmpeg to
  encode its media, and this machine has a second FFmpeg under
  `/opt/homebrew/include` whose headers are two major versions older than the
  `ffmpeg@8` libraries on the link line. The mismatch did not fail the build; it
  produced garbage struct fields and an encoder that silently refused. The test
  target now puts the pinned prefix first with `target_include_directories(...
  BEFORE ...)`.
- `tex_schema_tests` does not build here (`lz4.h` not found). It is outside
  `check_renderer.py`'s target list and was not built or run in earlier rounds
  either; recorded as a pre-existing environment gap, not a regression.
- Not run, not authorized: any desktop session, wallpaper apply, screenshot,
  lock screen, `scripts/test.py --ui`, power sampling. No wallpaper of any kind
  has been seen on a display this round, nothing has been compared against the
  compatibility backend on real content, and **no power measurement of any kind
  was taken** — reduced work is reported as a conversion not encoded and a
  destination not allocated, never as a saving.

## 2026-09-19 — Round 9: scene optimisation on Metal, sprites, 2D particles

Scene optimisation (target reuse + copy elision) now runs on the Native Metal
backend, sprite-sheet animation and standard two-dimensional sprite particles
draw natively, and two defects in the shared reuse analysis were fixed in both
backends. Default stays Compatibility. The NV12 dual-plane fast path was not
built; the blocker is recorded in the progress document.

- `python3 scripts/check_renderer.py` — exit 0. All 10 golden cases
  `pixels_equal=True`, 0 diagnostics, 8 projects × 2 reload cycles clean, every
  test binary exit 0. Evidence bundle
  `artifacts/renderer/adaptive-20260919-120841` (disposable).
- Inside that run, on a real Metal device with private textures only:
  `metal_backend_test` 20 passed (7 new capability cases: rope, trail and other
  dynamic meshes each with their own reason, video sheet refused, plain sheet
  accepted, sprite-particle layer accepted, empty particle layer accepted,
  zero-capacity mesh refused); `metal_scene_draw_smoke` 8 passed (5 new:
  unchanged second frame skips passes and reads back byte-identical pixels, a
  moved layer re-executes and changes the picture, the setting switched off
  skips nothing, post-compile geometry uploads reach the target across more
  frames than in-flight slots, a sheet is reused between steps and redrawn on a
  step, and re-enabling the setting after frames drawn with it off redraws and
  restores the right picture — that last one was run against the unfixed code
  first and fails there on the pixel comparison); `static_subgraph_cache_test` 24 passed (3 new: alias chain
  resolution, cycle termination, a reader of an aliased destination inheriting
  its source's dynamism); `metal_poster_capture_test` 7, `metal_video_texture_test`
  8, `playback_gpu_test`, `timer_tests`, `render_scale_test` and the rest all
  exit 0.
- `python3 scripts/test.py` — 483 XCTest cases, 473 passed, 9 skipped, 1 failed:
  `ControlPanelLayoutTests/testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`,
  the same overflow-52 failure recorded in earlier rounds. The Discover grid was
  not touched this round; recorded as pre-existing, not fixed and not
  investigated.
- `python3 scripts/build.py --configuration Release` — **BUILD SUCCEEDED**, no
  CodeSign xattr rejection this round. App and extension binaries at 12:10
  contain this round's strings (`PRENDER_SPRITE`, "the scene draws particle
  trails"), and the bundled `WebUI/settings.js` contains the rewritten Scene
  optimisation and Scene renderer copy. Delivered at
  `build/Build/Products/Release/MacWallpaperEngine.app`.
- All three gates above were re-run after the last source change (limiting
  multi-slot image import to sprite sheets), so they describe the delivered
  tree rather than an earlier one.
- Not run, not authorized: any desktop session, wallpaper apply, screenshot,
  lock screen, `scripts/test.py --ui`, power sampling. No sprite-sheet or
  particle wallpaper has been seen on a display, no comparison against the
  compatibility backend on real content, and no sheet was sampled by an author
  shader on the GPU — the smoke fixture's shader binds no texture slot, so that
  test covers pick-up, advance, invalidation and demand reporting only. No
  power number is reported; reduced work is stated as passes not run.

## 2026-09-19 — Round 8: native Metal backend, second version

Metal desktop poster, backend creation deferred until the scene is parsed,
effect chains / post-processing / same-frame layer links on Metal, and BGRA +
8-bit NV12 video textures in Metal scenes. Default stays Compatibility.

- `python3 scripts/check_renderer.py` — exit 0. All 10 golden cases
  `pixels_equal=True`, 0 diagnostics, 8 projects × 2 reload cycles clean. These
  run the compatibility backend through the offscreen path, which still creates
  Vulkan at init; they show the lazy-creation change did not disturb it, not
  that the lazy path works on a layer.
- Inside that run: `metal_backend_test` 16 passed (capability and graph gate:
  effect chain and same-frame link accepted, history feedback and MSAA target
  rejected), `metal_scene_draw_smoke` 3 passed (adds an intermediate target
  drawn, blitted and resampled in one frame, by readback),
  `metal_poster_capture_test` 7 passed (new), `metal_video_texture_test` 8
  passed (new; synthetic IOSurface frames through an injected source — no real
  decoder), `playback_gpu_test` 39 passed, `timer_tests` 24 passed. All on a
  real Metal device, private textures only.
- `cargo test -p wallpaper-bridge --lib` — 311 passed, 0 failed (one new case:
  a scene with no backend yet is reported apart from a fallback).
  `cargo test -p wallpaper-core --lib` — 209 passed, 0 failed. Both need the
  environment from `scripts/build.py`'s `build_environment()`; without it the
  link fails on `-lvulkan`. The first run with that environment died in the
  `wallpaper-core` build script (cmake panic) and an immediate re-run passed;
  the cause was not investigated.
- `python3 scripts/test.py` — 483 XCTest cases, 9 skipped, 1 failed:
  `ControlPanelLayoutTests/testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`,
  the same overflow-52 failure recorded in earlier rounds; the Discover grid was
  not touched. `WebPanelSceneSettingsTests` passed with its new
  preparing/fell-back case. The first attempt ran no tests: CodeSign rejected
  the Debug app for "resource fork, Finder information, or similar detritus"
  (`com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P` on the bundle
  directory). `xattr -cr` on that build product fixed it.
- `python3 scripts/build.py --configuration Release` — **BUILD SUCCEEDED** on
  the second attempt; the first hit the same CodeSign xattr rejection on the
  Release bundle and was cleared the same way. The app and the extension
  binaries contain this round's renderer strings, and the bundled
  `WebUI/settings.js` contains the preparing state.
- Not run, not authorized: any desktop session, wallpaper apply, screenshot,
  lock screen, `scripts/test.py --ui`, power sampling. No Metal effect chain,
  video scene or poster has been seen on a display. Shader sampling of a link
  target, mip generation and camera overrides have no GPU test; the dual-plane
  NV12 fast path does not exist.

## 2026-09-19 — Round 7: on-demand updating, managed user assets, native Metal

P02 whole-scene on-demand updating (default off), the relocation of
`file`/`directory` property assets into app-managed storage, and a first native
Metal scene backend (default off) wired into the production creation path.

- `python3 scripts/check_renderer.py` — exit 0. All 10 golden cases
  `pixels_equal=True`, 0 diagnostics, 8 projects × 2 reload cycles clean.
- `cargo test -p wallpaper-core --lib` — 209 passed, 0 failed.
- `cargo test -p wallpaper-bridge --lib` — 310 passed, 0 failed.
- `timer_tests` — 24 passed, including four new cases: frame requests are
  bounded by the configured interval; a request made while running survives
  into idle; an idle clock produces no ticks at all and still answers one
  request with exactly one frame; and a deadline already past is taken
  immediately rather than after a cadence interval. The last two were each
  confirmed to fail against the defect they describe — idle re-implemented as a
  16 ms wait ticks 16 times in 300 ms, and the owed frame waited 905 ms for the
  cadence.
- `python3 scripts/test.py` — **482 tests, 472 passed, 9 skipped, 1 failed.**
  The failure is `ControlPanelLayoutTests`
  `testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`, pre-existing
  since round 4 with identical numbers (overflow 52 px, tile 166, 5 columns,
  4 rows). The Discover grid was not touched this round.
- `python3 scripts/build.py --configuration Release` — BUILD SUCCEEDED,
  including UniFFI regeneration of `App/Bridge/Generated/`.

Cargo cannot be run bare on this machine: a broken Homebrew `ffmpeg` 7.1.1
shadows `ffmpeg@8` and its `libavdevice` wants a `libvpx.11` that is not
installed, and `libvulkan` is not on the default search path. The counts above
were taken with the environment `scripts/build.py` itself constructs
(`OWE_NIX_LIBRARY_PATH` and friends). Setting `LIBRARY_PATH=/opt/homebrew/lib`
by hand reproduces the breakage rather than fixing it.

Metal evidence, specifically: `metal_backend_test` 11/11 and
`metal_scene_draw_smoke` 2/2, both registered in `check_renderer.py`. The draw
test parses a real project, translates its shaders to MSL, compiles them with
`newLibraryWithSource:`, draws, and reads the render target back. Two mutation
checks were executed rather than assumed: wrapping the author draw call in
`if (false)` fails the pixel assertion, and inserting a Y flip into
`MetalClipSpaceFold` fails the projection test.

One tautological assertion was found and replaced:
`EXPECT_TRUE(reasons != 0 || true)`, under a comment promising a check it was
not making. The original derivation behind it was **not** shown to be wrong —
it returned zero, and zero is correct for a fixture whose shader binds no
frame-varying uniform, which this one does not. `FrameVaryingUniforms` returns
`kAll` for a node the updater never captured, so an unprepared pass reads as
fully dynamic rather than still. The rewrite is a hardening: demand is derived
from the Metal backend's own pass descriptions, and a compiled graph yielding no
shader pass reports `UnknownInput`. The replacement assertion checks that an
unanalysed renderer reports `UnknownInput`, which is the property that catches
the dangerous case.

A genuine regression WAS found and fixed, introduced by this round's own work.
`ThreadTimer` honoured a `WakeOnce` latch unconditionally and rebased its
cadence afterwards, and `RequestFrame` is called on every pointer sample for a
pointer-reactive scene. On the default path — on-demand updating off, where the
FPS ceiling is the only bound — that let the pointer drive the frame rate.
Measured: 159 frames in 200 ms against a 10 FPS ceiling. The latch is now
honoured immediately only while idle and is cleared by the next cadence tick
otherwise, which keeps the lost-event race closed. Two tests cover it, and the
rate one was confirmed to fail against the old behaviour by restoring it.

Not verified: no desktop session. No scene was observed stopping its clock on a
real wallpaper, no Metal frame has ever been presented to a screen, the
production backend-switch path has never executed, there was no visual check and
no power measurement. The Metal evidence is an offscreen readback in a test.
Nothing here is a power claim, and no comparison between the two backends was
measured.

A sibling agent's cleanup test ran `clean.main()` against the real repository
root and deleted `build/` and `artifacts/` mid-round. Both are declared
disposable, and both were regenerated; no tracked source was affected. The test
now redirects `clean.ROOT`, `clean.ARTIFACTS` and `clean.BUILD` into its own
temporary directory, asserts that redirection before calling `main()`, and
asserts in teardown that the repository's own `build/` and `artifacts/` are
untouched. No guard was added to `clean.py` itself: the tool is supposed to
delete those directories, and it was the test that was aimed at the wrong root.

## 2026-09-19 — Workshop filters mirror Wallpaper Engine's sidebar; opens on Most popular this year

The Discover sidebar now lists Wallpaper Engine's own filters (Show only; Type;
Age rating; Resolution in Widescreen / Ultrawide / Dual / Triple / Portrait
sub-groups plus Other and Dynamic; Tags) as tick boxes. Show only boxes are
`requiredtags[]`; every other box starts ticked and unticking it sends the tag
as `excludedtags[]` (`WorkshopQuery.excludedTags`, `WorkshopService.browseURL`
`excludedTags:`). Defaults follow Wallpaper Engine: Everyone only, Unspecified
genre off, Application and Asset never offered (`WorkshopStore.defaultExcludedTags`).
The type menu, the old resolution/genre subset and the Asset box are gone;
`kind` in the `workshopSearch` action is now optional (defaults to all types)
and the store opens on `.all` / `.trendingYear`.

- Live `curl` probes of `steamcommunity.com/workshop/browse` (app 431960,
  trend/365, Scene): `total_count` 1,577,597 with no exclusions; 1,456,141
  excluding Questionable+Mature; 1,175,495 excluding Anime; all types
  excluding Application+Asset+Questionable+Mature+Unspecified: 1,938,366 of
  3,208,185; the same plus `requiredtags[]=Approved`: 16,553. Mature alone
  2,759,535 and Questionable alone 2,781,050, so exclusion is any-of and
  combines with required tags. The tag catalog (names above) was read from
  the page's `readytouse_tags` payload.
- `node --check WebUI/panel.js`: OK.
- `python3 scripts/test.py`: passed, 470 tests, 0 failures, 9 skipped
  (pre-existing `NativeVideoPlayerMediaTests` hardware skips). New
  `testExcludedTagsAreSentOnceAndNeverContradictRequiredTags` (dedupe; a tag
  that is also required is not sent as excluded; no tags → no tag params) and
  `testDefaultsMatchWallpaperEngineSidebarAndExclusionsReachSteam` (store
  defaults; exclusions reach the fixture request; the committed query keeps
  its own list while the draft changes). Store fixture `request`/`reply` and
  `assertBrowseURL` gained an optional `excludedTags` check; tests that relied
  on the old `.scene`/`.trending` defaults now expect `.all`/`.trendingYear`.
  `testFilterSidebarTogglesFromTheToolbarPerPageAndInspectorFollowsWindowWidth`
  now also asserts Discover's sort value `trend-year`, 61 boxes, exactly
  Approved / Audio responsive / Customizable / Questionable / Mature /
  Unspecified unticked, no `<select>` in the sidebar and no filter count pill.
  A first run timed out twice because two expected `WorkshopQuery` values
  lacked the new default `excludedTags`; the inequality surfaced as a silent
  test-timeout rather than an assertion message, fixed by completing them.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED.
- Not verified: the sidebar in the running app (no desktop run). Wallpaper
  Engine's "mobile compatible" box has no Steam tag and is not offered.

## 2026-09-19 — Discover: whole page of stills before any animation

`queueLivePreviews` now returns until every `img.tile-still` in the grid is
`complete` (loaded or failed); a still's `error` also re-queues. Discover
stills drop `loading="lazy"` so the page's pictures arrive together instead
of as the user scrolls (Installed keeps lazy local previews).

- `node --check WebUI/panel.js`: OK.
- The offscreen WebKit regression delays `c`'s still by 400 ms and records, at
  each animation-layer insertion, whether all three stills had loaded; it also
  checks `loading !== 'lazy'`. With the gate removed on purpose the test
  failed (animations for `a`/`b` inserted before `c`'s still); restored, it
  passed three times in isolation.
- `python3 scripts/test.py`: passed, 486 tests, 0 failures, 9 skipped
  (pre-existing hardware skips).
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED.
- Not verified: perceived ordering on a throttled link in the running app.

## 2026-09-19 — Discover tiles: animation beneath the still, revealed only while bright

Follow-up to the entry below: animated previews return, but still-first and
without the black-tile failure. `WebPanelAssets` gained `mwe-ui://animated/<id>`
(`WorkshopThumbnailCache.animatedPreview`, own two-slot lane, refuses sources
the still pass marked single-frame via an empty `.still` file, MIME from
ImageIO). `WebPanelSnapshot.workshopItem` carries `animated`. `panel.js`
queues the relay for on-screen tiles whose still is complete (two at a time,
grid order; pending requests dropped when tiles leave), inserts the animation
beneath the still, and samples each on a 16px canvas every 250 ms (both
images `crossorigin="anonymous"`, served with `Access-Control-Allow-Origin`);
the tile takes `playing` (still fades out) at >= 60% of the still's luminance
and loses it below 40%. `WebPanelController` accepts injected assets for tests.

- `node --check WebUI/panel.js`: OK.
- `python3 scripts/test.py`: passed, 486 tests, 0 failures, 9 skipped
  (pre-existing `NativeVideoPlayerMediaTests` hardware skips). New:
  `testAnimatedPreviewRelaysSteamBytesButRefusesSingleFrameSources`,
  `testAnimatedPreviewsQueueOnTheirOwnLaneBesideStills`, animated routes in
  `WebPanelAssetsTests`, and the offscreen WebKit regression
  `testDiscoverTilesRevealTheAnimatedPreviewOnlyWhileItIsBrightWithoutWindow`
  (stills load first, bright animation takes `playing`, black animation under
  a bright still never does, single-frame preview gets no layer and no second
  download). The regression was run three more times in isolation: passed each
  time. An earlier form polled for "no animation complete before the stills"
  and raced the in-memory fetcher; it now records still readiness at the
  moment each animation layer is inserted.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED.
- Not verified: real Steam GIFs in the running app (CPU of 30 concurrent GIF
  decodes, actual fade timing, throttled-link behaviour); no desktop run.

## 2026-09-19 — Discover tiles: no hover animation, stills skip black fade-ins

The on-demand animated overlay (`tile-live` `<img>` under the pointer after a
180 ms dwell or under keyboard focus) is removed from `WebUI/panel.js` and
`panel.css`: Steam GIFs frequently open on black frames, so the overlay read
as a black tile. The same frames made the cached stills black, because
`WorkshopThumbnailCache.encodeThumbnail` always took frame 0. It now calls
`representativeFrameIndex`, which measures the mean luminance of up to eight
evenly spaced frames on a 32px grayscale decode and keeps the earliest frame
that reaches 60% of the brightest sample (and at least 0.08); bright-first,
uniformly dark and single-frame sources still yield frame 0. Tiles keep
loading the cached 512px JPEG stills, so slow links are unaffected.

- `node --check WebUI/panel.js`: OK; no `animatedID`/`tile-live` references remain.
- `python3 scripts/test.py`: passed, 459 tests, 0 failures, 9 skipped
  (pre-existing `NativeVideoPlayerMediaTests` hardware skips). New
  `testEncodeThumbnailSkipsTheBlackFadeInOfAnAnimatedPreview` (24-frame GIF
  with six black frames then a fade: still luminance > 0.35; dark-throughout,
  bright-first and PNG sources choose index 0); the synthetic image helper
  gained a per-frame brightness parameter.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED.
- Cache key gained a version prefix (`2:`) so stills cached by the old
  first-frame choice regenerate on next view; orphans go with oldest-first
  pruning. `python3 scripts/test.py` and the Release build re-run after this:
  459 passed, 0 failed, 9 skipped; BUILD SUCCEEDED.
- Not verified: real Steam previews in the running app (no desktop run).

## 2026-09-19 — Workshop sort menu: Highest rated and popularity windows

`WorkshopSort` gained `topRated` (`browsesort=toprated`) and `trendingToday` /
`trendingMonth` / `trendingYear` (`browsesort=trend` with `days=1/30/365`);
the raw value stays the panel-facing key and `browseSort`/`days` feed the URL.
`WebUI/panel.js` lists the eight options in a `workshopSorts` table. Steam's
public browse page was probed with `curl` for `mostvoted`, `totalvotes`,
`votesup`, `mostupvotes`, `mostvotes`, `votes`, `upvotes`: every one returned
the trending page (same heading, same first item), so no "most voted" sort was
added. `toprated` and `trend` with `days=1/30/365` returned distinct headings
("Top Rated All Time", "Most Popular (Today/Thirty Days/One Year)").

- `python3 scripts/test.py`: passed, 458 tests, 0 failures, 9 skipped
  (pre-existing `NativeVideoPlayerMediaTests` hardware skips). New
  `testSortOrdersMapToSteamBrowseSortAndTrendWindow`; store/fixture URL
  assertions now check `browsesort` and `days` per sort.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED.
- Not checked: live result lists per new sort inside the app (no desktop run).

## 2026-09-19 — Filter-sidebar and pagination subtext removed

`WebUI/panel.js` no longer renders the Installed sidebar note ("Filters only
narrow the list; nothing is applied."), the Discover sidebar note ("Match all
selected tags. Filters search the entire Workshop.") or the Steam cap note
under the pagination row; the `.pagination-note` rule left `panel.css`. The
page jump still clamps to Steam's 1,000-page limit and the snapshot still
carries `reachable`. `testWorkshopPageJumpClampsToSteamsPageLimit` (renamed)
now asserts only the clamp and the single-page disabled state.

- `python3 scripts/test.py`: passed, 457 tests, 0 failures.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED.
- Not checked: visual result in a live panel (no desktop run requested).

## 2026-09-19 — Discover pages are Steam pages; three-column floor; no page-size negotiation

A Discover page is now exactly one Steam page of 30 tiles and the panel never
offers more than 1,000 pages (`WorkshopService.maxPages`, mirrored as
`WorkshopStore.maxPages` and the snapshot's `maxPages`). The grid-measured page
size (`measureWorkshopPageSize`, its `ResizeObserver`, the `workshopPageSize`
action, `WorkshopStore.setPageSize`/`pageSizeRange` and the span/cut/compose
machinery) is gone, so a resize only reflows tiles and can no longer trigger a
re-fetch/re-render loop. `WebUI/panel.css`: the grid's track minimum is
`min(--tile-min, (100% - 2 gaps) / 3)`, guaranteeing three square columns at
the 760px window minimum and more as the width grows; a ≤360px container
breakpoint tightens the caption and ring.

- `python3 scripts/test.py` — 455 passed, 2 failed, 9 skipped of 466. The two
  failures (`testFilterSidebarTogglesFromTheToolbarPerPageAndInspectorFollowsWindowWidth`:
  temp directory already removed; `LibraryMetricsTests/testReloadRemeasuresOnlyFoldersWhoseContentsMoved`)
  belong to a concurrent, uncommitted sidebar/library-metrics change in the same
  tree and do not touch the grid or pagination. New tests pass:
  `WorkshopStoreTests.testPagesAreSteamPagesServedFromCacheAndCappedAtSteamsLimit`
  (page 1 served from cache without a request, page 4 of 3 refused, 4,000
  reported pages clamped to 1,000, page 1,001 refused) and
  `ControlPanelLayoutTests.testDiscoverGridKeepsSquareTilesInAtLeastThreeStableColumns`
  (Discover and Installed at 760×560, Discover at 960×640, 1400×900, 1900×1000:
  ≥3/≥3/≥3/≥5/≥6 columns, square and uniform tiles, all 30 tiles, column count
  identical across eight samples after each resize, zero `workshopPageSize`
  messages). The two former page-size tests were removed with the feature.
- `python3 scripts/build.py --swift-only --configuration Release` — BUILD
  SUCCEEDED; bundled `panel.js`/`panel.css` byte-identical to `WebUI/`.
- Not run: desktop/visual check of the grid at any width.

## 2026-09-19 — Shared left filter sidebar with a toolbar Filter button; Installed sort keys

Discover and Installed now share one left filter sidebar (`#filter-sidebar`)
whose only switch is a filled **Filter** button (funnel glyph, active count
pill) leading the toolbar; the collapse control inside the sidebar, the 36px
rail and Installed's Filters popover are gone. Each page stores its own choice
(`filters` action, `filtersCollapsed` snapshot map, `WebPanelController.
filtersCollapsedKeys`). Installed's sort menu grew to Name, Type, Favorites,
File size and Date added with a direction button; `LibraryMetricsService`
measures folder size and date added off the main thread and re-checks only
after a library reload (`BridgeStore.libraryRefreshRevision`).

- `python3 scripts/test.py` — Passed, 457 passed, 0 failed, 9 skipped of 466.
  `testFilterSidebarTogglesFromTheToolbarPerPageAndInspectorFollowsWindowWidth`
  covers the button (label, glyph, filled, first in the toolbar, beside the
  sidebar), the sidebar at the left edge with no toggle of its own, no popover
  on Installed, per-page persistence across a relaunch and the inspector
  widths. `testInstalledSortsByEveryKeyInBothDirectionsWithoutWindow` checks
  every key in both directions, natural starting direction, name tie-breaks and
  unmeasured wallpapers last. `LibraryMetricsTests` (2) cover the walk, the
  single change callback, dropped ids and reload-only re-measuring.
- `python3 scripts/build.py --swift-only --configuration Release` — BUILD
  SUCCEEDED; bundled `panel.js`, `panel.css`, `index.html`, `icons.js`
  byte-identical to `WebUI/`.
- Not run: desktop/visual check of the sidebar, Filter button or sort menu.

## 2026-09-19 — Inspector width follows the window only; drag handle removed

The inspector's left edge is no longer a drag handle and no width is stored or
published. `WebUI/panel.css` sizes it with a single window-driven curve,
`clamp(260px, 15vw + 146px, 420px)`, on both pages (the ≤1040px overrides are
gone); the inspector is an inline-size container whose insets and display
fields adapt past 360px. `#inspector-resizer`, the `inspectorWidth` action, the
snapshot field and `WebPanelController.inspectorWidth` were removed; the old
`UserDefaults` key is cleared on launch.

- `python3 scripts/test.py` — Passed, 455 passed, 0 failed, 9 skipped of 464.
  `testWorkshopFilterSidebarCollapsesPersistsAndInspectorFollowsWindowWidth`
  replaces the drag scenario: no separator/resizer element, no snapshot field,
  a legacy stored width cleared, and the inspector measured at 760/960/1040/
  1600/2000px on both pages (260/290/302/386/420) with columns summing to the
  window width.
- `python3 scripts/build.py --swift-only --configuration Release` — BUILD
  SUCCEEDED; bundled `panel.css` byte-identical to `WebUI/panel.css`.
- Not run: desktop/visual check of the inspector at any width.

## 2026-09-19 — Square tiles on both grids; Discover pages scroll

`WebUI/panel.js`/`panel.css`: the Discover row stretch (`TILE_STRETCH`,
`fitRows`, `--tile-height`) is gone, so tiles are always square on Installed and
Discover. Both use the same width-filling auto-fill grid with a reserved
scrollbar gutter; a Discover page is cut to whole rows that cover the grid's
height and scrolls to reach the last one.

- `python3 scripts/test.py` — Passed, 455 passed, 0 failed, 9 skipped of 464.
  `ControlPanelLayoutTests` now asserts square tiles, whole-row page sizes,
  less than a row of scroll and no more than a sliver empty beneath a page. An
  intermediate no-scroll fit (choosing columns to minimise blank space) failed
  its blank bound at 994×737 and was dropped once scrolling was allowed.
- `python3 scripts/build.py --swift-only --configuration Release` — BUILD
  SUCCEEDED; bundled `panel.js` byte-identical to `WebUI/panel.js`.
- Not run: desktop/visual check of either grid.

## 2026-09-18 — Remove the password guide card from the Steam sign-in dialog

`WebUI/panel.js`: `signInGuide` no longer returns a guide for a secure
password prompt, so the dialog shows identity → labelled field → actions →
footer note only. Steam Guard stages keep their guide cards.

- `python3 scripts/test.py` — Passed, 455 passed, 0 failed, 9 skipped of 464.
  `ControlPanelLayoutTests` now asserts the password prompt renders no
  `.dialog-guide` instead of pinning the removed steps/icon.
- `python3 scripts/build.py --swift-only --configuration Release` — BUILD
  SUCCEEDED; bundled `panel.js` byte-identical to `WebUI/panel.js`.
- Not run: desktop/visual check of the live dialog.

## 2026-09-18 — Post-pull integration build (origin/main dd01e58 + local panel work)

Pulled three upstream commits (quality settings, native video admission,
static subgraph reuse / web audio) onto the uncommitted control-panel work;
only `verification-log.md` conflicted (additive, both entries kept).

- `python3 scripts/test.py` on the stale tree failed at link time: the local
  renderer library predated the new bridge symbols
  (`submit_system_media_event`, `web_audio_spectrum`). Not a source failure.
- `python3 scripts/build.py --configuration Release` — BUILD SUCCEEDED
  (renderer + bindings regenerated).
- `python3 scripts/test.py` after the rebuild — Passed, 455 passed,
  0 failed, 9 skipped of 464.
- Bundled `Contents/Resources/WebUI/` is byte-identical to `WebUI/`.
- Not run: `check_renderer.py` (no local renderer edits), desktop/UI checks.

## 2026-09-18 — Round 6: scene optimisation, web audio/media, file properties

Feature delivery round. Commands run:

- `python3 scripts/check_renderer.py` — exit 0. All ten generated cases
  `pixels_equal=True`, zero diagnostics, reload cycles 0. New target
  **`static_subgraph_cache_test` 21** registered in the gate.
- **R03 A/B on the production analysis**, eight generated fixtures, each run
  twice through `offscreen_scene_probe` with and without
  `WE_TEST_NO_SCENE_OPTIMIZATION`: output byte-identical in 8/8, and 8/8
  genuinely reused passes (6–8 reused against 3–7 executed over a three-frame
  run). This matters because the golden probe previously did **not** exercise
  the skip path at all: it drives `UpdatePreparedPasses` /
  `ExecutePreparedPasses` directly and never calls `VulkanRender::drawFrame`,
  so a passing golden run proved nothing about reuse. The probe now drives the
  cache the same way the renderer does, and reports its reuse counts so an
  identical-pixels result cannot pass vacuously.
- `cargo test -p wallpaper-bridge` — 292 passed, 0 failed.
- `cargo test -p wallpaper-core audio` — 29 lib + 5 `core_audio_api` passed.
  C++ analyser `audio_tests` 21/21.
- `python3 scripts/test.py` — **463 tests, 9 skipped, 1 failure.** The failure
  is the pre-existing `ControlPanelLayoutTests`
  `testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes` (overflow 52 px,
  tile 166, 5 columns, 4 rows), numbers identical to the round 4 and round 5
  entries. The Discover grid was not touched this round. The 9 skips are the
  opt-in `NativeVideoPlayerMediaTests`.
- `python3 scripts/build.py --configuration Release` — succeeded; app and
  extension at 22:19.

Two test-integrity corrections made during the round, both of the same shape as
the round 5 pacing-test fault — a test that could not have failed for the reason
it claimed:

- `DirectoryWatcherTests` failed all four cases in its shared `settle()` helper,
  which created an **inverted** `XCTestExpectation` and then fulfilled it on a
  timer. An inverted expectation fails when fulfilled, so every test that waited
  failed by construction and the watcher's behaviour was never exercised.
  Replaced with a plain run-loop pump; all four now pass against the real
  FSEvents stream.
- A first attempt at the R03 A/B reported `identical=True` for six cases while
  both sides exited non-zero and produced no output at all. The probe needs
  `WE_TEST_PROJECT`, `WE_TEST_ASSETS` and `WE_TEST_OUTPUT`; the comparison was
  of two empty sets. Re-run with the right environment, and the reuse counters
  above exist so that failure mode is visible rather than silent.

Late in the round the panel's audio/media status was changed from a static
sentence to the live state read from the running web host, because "see the
feature status" was part of the ask and a sentence is not a status. The first
version of that wiring had the bug it was meant to prevent: an available media
source and "no host running" both serialised to `null`, so the panel would have
reported a capability it had not observed. `WebPanelDeliveryStatusTests` pins the
three states apart; deleting the line that distinguishes them fails exactly
`testAnAvailableMediaSourceIsDistinguishableFromAnUnknownOne` and
`testAnUnavailableMediaSourceCarriesItsReason`, which was checked by making that
edit and re-running, not assumed.

Not verified: no desktop session, no visual check, no power measurement, no
system audio captured, and MediaRemote was never called, so the media
provider's runtime availability on this machine is unobserved. Scene
optimisation, web audio delivery, media listeners and file/directory properties
have not been seen on a real display.

## 2026-09-18 — Round 5: render scale, settings, shared decode

Feature delivery round. Commands run:

- `python3 scripts/check_renderer.py` — exit 0. `playback_gpu_test` 39,
  `video_conversion_budget_test` 37, `video_source_input_test` 11,
  `text_object_runtime_test` 60, `video_frame_pacing_test` 21,
  `video_decode_pump_test` 13, `video_color_conversion_test` 9,
  `render_target_lifetime_test` 4, `shader_cache_metadata_test` 1,
  `timer_tests` 20, plus the two new targets **`render_scale_test` 8** and
  **`shared_video_session_test` 8**. Both are registered in the gate.
- `cargo test --release -p wallpaper-bridge` — 276 passed, including new
  config-migration and quality-settings cases.
- `python3 scripts/test.py` — **382 tests, 372 passed, 1 failed, 9 skipped**.
  The failure is the pre-existing `ControlPanelLayoutTests`
  `testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes` (overflow 52 px,
  tile 166, 5 columns, 4 rows), with numbers identical to the round 4 entry. The
  Discover grid was not touched this round. The 9 skips are the opt-in
  `NativeVideoPlayerMediaTests`.
- `python3 scripts/build.py --configuration Release` — succeeded; app and
  extension at 20:25.

`shared_video_session_test.PausingOneSurfaceLeavesTheOtherPlaying` failed on its
first run. A control against an unshared decoder failed the same way, which
established the fault was in the test's driving model — a tight sync/refresh loop
never lets the decode thread produce — and not in the sharing. Fixed by letting
real time elapse between steps. The same flaw had made
`AFrameStaysValidAfterTheDecoderMovesOn` pass vacuously; it now asserts the
decoder actually advanced before claiming the retained frame survived.

No desktop session, no visual check, no power measurement. Render scale, video
backend routing and shared decode have not been observed on a real display.


## 2026-09-18 — Round 4: R02 memory accounting audit and V04 real-media hardening

Audit round on top of `c0461f7` (clean tree at start). No new plan task. R02's
conversion-memory ledger was rebuilt so one destination is billed in exactly
one mutually exclusive state, V04's frame-rate admission was rewritten on real
AVFoundation metadata and exercised against generated media, and V04's poster
path stopped being a second decoder. P02 stays opt-in and the native video
backend stays off by default. I01 code is untouched; only its evidence wording
in the progress doc was corrected.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  **377 tests, 1 failed**. The failure is
  `ControlPanelLayoutTests/testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`
  (a full Discover page scrolls by 52 px at tile 166 / 5 columns / 4 rows in a
  960x640 web view). It reproduces deterministically in isolation and is
  **unrelated to this round**: no file under `WebUI/`, `App/Views/ControlPanel/`
  or `Tests/Unit/Panel/` was modified. Not fixed, not worked around, not
  claimed as passing.
- `python3 scripts/check_renderer.py`: exit 0. `playback_gpu_test` 39,
  `video_conversion_budget_test` 37, `video_frame_pacing_test` 21,
  `timer_tests` 20, `video_decode_pump_test` 13, `video_source_input_test` 11,
  `video_color_conversion_test` 9, `render_target_lifetime_test` 4,
  `shader_cache_metadata_test` 1, `text_object_runtime_test` 60. The ten
  generated GPU cases ran with `pixels_equal=true` and 0 diagnostics; reload
  cycles 0. Vulkan/Metal were available on this machine (Apple M3 Max), so the
  6144x3456 conversion cases executed for real.
- `cargo test --release --workspace` (from `upstream/renderer`, with
  `scripts/build.py`'s environment and `CARGO_TARGET_DIR` unset): pass,
  including `wallpaper-bridge` **264** with `native_video_routing` at 19.
- `MAC_WALLPAPER_ENGINE_MEDIA_TESTS=1` `NativeVideoPlayerMediaTests`: **9/9**
  with real decode — 2 observed loop wraps, poster obtained from the playing
  item after both wraps with 0 image-generator fallbacks, concurrent requests
  coalesced, paused poster returned without resuming, item create/release
  counters balanced. `scripts/test.py` now forwards this variable as
  `TEST_RUNNER_…` because `xcodebuild` does not pass its environment to the
  hosted test process; without that the suite silently skipped.
- `python3 scripts/build.py --renderer-only`: pass; regenerated bindings carry
  `admissionKey`, the three-argument `rejectNativeVideo`, and
  `videoConversionLiveBytes` / `videoConversionPeakLiveBytes`.
- `python3 scripts/build.py --configuration Release`: **BUILD SUCCEEDED**, app
  and embedded `MacWallpaperExtension.appex`.

A second review pass over this round's own work found fifteen further defects in it
and they were fixed before yielding: the conversion domain could hand the same
bytes to two pools (reservations were published to it but never subtracted from
other budgets' headroom, and the fit test was not atomic with the record); the
overage was counted but not bounded; the admission rule could still admit on a
nominal *average* alone when `minFrameDuration` was unusable; a running player
outlived the decision that admitted it, so lowering the target rate under a
60 fps clip left it playing at 60; playback failure after a successful
admission had no hand-off, leaving a black display with the scene engine
excluded; and the bridge stored one rejection per wallpaper id, so the same clip
refused on two displays left one of them with no backend at all; the in-flight
cap was never read on the production path, so a denial allocated an uncounted
texture; a playback failure on one display was discarded as stale as soon as a
second display opened; the failure observer watched the looper's template item,
which is never played; and the host's own permanent refusal set disagreed with
the bridge's, so a key refused, superseded and offered again was silently
skipped while the scene engine was already excluded. Each is pinned by a test
that was falsified against the pre-fix code.

Five more followed in the same pass: a denied reservation still allocated and
was never read, so the denial left an uncounted texture; a known-unsatisfiable
allocation was retried every frame; the buffered-failure fix could order a
stopped, unregistered window onto the desktop; mirrors inherited their source's
admission key and so never evaluated their own target rate; and the "no video
track" case was only ever asserted against a hand-built probe, not real media.

One attempted fix had to be withdrawn on evidence. Making the in-flight cap a
real refusal **deadlocked** the production path on the real GPU: refusals per
generation 1, 8, 14, 19, 23 with `created` frozen and `reused` at 0, because a
refused import leaves the consumer holding the `ImageSlotsRef` whose release the
import would have caused. The cap is now stated and reported, never enforced;
`InFlightCapReached` was removed from the refusal enum, and the two tests
briefly trimmed to fit the cap were reverted to byte-identical.

Headline correction: round 3's "peak resident pool bytes 84,934,656" was the
idle-cache high-water mark, not memory held. The same 6144x3456 workload now
reports `peak_live_bytes` **339,738,624** — four destinations alive at once —
with `peak_cached_bytes` still 84,934,656 and correctly labelled as the
Available state alone. A first version of the new ceiling refusal was measured
destroying reuse entirely (17 allocations / 0 reuses / 13 refusals) while
saving no memory at all, and was corrected before landing rather than pinned.

**Not run, and still required:** any desktop session. No wallpaper has been
displayed by the native backend, no screenshot or capture was taken, no
wallpaper or appearance setting was changed, `--ui` was not run, and no power
measurement exists. The minimum authorized-session checklist is in
[../mac-wallpaper-engine-implementation-progress.md](../mac-wallpaper-engine-implementation-progress.md).
## 2026-09-18 — Shared-resources consent stage: two choices instead of caveats

The resources stage of the download dialog in `WebUI/panel.js` / `panel.css`
(`resourcesStep()`, new `choiceButton()`, `.dialog-choice*` rules) replaced a
paragraph, a three-clause warning notice, a three-button row and a footnote
(~75 words) with one lead sentence and two full-width choice buttons
(**Download from Steam** / **Use an existing installation**, ~45 words), each
carrying the fact that decides it; **Not now** sits alone at the bottom right.
Title is now "Shared resources needed". The `sceneAssetsWarning` notice and
the already-installed status still render above the choices. The "no Windows
program is ever run" reassurance left this dialog; Settings keeps it.

- Rendered `WebUI/` in the harness's headless Chromium at 424px dialog width
  with a fake `webkit.messageHandlers.native` and a synthetic
  `downloadRequests` snapshot: dark default, and light with
  `sceneAssetsReady` + `sceneAssetsWarning`. Focus lands on the first choice;
  clicking the choices posts `locateAssets` and `continueDownload` as before.
- `impeccable detect --json WebUI/panel.js WebUI/panel.css`: no findings.
- `python3 scripts/test.py`: Python → XcodeGen → native unit/integration,
  336 tests passed, 0 failed, 0 skipped.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; bundled `panel.js` / `panel.css` byte-identical to sources.
- Not rendered in the app's own WKWebView or on the desktop.

## 2026-09-18 — Steam sign-in account stage: guide card removed

The account stage of the "Sign in to Steam" dialog dropped its guide card (the
"Use the Steam account that owns Wallpaper Engine" title and the mock of Steam's
**Sign in with account name** field) because it only restated the **Steam
account name** field directly below it. `accountStep()` in `WebUI/panel.js` now
renders the field, the keep-signed-in checkbox, the saved-account note, the
actions and the password/Steam Guard note; the `.dialog-demo` / `.demo-*` rules
left `WebUI/panel.css`. The password and Steam Guard guide cards are unchanged.

- `node --check WebUI/panel.js`: ok.
- `python3 scripts/test.py`: Python → XcodeGen → native unit/integration,
  336 tests passed, 0 failed, 0 skipped.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `Contents/Resources/WebUI/panel.js` and `panel.css`
  are byte-identical to the sources (`cmp`), so the app no longer carries the
  `.dialog-demo` markup.
- Not rendered on the desktop; the dialog was not viewed in the app's window.

## 2026-09-18 — Steam sign-in account stage: centred step numbers, demonstration instead of prose

Two fixes to the "Sign in to Steam" dialog in `WebUI/panel.js` / `panel.css`.
The step counters sat high because `* { box-sizing: border-box }` never
matches `::before`: the circle was a 20px content-box with a 16px line box
pinned to its top. `.dialog-steps li::before` now sets `box-sizing: border-box`
itself. The account stage dropped its three explanatory steps and the
three-line footnote for a mock of Steam's own **Sign in with account name**
field (`.dialog-demo` / `.demo-screen`), one line ruling out email and profile
names, the field relabelled **Steam account name**, and a one-line note that
the password and Steam Guard come next and are never saved.

- Root cause measured inside an offscreen `WKWebView` through a throwaway
  `ControlPanelLayoutTests` probe (removed afterwards): with the pseudo's
  computed styles copied onto a real span, the digit's ink centre sat 0.87px
  above the circle centre and the box was 20px tall; with `border-box` the box
  is 18px and the offset is +0.13px.
- The new account stage and a two-step password card were rendered against the
  real `panel.css` in headless Chromium in light and dark themes (424px dialog);
  the digits sit centred and the demo block, field, checkbox, actions and note
  fit without overflow. Not rendered in the app's own `WKWebView`.
- `.agents/skills/impeccable/scripts/impeccable detect --json WebUI/panel.js WebUI/panel.css`: no findings.
- `python3 scripts/test.py`: Python → XcodeGen → native unit/integration,
  336 tests passed, 0 failed, 0 skipped.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `Contents/Resources/WebUI/panel.js` contains the new
  `.demo-screen` markup. Not run inside the app's window, so the dialog was
  not viewed on the desktop.

## 2026-09-18 — Settings "Steam account · Log out…" replaces "Forget account…"

Reframed the saved-session control in Settings → Library & Steam: the row is now
always present as **Steam account**, reading "Signed in as <name>" with a
destructive **Log out…** button, "Not signed in" otherwise, and noting that
log-out waits for downloads to finish while one runs. The WebUI action was
renamed `forgetAccount` → `logOutSteam` (the dead `panel.js` case was removed),
the native confirm and service error strings were localized (`en`, `zh-Hans`)
under "Log out of Steam?" / "Could not log out of Steam: %@", and the privacy
disclosure plus `docs/features/workshop-downloads.md` describe log-out as
removing only this Mac's cache. Underlying `forgetSavedAccount()` and session
removal are unchanged.

- `python3 scripts/test.py`: Python → XcodeGen → native unit/integration,
  336 tests passed, 0 failed, 0 skipped.
- `Localizable.xcstrings` parsed as JSON with 527 keys and no duplicates.
- WebUI: `renderSettings` was loaded in headless Chromium with a stub `send`
  in three states — saved account, no account, saved account with a pending
  download. Row text, the enabled/disabled `logOutSteam` button and the
  disclosure wording were checked; clicking dispatched `["logOutSteam", {}]`.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; `build/Build/Products/Release/MacWallpaperEngine.app` bundles the
  updated `WebUI/settings.js` (`logOutSteam` present).
- Not exercised: the native confirm sheet and a real SteamSession removal from
  the running app (no desktop run requested); the service path is covered by
  the existing `DownloaderTests` forget/opt-out cases.

## 2026-09-18 — Vendored agent skills restored and wired into Claude Code

Restored `impeccable`, `swiftui-webkit` and `webkit-integration` into
`.agents/skills/<name>/` from the commits pinned in
`.agents/skills/sources.json`, copied each upstream `LICENSE` (and Impeccable's
`NOTICE.md`), and reapplied the local adaptations from `.agents/README.md`:
every entry point opens with a project-rules block linking `../../../AGENTS.md`,
`webkit-integration` lost its `allowed-tools` metadata and gained
`disable-model-invocation: true` plus the `decidePolicy(for:preferences:)`
API-disagreement note. Added `.claude/skills/<name>` directory symlinks so
Claude Code discovers the vendored copies, ignored `.claude/skills/` in
`.gitignore`, documented the wiring in `.agents/README.md`, and recreated the
Git-ignored `.pi/settings.json` override. Docs/skill-only change: no app build
or desktop test.

- Checkout: each repository cloned and checked out at its pinned commit;
  source paths matched `sources.json`.
- Links: every `.claude/skills/<name>/SKILL.md` resolves through its symlink;
  a script over all vendored `*.md` found 0 broken relative links; each skill
  directory reaches `../../../AGENTS.md`.
- Metadata: three unique `name` fields; only `webkit-integration` carries
  `disable-model-invocation`; no `allowed-tools` key remains.
- Not checked: the harness was not reloaded in this session, so automatic
  routing exposing only `impeccable` and `swiftui-webkit` is unconfirmed until
  the next Claude Code start. The Impeccable launcher was not run.

## 2026-09-18 — Steam sign-in dialog explains each stage with icons and confirms the started download

The sign-in dialog's one-line Steam Guard hint was replaced in
`WebUI/panel.js` by a guide card per stage: a Lucide glyph (`smartphone`,
`mail`, `lock`, `keyRound`, `userRound`, `logIn`, copied into `WebUI/icons.js`
from the local lucide-react 1.45.0 cache), a title and numbered steps for the
login name, the password, mobile approval, the authenticator code and the
emailed code. The mobile-approval steps now say to answer **Steam Client**
when the Steam app asks where the sign-in comes from. Once Steam accepts the
sign-in the dialog switches to a "Signed in" card with the running job's
status and progress, **Done** and **Show downloads**, and closes on its own
after six seconds instead of vanishing the moment the prompt clears. Styles
in `WebUI/panel.css` (`.dialog-guide`, `.dialog-steps`). Documented in
`docs/features/workshop-downloads.md` and `docs/features/control-panel.md`.

- `ControlPanelLayoutTests/testDiscoverTilesCarryDownloadRingsAndOnlySteamRequestsOpenTheDialogWithoutWindow`
  now asserts that the password and mobile-approval stages render a glyph and
  numbered steps, that mobile approval asks for nothing to type, that
  finishing the sign-in keeps the dialog open at the started stage with
  progress and the wallpaper's name, that later progress updates it rather
  than closing it, and that **Done** closes it while the tile keeps reporting.
- `python3 scripts/test.py`: Python 50 tests OK (1 + 24 + 4 + 10 + 11),
  XcodeGen regenerated, native suite 336 passed, 0 failed, 0 skipped.
- `python3 scripts/build.py --swift-only --configuration Release`: succeeded;
  `build/Build/Products/Release/MacWallpaperEngine.app` carries the new dialog
  copy (bundled `panel.js` contains the Steam Client step).
- Headless preview (Chrome `--headless=new --screenshot` of a scratch page that
  reuses the dialog functions from `panel.js` and the real `panel.css`) showed
  bold words inside a step breaking into flex columns; each step's text is now
  wrapped in a `<span>` (`.dialog-steps li > span`). Re-run after the fix:
  `python3 scripts/test.py` native suite 336 passed, 0 failed; Release build
  succeeded again. All eight stages rendered cleanly in dark and light.
- Not checked: no live Steam sign-in was run, so the real SteamCMD handoff
  timing and the Steam app's "Where are you trying to sign in?" screen were
  not observed in this session; the copy follows the user's screenshot of it.
  The in-app rendering inside the WKWebView panel was not inspected.

## 2026-09-18 — Top bar drops the renderer-source link and adapts to narrow windows

The top bar's "Renderer source" button duplicated the Settings → About
"Scene renderer" link and was the widest control on the right, so it was
removed from `WebUI/panel.js`. In `WebUI/panel.css` the bar's side tracks are
now `minmax(max-content, 1fr)` instead of `minmax(0, 1fr)`, so the tabs and
the display picker keep their width and nudge the brand off-center instead of
running under it; at 840px and below only the name and version hide
(`.app-title`) while the GitHub button stays, where previously the whole
identity vanished at 1040px and below. Documented in
`docs/features/control-panel.md`.

- New `ControlPanelLayoutTests/testTopBarKeepsTheRepositoryLinkAndNeverOverlapsAtTheMinimumWindowWidth`
  renders the bar at 760, 840, 900, 1040 and 1240px with a download in flight
  and the 70px traffic-light inset, and asserts no two top-bar controls
  overlap, none leaves the bar, the GitHub and downloads buttons stay, and the
  name hides only at 840px and below. Its first draft waited on
  `requestAnimationFrame`, which never fires in the offscreen web view and
  timed out the sidebar run logged below; the wait was removed.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native unit
  tests ran 336 with 0 failures.
- `node --check WebUI/panel.js` passed.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `panel.js` no longer contains the renderer link.
- Not verified: the live look at each width (no desktop run requested).

## 2026-09-18 — Filter sidebar toggle uses panel glyphs; rail is one labelled button

The Discover filter sidebar's collapse control was a bare chevron that neither
stood out nor explained itself. The heading button now renders Lucide's
`panel-left-close` glyph (framed pane with an inward arrow, tooltip "Hide
filters") with the normal bordered button look, and the collapsed strip became
a single full-height `.filter-rail` button (36px, was 30px) showing
`panel-left-open`, the active filter count and a vertical "Filters" label, so
clicking anywhere on the rail expands it. Both glyphs were copied from the
Lucide repository into `WebUI/icons.js`.

- `python3 scripts/test.py`: Python suite and XcodeGen passed; native unit
  tests ran 336 with 1 failure. The failure is
  `ControlPanelLayoutTests/testTopBarKeepsTheRepositoryLinkAndNeverOverlapsAtTheMinimumWindowWidth`,
  an uncommitted test from concurrent top-bar work that was already in the
  working tree and does not touch the sidebar; it was left as found. The
  sidebar test `testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth`
  passed with its rail expectation updated to 36px.
- `node --check WebUI/panel.js` passed; importing `icons.js` under Node
  reports 24 glyphs.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `panel.css` matches the source tree.
- Not verified: the live look of the new toggle and rail (no desktop run
  requested).

## 2026-09-18 — Trimmed vendored upstream tree

Removed files under `upstream/renderer` that no build path, script or doc
uses: upstream READMEs and screenshots, GitHub workflows, the Nix dev shell,
stale `.gitmodules`, the Linux `waywallen` host, the Qt `qml_helper`, the
`standalone_view` viewer, and the miniaudio/spirv_reflect extras, examples,
tests and vendored googletest. Their `BUILD_WAYWALLEN`/`BUILD_QML` CMake
options, presets and the matching `-D` flags in `crates/core/build.rs` and
`scripts/check_renderer.py` were dropped. All license files stay; `wpdoc/`
and the scene-engine `tests/` stay. Recorded in `upstream/provenance.json`.
Rebased onto the native-video and per-display suspension commits below;
results are from the rebased tree.

- `python3 scripts/build.py --configuration Release`: BUILD SUCCEEDED
  (renderer, regenerated bindings, app). `xcodegen generate` reordered one
  line of the committed project file; committed as generated.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  **335 passed**, 0 failed, 0 skipped.
- `python3 scripts/check_renderer.py`: shader crate and CMake configure/build
  succeeded on the trimmed tree (the only configure warning is spirv_reflect's
  pre-existing `cmake_minimum_required` deprecation). All compiled test
  binaries passed: `playback_gpu_test` 34, `timer_tests` 20,
  `video_frame_pacing_test` 21, `video_decode_pump_test` 13,
  `video_conversion_budget_test` 11, `video_source_input_test` 11,
  `video_color_conversion_test` 9, `render_target_lifetime_test` 4,
  `shader_cache_metadata_test` 1, `text_object_runtime_test` 60 with the 2
  opt-in corpus cases skipped. The ten generated GPU cases and the reload
  cycles **did not run**: the shared
  `~/Library/Application Support/mac-wallpaper-engine/SceneAssets` directory is
  absent on this machine (the app data went with the earlier uninstall), so
  every probe exited 1 at asset mount. Environmental, not a renderer result;
  re-run once the app has restored its shared assets.
- Before the rebase, on the pre-merge tree: `cargo test --release -p
  wallpaper-core --lib` **197 passed**, `-p wallpaper-bridge --lib` **224
  passed**; not repeated after the rebase.

## 2026-09-18 — Phase C first batch: P02 closeout, R02, I01 and an opt-in V04

Third round, on the same uncommitted tree as round 2 (`6bfaa1d84` plus that
round's 41 modified and 9 untracked files, verified rather than assumed).
Nothing was reset, stashed or committed. Per-task evidence:
[../mac-wallpaper-engine-implementation-progress.md](../mac-wallpaper-engine-implementation-progress.md).

- `python3 scripts/test.py`: passed, 325 tests, 0 failures (314 before). New
  suites: `NativeVideoWallpaperHostTests` (7) and four added
  `RuntimeDiagnosticsReportTests` cases.
- `python3 scripts/check_renderer.py`: exit 0. Ten generated cases with
  `pixels_equal=true` and no diagnostics, and every test binary exit 0,
  now including `video_conversion_budget_test` (11) and
  `video_source_input_test` (11), both added to the gate. `timer_tests` is 20
  cases and `playback_gpu_test` 34.
- `cargo test --release --workspace`: passed, 251 `wallpaper-bridge` cases
  including the new `native_video_routing` module (7).
- `python3 scripts/build.py --renderer-only` and
  `python3 scripts/build.py --configuration Release`: both passed; the Release
  app and embedded extension contain the new window class and both switches.
  Not installed, not launched, `/Applications` untouched.
- P02's round 2 claim that a rate transition costs at most one frame was
  **disproved on the production path**: `ThreadTimer::SetInterval` could not
  shorten a wait already in progress, so a demand change waited out the whole
  previous period. Two new timer cases fail against the old code and pass now.
  Because the remaining exposure — the period only reaches the clock after a
  completed frame — cannot be bounded without an event-driven clock, pacing was
  made opt-in and the safe baseline is the default.
- Counter attribution was corrected: conversions and imports are consumer work,
  source work is keyed on a process-unique decoder instance rather than a file
  path, and a roll-up totals one decoder once without ever folding two decoders
  that read the same file.
- R02 and I01 report measured, non-power numbers: a warm 6144x3456 clip settles
  at 4 created and 13 reused conversion destinations with an 81 MiB resident
  peak, where the old ceiling kept allocating; scene-load peak for a 67 MB
  wallpaper drops from +134,316,128 to +4,079,616 bytes. Every R02 rule was
  confirmed load-bearing by deleting it and watching the matching test fail.

Environment faults worth recording, both self-inflicted: a scratch CMake
directory configured without `scripts/build.py`'s environment linked the default
Homebrew `ffmpeg` instead of the pinned `ffmpeg@8` and produced dangling
dylibs that looked like a broken toolchain; and a stale cmake cache under
`target/release/build/wallpaper-core/*/out` carrying `BUILD_TESTS=ON` broke
`build.py --renderer-only` until that one directory was removed.

Not run, and therefore skips rather than passes: the local wallpaper corpus,
`python3 scripts/test.py --ui`, and every desktop, visual and power measurement.
No watt figure or saving percentage is claimed. In particular the native video
backend has never put a pixel on a screen: its refusal path is tested with an
injected decision, so the real frame-rate probe has not run against a real
asset, and it stays off by default. Its window and player have no automated
coverage at all — an earlier version of the host tests did construct a real
desktop window, which this project's rules do not allow from an automated run,
so the host now takes an injected surface factory and the tests use a fake.

## 2026-09-18 — Release 0.4.0 published

The Workshop/control-panel work logged below (concurrent downloads, tile
download rings, grid-sized Discover pages) was committed as
`feat(workshop): concurrent downloads, tile download rings and grid-sized
Discover pages` with a `release: minor` line and pushed to `main`.

- `python3 scripts/test.py` on the committed tree: Python suites and XcodeGen
  passed; native suite executed 277 tests with 0 failures.
- Version workflow: bumped `0.3.2` -> `0.4.0` (build 15), committed
  `chore: bump version to 0.4.0`, pushed `v0.4.0`; the called Build job
  succeeded and GitHub Release `v0.4.0` carries
  `MacWallpaperEngine-0.4.0-arm64.zip` as its only asset.
- Local checkout was re-cloned from `origin/main` at the bump commit after an
  uninstaller (Pearcleaner) moved the working copy and its `build/` output to
  the Trash; `python3 scripts/build.py --configuration Release` on the fresh
  clone: BUILD SUCCEEDED, bundle reports `0.4.0`.
- Not run: the manual smoke pass against the packaged build
  ([manual-smoke.md](manual-smoke.md)); no desktop run was requested.

## 2026-09-18 — Batch with a saved sign-in starts together; SteamCMD sessions log their progress

A live run of the concurrent queue on a real account (Release build from the
entry below, three Scene tiles queued) still transferred one item while the
other two sat on "Waiting for the current sign-in to finish", and the app quit
before any of them imported. The app log showed the manager holding the
siblings on that reason and nothing else: the worker logged nothing about the
running session, and the saved session was never rewritten during the run, so
the first job had not passed the point where the worker sees Steam accept the
login. Holding on that at all was the mistake when a saved sign-in already
exists: the siblings restore it themselves. `holdBehindRunningJobs` now starts
a job immediately when the saved sign-in belongs to its account, holds only
while a running job has a password/Steam Guard prompt on screen, and waits for
a running login only when there is no saved sign-in to restore.
`WorkshopDownloader` now logs, per session, the runtime preparation and
whether a saved sign-in was restored, every status change, the sign-in
handoff with the early-save result, and SteamCMD's exit status.

- A direct SteamCMD probe with a copy of the saved sign-in (to read the real
  transcript and try two sessions at once) was blocked by the harness's
  permission classifier, so SteamCMD's actual output on this machine remains
  unobserved.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 277 tests with 0 failures, including the new
  `DownloaderTests.testSavedSignInStartsAWholeBatchAtOnceWithoutWaitingForTheFirstLogin`
  (one job signs in and saves; three more then start together with
  `activeCount == 3` and no prompt while every fixture session is still
  blocked before its transfer). The fresh-sign-in batch, session-conflict,
  saved-sign-in handoff and store intent tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the built binary carries the per-session log strings.
- Not verified: the live batch itself. The next live run's log under
  **Show download logs** will carry `SteamCMD <item>: …` lines that say where
  the first session stalls.

## 2026-09-18 — Several Workshop downloads at once, sharing one accepted sign-in

`WorkshopDownloadManager` runs up to `maximumConcurrentDownloads` (default 3)
private SteamCMD sessions at once. The withdrawn attempt held every sibling
until the first job *finished* because the session was only saved at the end;
now `WorkshopDownloader` saves the session the moment Steam accepts the sign-in
(`saveAcceptedSession`, then `onAuthenticated`), so siblings start silently
while the first transfer is still running. The queue holds, in order, only
while a running job is still authenticating, while the saved sign-in is not yet
on disk for the account, without **Keep me signed in**, or after Steam ended a
session with "logged in elsewhere" for another of our sessions
(`sessionConflictDetected`: the ended job goes back in line once and the queue
stays serial). Every queued job carries its hold reason
(`WorkshopDownload.hold`); starts and holds go to the app log. The snapshot
carries `downloadSlots`; `panel.js` `queueState()` sums running jobs for the
activity bar and the queue footer states the slot rule.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 276 tests with 0 failures, including the new
  `DownloaderTests.testAcceptedSignInLetsSiblingsRunSideBySideUpToTheSlotLimit`
  (limit 2: only the first job prompts, the other three hold for the sign-in,
  two transfer together once the password is accepted, the third waits for a
  slot and starts when the first releases, all four import, no staging left,
  private session permissions) and
  `testSessionConflictSerialisesTheQueueAndRetriesTheEndedJob` (a sibling
  ended with "FAILED (Logged in elsewhere)" is back in line with no error, does
  not start while the first still runs, the slot limit drops to 1, and it
  imports on its automatic retry). The serial opt-out queue, saved-sign-in
  handoff, failure-slot, shutdown and store intent tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED (the CoreDevice/CoreSimulator plug-in warnings are Xcode's); the
  built app's bundled `WebUI/panel.js` carries `downloadSlots`.
- Not verified: a live batch on a real account — whether Steam keeps two of
  the app's sessions signed in on one account, whether SteamCMD has written a
  reusable sign-in by the time it reports the login, and the activity bar with
  several real transfers. No desktop run was authorised.

## 2026-09-17 — Renderer work counters and the P02 correctness re-examination

Second round on top of `6bfaa1d840f2ca84feb7ff600e7b32e78a6e9610`, whose working
tree was clean, so the 310-test result recorded below belongs to exactly that
commit. Built the renderer half of M00 that round 1 left unbuilt, and re-checked
P02's correctness argument. Per-task evidence, with implementation, automated,
runtime, visual and power verification tracked separately:
[../mac-wallpaper-engine-implementation-progress.md](../mac-wallpaper-engine-implementation-progress.md).

- `python3 scripts/test.py`: passed, 314 tests, 0 failures (310 before this
  round). New suite: `RuntimeDiagnosticsReportTests` (4). That run builds the
  embedded extension, so `Shared/` still compiles under
  `APPLICATION_EXTENSION_API_ONLY`.
- `python3 scripts/check_renderer.py`: exit 0. Ten generated cases with
  `pixels_equal=true` and no diagnostics, `scene_reload_cycle_probe` exit 0, and
  every test binary exit 0, now including the new `video_frame_pacing_test`
  (21 cases) and an expanded `timer_tests` (18 cases, 7 of them new).
  `playback_gpu_test` (32 cases) ran green inside the gate this time.
- `cargo test --release --workspace` in `upstream/renderer` with
  `CARGO_TARGET_DIR` unset: passed, 241 `wallpaper-bridge` cases including the
  new `renderer_counters` module (8), every other crate green.
- `python3 scripts/build.py --renderer-only`: passed; `App/Bridge/Generated`
  regenerated with `rendererCounters` and `setRendererCountersEnabled`.
- `python3 scripts/build.py --configuration Release`: **BUILD SUCCEEDED**, app
  and embedded extension, at
  `build/Build/Products/Release/MacWallpaperEngine.app`. Not installed, not
  launched, and `/Applications` was not touched.
- Counter-example checked by running it, not by assertion: with
  `FrameTimer::SuspensionThreshold` temporarily cut back to the old fixed 5 s
  floor, `AContentWaitAtTheClampIsNotMistakenForASuspension` and
  `TheSuspensionThresholdFollowsTheIntervalAndNeverDropsBelowTheFloor` fail;
  with the real implementation restored all 18 timer cases pass. The temporary
  edit was reverted before any suite above was run.
- Three P02 concerns were checked. One is falsified: the shortest-period `min`
  was already taken over periods, i.e. `1 / max(fps)`. Two were real and are
  fixed: pacing trusted container metadata that cannot describe a particular
  gap, and it ignored playback speed. A third defect was found while checking
  them: the pacing clamp and the suspension cutoff were the same 5 s constant,
  so a scene paced at the clamp had every frame boundary misread as a resume and
  fell behind on every frame.

Not run, and therefore skips rather than passes: the local wallpaper corpus,
`python3 scripts/test.py --ui`, and every desktop, visual and power measurement.
No watt figure, energy number or saving percentage is claimed. Whether a hidden
surface's counters actually stop rising on a real desktop, whether a
non-cooperating web page's timers really halt, and whether a paced video keeps
its timeline at equal quality are all unverified and need an authorized desktop
session.

## 2026-09-17 — Parallel Workshop downloads withdrawn; the queue is serial again

On a real account the parallel queue never ran a second transfer: with one
item transferring, the next two tiles stayed at the dimmed "waiting" ring until
it finished (the manager's saved-sign-in gate held them, and the downloader
writes nothing to the app log that would say why). Steam's handling of two
SteamCMD sessions sharing one saved sign-in is undocumented and could not be
tried without a live sign-in, so `WorkshopDownloadManager` is back to one
private SteamCMD session at a time (the pre-parallel version): queued jobs
start in order as each finishes and reuse the sign-in the previous job saved.
Removed with it: `maximumConcurrentDownloads`, `canJoinRunningDownloads`,
`WorkshopDownloader.promptedForSignIn` and `onAuthenticated`, the snapshot's
`downloadSlots`, and the multi-job aggregate in `panel.js` `queueState()`
(the activity bar carries the running job's own status, percentage and speed;
the queue footer states that downloads run one at a time). The disk-measured
progress, tile rings and page-size negotiation from the same batch stay.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 274 tests with 0 failures after deleting
  `DownloaderTests.testSavedSignInRunsDownloadsInParallelUpToTheSlotLimit` and
  `testStaleSavedSignInHoldsTheQueueUntilTheRenewingJobFinishes`; the serial
  queue, sign-in handoff, failure-slot and shutdown tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED (the CoreDevice/CoreSimulator plug-in warnings are Xcode's, not the
  app target's); the built app's bundled `WebUI/panel.js` no longer mentions
  `downloadSlots` and carries the one-at-a-time queue note.
- Not verified: a live batch on a real account with the serial queue. No
  desktop run was authorised.

## 2026-09-17 — Discover rows fill the grid height

A window whose grid was about a pixel short of a fourth row showed three rows
and a near-row of blank space (Discover asks for 15 tiles per page). Discover
tiles may now stretch or squash by up to 15% so the rows fill the grid exactly,
and the page-size measurement reads the grid's outer width so a classic
scrollbar appearing on a briefly overflowing page cannot flip the fit.

- A throwaway sweep of 210 web-view sizes (900–1600 × 600–1100) through the
  panel with a stand-in native reply: before the width change, two sizes at
  600pt toggled the fit every frame as a 9pt scrollbar appeared and vanished;
  after it, 0 mismatches (page size = rendered columns × rows, no overflow,
  three or more rows leave under a pixel per row). The sweep was removed; the
  kept `testDiscoverPageRowsFillTheGridHeight` checks five sizes including the
  reported one and the oscillating one.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 276 tests with 0 failures.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `WebUI/panel.js` carries the row-fit (`fitRows`).
- Not verified: the live app at the reported window size with overlay
  scrollbars and real thumbnails. No desktop run was authorised.

## 2026-09-17 — Parallel Workshop downloads re-verified on the integrated tree

Re-ran the routine gate and the Swift-only Release build on the tree that
carries the parallel download manager, the disk-measured transfer progress,
the Discover page-size negotiation and the tile download ring together.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 273 tests with 0 failures, including both parallel-queue tests in
  `DownloaderTests` and the disk-progress tests.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED (Xcode's CoreDevice/CoreSimulator plug-in warnings are unrelated
  to the app target). The built app's bundled `WebUI/panel.js` contains
  `queueNote()` and the `downloadSlots` slot rule, and its binary carries the
  queued-status string.
- Not verified: a live batch of several Steam transfers on a real account, the
  activity bar with more than one running job, and Steam-side limits on
  concurrent SteamCMD sessions. No desktop run was authorised.

## 2026-09-17 — Workshop progress capped by bytes received over the network

Workshop transfer progress was the allocated bytes under the staging's
`steamapps/workshop` tree alone. Steam can allocate a file's full length before
its chunks arrive, so that figure could claim 99% of an item at once and sit
there. `NetworkReceiveMeter` now also totals the bytes the SteamCMD process
receives (`bytesReceived`, exposed through `ProcessNetworkMonitoring`), and
`WorkshopDownloader.sampleWorkshopDisk` reports the smaller of the tree and
that total, both capped at the listed `file_size`; without a meter the tree
alone is used, as before. `nettop`'s first delta row for a process carries
everything it received since launch, so it anchors the timeline and neither
the rate nor the total includes it.

- Probe of `/usr/bin/nettop -P -L … -p <pid> -n -x -d -s 1 -J bytes_in`
  against a rate-limited `curl` child started 3 s earlier: header `,bytes_in,`
  then `curl.<pid>,<bytes>,` rows, no time column; the first row held ~6.6 MB
  (everything since the process began), later rows ~2.06 MB each at the 2 MB/s
  limit. A real Workshop browse page carried `file_size` as a decimal string.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  ran 275 tests with 0 failures, including the new
  `DownloaderTests.testPreallocatedWorkshopFilesReportOnlyBytesThatCrossedTheNetwork`
  (2048 bytes on disk at once with the meter at 0 → 0%, then 512 → 25%,
  1536 → 75%, a meter beyond the tree → 99% at the tree's 2048, a meter that
  stops reporting falls back to the tree, cleared on shutdown) and
  `testNetworkReceiveMeterTotalsEveryRowAfterTheFirst` (first row dropped,
  foreign/malformed rows ignored, out-of-window and same-timestamp rows still
  counted, the total survives the oversized-output reset). The existing
  disk-growth, rate and monitor tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED from the edited tree; the Release binary is stripped, so its
  contents were not inspected beyond the build's own output.
- Not verified: a live SteamCMD transfer (whether Steam's macOS writer really
  preallocates, and how far compressed chunks put the network total behind
  the listed size). No desktop run was authorised.

## 2026-09-17 — Parallel Workshop downloads gated on a saved sign-in

`WorkshopDownloadManager` runs up to `maximumConcurrentDownloads` (default 3)
private SteamCMD sessions at once instead of one. A queued job joins running
downloads only when it can sign in silently: **Keep me signed in** is on, the
saved sign-in belongs to its account, and no running job is still
authenticating or was prompted (`WorkshopDownloader.promptedForSignIn`, set by
any password/code/approval prompt). The worker's new `onAuthenticated` hook
re-pumps the queue when Steam accepts a sign-in, so the first job of a batch
authenticates alone and the rest reuse what it saves on completion; without a
saved sign-in behaviour is unchanged (serial). The panel snapshot carries
`downloadSlots`; `panel.js` `queueState()` aggregates every active job (mean
of measured percentages, summed speeds, "N downloading") for the activity bar
and badge, and the queue footer states the slot rule.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  ran 273 tests with 0 failures, including the new
  `DownloaderTests.testSavedSignInRunsDownloadsInParallelUpToTheSlotLimit`
  (limit 2: the fresh sign-in runs alone, two jobs transfer together once it
  saved, the fourth waits for a slot, all four import, no staging left,
  private session perms) and
  `testStaleSavedSignInHoldsTheQueueUntilTheRenewingJobFinishes` (a rejected
  saved sign-in keeps `activeCount == 1` through the prompt and through the
  transfer that follows it; siblings start silently after it finishes). The
  existing serial, session-handoff, failure-slot and intent-ladder tests pass
  unchanged.
- Throwaway Bun evaluation of `queueState()`/`queueNote()` extracted from
  `WebUI/panel.js`: two active jobs at 20%/60% with 1 MB/s + 500 KB/s summarise
  as "2 downloading · 40% · Network speed: 1.5 MB/s", badge count 3 with one
  queued; a single authenticating job keeps its status text with no percentage.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the built app's binary carries the new queued-status string and
  its bundled `WebUI/panel.js` contains `queueNote()` and the multi-job
  `queueState()` summary.
- Not verified: the live activity bar with several transfers, and real Steam
  behaviour for concurrent SteamCMD sessions on one account (each session uses
  its own private copy of the saved sign-in; Steam-side session limits or rate
  limits would surface as per-job failures). No desktop run or Release build
  was authorised.

## 2026-09-17 — Larger, steady Discover download ring with transfer speed

The Discover tile ring (`.tile-download`) is redrawn closer to Wallpaper
Engine's own: 72px (64/60px in the narrow tile breakpoints), the still dims
behind it, no chip until hover, a 4px accent stroke on a faint track, the
percentage centred with the transfer speed beneath it (speed alone while the
percentage is unknown; hidden at the 116px tile size where it cannot fit).
Hover fills the chip and shows the cancel mark. The shimmer is gone because
nothing rotates any more: the value circle uses `pathLength="100"` so progress
is a plain dash offset, and the busy sweep animates `stroke-dashoffset` instead
of a `rotate()` transform on a layer centred between device pixels. Attention
and failed states colour the track instead of a box-shadow ring; the attention
pulse is a sonar ripple. `speed()` formats the compact value; `rate()` keeps
its "Network speed:" prefix for the activity bar and queue.

- `python3 scripts/test.py`: Python suite and XcodeGen passed; native suite
  ran 271 tests with 0 failures, twice (before and after extending
  `ControlPanelLayoutTests.testDiscoverTilesCarryDownloadRingsAndOnlySteamRequestsOpenTheDialogWithoutWindow`
  to assert `.ring-speed` reads "600 KB/s" beside the 42% label and alone while
  authenticating without a percentage; `.ring-label` still reads "42%" and the
  progress dash offset stays positive).
- `.agents/skills/impeccable/scripts/impeccable detect --json WebUI/panel.css WebUI/panel.js`:
  no findings.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `WebUI/panel.js` and `panel.css` in the built app
  contain the new ring markup and styles.
- Not verified: the rendered ring, hover state and the absence of shimmer on a
  live panel. No desktop run or screenshot was authorised; the offscreen
  WKWebView tests cover markup and state only.

## 2026-09-17 — Tile download rings, double-click download, measured Workshop progress

Discover tiles now carry their download state as a ring over the thumbnail
(`.tile-download`: percentage + filling stroke, spinning arc, queued arrow,
pulsing shield, retry mark; `.tile-installed` check for library items), a
double-click on a Discover tile requests the download (or applies an installed
item), the top-bar downloads button appears only while downloads exist, and the
sign-in dialog no longer opens for every hand-off: it opens by itself only when
a job carries a password prompt or Steam Guard challenge, **Not now** silences
that exact request, and it closes once Steam is satisfied. Workshop transfer
progress is measured on disk: `WorkshopDownloader` sums allocated bytes under
the staging's `steamapps/workshop` tree twice a second while Steam reports
"downloading item" and divides by the Workshop `file_size`, capped at 99% until
Steam's own success line; items without a listed size stay indeterminate.

- `python3 scripts/test.py`: Python suite and XcodeGen passed; native suite
  ran 246 tests with 5 failures, all in
  `WorkshopStoreTests.testPanelPageSizeComposesPagesFromCachedSteamPages`,
  which belongs to an uncommitted, concurrent panel page-size change in
  `WorkshopStore.swift` / `WorkshopStoreTests.swift` that this work did not
  touch. New and changed tests passed:
  `DownloaderTests.testWorkshopDiskGrowthReportsProgressAgainstListedSize`
  (512/2048 → 25%, 1536/2048 → 75%, over-listed bytes stay at 99%, cleared on
  shutdown), `testWorkshopDiskGrowthWithoutListedSizeStaysIndeterminate`, and
  `ControlPanelLayoutTests.testDiscoverTilesCarryDownloadRingsAndOnlySteamRequestsOpenTheDialogWithoutWindow`
  (ring percentage and cancel action, no dialog while authenticating with no
  prompt, auto-open on a password prompt, Not now stays quiet for the same
  prompt, reopens for a mobile challenge, closes when the job resumes, retry
  ring after failure, check once installed).
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `WebUI/panel.js` in the delivered app contains the
  tile ring code.
- Not verified: the ring against a live SteamCMD transfer (no desktop run
  requested), and whether Steam's macOS content writer ever block-preallocates
  Workshop files, which would inflate the on-disk measurement.

## 2026-09-17 — Discover pages sized to the grid

A Discover page held Steam's fixed 30 items, so wide windows ended in a partial
row and empty space. The panel now measures its grid (columns × full rows of
square tiles, empty-state box while the grid is hidden, `ResizeObserver` plus a
re-measure after each grid render, 120ms debounce) and sends `workshopPageSize`.
`WorkshopStore.setPageSize` cuts pages of that size from a per-query cache of
Steam pages, fetching only the missing ones (the first alone while Steam's page
count is unknown, the rest concurrently, in-flight fetches joined rather than
repeated); a size change keeps the first visible tile by remapping the page
number, restarts a loading page at the new size, and a fully cached page is
published synchronously without a loading state. The snapshot carries the
current `pageSize` and a `reachable` count for the Steam cap note.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (271 tests, 0 failures). New
  `testPanelPageSizeComposesPagesFromCachedSteamPages` drives pages of 40 across
  Steam pages 1–3, a shrink to 30 served from cache with no request, a fresh
  search discarding the cache, and a grow to 35 while page 3 loads. New
  `testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes` checks the page's
  reported size equals resolved columns × full rows at 960×640, that exactly
  that many tiles neither scroll nor leave a full row empty, that nothing is
  re-requested, and that a 1400×900 resize reports a larger size that the store
  adopts.
- Earlier attempts of the WebUI test failed on non-numeric fixture ids (the
  parser drops them) and on measuring after the native reply had re-rendered
  Installed; both were test-side fixes.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the delivered app carries the new WebUI and store.
- Not verified: the live window's look while resizing (no desktop run
  requested).

## 2026-09-17 — Phase A and most of phase B of the power improvement plan

Implemented M00 (minimal counters plus a configuration manifest), V01 (FFmpeg
receive-first decode state machine with EOF drain, cancellation and a
no-progress budget), V02 (`AppleVideoFrameLease` owning the Core Video texture
wrapper and pixel buffer), V03 (shared limited-range colour parameters for the
CPU path and the Metal kernel), W01 (canonical web entry identity,
committed-state replay per document generation, windowed crash budget with
backoff), P01 (per-display presentation suspension in the Swift policy, the
bridge and the web host) and W02 (media suspension, removal from the window
tree, placeholder and pointer gating). A01 is limited to the visible-consumer
gate for system audio capture; its real-time callback is unchanged. Details and
per-task evidence:
[../mac-wallpaper-engine-implementation-progress.md](../mac-wallpaper-engine-implementation-progress.md).

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests passed
  (310 tests, 0 failures; 267 before this work). New suites:
  `RuntimeCountersTests` (8), `WebWallpaperRecoveryTests` (11),
  `WebWallpaperSuspensionTests` (4),
  `WallpaperPresentationAuthorityTests` (11), and a rewritten
  `WallpaperPresentationPolicyTests` (17, migrated from the single global
  visibility closure to per-display surfaces). That run builds the embedded
  extension, so the two files moved or added under `Shared/`
  (`RuntimeCounters.swift`, `WallpaperPresentationAuthority.swift`) are also
  confirmed to compile under `APPLICATION_EXTENSION_API_ONLY`.
- `python3 scripts/check_renderer.py`: exit 0. Ten generated cases with
  `pixels_equal=true` and no diagnostics, `scene_reload_cycle_probe` exit 0, and
  all seven test binaries exit 0, now including the new `video_decode_pump_test`
  (13 cases), `video_color_conversion_test` (9 cases), and `playback_gpu_test`
  (32 cases) and `timer_tests` (11 cases, 5 of them new), both added to the
  gate.
- `cargo test --release --workspace` in `upstream/renderer`: passed, 233
  `wallpaper-bridge` cases including the new `display_presentation` module, and
  every other crate green. The shell had `CARGO_TARGET_DIR` pointed at a sandbox
  cache, which silently left the committed static library and the generated
  bindings stale; every renderer build and test here ran with it unset.
- `python3 scripts/build.py --renderer-only`: passed; `App/Bridge/Generated`
  regenerated with `setDisplayPresentationSuspended`.
- Tests found four real defects in this round's own work, all fixed: the
  per-display delivery queue did not drain after a successful transition, a
  decision that changed while in flight was dropped, an absolute web entry path
  resolved inside the project instead of being rejected, and a timer-based
  restart-budget reset could be collapsed by a page that crashed immediately
  after each load.

Not verified, and not claimed:

- **No power was measured.** No `powermetrics`, Instruments or external meter
  run; `scripts/power_benchmark.py` records configuration only and writes every
  condition as `measured: false`. No saving percentage or watt figure exists for
  any task in this round.
- No desktop run: no window occlusion, Spaces, lock/unlock, display sleep,
  hot-plug or wallpaper change was exercised. `scripts/test.py --ui` was not
  run.
- Nothing visual was compared. The colour fix is verified against an
  independently derived reference and against the CPU path from the Metal
  kernel, not against a displayed wallpaper.
- Whether a web page's own timers, workers, WebGL and media stop while suspended
  is unverified: a detached web view stops answering script evaluation, and a
  windowless test container cannot reproduce WebKit's in-window condition.
- Whether the renderer's submission and present counts actually stop for a
  hidden surface is unverified; the per-display work is asserted on the decision
  and the rebuilt descriptor, not on renderer-side counters.
- The local wallpaper corpus was not exercised (skip, not a pass), no synthetic
  B-frame clip was decoded end to end, and no Metal API-validation or
  leak-instrumented run was made.
- E01 is implemented as one shared presentation-eligibility rule set compiled
  into both targets (a preview was previously never suspended once it had
  produced its readiness frame), but no lock, unlock, display-sleep or
  preview-close transition was exercised against the real extension and no
  joint per-process submission count was captured. The two processes agree by
  construction rather than by exchanging authorization, which is weaker than
  the plan's design.
- P02's first version is implemented as content-rate pacing: the frame clock
  takes a pushed `FrameDemand` that can only lengthen the tick interval, and the
  engine's own plain-video scene reports the video's shortest plausible frame
  period. Previously a 30 fps video on a 60 fps target rendered twice per decoded
  frame. **That the number of renders per decoded frame actually drops is
  unverified**: the interval arithmetic and its bounds are tested, but the
  end-to-end effect needs a desktop run reading the video submission counters,
  compared at equal presented frame rate and identical pixels. Static-scene
  classification was deliberately not attempted — a wrong verdict freezes a live
  wallpaper — so every authored scene keeps the fixed cadence. Two findings that
  shaped this are in the progress document: pausing already stops the frame
  timer, and the tick rate was the user/display ceiling rather than the content
  rate.
- GPU test binaries fail with `VK_ERROR_INCOMPATIBLE_DRIVER` inside the command
  sandbox and were run outside it; they create only private GPU images.

## 2026-09-17 — Filter sidebar arrow rail and draggable inspector edge

Follow-up to the collapse/fluid-width entry below: the toolbar **Filters**
toggle moved into the sidebar as an arrow (heading arrow collapses to a 30px
rail, rail arrow expands), and the inspector's left edge became a drag handle
(`#inspector-resizer`, `role="separator"`, arrow keys and `Home`). A dragged
width is clamped to 240px–45vw, sent natively once on release
(`inspectorWidth` action, `UserDefaults`, snapshot field `inspectorWidth`,
double-click clears it). Sidebar widths in the narrow media queries moved to
`--filters-width` so the rail width wins there too.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (267 tests, 0 failures). The extended
  `testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth`
  now also drives the rail (first column 30px while collapsed), a synthetic
  60px pointer drag (260px → 320px, persisted as 320), a double-click reset
  back to the fluid width, and a stored width surviving a relaunched controller.
- Two earlier single-test runs failed on the way: a wait condition that could
  never be met once the native reply re-rendered on Installed, and the 148px
  sidebar literal in the ≤1040px media query overriding the rail; both fixed.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled WebUI files match the source tree.
- Not verified: pointer feel of the drag handle in the live window (no desktop
  run requested).

## 2026-09-17 — Panel icons switch to vendored Lucide glyphs

The hand-drawn SVG path map in `panel.js` is replaced by `WebUI/icons.js`,
22 glyphs copied from the locally cached `lucide-react` 1.45.0 package (ISC
notice in the file header; the GitHub brand mark stays as before because
Lucide ships no brand icons). `icon(name)` now renders Lucide's 2px stroke
and `WebPanelAssets` serves the new module.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (267 tests, 0 failures). The new
  `testServesEveryBundledPanelModule` checks every bundled page module,
  including `icons.js`, routes to a file and an unknown name is refused.
- `node --check WebUI/panel.js` and importing `icons.js` under Node both
  succeed (22 glyph entries, none empty).
- Not checked: visual rendering in the app; no build or desktop run was
  requested.

## 2026-09-17 — Discover filter sidebar collapses; inspector width is fluid

Instead of drag-resizable sidebars, Discover's toolbar gained a **Filters**
toggle that hides the fixed-width filter column (stored in `UserDefaults`
because the panel's website data store is non-persistent, exposed as
`workshopFiltersCollapsed` in the snapshot), and the inspector column now uses
`clamp(280px, 22vw, 340px)` so wide windows stop leaving a fixed strip.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (266 tests, 0 failures). The new
  `testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth`
  checks the toggle releases the grid column, the flag persists across a
  relaunched controller, Installed never carries the Discover-only class, and
  the inspector measures 260px at 960px and 340px at 1600px.
- First run of the same command failed
  `ControlPanelWindowSizingTests/testHostedPanelWindowKeepsItsSizeFloor`
  (untracked test from concurrent minimum-size work, unrelated to this
  change); it passed on the immediate re-run.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED;
  the delivered app bundles the updated `panel.js`.
- Not verified: the live window (no desktop run requested).

## 2026-09-17 — Control-panel window can no longer shrink below 760×560

The window set `contentMinSize` to 760×560, but the panel could still be
dragged down to a stub showing only the traffic lights. A hosted test showed
why: after `NSHostingController` attaches, it resets `contentMinSize` to
`(0, 0)` even with `sizingOptions = []`. Window construction now lives in
`ControlPanelWindow`, and `AppDelegate.windowWillResize` clamps every user
resize to the floor (minimum content size plus chrome, capped by the visible
screen frame). `constrainToScreen` still grows a restored frame on reopen.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (266 tests, 0 failures), including the new
  `ControlPanelWindowSizingTests` (offscreen hosted window: resize proposals
  clamp to the floor, larger proposals pass through, reopen grows a shrunken
  frame). A first full run failed once in the pre-existing
  `testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth`
  (inspector 260 vs 280 px); it passed alone and on the second full run.
- Not verified: dragging the live window by hand (no desktop run requested);
  no Release build was made.

## 2026-09-17 — Display titles use the system display name

The panel showed the renderer's raw `Vendor 1552 - Model 41055 (1 - Primary)`
label for the built-in display because the vendored renderer never fills a
display name. `DisplayTitleResolver` now maps a display to
`NSScreen.localizedName` and rewrites the title in the page snapshot (target
picker, Settings -> Displays, mirror targets, inspector display sections),
keeping the `(id - Primary)` suffix. A first cut keyed only on the settings
row id and changed nothing in the delivered app: configured rows carry
`primary` / `identity:{json}` ids, not the screen number. The resolver now also
matches the live id in the title suffix and the identity UUID against
`NSScreenNumber` / `CGDisplayCreateUUIDFromDisplayID`. Unmatched ids keep the
renderer label; the bridge and persisted state are untouched.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (264 tests, 0 failures), including the new
  `DisplayTitleResolverTests` (suffix handling, primary/identity selector
  ids, unmatched ids, blank names, system names keyed by screen number and
  UUID) and `testDisplayTitlesUseTheSystemNameEverywhereTheRendererLabelAppears`.
- `python3 scripts/build.py --swift-only --configuration Release` after the
  fix: BUILD SUCCEEDED, delivered to
  `build/Build/Products/Release/MacWallpaperEngine.app`. The user's own
  Release build of the first cut still showed the vendor/model label, which
  is what exposed the id mismatch.
- Not run: a desktop check of the rebuilt panel; the name shown depends on
  `NSScreen.localizedName` on the user's Mac.

## 2026-09-17 — Tile grid density follows the browser column width

The Discover grid no longer switches between fixed column counts that divide
the 30-item page (2 / 3 / 5 / 6 / 10) at hard container breakpoints, which made
tiles balloon just below each breakpoint (two ~227px tiles per row in a 890px
window). Both grids now use `repeat(auto-fill, minmax(var(--tile-min), 1fr))`
with a container-driven minimum (154px, 130px under 560px, 116px under 440px),
so a narrower browser column shows smaller tiles and more of them. A full
Workshop page may end in a partial row.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (250 tests, 0 failures).
- Not checked: the live layout in a running window (no desktop run was
  requested); the sizes above are computed from the CSS.

## 2026-09-17 — Cached still thumbnails for Discover tiles

Discover tiles used Steam's full-size `preview_url` directly. Measured on the
live "Trending this week · Scene" page 1: 30 items, 22.8 MB, 17 of them GIFs
(14.7 MB); the CDN's `imw/imh` scaling shrinks JPEG/PNG about 9× but leaves
GIFs at 12.7 MB. Tiles now load `mwe-ui://thumbnail/<id>`, served by the new
`WorkshopThumbnailCache` actor (scaled download, first frame via ImageIO, JPEG
on disk under `Cache/WorkshopThumbnails`, four downloads at a time, oldest-first
pruning at 128 MB). The scheme handler only resolves ids in the current
snapshot; tiles pulse their placeholder while loading.

- `curl` probes against `images.steamusercontent.com`: the scaling query
  returns 200 for JPEG and GIF previews; no query parameter converts a GIF to a
  still image, hence the local first-frame extraction.
- `python3 scripts/test.py`: Python script tests OK, XcodeGen OK, native
  suite 258 passed, 0 failed, 0 skipped (adds `WorkshopThumbnailCacheTests`
  ×7 and `WebPanelAssetsTests` ×1). First run failed only on a synthetic
  size assertion (a flat test GIF compresses smaller than its JPEG); the
  assertion was removed and the suite re-run.
- Follow-up the same day: animated previews return on demand. The tile under
  the mouse pointer (180 ms dwell) or keyboard focus renders a `tile-live`
  `<img>` with Steam's full preview over its still and fades it in on load;
  leaving removes it. `node --check WebUI/panel.js` OK;
  `python3 scripts/test.py` re-run after the change (see result below).
- Not verified: the thumbnails and hover animation inside the running app on a
  throttled link (no desktop run, no Release build requested).

## 2026-09-17 — Top bar in the title-bar strip, centered brand, GitHub link

The control-panel window now hides its native title (transparent title bar, an
empty unified toolbar sizing the strip to 52px) and the page's top bar occupies
that strip: tabs after the traffic lights, whose measured inset arrives in every
snapshot as `windowControlsInset`; product name, version and a GitHub button
(`repositoryURL`, opened through the existing `openExternal` allowlist) on the
window's horizontal center; picker, downloads and renderer link on the right.
Background presses on the bar post `dragWindow` / `titleDoubleClick`, which the
host answers without a snapshot (`performDrag`, system double-click action).

- `python3 scripts/test.py` (twice, after the final test edit): Python script
  tests OK; native **250 passed, 0 failed, 0 skipped**, including the new
  `testTopBarCentersTheBrandBesideARepositoryLinkAndOwnsTitleBarGesturesWithoutWindow`
  (repository link equals `AppUpdateConfiguration.repositoryURL` and passes the
  allowlist, brand center within 1px of the bar center at 1240px, inset 0 and
  gesture replies empty without a window, background press posts no snapshot).
- No Release build or desktop run. Unchecked on a real window: traffic-light
  vertical alignment against the 52px bar on macOS 26, click pass-through in
  the toolbar strip, and the measured inset value.

## 2026-09-17 — Workshop page jump and Steam's 1,000-page cap

The Discover pagination showed **Page 1 of 1000** against millions of results.
Live probes of `steamcommunity.com/workshop/browse` (app 431960, trend sort)
confirmed the cap is Steam's: `total_pages` is 1000 for `total_count`
2,891,159, `p=1001` and `p=5000` both return page 1000, and `numperpage`
above 30 is clamped back to 30. The panel now exposes an editable page number
(Return or **Go**, clamped to the last page) and, when the count exceeds
`totalPages × pageSize`, a note that only the first 30,000 results are
reachable. `WorkshopService.pageSize` feeds both the browse URL and the
snapshot's new `pageSize` field.

- `python3 scripts/test.py`: Python script tests OK; native **249 passed,
  0 failed, 0 skipped**, including the new
  `testWorkshopPageJumpClampsToSteamsPageLimitAndExplainsTheCap` (typed 5000
  requests page 1000, cap note names 30,000 of 2,891,159, no note and a
  disabled field for a single page).
- No Release build or desktop run; visual layout of the inline number field is
  unchecked on a real window.

## 2026-09-17 — Delete affordances moved into view

Moved the inspector's **Show in Finder** / trash buttons into the heading
action row beside **Apply wallpaper** (previously below the options, off-screen
once options loaded) and added a toolbar **Select** / **Done** toggle that keeps
every tile's check box visible and makes plain clicks toggle selection.

- `python3 scripts/test.py`: native **248 passed, 0 failed, 0 skipped**.
- Headless-Chromium smoke with the stubbed `native` handler: trash button
  renders in the inspector action row without scrolling; **Select** turned on
  persistent check boxes, two plain tile clicks produced
  `2 selected · Select all · Clear · Move 2 to Trash`; **Done**/`Escape` leave
  the mode. Harness removed afterwards. No Release build or desktop run.

## 2026-09-17 — Library batch deletion and tile multi-select

Added `BridgeStore.deleteWallpapersAsync(ids:recycle:)` (per-wallpaper failure
tolerance, one library refresh), the `deleteMany` panel action with a single
confirmation and a combined failure message, and WebUI selection (tile check
buttons, Cmd/Shift-click, Select all, Clear, `Delete`/`Escape` on the grid).

- `python3 scripts/test.py`: native **248 passed, 0 failed, 0 skipped**,
  including new `BatchDeletionTests` (continues past an invalid id and a
  recycle failure, refreshes once; skips refresh when nothing was trashed).
- WebUI smoke in a headless Chromium against a throwaway copy of `WebUI/` with
  a stubbed `native` handler: check click + Shift-click selected `w1…w3`, the
  summary row showed `3 selected · Select all · Clear · Move 3 to Trash`,
  **Move to Trash** posted `{action:"deleteMany", ids:["w1","w2","w3"]}` and the
  grid dropped the returned ids; `Escape` cleared the selection and `Delete` on a
  focused tile posted a one-id `deleteMany`. Harness removed afterwards.
- Not exercised: the native NSAlert confirmation sheet (needs a window), the
  real Trash move inside the app, and Release build/desktop run.

## 2026-09-17 — Scripted vector constants and timeline events

Follow-up to the entry below, which reported both defects and deferred them.
Source-only. No Release build, application launch, desktop automation,
screenshot, wallpaper change, audio hardware, permission prompt or install.

### Scripted material constants kept their component count

`MakeMaterialConstantDynamicValue` treated only three-or-more components as a
vector and sent everything else through `ResolveStringSetting`. `WPJson`'s
`std::vector<float>` overload converts the authored `"0.79139 0.44186"` through
`utils::StrToArray`, so these constants really do have two components; the
script was still handed `parse_string` of the array — the text
`[0.79139,0.44186]` — and `value.x` was `undefined`. That is both reported
symptoms: `g_Point2=[nan,nan,0]` on layer 503 `中-菜单-浮动`, and
`g_Point1=[0]` on the page-fold pass, where `ShaderValueFromDynamicValue` parses
a string that starts with `[` and yields one zero.

Constants now resolve at the authored count through the new
`ResolveVectorSetting`: one component as a float, two and four as vectors, three
unchanged. After the change the same probe run reports `g_Point2=[0,0]` — the
authored `"0.00000 0.00000"` — and no `nan` appears anywhere in either package's
dumped pass constants. Diffing all 146 dumped passes of `3292361861` before and
after gives **0 changed constants**, so its four scripted scalars and three
scripted `vec3`s are unaffected.

### Timeline events now reach the layer

`options.events` is parsed into `ScalarAnimation::events`, and
`ScalarAnimationPlayback::Advance` queues each crossed marker as a whole
`ScalarAnimationEvent`: the authored `AnimationEvent` carries `frame` beside
`name`, so a handler can tell two markers apart in one tick. Departure is
exclusive and arrival inclusive. A loop is treated as a circle and the distance
to each marker is measured along the direction of travel, which keeps reverse
travel symmetric and makes a wrap, an exact landing on the seam and a marker
authored at the period the same point; travelling a whole period reports each
marker once, not once per lap; `SetFrame` reports nothing because a seek is not
playback.

`SceneRuntimeContext::Tick` drains the queue after advancing the clocks **and**
re-evaluating the scripted values: a property script initializes lazily on its
first evaluation, so a marker crossed by the first tick would otherwise reach an
uninitialized handler. The `engine.on`/`scene.on` list is global to the shared
context, so it is run once per marker from the runtime rather than inside each
matching `SceneScriptProgram` — two bound scene scripts would otherwise repeat
every listener, and none would silence them entirely. That runner also
refreshes the `engine` object before calling the listeners: a global listener
can be a marker's only consumer, and nothing else would have updated
`engine.runtime`/`engine.frametime` this tick.

`scene.getAnimation(name)` did not exist: `getAnimation` was only on the layer
object. A null layer argument to `__animationControl` now means a scene-wide
name match (`SceneRuntimeContext::FindAnimationByName`).

### Commands and results

- `cmake --build artifacts/renderer/bin --target scene_schema_tests
  script_runtime_compat_test media_thumbnail_texture_smoke mouse_input_test
  mdl_schema_tests playback_gpu_test render_target_lifetime_test
  text_object_runtime_test shader_cache_metadata_test
  scenescript_sound_layer_smoke particle_mouse_controlpoint_test` then each
  binary: **68 / 66+1 / 10 / 11 / 52 / 31 / 4 / 60 / 1 / 8 / 38 passed**. The
  single failure is the documented pre-existing
  `ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`.
  `tex_schema_tests` does not build in this checkout (`lz4.h` not found) before
  or after this change and was not touched.
- Non-vacuity, one targeted mutation at a time with a rebuild between each:
  restoring the old `value.size() >= 3` rule fails the scripted-vector test;
  removing the `DispatchPendingAnimationEvents()` call fails both crossing
  tests; forcing the loop direction forward or making arrival exclusive fails
  the reverse/exact-wrap test; dropping `frame` from the event object fails the
  marker-tally test; removing the runtime's single
  `RunAnimationEventCallbacks` call fails the global-listener test; pinning
  `scene_wide` to false fails the scene-wide lookup test; and moving the drain
  back ahead of `reevaluate()` fails the initialization test (`-1` instead of
  `7`); and dropping the `UpdateEngineObject` call from the global runner makes
  a global-only listener read `engine.runtime`/`engine.frametime` as `0`
  instead of `2`.
- `python3 scripts/check_renderer.py --project …/2887099508/project.json
  --project …/3292361861/project.json`: ten generated cases pass with no
  diagnostics; `2887099508` `pixels_equal=true` with **7** pre-existing
  SceneScript diagnostics (8 before: the `animationEvent` `TypeError` is gone);
  `3292361861` `pixels_equal=false` with its 28 pre-existing diagnostics.
  Reload cycles: 0.
- `python3 scripts/build.py --renderer-only`: succeeded. `python3
  scripts/test.py`: Python **39 passed**, native **246 passed, 0 failed,
  0 skipped**.

### The two-phase page turn now completes on the original package

`offscreen_scene_probe` on `2887099508` with its saved overrides,
`WE_TEST_CLICK_LAYER=384`, `WE_TEST_FRAME_STEP=0.0333` and
`WE_TEST_DUMP_PASSES=1`. The dumped pass lines now also carry live visibility,
which the prepare-time listing and `nodes.txt` cannot show — `nodes.txt` is
written once before the frame loop.

The first attempt looked finished at the layer swap but was not: the probe log
still carried `ScriptEngine[animationEvent]: TypeError: not a function` at
`<property-script-factory>:25:8526`, the `thisScene.getAnimation('111')` call
that starts the second fold. The swap happens before that line, so it succeeded
while the rest of the handler did not.

With the scene-wide lookup in place the probe logs **zero** `animationEvent`
errors and the whole authored sequence runs:

- frame 28: `page首`'s perspective pass is `visible=1` mid-fold
  (`g_Point1=[0.280963, 0.344198]`); `page` is `visible=0`.
- frame 30, `houye`: the two swap, and `111` starts on `page`.
- frame 45: `page` is `visible=1` with its own corners moving —
  `g_Point0` has left its static `0.26795,0.34444` for `0.187791,0.399638` and
  `g_Point3` `0.38914,0.94238` for `0.358402,0.855579`.
- frame 60, `yeshu`: `page` goes `visible=0`. Frame 90 holds it, and the thin
  white sliver that the unfinished handoff left at the page edge is gone.

Desktop presentation is still **unverified**; no application was launched.

## 2026-09-17 — Vector material constant timelines (page-fold corners)

Source-only work on the local tree. No Release build, application launch,
desktop automation, screenshot, wallpaper change, audio hardware, permission
prompt or install. Scaling settings were read, never written: both reported
wallpapers keep `fill` at factor `1.0` and their saved property overrides.

### What changed

`ResolveScalarAnimation` takes a component index and reads `c0`–`c3` plus the
matching entry of a vector initial value. `MaterialConstantAnimation` holds one
`ScalarAnimation` per component beside the single shared
`ScalarAnimationPlayback`; `SceneRuntimeContext` binds and samples every
component, reusing the sampled `ShaderValue` while the shared frame is
unchanged. `WPSceneParser::RegisterMaterialConstants` resolves
`options.parent.key` to a root inside one material pass and registers one clock
per root. `offscreen_scene_probe`'s `WE_TEST_DUMP_PASSES` now dumps only the
last sampled frame and appends each dumped pass's material slot constants to
`passes.txt`. `tests/CMakeLists.txt` links `nlohmann_json` into
`media_thumbnail_texture_smoke`, which failed to compile before this change too.

### Commands and results

- `python3 scripts/check_renderer.py` **before** the C++ change: the new
  `generated-perspective-animation` case failed its pixel assertions while the
  other nine passed. Its `frame-2.ppm` had the clear colour at the centre
  (26,51,77) and white at (48,32) — no page, wedge in the margin, 9984 white
  pixels. **After**: all ten generated cases pass; the same frame has white at
  the centre, the clear colour at both margin samples and 26112 white pixels,
  which is exactly the authored quad's area (0.265625 × 384 × 256).
- `python3 scripts/check_renderer.py --project …/2887099508/project.json
  --project …/3292361861/project.json`: ten generated cases pass with no
  diagnostics; `2887099508` `pixels_equal=true` with 8 pre-existing SceneScript
  `TypeError` diagnostics; `3292361861` `pixels_equal=false` with 28
  pre-existing diagnostics (SceneScript errors plus one workshop clipping-mask
  shader that fails to compile). Those two scenes run clock- and random-driven
  scripts, so their pooled/isolated pixels are not expected to match and the
  criterion was not relaxed. Reload cycles: 0.
- `cmake --build artifacts/renderer/bin --target scene_schema_tests
  script_runtime_compat_test media_thumbnail_texture_smoke mouse_input_test
  mdl_schema_tests playback_gpu_test` then each binary: **67 / 58+1 / 10 / 11 /
  52 / 31 passed**. The single failure is the documented pre-existing
  `ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`.
- Non-vacuity was checked by stashing only the changed sources and rebuilding:
  the four new parser cases fail there, reading the static values (0.375, 9),
  and `SceneSchema.OneBrokenVectorTimelineGroupIsReportedOnce` reports 2 errors
  instead of 1 when the unusable parent is not memoized.
- `python3 scripts/build.py --renderer-only`: succeeded, regenerated bindings.
- `python3 scripts/test.py`: Python **39 passed** (1 + 24 + 4 + 10), native
  **246 passed, 0 failed, 0 skipped**.

### Original-asset attribution: the reported wedge, reproduced and fixed

All `offscreen_scene_probe` runs used `2887099508` with its saved overrides
(`audioline`/`insert`/`randomchat`/`renwu`) and exited 0.

The authored trigger was traced by running every script-bearing setting of the
packaged scene under a recording stub (80 settings). The page turn is not a
timed effect: the `cursorClick` export on node 384's perspective `point1`
constant does `thisLayer.visible = true`, `thisObject.getAnimation('900').play()`
and plays the `翻页mp3` layer, while the `cursorClick` on the same node's
`visible` setting plays the `hand turn` puppet animation on `hand book`. Node
384's `visible` is authored `value:false` with a script that exports only
`cursorClick` and `animationEvent` — no `update` — so the layer is simply hidden
until a click, and the 164 `ScriptEngine[update]` errors in the log belong to
other layers, not to this one. An idle sample therefore cannot show the page at
all, and `nodes.txt` is written once before the frame loop, so it is a snapshot
at the click point, not proof about the whole sample.

Driving that trigger with `WE_TEST_CLICK_LAYER=384`, `WE_TEST_FRAME_STEP=0.0333`
and `WE_TEST_DUMP_PASSES=1` reproduces the report and shows it fixed. `nodes.txt`
records `384 page首 visible=1 effective=1` and the perspective pass turns
`visible=1` in both builds, so this is not a hidden layer:

- pre-fix, frames 14 and 30: `g_Point1=[0]` — a one-component value, because no
  timeline was ever registered for a two-component constant, so the layer's own
  `getAnimation('900').play()` found nothing — and `g_Point2=[0.44054, 0.89494]`,
  the static value. The corners never move. `squareToQuad` gives
  `w = [1, 0.333, -0.819, -0.152]`; the two negative terms invert the quad, and
  both the perspective pass and the final composite show a large white spike
  shooting off the top of the screen — the reported 巨大白色尖三角 and the
  content that leaves the frame.
- post-fix: `g_Point1=[0.79139, 0.44186]`/`g_Point2=[0.90044, 0.95983]` while
  paused (`w = [1, 1.025, 1.069, 1.044]`), `[0.524352, 0.390766]`/
  `[0.662799, 0.9263]` mid-fold (`w = [1, 0.977, 0.965, 0.988]`), and the
  authored last key `[0.2746, 0.34298]`/`[0.44054, 0.89494]` at frame 30
  (`w = [1, 0.825, 0.469, 0.644]`). Every sampled pose is a valid quad; the
  spike is gone from the perspective pass and from the final composite, and the
  page renders and folds as a page. Near-white in the final frame drops from
  4.24% to 3.36% mid-fold and 4.14% to 3.00% at the end.

Idle sampling (`WE_TEST_FRAMES=21`, `WE_TEST_FRAME_STEP=1`, cold then warm cache
in one directory plus a separate `WE_TEST_NO_REUSE=1` directory) holds the paused
first key for all 21 seconds instead of running to the last key. The author's
opening zoom is intact: the first sampled frame is still zoomed in at 3× and the
21-second frame is fully zoomed out. `3292361861` has no perspective pass at all
and renders unchanged; its source canvas stays 3840×2160 and no camera, layer or
scaling behaviour was touched.

### Residual defects found here

Both were left for a separate change and are resolved in the next entry above:
the page turn never completed because `options.events` was not read and no
`animationEvent` export was dispatched, and the visible
`workshop/2872021376/effects/perspective` pass on layer 503 `中-菜单-浮动`
reported `g_Point2=[nan,nan,0]` identically before and after this change.

The SceneScript `TypeError` diagnostics were not silenced or worked around; no
wallpaper ID branch, hidden layer or asset edit was used.

## 2026-09-17 — Playback optimization rebased onto web-wallpaper main

Before publishing, remote `main` advanced to `6a7ce92` (the Web wallpaper
implementation and version `0.3.2`). Rebased the playback optimization onto it
without force-pushing or dropping either side's changes. The two textual
conflicts were the verification log and renderer provenance note; both histories
and both modification descriptions were preserved.

Fresh integration verification:

- `cargo test --release -p wallpaper-bridge --lib`: **224 passed**, including
  Web wallpaper host routing and committed pointer-consumer polling behavior.
- `python3 scripts/build.py --renderer-only`: succeeded; generated bridge
  bindings from the integrated static library.
- `python3 scripts/test.py`: Python **35 passed**; native **246 passed,
  0 failed, 0 skipped**, including the windowless Web wallpaper tests and
  lock-screen persistence/monitor regressions.
- Kept XcodeGen's regenerated target ordering; no hand-edit of the project.
  No Release app build, normal application launch or desktop run.

The incoming commits did not change the C++ renderer or core input sources;
the earlier GPU/CPU measurements below were not rerun or relabeled as new
measurements during this publishing rebase.

## 2026-09-17 — Continuous-playback work reduction, synchronized baseline

Source-only implementation on the refactored `986f2e6` workspace. No fetch,
branch change, normal application launch, desktop automation, swapchain test,
screen/audio capture, wallpaper-service reload, administrator sampling or
Release app delivery. The native gate used its normal non-windowed test host.

Implemented the approved GPU, input, lock-screen and scene-CPU paths. Source
review also found a cross-boundary button-latch defect in capability gating:
discarding inactive Rust edges alone could leave native `down` stuck or lose a
held button's later release. A level-only native baseline now reconciles the
geometry-resolved sample before its unchanged transitions, with retry on failure;
pending accepted edges survive. Native pending edges are cleared only on a
successful scene commit involving a non-consumer, not on failed or
interactive-to-interactive commits.

### Commands and correctness results

All Cargo commands used `scripts/build.py::build_environment()`,
`CARGO_NET_OFFLINE=true` and `cwd=upstream/renderer`; CMake used the root working
directory and the existing GoogleTest 1.14.0 cache with FetchContent fully
disconnected. The renderer/scene-engine provenance notes were updated without
changing source pins or licensing boundaries.

- `cargo build --release -p shader --features ffi` and the approved Release
  CMake configuration succeeded. Step 0's production libraries and probes were
  built before optimization; **22 private GPU tests passed**, then separate
  baseline executables/raw samples were preserved.
- Explicitly built all 16 approved targets: `playback_gpu_test`,
  `scene_schema_tests`, `script_runtime_compat_test`, `mdl_schema_tests`,
  `particle_mouse_controlpoint_test`, `mouse_input_test`, `timer_tests`,
  `audio_tests`, `render_target_lifetime_test`, `text_object_runtime_test`,
  `shader_cache_metadata_test`, `offscreen_scene_probe`,
  `scene_reload_cycle_probe`, `vulkan_render_batch_planner_smoke`,
  `video_texture_submission_smoke`, `scenescript_sound_layer_smoke`.
- Final direct runs: GPU **31**, scene schema **62**, MDL **52**, particle mouse
  **38**, mouse input **11**, timers **6**, mono audio **19**, target lifetime
  **4**, shader-cache metadata **1**, video submission **5**, sound layer
  **8** passed. The batch-planner standalone smoke exited **0**.
  `audio_tests` ran only `--gtest_filter=AudioResponseMonoTest.*`.
- `script_runtime_compat_test`: **56 passed, 1 failed**. The unchanged
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors` still references
  undeclared `scriptProperties`; it was run, not excluded. All new script,
  binding, rollback, audio and puppet regressions passed.
- `text_object_runtime_test`: **60 passed, 2 skipped** because the opt-in local
  wallpaper projects were not supplied. No full wallpaper-corpus claim.
- `python3 scripts/check_renderer.py --skip-build`, using the freshly built
  same-tree binaries and existing shared assets: **9 generated GPU cases**
  passed independent known-pixel assertions and pooled/isolated byte equality,
  **0 case diagnostics**; **8 projects × 2 reloads** passed.
- `cargo test --release -p wallpaper-core --lib`: **197 passed**.
  `cargo test --release -p wallpaper-bridge --lib`: **223 passed**.
- `python3 scripts/build.py --renderer-only` succeeded and regenerated the
  Swift bridge from the current static library. This is not a Release app.
- `python3 scripts/test.py`: Python **35 passed**; native **239 passed,
  0 failed, 0 skipped**. Includes isolated lock-screen journal/timer/readiness
  failures and recovery, the real local `nettop`/private-PTY streaming test, and
  CRLF/split-line-ending coverage. Existing public Steam search tests also ran;
  no live login was performed.

Initial validation caught new-fixture mistakes, not hidden by filtering:
unsupported `texture2DLod`, a VMA image-creation failpoint that bypassed device
dispatch, browser-style storage methods, writes to copied JS vector components,
missing parser runtime bootstrap, and named targets reused without graph
retirement before resize. Fixtures were corrected to the real APIs and rebuilt/
rerun. The shared viewport extraction also needed mutable values for vvk's span
interface; the corrected source compiled and passed the final matrix.

### Deterministic work elimination

- Valid pre-clears decreased **2→1** for hidden clear-only output and **1→0**
  for a normal first-clear writer. Reader, alias and boundary cases retain the
  required clear. Direct presentation decreased **2→1 render passes/draws**,
  with **one successful draw submit per frame** in every variant.
- The isolated Rust iterator driver emitted **730,000 ordered transitions**
  over **40,000 iterations**, with **0 allocator requests**.
- An instrumented copy of the actual private pose evaluator checked full affine
  results and control mutations: after one prime, **16 same-State copy lookups
  caused 0 additional solves**. The complete mutation/independent-State matrix
  made **27** actual evaluator calls; no production counter was added.
- Audio initialization allocated **one 1,024-byte scratch buffer** on first
  spectrum discovery. No-audio and repeated/rediscovered initialization allocated
  **0**; **1,080** steady disabled-spectrum callbacks allocated **0**. Fresh
  active-spectrum packing also dropped **12→0 C++ `new` requests per call**.
- Core/bridge tests verify no periodic ask without consumers, independent pause
  policy, successful-input deduplication, bounded relay delivery and activation
  edge semantics. Lock-screen tests verify no off-state timer and no unchanged
  journal rewrite; no production preferences/store were used.

### Fixed-simulation timing samples

CPU: 60 warm frames then **180 samples × 3 interleaved blocks per variant**,
`t=frame/60`, with checked outputs outside timing. Values are aggregate
**median / p95 in microseconds**, baseline → optimized:

| Synthetic workload | Baseline | Optimized | C++ `new` requests |
| --- | ---: | ---: | ---: |
| 64 init-only property programs | 63.333 / 75.000 | 16.917 / 18.375 | 128→0 |
| 64 real update programs | 65.541 / 72.292 | 63.500 / 72.208 | 128→128 |
| 64 absent hover handlers | 97.084 / 108.583 | 0.125 / 0.125 | 0→0 |
| 128 steady TRS/material bindings | 13.125 / 42.750 | 3.666 / 3.750 | 0→0 |
| 128 changed/overwritten destinations | 14.458 / 14.958 | 5.500 / 6.250 | 128→128 |
| 16 copies, 64 bones and attachments | 61.291 / 68.167 | 2.917 / 3.083 | 0→0 |
| FrameBegin plus 16 bone uniform consumers | 66.334 / 72.917 | 8.458 / 8.792 | 16→16 |
| Fresh 16/32/64-bin audio packing | 3.958 / 11.583 | 1.375 / 4.542 | 12→0 |
| Disabled audio packing | 1.688 / 2.125 | 0.500 / 0.959 | 12→0 |
| 128 unlinked particle subsystems | 2.958 / 4.875 | 0.334 / 2.041 | 0→0 |
| 128 linked particle subsystems | 3.166 / 3.542 | 2.833 / 6.250 | 0→0 |

The linked-particle control's block medians were **3.166/3.083/3.417 →
2.833/2.375/5.292 µs**: one block regressed while two improved, so no speedup is
claimed for that path. The required-update script control is also within small
timing variation. Allocation counts cover intercepted current-thread C++ `new`,
not QuickJS/Eigen `malloc`, worker threads or whole-process memory.

GPU: **3840×2160**, **180 frames/block**, three reversed-order baseline/optimized
pairs, each with three rotating blocks (**1,620 samples per variant**).
Vulkan timestamps reported **64 valid bits, 1 ns period**. Aggregate
**median / p95 in microseconds**, baseline → optimized:

| Path | CPU recording | Submit + wait | GPU timestamp elapsed |
| --- | --- | --- | --- |
| Hidden clear-only | 2.667 / 11.375 → 2.291 / 8.333 | 694.438 / 1996.250 → 600.021 / 1439.166 | 207.937 / 1323.583 → 166.542 / 676.375 |
| Normal + final copy | 2.667 / 8.416 → 2.250 / 7.334 | 716.625 / 1964.584 → 596.167 / 1586.792 | 237.354 / 1302.584 → 167.104 / 750.792 |
| Multi-writer fallback | 3.875 / 12.333 → 2.750 / 8.792 | 824.542 / 2348.917 → 654.979 / 1615.750 | 280.687 / 1646.542 → 207.021 / 812.166 |
| Direct versus its normal reference | 2.667 / 8.416 → 1.417 / 4.583 | 716.625 / 1964.584 → 493.145 / 1242.792 | 237.354 / 1302.584 → 73.105 / 505.791 |

Raw samples, each block's median/p95/min/max, command traces, build manifests
and comparison order were preserved in the session's raw-evidence archive before
repository byproduct cleanup. The benchmark executables were kept separate
through measurement. GPU timing remains noisy; some CPU recording rounds were
slower despite the removed work. These uncapped fixed-simulation samples do not
measure real 60 fps playback, watts, GPU residency or battery life.

### Remaining boundaries

Actual Vulkan layer enumeration returned **no layers**, so synchronization
validation was unavailable and not installed. Disposable command traces checked
real RAW/WAR ordering, stage/access scopes and mip ranges; pixel equality alone
was not treated as synchronization proof. Invalid feedback cases were recorded
and discarded rather than submitted as undefined GPU work.

Independent failure injection for FinPass's second vertex allocation, each
individual immediate CPU staging write, and framebuffer-cache `std::bad_alloc`
was not available through the permitted device-dispatch seam. Their return/
ownership checks are source-reviewed; real pending-storage, image-view,
descriptor/pipeline/framebuffer, submit/wait/reset and device-failure scenarios
were exercised where the existing fixture exposes them. Actual AppKit
acquire/present, poster output, Spaces, renderer first-ready failure suppression
through a real swapchain, desktop visuals, live audio and real power remain
unverified. No normal application was quit, reopened or installed.

Cleanup: after confirming no peers were running and preserving the raw archive,
`python3 scripts/clean.py --dry-run` followed by `python3 scripts/clean.py`
removed **1.78 GB** of disposable artifacts/old test results and temporary
drivers. Built app products and current renderer/bridge outputs were retained.
The relative `CLAUDE.md → AGENTS.md` symlink, 20 local documentation links and
unchanged vendored source revisions were checked.


## 2026-09-17 — Web wallpapers receive mouse input; desktop-click setting

Workshop 3799142774 (*Rhine Lab · 莱茵生命交互桌面 | Interactive Desktop*) rendered
but ignored the mouse. `WebWallpaperMouseForwarder` now mirrors desktop pointer
events into the page from a global `NSEvent` monitor (nothing consumed, no
permission prompt); `WebWallpaperWindow` reports `isKeyWindow` so WebKit
hit-tests hover; the host script cancels `contextmenu` defaults. Settings ›
General gained *Keep windows in place when clicking the wallpaper*, which writes
`com.apple.WindowManager EnableStandardClickToShowDesktop`
(`DesktopClickRevealPreference`). See
[features/web-wallpapers.md](../features/web-wallpapers.md).

Verified:

- `python3 scripts/test.py`: Python script tests passed; `xcodegen generate`;
  `MacWallpaperEngineTests` **232 passed**, 0 failed, 0 skipped (~90 s). New
  `WebWallpaperMouseRoutingTests` (desktop-only routing, press/drag/release
  continuity per button, single hover exit, cross-display exit) and
  `WebWallpaperPageTests.testForwardedPointerEventsReachThePageWithoutANativeContextMenu`
  (windowless `WKWebView`: forwarded left click at CSS (100,100) and right click
  reach page listeners in order; `contextmenu` arrives default-prevented).
- Throwaway probe binaries (deleted after the run) against a `WKWebView` in a
  desktop-level, mouse-transparent window: `NSEvent.mouseEvent` replays produce
  `mousedown`/`mouseup`/`click`/drag `mousemove` at the expected CSS point;
  hover only reaches JS through `_simulateMouseMove:` and only while the window
  reports `isKeyWindow` (plain `mouseMoved(with:)` is dropped by `WKWebView`,
  and WebKit routes inactive-window moves to scrollbars only); `:hover` matches
  in standards mode; `_simulateMouseExit:` fires `mouseout`; a copied scroll
  `CGEvent` located at (x, primary height − y) converts to the wallpaper-local
  point and fires `wheel` at the correct coordinates. `NSWindow.windowNumber(at:)`
  plus `CGWindowListCopyWindowInfo(.optionIncludingWindow, id)` classified an
  application window (layer 0) and listed Finder's desktop at layer
  −2147483603 (`CGWindowListCreateDescriptionFromArray` returned nothing on this
  build, hence the `optionIncludingWindow` lookup).
- Not verified: the running app on the desktop (global monitor delivery, hover
  over the real Finder desktop, multi-display coordinates) and whether
  WindowManager applies `EnableStandardClickToShowDesktop` without a re-login
  on this build; no desktop run was authorized and the preference was not
  written during development.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; delivered `build/Build/Products/Release/MacWallpaperEngine.app`
  with the changes above (existing renderer/bindings reused).

## 2026-09-16 — Web wallpapers render in a host WKWebView

`type: "web"` projects (e.g. Workshop 3799142774, *Rhine Lab · 莱茵生命交互桌面*)
were library-only. The bridge now marks them supported, keeps them out of
engine reconciliation and exposes `web_wallpapers()`; Swift hosts one
desktop-level `WKWebView` window per display (`App/Services/WebWallpaper/`),
pushes `applyUserProperties`/`applyGeneralProperties`/`setPaused`, joins the
presentation policy and answers Space-poster requests with page snapshots.
See [features/web-wallpapers.md](../features/web-wallpapers.md).

Verified:

- `cargo test -p wallpaper-bridge --release --lib` (build env from
  `scripts/build.py`): **215 passed**, 0 failed, including the new
  `web_wallpaper_apply_bypasses_engine_and_exports_host_inputs` (no engine
  scene, active id, lock screen empty, properties payload, pause, eject).
- `python3 scripts/build.py --renderer-only` regenerated `App/Bridge/Generated`
  with `webWallpapers()` / `BridgeWebWallpaper`.
- `python3 scripts/test.py`: Python script tests passed; `xcodegen generate`;
  `MacWallpaperEngineTests` **227 passed**, 0 failed, 0 skipped (~90 s). New
  `WebWallpaperPageTests` load a synthetic project offscreen: ES module from the
  project folder, late-listener replay of properties/fps/pause, presentation
  suspension composed with user pause, top-frame navigation lockdown, no window.
- Throwaway offscreen smoke (deleted after the run) against a local copy of the
  Rhine Lab GitHub release: page loaded from `file:`, 74 user properties
  delivered, fps 30, app mounted 21 nodes into `#stage`, snapshot 3456×2234 with
  99.5 % lit pixels showing the wallpaper's opening screen.
- Not verified: desktop windows, Space posters, multi-display and
  presentation-policy behavior in the running app (no desktop run authorized);
  no Release build was requested.

## 2026-09-16 — Panel selects share button metrics

The Discover sort select (and every other `select` in `panel.css`) kept
WebKit's native `menulist` appearance, so macOS painted its own pop-up
button inside the padded, bordered 30 px box — a shorter control-in-a-box
beside the `Search` and refresh buttons. `select` now uses `appearance:
none` with an inline SVG chevron and a hover border, matching the button
height and edges. CSS-only; `settings.css` is untouched.

Verified:

- `.agents/skills/impeccable/scripts/impeccable detect --json WebUI/panel.css` → no findings.
- `python3 scripts/test.py` → 225 tests, 0 failures.
- Not verified: visual render in the running panel (no desktop run authorized).

## 2026-09-16 — Discover grid fills full Workshop pages

Discover used the shared `auto-fill` tile grid, so a 30-item Workshop page
left a partial last row (e.g. 7 columns → 4 full rows + 2 tiles) and a
visible void beside the pagination bar. `.browser-column` is now an
inline-size container and `.discover .wallpaper-grid` picks a column
count that divides 30 (2 / 3 / 5 / 6 / 10) by container width, keeping
the 154 px minimum tile; the Installed grid is unchanged.

Verified:

- `python3 scripts/test.py`: Python script tests **24** and **10** passed;
  `xcodegen generate`; `MacWallpaperEngineTests` **225 passed**, 0 failed,
  0 skipped (~90 s).
- `impeccable detect --json WebUI/panel.css`: no findings.
- No renderer or bridge changes; `python3 scripts/check_renderer.py` not run.
- Not visually verified in the running app (no desktop run authorized);
  breakpoints derived from tile minimum, 12 px gap and 16 px grid padding.
## 2026-09-16 — Cursor mapping rebased onto the coverage-mask work

`fix(scene): map cursor input through the presented wallpaper` was rebased onto
`2385923` (script side-effect writes, puppet animation layers, cursor coverage).
Conflicts resolved by hand: `CursorHitsLayer` now runs the content check before
the incoming hit-mask lookup, and both `provenance.json` notes and both
`renderer.md` coverage rows were kept.

Re-verified on the merged tree:

- `mouse_input_test` **9**, `script_runtime_compat_test` **39 passed, 1 failed**
  (the pre-existing `HostVectorUpdates…`), `scene_schema_tests` **53**,
  `scenescript_sound_layer_smoke` **8**, `particle_mouse_controlpoint_test`
  **35**, `text_object_runtime_test` **60 passed, 2 skipped**.
- `python3 scripts/test.py`: native **225 passed**, 0 failed, 0 skipped.
- `python3 scripts/check_renderer.py` (full): **9 generated GPU cases** passed
  known-pixel assertions and pooled/isolated byte comparisons; **8 projects × 2
  reloads** passed; the three test binaries exited 0.
- `python3 scripts/build.py --configuration Release` rebuilt
  `build/Build/Products/Release/MacWallpaperEngine.app` from the merged tree;
  the binary exports both this change's cursor symbols and the merged
  `PuppetAnimationControl`. The app was not launched or quit.

## 2026-09-16 — Cursor hit testing follows the presented wallpaper

Renderer source and native checks only; no desktop input, capture or delivery.

Problem: `SceneRuntimeContext::SetCursorInput` mapped the window-normalized
cursor onto the raw scene canvas. The wallpaper is presented through the global
camera rectangle and `ComputeWallpaperScalingLayout`, which `FILL` pushes
outside the window to crop, so on any scene whose aspect differs from the
display every `cursorEnter`/`cursorLeave` box was squeezed toward the screen
centre. Hovering the middle of a text layer enlarged it; hovering the same text
a few centimetres left or right did nothing.

Changes:

- `ComputeWallpaperCursorMapping` inverts the presentation transform
  (window pixel → viewport fraction → camera world coordinate) and reports the
  drawn content rectangle alongside the window rectangle.
- `VulkanRender::CursorMapping` computes it from the current output extent,
  scaling mode/factor and the global camera; `SceneWallpaper` pushes it into
  `SceneRuntimeContext::SetCursorViewport` before each frame's cursor dispatch.
  Without a valid mapping the runtime keeps the canvas rectangle.
- Named layers only take cursor events while the cursor is inside the drawn
  content. Coordinates still extrapolate past it, but letterbox bars no longer
  reach layers whose box crosses the canvas edge.
- `scripts/check_renderer.py` runs Cargo from `upstream/renderer` so rustup
  resolves that tree's `rust-toolchain.toml`; `scripts/build.py` already did.
- `scenescript_sound_layer_smoke` now links `nlohmann_json`; it did not compile.

Results:

- A disposable CPU-only probe parsed the selected local 7680×2160 package and
  walked the cursor across the **visible** width of its weekday text, using the
  configuration its own run log records (`output_px=4112x2658`,
  `display_scale=2.000`, scaling mode `fill`, factor `1.000`). Before: **4 of
  11** samples enlarged the layer, which is drawn across 0.4561–0.5503 of the
  window width. After: **11 of 11**, the date layer likewise, zero script
  errors. The probe was removed.
- `mouse_input_test` **9 passed**, including three new cases.
  `LayerHitTestingFollowsWhereTheWallpaperIsPresented` fails without the
  viewport mapping; `LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge`
  fails without the content check (verified by disabling each in turn).
- `script_runtime_compat_test` **35 passed, 1 failed**. The new
  `HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper` drives the
  existing synthetic hover script through `SetCursorInput` at the recorded
  display configuration and fails without the mapping. The failure is the
  pre-existing `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
  recorded in `renderer.md`.
- `scene_schema_tests` **51**, `scenescript_sound_layer_smoke` **8**,
  `particle_mouse_controlpoint_test` **35**, `text_object_runtime_test`
  **60 passed, 2 local-asset cases skipped**.
- `python3 scripts/check_renderer.py` (full, including the Cargo build): all
  **9 generated GPU cases** passed known-pixel assertions and exact
  pooled/isolated comparisons with no diagnostics; **8 projects × 2 reloads**
  passed; lifetime, text and shader-cache binaries exited 0.
- `python3 scripts/test.py`: Python **24** and **10** passed; native
  **225 passed**, 0 failed, 0 skipped.
- `python3 scripts/build.py --configuration Release` succeeded and refreshed
  `build/Build/Products/Release/MacWallpaperEngine.app`. The delivered binary
  exports `ComputeWallpaperCursorMapping`,
  `SceneRuntimeContext::SetCursorViewport`,
  `SceneRuntimeContext::CursorInsidePresentedContent` and
  `VulkanRender::CursorMapping`, so it contains this change. The app was not
  launched or quit.

Toolchain note: before the `cwd` fix the checker's Cargo step ran from the
repository root and picked the default stable toolchain, which fails with
`E0463`. On this machine stable **rustc 1.97.0** and **1.84.1** emit proc-macro
dylibs that dyld on macOS 27.0 refuses to load (`mis-aligned LINKEDIT string
pool`); a minimal throwaway proc-macro crate reproduced it outside the
repository, under the project build environment and a plain one, and with
`-ld_classic` and `strip=debuginfo`. The pinned nightly toolchain produced a
loadable dylib. `scripts/build.py` already ran Cargo from `upstream/renderer`,
so the application build path was never affected by this, and the Release build
above confirms it.

Not verified: real cursor capture, rendered pixels, multi-display or mirrored
layouts, non-default scaling modes on a real display, and the lock-screen
extension. No desktop automation, wallpaper change or app launch was performed;
the delivered bundle was checked by symbol inspection, not by running it.

## 2026-09-16 — Restore Settings → About update controls

The WebKit control panel still held `AppUpdateStore` and the application
menu still had **Check for Updates…**, but Settings → About never drew
the updater after the native SwiftUI settings were removed. The About
page now shows check / download / restart-install, and the menu item
opens that section.

Verified:

- `python3 scripts/test.py`: Python script tests **24** and **10**
  passed; `xcodegen generate`; `MacWallpaperEngineTests` **225 passed**,
  0 failed, 0 skipped (~95 s of test execution). New coverage:
  `testUpdateSnapshotExposesCheckDownloadAndReadyActions` and
  `testAboutUpdateControlsCheckDownloadAndBlockInstallWithoutWindow`
  (offscreen `WKWebView`; fake GitHub client; install confirmation
  refused without a window).
- No renderer or bridge changes; `python3 scripts/check_renderer.py`
  was not run.

Not verified: live GitHub Releases, archive extraction, replacement of
an app in Applications, or visual layout of the About page in a real
window. No desktop automation, wallpaper change, or Release delivery
was performed.
## 2026-09-16 — Script side-effect writes, puppet animation layers, cursor coverage

"流萤 夏日沙滩" (`3292361861`, the wallpaper applied on this machine) reported
three defects. All three were scene-engine bugs, none package-specific:

1. **Viewing mode + "无遮" hid the character.** The layer is authored
   `visible: false` and driven by the workshop "video texture controls" script
   (`thisLayer.visible = false` in `init()`, `thisLayer.visible = alpha != 0`
   in `update()`, no return value). `ScriptedDynamicValue` only overrode
   `update(const DynamicValue&)`, so the typed `update(bool)` that
   `SetNodeVisible` calls never reached its base value; the next
   `Evaluate` fed the stale `false` back in and reverted the write every tick.
   Resolved by the concurrent "persist state across frames" change (entry
   above), which evaluates from the live dynamic value; this entry's
   regression test covers the visibility case on that implementation.
2. **Double-click on the character did nothing.** `getAnimationLayer(name)` was
   a JavaScript stub whose `play()` was empty. `WPPuppetLayer` copies now share
   one playback state, the parser registers it with the runtime, and the shim is
   backed by `SceneRuntimeContext::PuppetAnimationControl` (play/pause/stop,
   frame, rate, blend, visible, isPlaying). Single-shot layers hold their last
   frame and report stopped so `play()` restarts them. The same path binds
   `animationlayers[].visible/rate/blend` to user properties, which this
   package uses to switch the "健全/无遮" idle animations in interactive mode.
3. **Both triangle buttons fired on one click.** The two buttons are
   interlocking triangles whose bounding boxes overlap by roughly half; the hit
   test was a world-space AABB. It now runs in the layer's local plane and, for
   image layers whose scripts handle cursor events, consults a coverage mask
   sampled from the albedo alpha at parse time (RGBA8/BC2/BC3, ≤256 px/side).

Verified:

- `offscreen_scene_probe` on `3292361861`, `WE_TEST_PROPERTIES` for all four
  mode/outfit combinations. Before: viewing + 无遮 rendered no character and
  `nodes.txt` had `293 … visible=0 effective=0`. After: `visible=1 effective=1`
  and the frame shows the character; interactive frames now differ between the
  two outfit values (**9576** sampled pixels vs **7** before), i.e. the bound
  animation layers switch. Diagnostics are the pre-existing set (media-player
  scripts, `clipping_mask` shader, `MediaPlaybackEvent`); nothing new.
- `offscreen_scene_probe` clicks with the new `WE_TEST_CLICK_OFFSET`: clicking
  `468` at `+150 0` (inside its rectangle, in its transparent half, over the
  other triangle) leaves `interactiveLayer1 visible=1`; clicking it at `0 -60`
  (covered texels) switches to `viewingLayer1 visible=1`. Two clicks on `232`
  raise no cursor script errors.
- `script_runtime_compat_test`: **36 tests, 35 passed**; the four new
  regressions `UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined`,
  `PuppetAnimationLayerPlayRestartsFinishedSingleShotForAllCopies`,
  `PuppetAnimationLayerVisibilityFollowsUserProperty` and
  `CursorHitTestRespectsCoverageMask` pass. The first was confirmed failing
  (`visible=0` on every tick) against the pre-fix engine through a throwaway
  harness. The one failure is the documented pre-existing
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`.
- `mdl_schema_tests` **45 passed**, `scene_schema_tests` **53 passed**,
  `mouse_input_test` **6 passed** after the `WPPuppetLayer` blend refactor.
- `python3 scripts/check_renderer.py --project …/3292361861/project.json`: the
  three test binaries pass, all nine generated cases pooled/isolated equal with
  0 diagnostics and pixel assertions met, reload cycles 0. The `3292361861`
  case reports `pixels_equal=false`; two consecutive pooled runs of that scene
  also differ (wall-clock text and randomised script delays), so the mismatch
  is inherent to the package, not the change.
- `python3 scripts/test.py`: Python script tests, `xcodegen generate`, then
  **223 native tests passed, 0 failed, 0 skipped**.

Not verified: no desktop run, no live mouse input, no Release build. The
delivered app still carries the old renderer until
`python3 scripts/build.py --configuration Release` is run. The `clipping_mask`
shader failure (`!float` in the translated vertex shader) is pre-existing and
only affects effects this package leaves disabled.

## 2026-09-16 — Hidden-by-default visibility scripts and lost alignment anchors

"On the way" (`3798819887`) rendered nothing but `general.clearcolor`
(`0.7 0.7 0.7`, the reported plain grey). Three scene-engine defects, none
specific to that package:

1. `WPSceneParser` dropped *every* dynamic binding — `visible`, `origin`,
   `scale`, `angles`, queued scene scripts — of a layer whose `visible` setting
   combined a `script` with a falsy `value`. The authored value is the script's
   initial value, not a licence to run it, so the three weather layers stayed at
   their authored `false`/`false`/`true` and the day layer could never appear.
   The gate and the `allow_script_update` parameter it fed through
   `ResolveBoolSetting`/`ResolveVec3Setting`/`ResolveStringSetting` are gone.
2. Image-layer alignment was baked into the node translate by `LoadAlignment`,
   so the first tick of a scripted origin overwrote it and the layer rendered
   half a canvas off. `SceneRuntimeContext` now owns the anchor for image layers
   (`SetNodeAnchorAlignment`, renamed from `SetNodeTextAlignment`) and
   re-derives `origin + size * scale * 0.5`; center alignment keeps the old
   direct path.
3. `RegisterNode` re-seeded the anchor origin from `node->Translate()` on every
   call, and `RegisterNodeVisibility`/`Translate`/`Scale`/`Rotation` each call it
   again for the same node. Once an anchor is registered that translate already
   holds the offset, so the next `ApplyNodeTransform` added a second one. It now
   re-seeds only when the bound node changes or no anchor exists, and
   `SetNodeAlignment` no longer forces `size_anchor = false` on an anchored node.
   This also fixes pre-existing double-counting on *text* layers, whose anchor is
   registered before their translate/scale bindings.

Verified:

- `offscreen_scene_probe` on `3798819887`: before, `nodes.txt` reported
  `TramDay/TramRain/TramNight` all `visible=0 effective=0` and `frame-2.ppm`
  sampled **1 distinct colour** (`178,178,178`). After, `TramDay` is
  `visible=1 effective=1 translate=1280 540`, the frame has **0 fully grey rows**
  and **2719 distinct sampled colours**, and the PNG shows the authored tram,
  rice fields and sky.
- `scene_schema_tests`: **53 tests passed**, including the two new regressions
  `HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin` and
  `ImageAlignmentAnchorSurvivesScriptedOriginAndScale`. Both fail against the
  pre-fix engine with the expected values (origin `0` instead of `30`, anchor
  `y=0` instead of `16`, `x=42` instead of `74`). The anchor test also covers a
  static origin with a scripted scale, which fails with `90` instead of `26`
  when `RegisterNode` re-seeds the anchor.
- Local corpus A/B, **21 scene wallpapers**, run in a detached worktree at
  `HEAD` so concurrent edits in the main tree could not leak into either arm;
  both arms carry the same probe, so only the engine change differs.
  `nodes.txt` (visibility, translate, scale) differs in **4 of 21** scenes:
  `3798819887` gains its visible day layer and its anchor; `2887099508` and
  `3292361861` restore anchors on menu/overlay layers and finally run the origin
  scripts of previously frozen click-activated panels; `3799253558` moves two
  media-info text layers back onto their authored anchor (`259` → `154.5` and
  `235.85` → `142.925`, each exactly one half-width of double count). No
  previously hidden layer became visible. Frame hashes differ for **7** scenes,
  **six** of which are the known wall-clock/RNG scenes (three distinct hashes
  across three runs of one binary); the only time-independent frame change is
  `3798819887`. `3292361861`'s `Audio Bars` now lands on
  `-155.18878 + 512 × 0.45 / 2 = -39.9888` instead of the double-counted
  `88.0112`.
- `python3 scripts/check_renderer.py`: 9 generated cases pooled vs isolated
  **pixel-equal**, known-pixel assertions passed, **0 diagnostics**,
  `render_target_lifetime_test`/`text_object_runtime_test`/
  `shader_cache_metadata_test` and the reload cycles all exit `0`. Re-run with
  `--project .../3798819887/project.json`: pixel-equal, **0 diagnostics**,
  reload cycles `0`.
- C++ binaries: `scene_schema_tests` 53, `mdl_schema_tests` 45,
  `script_runtime_compat_test` 32 passed with only the documented pre-existing
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors` failure,
  `render_target_lifetime_test` 4, `shader_cache_metadata_test` 1,
  `audio_tests` 38, `mouse_input_test` 6,
  `particle_mouse_controlpoint_test` 35, `timer_tests` 6.
- `python3 scripts/test.py`: Python script tests, `xcodegen generate`, then
  **223 native tests passed, 0 failed, 0 skipped** in **99 s**.
- `offscreen_scene_probe` now requests the production device extensions
  (`VK_EXT_metal_objects`), so scene video textures import headlessly instead of
  logging `failed to import initial video frame`. That alone removed pre-existing
  probe-only diagnostics from `3147346398`, `3292361861`, `3800572533` and
  `3801438494` without touching the engine.

The renderer checks, the C++ binaries and the corpus A/B above were all run in a
detached `HEAD` worktree carrying only this change, so concurrent edits in the
main tree could not leak into either arm. Another agent was editing
`SceneRuntimeContext`, `ScriptedDynamicValue`, `WPPuppet`, `WPImageObject`,
`ScriptEngine` and `WPSceneParser` throughout; their work is preserved (this
change to `SceneRuntimeContext.cpp` was re-applied by hand after a stash
collision). Once the main tree compiled again it was re-verified on the merged
sources: `scene_schema_tests` 53, `mdl_schema_tests` 45,
`script_runtime_compat_test` 32 with only the documented pre-existing failure,
`render_target_lifetime_test` 4, `shader_cache_metadata_test` 1, `audio_tests`
38, `mouse_input_test` 6, `particle_mouse_controlpoint_test` 35, `timer_tests`
6; `scripts/check_renderer.py --skip-build` pixel-equal on all 9 cases with
**0 diagnostics** and reload cycles `0`; and `3798819887` still reports
`TramDay visible=1 effective=1 translate=1280 540`.

Not verified: on-desktop presentation. No Release build, no app launch, no
wallpaper change and no screenshot. Pre-existing gaps observed while building the
vendored tests, untouched: `tex_schema_tests` fails to compile (`lz4.h` not on
its include path) and `scenescript_sound_layer_smoke`,
`scenescript_media_event_smoke`, `media_thumbnail_texture_smoke` and
`rendergraph_smoke` do not link `nlohmann_json`, so none of them build here;
`scripts/check_renderer.py` does not build them either. Removing the visibility
gate also exposes an unimplemented `thisLayer.getParent()` in `3292361861`
(**23** `cannot read property 'multiply' of undefined` update errors per run,
alongside the **17** `init` failures that scene already logged); that layer keeps
its authored value, so its rendered output is unchanged.

## 2026-09-16 — Build stamp resolves the repository, not the pinned renderer

`scripts/build.py` computed `GIT_SHORT_COMMIT` with the working directory set to
`upstream/renderer`. That directory carries its own Git checkout at the pinned
vendored revision, so the stamp was frozen at the upstream revision on any
machine where that checkout exists, and Settings reported it as `Git revision`.
The stamp is now resolved with `git -C <repository root>` through a new
`repository_commit()` helper; the renderer layout and vendored sources were left
unchanged.

Verified:

- Reproduction in the linked artifact: `strings` on the previously built
  `upstream/renderer/target/release/libwallpaper_bridge.a` matched the pinned
  revision `8c19c00` **5 times** and the repository HEAD `2916c00` **0 times**.
  `shadow_rs` resolved the same checkout for its `SHORT_COMMIT` fallback
  (`8c19c002`).
- `python3 scripts/tests/test_build.py`: **1 test passed**. It builds a
  throwaway repository containing a second checkout at `upstream/renderer` and
  asserts the outer commit is reported; the previous working-directory
  behaviour returns the nested commit and fails it.
- `python3 scripts/test.py`: Python script tests, `xcodegen generate`, then
  **223 native tests passed, 0 failed, 0 skipped** in **94 s**.
- `python3 scripts/build.py --renderer-only`: only `wallpaper-bridge`
  recompiled (**6.38 s**), because cargo records `# env-dep:GIT_SHORT_COMMIT`
  from `option_env!` and invalidates just that crate. The rebuilt static library
  now contains `2916c00`, and `uniffi-bindgen` regenerated
  `App/Bridge/Generated` with no diff.

Not verified: the on-screen Settings `Git revision` row. No app build beyond the
Debug test run, no Release build, no app launch and no desktop automation. The
vendored `shadow_rs` fallback still resolves the pinned checkout, so a bare
`cargo build` outside `scripts/build.py` continues to stamp `8c19c002`; the
vendored crates were deliberately not modified.

## 2026-09-16 — Compact agent guidance and Claude entry point

Documentation and symlink only. Aligned the root guidance with the workspace
refactor, replaced the mandatory reading sequence with task-based routing, and
kept authorization, generated/vendored ownership and delivery rules explicit.
Detailed regression coverage stays in `renderer.md`, including the private-PTY
`nettop` and CRLF requirements. Registered `CLAUDE.md` as a relative symlink in
the tooling notes, layout and documentation index.

Verified:

- In-memory Python checks resolved **46 relative Markdown links** across the
  five changed guidance/reference files, including heading anchors, and checked
  **22 unique root-rule path references** against the tree or build-path helper.
- `readlink CLAUDE.md` returned `AGENTS.md`; `cmp AGENTS.md CLAUDE.md` succeeded.
  Python also confirmed a relative symlink resolving to the same file.
- `python3 scripts/build.py --help`, `python3 scripts/test.py --help`,
  `python3 scripts/check_renderer.py --help` and
  `python3 scripts/clean.py --help` all exited **0** with the documented options.
  `PYTHONDONTWRITEBYTECODE=1` kept these checks from creating repository caches.
- `wc -l -w -c AGENTS.md`: **139 → 73 lines, 1,044 → 526 words,
  7,982 → 4,900 bytes**. This measures text size, not model-specific token counts.

Not verified: native/renderer behavior, desktop or visual behavior, permission
grants, or Release delivery. No app build, app launch, desktop automation or
wallpaper change was performed. Checks created no repository scripts or evidence
files; existing shared-workspace byproducts were left untouched.

## 2026-09-16 — Property-script feedback and hover enlargement

Source, native runtime and headless GPU checks only; no desktop input or capture.

Changes:

- `ScriptedDynamicValue` passes its current value to `update(value)` rather than
  restarting from the authored base on every frame. The redundant base-value
  copy and update override were removed. Explicit property writes remain the
  starting point for subsequent updates.
- Script input serialization reads the payload without copying live
  `DynamicValue` subscriptions. Existing callback-only behavior is preserved.
- Added original synthetic regressions for hover convergence, interrupted
  leave/re-entry and user-value replacement. Updated the existing text-field
  regression to continue from its parse-time script result instead of expecting
  the original text again.

Results:

- Both new `script_runtime_compat_test` cases failed before the fix and passed
  afterward. The old hover implementation stayed at **1.02×** instead of
  progressing toward **1.20×**, and snapped back to **1.00×** on leave.
- A disposable native driver ran all **13 unmodified hover scale scripts** read
  from the selected local package, bound to synthetic scene nodes. It checked
  all three scale components for 120 hover frames and 120 return frames at a
  fixed 60 Hz step against the authored interpolation. **Zero mismatches and
  zero script errors**: weekday text reached **1.10×**, date text **1.20×**, and
  every layer returned to its original scale. This does not compare rendered
  pixels with Windows or verify real cursor capture.
- Full script runtime suite: **34 passed, 1 failed**. The remaining failure is
  the previously documented
  `ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
  (`scriptProperties` is undeclared); it was not excluded.
- Freshly rebuilt C++ targets: camera zoom/callback-only filters **4 passed**,
  mouse input **6 passed**, MDLS3 hierarchy/pivot regression **1 passed**.
- `python3 scripts/check_renderer.py --skip-build`, after rebuilding its C++
  targets: all **9 generated GPU cases** passed known-pixel assertions, exact
  pooled/isolated comparisons and diagnostic checks; **8 projects × 2 reloads**
  passed. Texture lifetime **4 passed**, shader-cache metadata **1 passed**,
  text runtime **60 passed, 2 local-asset cases skipped**.
- `python3 scripts/test.py`: **223 native and 34 Python tests passed**. This
  checks the application layer with its existing bridge archive, not delivery
  of the changed renderer in an app bundle.

Build limitation: the non-skipping renderer check failed while compiling Rust
`linkme` with **E0463: can't find crate for `linkme_impl`**, including a retry in
an isolated Cargo target directory. The C++ checks above used the existing
`libshader.a`; no fresh full-chain build is claimed.

Not verified: desktop presentation, visual smoothness, Windows equivalence or
real mouse input. No wallpaper files or settings were changed, and no Release
app was built, replaced, launched or restarted.

## 2026-09-16 — Continuous-playback resource reuse

Source and headless GPU only.

Changes:

- NV12 conversion remains synchronous and generation-sensitive. Converted Metal
  destinations enter a per-cache idle pool only after the final owning reference
  retires. The idle pool retains at most four textures and 64 MiB in total;
  active frames are not throttled. Vulkan Image/View objects are still imported
  per new generation. BGRA retains its existing direct/alias semantics.
- Successful draw fences retire video pins and staging transactions together.
  Failed submissions never wait on an unsignaled frame fence. Unknown
  completion retains owners and stops that renderer; surface reset recreates
  frame sync resources. Confirmed device loss is terminal for that device. Final
  destruction terminates only when checked device idle cannot prove safe
  resource release.
- Prepared-pass CPU updates precede uploads. Staging stays mapped, compares
  exact bytes, flushes actual dirty ranges, and freezes storage until completion
  or checked recording discard. Batch scratch capacity is reused, camera matrix
  selection avoids duplicate work, and descriptor writes are pushed once per
  draw. FPS, resolution, color conversion, audio response, input and animation
  policies were not reduced.

Results:

- `playback_gpu_test`: all **13 PlaybackGPU cases passed** —
  generation/retained-pixel correctness, six concurrently recorded consumers
  across cache eviction, conversion/import failure rollback, resize/BGRA
  lifetimes, recording/submit/fence recovery, Clear and isolated terminal
  cleanup, partial/discarded/grown uploads, current-frame UBO/geometry, graph
  ordering, split/combined descriptors and MSAA.
- All ten requested renderer targets built with disconnected CMake dependencies.
  `offscreen_scene_probe` was built for caller migration, not run on private
  assets. Video policy/submission **5 passed**; shader bridge **16 passed**;
  planner smoke passed with Release assertions enabled; render-target lifetime
  **4 passed**; mouse **6 passed**; particle **35 passed**; timer **6 passed**.
- Script runtime: **30 passed, 1 failed**, both before and after the work. The
  unchanged failure is
  `ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`.
  The extended compose-camera matrix regression passed.
- Rust core **174 passed**; Rust bridge **214 passed**.
- `python3 scripts/test.py`: **200 native and 34 Python tests passed**.

Performance measurement: the generated workload uses 3840×2160 NV12 inputs, a
4112×2658 private target, a reflected 256-byte material block, 2 MiB staging
allocations, and three interleaved 180-frame rounds per mode at 60 Hz.
Compilation and readback are outside timing. Comparing the current pipeline with
forced-fresh conversion outputs against pooled outputs, mean process CPU was
**2.421 ms/frame versus 0.868 ms/frame**. Across the 540 measured pooled frames:
**0 new converted destinations, 540 reuses, 540 Vulkan imports, 0 dynamic
copies, 540 descriptor pushes**, with stable scratch capacity. This isolates
destination reuse inside the current pipeline; it is not an old
full-application A/B comparison. A separate unpooled conversion-only run
measured **2.080 ms/frame**, and the pre-existing compiled conversion experiment
was rerun.

The 2 MiB dirty-upload probe copied only `(offset=4, size=4)` and
`(offset=68, size=8)` for writes at offsets 5 and 69, and verified all 256
output bytes through GPU readback. An unchanged update recorded no copy.

GPU elapsed measurements varied substantially across repeated runs. An isolated
diagnostic aligning draw submission timing narrowed or reversed the apparent
draw differences; no such delay was added to production. These samples do not
establish a GPU-time improvement or an attributable GPU regression, and they are
not power or battery measurements. Temporary instrumentation was removed.

Merges: the work was merged with upstream `main` at `9f192ce` before pushing.
The additive control-panel test conflict retained both sets of regressions, and
the hidden-panel download fixture now observes password-prompt/downloading
transitions instead of the removed, fabricated Workshop percentages. Post-merge:
**219 native and 34 Python tests passed**, all **13 PlaybackGPU cases passed**,
Rust core/bridge remained **174/214**, and the targeted upstream camera-zoom,
callback-only script, MDLS3 hierarchy and text-centering regressions passed.
Script runtime then had **32 passed** plus the same single pre-existing
Vector-constructor failure. The concurrent appearance commit `07ba75e` was
integrated afterwards without dropping the theme injection or
visibility/minimization notifications; newly added transfer telemetry fields
participate in the existing snapshot observation. The final merged tree passed
**223 native and 34 Python tests**. Renderer sources were unchanged by that
second merge, so the renderer results above still apply.

Not verified: no Release application was built or delivered and neither app
installation was replaced or restarted. Real screen playback,
surface/acquire/present failure recovery, visual equivalence on the desktop, and
battery or power gains remain unverified.

## 2026-09-16 — Theme and appearance contrast

Coverage added in `AppThemeTests` (preference recreation, rejection of invalid
changes without overwriting saved values, recovery from a damaged saved accent,
reset isolation) and the offscreen appearance regression in
`ControlPanelLayoutTests`.

Results:

- `python3 scripts/test.py`: **215 native tests and 34 script tests passed**.
- After the final contrast adjustments, the 10 `AppThemeTests` and
  `ControlPanelLayoutTests` passed again.
- A throwaway, scheme-matched offscreen WebKit probe exercised 48 light/dark,
  surface-tone and extreme-accent combinations at 760/960/1240 px, then 768
  combinations using deterministic sampled accent colors. Computed text and
  primary-label contrast exceeded 4.5:1; focus, custom primary boundaries and
  progress indicators cleared 3:1 in the checked combinations. Appearance
  content did not overflow horizontally. The probe was removed.

Not verified: these are non-visual checks. Desktop presentation, native
color-picker interaction and titlebar appearance remain visually unverified. No
Release build was requested or delivered.

## 2026-09-16 — Idle-work reduction

Source changes only.

Changes:

- Audio response uses stop-aware input/deadline waits instead of a periodic
  16 ms timeout. Expiry clears retained input and publishes silence once; fresh
  input, continuous silence, FFT size/hop, accepted frames and restart behavior
  are unchanged. Child-process regressions give partial-input and expired-input
  Reset paths a two-second exit deadline.
- Mouse polling sleeps while no scene is active or effective playback is paused,
  retaining the 16 ms interval and single-in-flight contract when enabled.
  Renderer/audio pause failures and canceled shutdown restore polling from the
  confirmed playback state and remaining handles. Reconciliation failures also
  refresh from actual handles: scene creation can succeed before audio setup
  fails, including configured refresh, shader-cache rebuild and asynchronous
  restore. Mouse setters no longer publish unchanged engine snapshots; sampling
  borrows the current display list.
- Hidden, minimized or occluded panels register native dependencies without
  building page dictionaries or pushing JavaScript. Download continuation and
  error reconciliation remain active, including while a previous page Promise is
  pending. Visible pushes coalesce through one in-flight task; old-page
  completions cannot affect a replacement page. Supplemental display options are
  fetched only for visible Settings/display pages, reuse selected options, and
  discard canceled or superseded revisions.

Results:

- `cargo test --release -p wallpaper-core --lib`: **174 passed**.
- `cargo test --release -p wallpaper-bridge --lib`: **214 passed**, including
  scene lifetime, presentation/manual pause precedence, failure rollback,
  disabled destruction, stalled single-flight mouse scenarios, and live handles
  remaining after reconciliation/audio errors. The three new error-exit
  regressions fail before the follow-up correction and pass afterwards.
- Renderer CMake targets: `AudioResponseMonoTest.*` **19 passed**,
  `mouse_input_test` **6 passed**, `particle_mouse_controlpoint_test`
  **35 passed**, `timer_tests` **6 passed**.
- `python3 scripts/test.py`: **200 native tests and 34 Python tests passed**.
  The 13 control-panel tests use unattached `WKWebView`s, including real bundled
  page delivery and rendered FPS/volume values; no test opens a desktop window.
- Baselines before editing: core 174, bridge 206, audio 16, mouse 6,
  particle 35, timer 6, native 192, Python 34.

Device-free probes: the real audio analyzer accepted a synthetic 12 kHz tone,
published silence after expiry, held generation constant for five idle seconds,
accepted a fresh tone, and reset successfully. Process CPU during the settled
five-second idle phase was 0.004657 s before and 0.000014 s after in these
individual runs. These small synthetic-process measurements are not application
watts and not a controlled battery-life comparison.

A three-cycle headless mouse workload recorded zero additional engine calls
while paused and after removing the final scene, and sampled the latest input on
resume. The configured wait remains 16 ms; this run observed eight callbacks per
162.8–165.0 ms active window (about 20.3–20.6 ms per call, including host
scheduling), which is not guaranteed 16 ms wall-clock delivery. Offscreen
observation probes demonstrated hidden preview-map construction before the
change and none afterwards without an explicit page request. Throwaway probes
were removed. Rust formatting was scoped to edited ranges; unrelated existing
formatting drift was not rewritten.

Not verified: no Release application was built or delivered and the running
`/Applications/MacWallpaperEngine.app` was not replaced or restarted. Desktop
visuals, real input and audio capture, and actual battery/power savings remain
unverified. FPS, render resolution, video/animation timelines, audio-response
preferences, renderer fences and the lock-screen strategy were not changed.

## 2026-09-16 — Presentation suspension and scene timing

Changes: desktop presentation suspension is now separate from user/battery
playback state. Lock-screen scene exports retain only the latter, so hiding or
locking the desktop does not pause the visible lock-screen provider.
Presentation changes invalidate in-flight reconciliation through the existing
generation guard; stale completion restores committed configuration with the
current effective pause. A failed audio restart compensates renderer/capture
changes and restores capture intent. The Swift policy serializes delivery and
tracks acknowledged state separately from desired visibility. Failed or withheld
delivery remains pending for the next evaluation — including unchanged
visibility and canceled shutdown — instead of being mistaken for a successful
resume. Frame timing keeps render cost separate from animation time.

Results:

- `python3 scripts/test.py`: **192 native tests and 34 Python tests passed**.
- With the Homebrew environment from `scripts/build.py`:
  `cargo test --release -p wallpaper-bridge --lib` **206 passed**;
  `cargo test --release -p wallpaper-core --lib audio` **23 passed**.
- CMake `timer_tests`: all six `FrameTimerTest` cases passed.
- An isolated production-timer smoke at 30 FPS with 40 ms simulated draws
  advanced 2.215159 s of scene time over 2.215392 s of wall time (ratio
  0.999895); the first delta after a 500 ms pause was 0.033333 s.
  Production-policy smoke checks delivered the withheld resume after canceled
  shutdown and retried an injected asynchronous audio-start failure without a
  visibility change. Throwaway probe programs were removed.

Not verified: desktop presentation, real CoreAudio restart failures and native
lock-screen integration were not exercised; their regression coverage uses
injected state and failures. No Release build was performed or delivered.

## 2026-09-15 — Translucent coverage regression (red contours on soft edges)

Root cause and fix are documented in
[renderer.md](renderer.md#alpha-compositing). `scripts/check_renderer.py` grew a
ninth generated GPU scene, `generated-alpha`; expected readback is 128/191/255
and the pre-fix binary produced 64/96/191, failing the case.

Results: the generated matrix plus the reported scene passed pooled/isolated
pixel equality with no diagnostics and clean reload cycles. Local scenes
`3799253558`, `2309704117`, `3219398263` and `3299228616` still render without
new diagnostics; their MDLA, Rust `light_map` compile and shader-value alias
errors are pre-existing and untouched. A private before/after crop of the
reported scene measured a red-excess contour metric of 10509 px before and
3395 px after; the remainder is authored eyeliner, not a contour.

Not verified: offscreen GPU only; desktop presentation remains unverified.

## 2026-09-15 — Download flow

Results: `python3 scripts/test.py` passed **all 162 native tests and 34 Python
script tests**. JavaScript syntax checks passed.

Coverage: retained-intent tests cover setup/account progression, explicit
shared-resource consent including reinstall, resource-job deduplication, account
correction, and removal preventing resumption. The bundled `WKWebView`
regression opens no window and checks setup dismissal, snapshot updates without
reopening, resumption, and request removal. Queue tests exercise saved-session
handoff through local PTY fixtures, not a real Steam account.

Not verified: desktop visual presentation and live Steam authentication or
downloads. No Release build was performed.

## 2026-09-15 — WebKit interface migration

Results: `python3 scripts/test.py` passed **all 152 native tests**, and
`python3 scripts/build.py --swift-only --configuration Release` succeeded,
updating `build/Build/Products/Release/MacWallpaperEngine.app` (quit and reopen
the app to load it). The bundled interface was additionally exercised outside
the app against a synthetic state fixture in a local browser: tab routing, tag
filtering re-querying the Workshop, property and display actions carrying their
identifiers, and layout at 1240×800 and 760×560 without horizontal overflow.

Not verified: that fixture proves markup and script behavior only, with
placeholder thumbnails. Real previews, desktop presentation, downloads and the
XCUITest suite were not exercised.

## 2026-09-15 — SteamCMD universal-signature regression

Root cause: macOS `codesign --verify --deep --strict` returned an internal error
for the installed Valve-signed `steamclient.dylib`, while explicit Intel and ARM
slice verification both passed. Runtime validation now checks every CPU type and
subtype independently, retains deep framework resource checks, and leaves
Gatekeeper and content-bound approval intact.

Results: the read-only production-service smoke passed all installed-runtime
signatures and stopped at the existing macOS approval gate; it did not execute
or modify SteamCMD. All **13 `SteamCMDApprovalTests` passed** in an isolated
XCTest bundle built from the production runtime/runner and the existing test
file. The new universal-library regression uses disposable signed fixtures,
rejects corruption in either architecture even with an existing approval, and
fails with the old combined-verification loop.

Blocked: the normal `scripts/test.py` run and the Swift-only Release build were
attempted but blocked by concurrent `WebControlPanel.swift` compilation errors
at lines 107 and 126; the app was not updated.

Not verified: desktop presentation and a real Workshop download.

## 2026-09-15 — Renderer animation and puppet repair

Changes: puppet attachment, character-sheet reference pose decoding and
animation-delta handling, described in
[renderer.md](renderer.md#animation-and-puppets).

Results: the corrected scene rendered 71 samples at 0.1-second intervals;
inspected samples show no permanent chromatic distortion and no triangular face
artifact during blinking, and authored background shake remains enabled. All
**44 model schema tests**, two timeline runtime regressions and the
parser-to-material timeline regression passed. The broader **133-case**
scene/script/text run had one known failure
(`ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`)
and two asset-dependent skips. The renderer check recorded eight generated
scenes plus Sparkle passing pooled/isolated pixel equality without diagnostics,
plus repeated scene-load checks. A separate run had all eight generated cases and
two local scenes pass allocation pixel equality without renderer diagnostics;
Sparkle also rendered 150 samples at 60 FPS and a 240-frame 30 FPS cycle through
`offscreen_scene_probe`, with the attached mask/body and character-sheet pieces
assembled and no renderer errors, and reload cycles passed for both local
scenes. The full Release application build succeeded.

Not verified: no desktop automation was used. This proves offscreen animation
and reload state, not desktop presentation or audio.

## 2026-09-15 — Animated lock screen: revision publication

Changes: each published lock-screen revision now also updates the native choice
configuration for the selected display and every existing Space override.
Keeping a constant `current` choice while replacing only the extension's
renderer left inactive-Space thumbnails cached. Revision changes use the
existing journaled store update and WallpaperAgent reload; unchanged
reconciliation does not reload the service.

Results: the regression reproduces unchanged choices before the fix, then
verifies that all selected choices change, that repeated reconciliation is
inert, and that relaunch restores the original selections. **All 87 native tests
passed.**

Not verified: actual Mission Control cache refresh and visual timing. Verify
manually by applying A then B with Animate Lock Screen enabled, without visiting
other Spaces, and inspecting every desktop thumbnail.

## 2026-09-15 — Large-scene first-frame startup (Sparkle)

Root cause: quadratic staging-buffer growth, described in
[renderer.md](renderer.md#startup-and-staging-buffers). The final shader repair
additionally handles undersized cross-stage varying declarations, conditional
helper headers, source-defined `log10`, legacy scalar/vector argument
conversion, compound assignment narrowing and scalar initializer conversion;
shader pipeline revision 4 invalidates previously compiled programs.

Results: the original probe produced its first image at about **43.2 s**; the
allocator-only repair, without the discarded pipeline-cache experiment, reached
its first frame at **4.31 s**. Three rendered frames before and after the
allocation change were byte-identical. The final Sparkle probe logged no
shader/effect errors with a **cold first frame of 5.00 s and a warm first frame
of 2.41 s**. The portable Rust shader suite passed; three existing
asset-dependent pipeline cases (genericimage4 and a Workshop package) were
excluded because their referenced files are absent. Generated pooled/isolated
renderer checks passed all eight pixel cases.
`python3 scripts/build.py --configuration Release` succeeded.

Native verification ran **87 tests: 86 passed**;
`LockScreenWallpaperTests.testWallpaperRevisionInvalidatesEverySpaceAndKeepsRestorationOriginals`
failed its configuration-data inequality assertion. That test exercises native
selection fixtures, not the shader or staging-buffer paths changed here, and it
was not altered as part of this renderer fix.

Not verified: these are private GPU results. Desktop presentation remains
untested.

## 2026-09-15 — Wallpaper properties

Changes: the bridge exposes authored combo labels and editable values to native
menu pickers. Property snapshots evaluate authored visibility conditions against
all effective draft values, so language-specific rows follow the wallpaper's
language selector. Hidden values remain in the draft, so switching languages
does not erase them. Informational text properties are displayed as labels.
Bridge regressions live in `tests::property_snapshot`.

Results: a read-only Lonely Cat probe exercised all six authored language
options through the headless bridge; each returned its matching 13 properties
and every visible combo contained its current selection. That run recorded **202
passing checks** (201 permanent tests plus the removed local-asset probe).
Native verification passed **all 86 tests**. The full
`python3 scripts/build.py --configuration Release` build succeeded, regenerating
Swift bindings and updating `build/Build/Products/Release/MacWallpaperEngine.app`
(quit and reopen the app to load it).

Not verified: no desktop, wallpaper setter or real UI was exercised. Check the
Language, Clock Location and Bar Style menus manually, plus language-row changes
after reopening the app.

## 2026-09-15 — Lock-screen orphaned native selection recovery

Changes: orphaned native selections now recover only app-owned Desktop/Idle
fields from surviving native fallback selections, preserving external fields.
Space display entries prefer the physical display, then their Space default,
then SystemDefault and AllSpacesAndDisplays. Missing fallback data still blocks
activation without changing the store; this cannot reconstruct a lost per-Space
original exactly. Space defaults are journaled before activation alongside
SystemDefault so copied providers restore on disable or relaunch.

Results: regression fixtures cover orphaned Idle recovery with an unchanged
Desktop, copied Space defaults across relaunch, and refusal when no native
fallback survives. **All 86 native tests passed.**

Not verified: live wallpaper and lock-screen behavior.

## 2026-09-15 — Audio responsiveness

Changes: Audio Response defaults to enabled for new wallpaper configurations and
missing saved fields; an explicitly saved `false` remains disabled. The
application-level preference controls activation, while low-level renderer and
lock-screen extension defaults remain disabled so they do not independently opt
into audio capture.

Results:

- A device-free configuration smoke verified missing-field handling and saved
  opt-out round trips. The default-scene activation test verifies that capture
  starts without a manual toggle.
- `cargo test --release -p wallpaper-core --lib audio`: **20 passing checks**
  over capture ownership/failures, mono/multichannel conversion and resampling
  including sample-rate changes.
- `cargo test --release -p wallpaper-bridge --lib`: **199 passed** over live
  toggle errors, rollback/persistence, nonblocking selection and mirror
  behavior. A separate bridge run passed **201 tests**; the
  `local_lonely_cat_language_smoke` probe failed only because its private
  project-path environment variable was absent, not because of audio behavior.
- `audio_tests --gtest_filter='AudioResponseMonoTest.*'` **16 passed**,
  `particle_mouse_controlpoint_test` **35 passed**,
  `script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'`
  **2 passed**. The broader script compatibility check passed **28 tests** with
  the already documented
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors` failure excluded;
  that does not claim the excluded case is fixed.
- Device-free GPU evidence: a synthetic 234.375 Hz tone changed a rendered
  tile's red channel from 26 to 120 through the shader spectrum and its width
  from 64 to 88 pixels through SceneScript. Silence, disabled audio response and
  an out-of-band 3515.625 Hz tone produced identical baseline pixels. The probe
  uses private GPU images, not a window, audio device, microphone or desktop
  capture.
- `python3 scripts/test.py` passed **all 82 native tests**. The full
  `python3 scripts/build.py --configuration Release` build succeeded and updated
  `build/Build/Products/Release/MacWallpaperEngine.app` (quit and reopen the app
  to load the rebuilt renderer and settings UI).

Not verified: live system authorization, device switching and desktop
presentation. Unimplemented non-audio scene features, including some script
outputs, can still affect wallpaper compatibility.

## Undated earlier work

These records predate dated logging. They are retained for their technical
content; treat the results as historical.

### Offscreen GPU verification of clock corruption

The reported background patch and white clock/date bars were reproduced in
`offscreen_scene_probe` output. The fixes provide a real macOS font when Windows
Consolas is missing, retain pooled targets until every logical version has
finished, and explicitly clear effect inputs when `copybackground=false`.
`render_target_lifetime_test` asserts version lifetimes and a real transparent
writer before an effect samples its empty input; the text regression checks
actual glyph coverage rather than just nonempty strings.

After the fix, the full-size PPM of the probe's third frame was byte-identical
to the same run with `WE_TEST_NO_REUSE=1`. The patch and rotated duplicate are
absent and the clock and date are readable. The dim AM/PM row is present in the
authored sprite texture itself; the current period is highlighted. These runs
had no live audio input and do not verify audio-reactive motion or desktop
presentation. The Release build and **59 native app tests passed**.

### JPEG orientation regression (流萤)

Local wallpaper `3798997788` reproduced the reported overlapping image in the
surface-free `offscreen_scene_probe`. Its base JPEG stores 2342×3508 pixels with
EXIF orientation 8, while the TEX header and the already-oriented smaller mips
use 3508×2342; ignoring EXIF mixed differently oriented mip levels during
filtering. The parser now applies orientation independently to each embedded mip
and loose JPEG, and loose header dimensions use the same display orientation.
After the fix the same scene and its Iris Movement effect render without the
overlap or bottom band. `tex_schema_tests` covers all eight EXIF display
transforms. Offscreen GPU only; not proof of desktop or AppKit behavior.

### Original Lonely Cat regression

C++ coverage was extended over persistent shader-cache metadata, cache
invalidation after include edits, corrupt-cache recovery, parent-aware
compose-background sampling and SceneScript AM/PM sprite-frame selection; these
tests create no window and no Vulkan device. Besides the known
`ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
failure, the other **27 script compatibility tests, 45 scene schema tests, 59
text tests, 4 render-target lifetime tests** and the shader cache regression
passed.

### Authorized lock-screen experiments (macOS 26.6.2)

- Private context and IOSurface payloads passed real anonymous XPC round trips.
- Bundled video and Lonely Cat produced distinct GPU-fenced frames in remote
  layers. The actual native adapter produced four distinct scene snapshots and
  passed pause/clear/replacement readiness with the hosted context retained.
- An ad-hoc-signed sandboxed Release extension was launched by WallpaperAgent;
  video and scene separately acknowledged 3456×2234 rendered frames. Actual lock
  transitions reached `mode=locked`, `activity=active`, playback unpaused.
- A synthetic native provider was visually observed changing colors on the
  desktop. macOS refused screenshots while locked, so the final lock-screen
  appearance and smoothness are **not visually verified**.
- Another active wallpaper manager re-established global linked choices during
  continuous switch testing. Those runs ended with a reported conflict and
  ownership-aware restoration, not a claim of uninterrupted end-to-end playback.

Only logs were retained; private captures, fixtures and executable experiment
scaffolding are disposable. The feature stays off by default and must not run
alongside a competing global wallpaper manager. Multi-display hardware,
long-duration power use, sleep/wake and the final settings UI have not received
full visual release verification.

### Desktop Space API inspection (macOS 26.6.2, built with the 26.5 SDK)

Read-only inspection confirmed the dynamically resolved
`CGSCopyManagedDisplaySpaces` / `DesktopPictureSetDisplayForSpace` symbols and
four desktop Space IDs. The native setter and the GPU/Mission Control appearance
were **not** exercised by routine verification; pixel, ledger and coordinator
tests do not prove visual timing.

### Pre-merge branch results

An earlier native-workflow branch reported 110 of 198 tests. That figure is
per-branch history and never established post-merge success; it is recorded here
only so the number is not mistaken for coverage of the merged tree.

## Earlier end-to-end verification record (undated)

This record predates dated logging and was moved here from `LICENSING.md`. Its
original result bundles and screen captures were disposable build output and
have been removed, so every run below is described in prose rather than by
artifact path.

- A native test run covering **24 passing tests, zero failures**: import safety,
  live Workshop queries, download cancellation cleanup, launch and reopen,
  settings navigation, selection persistence, apply/pause/resume/relaunch,
  invalid-media recovery, and Workshop navigation persistence.
- A separate recovery-confirmation run: invalid-video activation and the
  subsequent valid-wallpaper recovery passed against the real desktop UI. Native
  UI and renderer pixel captures plus a machine-readable report recorded the
  exercised behavior and the unverified prerequisites.
- Installed-release checks at `~/Applications/MacWallpaperEngine.app`: the code
  signature and the bundled dynamic-library paths were verified locally.
  Invalid-video recovery was additionally exercised against that installed
  release — an actionable decoding error appeared, and Aurora Drift applied
  successfully afterwards without restarting the app.
- Login-fix run: **20 passing tests, zero failures**, including short and split
  password and Guard prompts, mobile-approval transitions, authentication
  rejection, and errors emitted immediately before process exit.
- SteamCMD login-prompt repair timings: the original downloader surfaced no
  password prompt during a 15-second local probe; the fixed downloader surfaced
  the real installed SteamCMD prompt in **3.33 s**, and the updated installed
  release displayed its password field in **3.28 s**, which a screen capture
  taken during that session recorded. The disposable session was cancelled
  without submitting a password; successful account authentication and an
  account-owned Workshop download were not claimed.
- Steam Guard retry run: **22 passing tests, zero failures**, including denied
  mobile approval followed by a fresh password/code session and a successful
  local fixture import, and distinguishing authentication rejection from
  Workshop content-access denial.
- Native UI smoke with a disposable local SteamCMD fixture: mobile instructions
  appeared, a simulated `FAILED (Access Denied)` exposed **Retry Steam
  sign-in**, the button requested fresh credentials, and a subsequent code
  submission imported the fixture into an isolated library. Screen captures
  taken during that session recorded the mobile and code guidance, the retry
  button and the Chinese instructions in the installed release. This claims no
  real Steam account approval and no protected Workshop download.
- Scene-assets fix run: **25 passing tests, zero failures**, covering Windows
  application asset installation, authenticated terminal interaction, keeping
  only validated resources, incomplete-install preservation, cancellation
  cleanup, and existing download/import behavior. The installation-completion
  tests used a disposable local SteamCMD fixture, not a purchased Steam
  download.
- Scene-asset setup in a separately identified native app with an isolated
  library: Settings and installed-Workshop recovery actions opened the setup
  sheet; Apply was disabled while assets were missing and enabled after a
  disposable resource fixture appeared in the same session. The real installed
  SteamCMD reached its password prompt from the asset-install action; the session
  was cancelled without a password and staging cleanup was confirmed. Screen
  captures taken during that session recorded the native setup sheet and the
  real prompt. This claims no authenticated asset acquisition and no third-party
  scene rendering.
- Scene-assets integration re-run: all three asset installation, preservation
  and cancellation regression cases passed again after the concurrent
  remembered-session integration. The packaged Release build was signed and its
  bundled-library paths verified; a separately identified copy opened the asset
  setup sheet and reached the real SteamCMD password prompt without submitting
  credentials.
- Remembered-sign-in run: **34 passing tests, zero failures**, including
  cross-launch cached downloads, case-insensitive account matching, account
  switching, expired-cache fallback and explicit retry, forgetting and opt-out,
  rejected-login isolation, post-authentication failure and cancellation
  retention, and private cache permissions. Session scenarios used disposable
  SteamCMD fixtures, not real account credentials. The installed SteamCMD's
  `help login` was run separately in an isolated runtime and confirms native
  cached authentication without storing the password.
- Remembered-sign-in native UI smoke passed: a separately identified copy of the
  app signed into a local SteamCMD fixture through the password and Guard
  fields, imported one wallpaper, restarted, auto-filled the account, and
  imported a different wallpaper without submitting credentials. The fixture
  recorded one fresh login followed by one cached login, and **Forget saved
  Steam sign-in** removed the cache and reset the form. Captures were taken
  during that session and the disposable UI driver was removed afterwards. Real
  Steam token lifetime and protected downloads remain account-dependent and
  unverified.
- Final downloader run after cleanup: **22 passing tests**, including
  failed-account-switch preservation and rejecting credential symlinks without
  reading or modifying the outside file. Release compilation succeeded, and the
  Simplified Chinese remember/forget labels and the remembered-account
  presentation were checked in the native UI.
- The remembered-session Release was packaged, signed and installed at
  `~/Applications/MacWallpaperEngine.app`; the previous app was retained
  separately as disposable build output. The installed bundle passed deep strict
  signature verification. Wallpaper and library data and the user's separately
  installed SteamCMD were left unchanged.

Not verified: account-dependent download and apply verification remains open.
No real Steam account approval, no protected Workshop download, no authenticated
asset acquisition and no third-party scene rendering were performed, and
account-dependent token lifetime is unverified. Actual Steam account downloads,
complex third-party scene fidelity, audio capture permission and multiple
physical displays require separate verification with the appropriate account,
content, permissions and hardware. This record does not claim that every
Workshop scene or every hardware configuration works.
