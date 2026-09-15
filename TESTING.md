# Testing

## Evidence scope

The results and local artifact paths below are historical evidence from the
respective pre-merge branches, not verification of the combined tree. In
particular, the native-workflow branch's prior 110/198 test results do not
establish post-merge success. Re-run the appropriate non-desktop checks after
integration and record fresh evidence separately. No desktop automation, real
SteamCMD exception, Steam sign-in approval, or system audio permission is
authorized by this checklist; each requires an explicit user decision.

## Routine checks

Run `python3 scripts/test.py`. This generates the Xcode project and runs only
`MacWallpaperEngineTests`, preserving a `build/Tests-*.xcresult` bundle.
The default Xcode scheme also excludes UI tests. The unit-test host skips app
startup: it does not create the control panel, initialize the renderer, or restore
wallpapers.

Existing native tests cover import validation, duplicates, cancellation, downloader
lifecycle, authentication, saved sessions, and scene-asset installation. Download
tests exercise three simultaneous private terminals, per-item secrets and
cancellation, duplicate-click suppression, FIFO slot handoff after failure/cancel,
shutdown without launching queued work, and protection against stale credential
rejections erasing a newer session. Import tests cover complete atomic adoption,
concurrent destinations, and rejection of linked, special, or incomplete content.
Workshop service tests cover search and pagination beneath the UI (two tests use live Steam
responses and therefore require network access). These remain in routine coverage.

Deterministic Workshop tests additionally cover committed-query pagination,
superseded requests, cancellation, and exact failed-request retry through the real
page parser. Editor-state tests cover locale-specific scaling, invalid raw text,
and independent wallpaper/field drafts.

SteamCMD setup tests use isolated preferences/directories, URLProtocol archives,
real system tar, and owned child processes. They cover publication/replacement,
invalid discovery, traversal/link/archive-size boundaries, network failures,
signature-policy blocking, cancellation, and no late writes. Runtime fixtures
exercise canonical macOS path aliases and nested Mach-O executable dependencies.
Fixtures do not prove that Valve's current distribution passes this Mac's policy.
An official no-login installation smoke must use a disposable support root and
the production providers, stop on any Gatekeeper/Rosetta/signature block, and never
approve a prompt, re-sign downloaded code, or remove quarantine automatically.

Approval tests operate only on isolated local fixtures: exact SHA-256 receipts,
signature/policy-failure rejection, stale candidates, changed resources, private
copies, and quarantine scope. Retained-install tests cover same-path retry/relaunch
and explicit discard. The installation-to-downloader regression launches the
published executable through the real PTY downloader and asserts imported manifest
and media bytes; it does not use a separate prebuilt runtime folder.

Control-panel layout tests measure offscreen NSHostingController proposals at
760×560, 960×640, and 1240×800, long display menus, and English/Chinese empty-state
reflow. They create no window, take no screenshot, and do not start the renderer.
They establish layout bounds, not visual or desktop-integration correctness.

Native desktop-poster tests use synthetic renderer pixels and an in-memory
workspace. They cover lossless PNG dimensions/channel order/orientation, malformed
frames, synchronous frame requests (no Apply debounce), first-frame delivery to
all Spaces without a Space-change event, stale old-layer completion, automatic
retry, independent display/Space originals, duplicate-frame suppression, immutable
frame URLs and reference-aware cleanup, legacy journal migration, relaunch
recovery, external wallpaper changes, and write failures. Topology and native
option/path translation are tested using fixtures, including empty inherited/default
native selections, exact pathless-option restoration across relaunch, rejected
native acknowledgements, and unreadable-original errors. Empty native dictionaries
are retained verbatim rather than replaced with a guessed static default image.
Actual macOS acceptance/restoration of these selections remains a manual smoke
check; fixture tests do not establish native setter compatibility.
Coordinator tests use unattached
CAMetalLayers and injected notification/encoding services; they never create a
window, initialize a renderer, or call the real wallpaper setter.

## Audio responsiveness

Device-free evidence: `build/verification/audio-20260915-121238/report.json`.
The synthetic 234.375 Hz tone changed a rendered tile's red channel from 26 to
120 through the shader spectrum and its width from 64 to 88 pixels through
SceneScript. Silence, disabled audio response, and an out-of-band 3515.625 Hz
tone produced identical baseline pixels. The probe uses private GPU images,
not a window, audio device, microphone or desktop capture.

Audio regression commands, using the Homebrew environment in `scripts/build.py`:

- From `upstream/renderer`, `cargo test --release -p wallpaper-core --lib audio`
  covers capture ownership/failures, mono/multichannel conversion, and resampling
  including sample-rate changes (20 passing checks).
- `cargo test --release -p wallpaper-bridge --lib` covers live toggle errors,
  rollback/persistence, nonblocking selection, and mirror behavior (199 passed).
- CMake targets `audio_tests`, `particle_mouse_controlpoint_test`, and
  `script_runtime_compat_test` cover physical FFT frequency mapping/DC/Nyquist,
  silent/stale input, box/sphere emission transitions and typed SceneScript views.
  Run `audio_tests --gtest_filter='AudioResponseMonoTest.*'` (16 passed),
  `particle_mouse_controlpoint_test` (35 passed), and
  `script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'` (2 passed).
  The broader script compatibility check passed 28 tests with the already
  documented `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors` failure
  excluded; this does not claim that unrelated case is fixed.

`python3 scripts/test.py` passed all 82 native tests, with evidence in
`build/Tests-20260915-122402-892930.xcresult`. The full
`python3 scripts/build.py --configuration Release` build succeeded and updated
`build/Build/Products/Release/MacWallpaperEngine.app`. Quit and reopen the app
to load the rebuilt renderer and settings UI.

The existing `offscreen_scene_probe` accepts `WE_TEST_AUDIO_HZ=0..6000` for
synthetic PCM; zero means silence. `WE_TEST_AUDIO_ENABLED=0` verifies the disabled
gate. Set these alongside `WE_TEST_PROJECT`, `WE_TEST_ASSETS`, and
`WE_TEST_OUTPUT`. Audio is submitted after GPU setup so shader compilation cannot
expire its live-input timeout. These options never initialize audio hardware.

Live system authorization, device switching, and desktop presentation were not
tested. For an explicitly authorized manual smoke check, use an authored
audio-reactive scene, enable Audio Response, grant system audio recording access,
play/pause music in another app, and check shader/script/particle response. Verify
that mute affects wallpaper playback only, the final disabled/removed scene stops
capture, and denied permission surfaces an error. Unimplemented non-audio scene
features (including some script outputs) can still affect wallpaper compatibility.

## General renderer regressions

Run `python3 scripts/test-renderer.py` for non-desktop renderer checks. It builds
the C++ test binaries and surface-free GPU probe using the Homebrew environment,
then runs generated scenes through pooled and isolated texture allocation.
`--skip-build` reuses those binaries; `--project /path/to/project.json` adds a
local scene and may be repeated. `--assets` selects the shared assets directory.
Reports, hashes, logs, original synthetic fixtures, and private GPU output go
under a new `build/verification/adaptive-*/` directory; imports are read-only.

Coverage is based on rendering semantics, not workshop IDs:

- Font decoding prefers valid authored bytes, then a usable installed family,
  then a platform fallback. Missing paths and malformed embedded fonts use the
  same fallback for measurement and rasterization. Tests cover seven font choices,
  three text samples (including Chinese), missing/corrupt sources and valid assets.
- Texture lifetime tests check 32 generated multi-version graphs against a
  last-access oracle, plus nested composites with aliases, three sizes, visible
  and hidden parents, and background-copy enabled/disabled. Alias clears and
  readers must refer to the same canonical resource.
- Eight generated GPU scenes vary nested children, background-copy settings,
  visibility, dimensions, transforms and declaration order. In addition to exact
  pooled/isolated pixel equality, known pixel assertions verify that empty inputs
  do not leak old pixels and children actually render (two blank outputs fail).
- The probe resolves each project's entry/package version and render dimensions;
  it discovers text nodes instead of using fixed layer IDs. It still tests scene
  rendering only, not video/web projects or AppKit presentation.

Latest evidence: `build/verification/adaptive-20260915-021127/report.json`.
All eight generated cases and three local scenes passed allocation pixel equality.
Lonely Cat and Acheron Black Hole logged no renderer errors. The Sparkle scene
still logs unrelated shader failures for Sine Wave Circle, Multistage Wave and
Tone mapping. Its allocation check passed, **not** full wallpaper compatibility.
The report records these diagnostics separately; optional real assets are not
claimed fully correct without authored references. No live audio or desktop
interaction was tested. The full native app suite and Release build also passed.

### Original Lonely Cat regression

The C++ tests now cover persistent shader-cache metadata, cache invalidation after
include edits, corrupt-cache recovery, parent-aware compose-background sampling,
and SceneScript AM/PM sprite-frame selection. These tests do not create a window
or Vulkan device.

`TextObjectRuntime.LonelyCatHeadlessRegression` is an opt-in local-asset diagnostic
in `text_object_runtime_test`. Set `WE_TEST_PROJECT` to Lonely Cat's `project.json`,
`WE_TEST_ASSETS` to the installed `SceneAssets` directory, and `WE_TEST_CACHE` to a
**disposable build-directory cache**, then run the binary with
`--gtest_filter=TextObjectRuntime.LonelyCatHeadlessRegression`. Add
`WE_TEST_EXPECT_WARM=1` for a second run to assert zero shader compilations.
It parses the package, ticks scripts, and constructs the render graph; it does not
initialize playback, capture the desktop, or modify the imported wallpaper.

The renderer test build requires `cargo build -p shader --features ffi --release`
and CMake `BUILD_TESTS=ON`, `RUST_SHADER_FFI=ON`, and `RUST_SHADER_STATICLIB` pointing
to `upstream/renderer/target/release/libshader.a`. Use the Homebrew environment from
`scripts/build.py`. Current binaries/evidence live under
`build/verification/renderer-tests` and `build/verification/lonely-cat-*.log`.

Known pre-existing extended-suite failure:
`ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
references undeclared `scriptProperties`. It also fails with the original
`ScriptEngine.cpp`; it is not a regression from the Lonely Cat fixes. The other
27 script compatibility tests, 45 scene schema tests, 59 text tests, 4 render-target
lifetime tests, and the shader cache regression pass. Native app tests remain the
routine gate above.

### Offscreen GPU verification of clock corruption

`offscreen_scene_probe` is a separate, explicitly invoked diagnostic executable,
not a ctest or UI test. It creates a surface-free Vulkan device and private render
targets, uses the production shader passes and batching plan, and writes PPM
images under `WE_TEST_OUTPUT`. It does not create a window, swapchain, audio device,
or inspect the desktop. Use a disposable build directory for its output/cache:

```sh
WE_TEST_PROJECT="$HOME/Library/Application Support/mac-wallpaper-engine/Library/3299228616/project.json" \
WE_TEST_ASSETS="$HOME/Library/Application Support/mac-wallpaper-engine/SceneAssets" \
WE_TEST_OUTPUT="$PWD/build/verification/cat-batched" \
build/verification/renderer-tests/tests/offscreen_scene_probe
```

The reported background patch and white clock/date bars were reproduced in
`build/verification/cat-offscreen-before/frame-2.png`. The fixes provide a real
macOS font when Windows Consolas is missing, retain pooled targets until every
logical version has finished, and explicitly clear effect inputs when
`copybackground=false`. `render_target_lifetime_test` asserts version lifetimes
and a real transparent writer before an effect samples its empty input. The text
regression checks actual glyph coverage rather than just nonempty strings.

After-fix GPU output is `build/verification/cat-batched/frame-2.png`. Its full-size
PPM is byte-identical to the same run with `WE_TEST_NO_REUSE=1` in
`build/verification/cat-batched-no-reuse`. The patch/rotated duplicate is absent
and the clock/date are readable. The dim AM/PM row is present in the authored
sprite texture itself; the current period is highlighted. These runs had no live
audio input and do not verify audio-reactive motion or desktop presentation.
Logs for this pass are `build/verification/cat2-*.log`; the Release build and
59 native app tests passed.

## JPEG orientation regression (流萤)

`tex_schema_tests` covers all eight EXIF display transforms on asymmetric RGBA
pixels, both TIFF byte orders, truncated JPEG/EXIF data and invalid IFD offsets.
The parser applies orientation independently to each embedded mip and loose JPEG;
loose header dimensions use the same display orientation.

Local wallpaper `3798997788` reproduced the reported overlapping image in the
surface-free `offscreen_scene_probe`. Its base JPEG stores 2342×3508 pixels with
EXIF orientation 8, while the TEX header and already-oriented smaller mips use
3508×2342. Ignoring EXIF mixed differently oriented mip levels during filtering.
After the fix the same scene and Iris Movement effect render without the overlap
or bottom band. Private before/after evidence is under
`build/verification/firefly-{before,after}`; no private asset is checked in.
This is an offscreen GPU check, not proof of desktop/AppKit behavior.

## Optional development tools

See [docs/DEVELOPMENT-TOOLS.md](docs/DEVELOPMENT-TOOLS.md) for Peekaboo,
Instruments, Accessibility Inspector, and the local regression corpus workflow.
Run `python3 scripts/check-dev-tools.py` for a non-interactive installation check;
it does not inspect or control the desktop and is not a release gate.

## Optional desktop automation

The existing `UITests/MacWallpaperEngineUITests.swift` suite is retained only as an
opt-in diagnostic tool: `python3 scripts/test.py --ui`, or the
`MacWallpaperEngineUI` Xcode scheme. It controls the desktop and is neither part of
routine verification nor a required release gate. Agents must not run it without
an explicit user request. No Peekaboo scripts or requirement were found in this
project when this policy was introduced.

## Manual release smoke checklist

Perform these checks yourself when preparing a release, using disposable imports
where needed. Note any checks skipped for unavailable hardware or assets.

- Launch: one library window, starter wallpaper visible, no blank floating panels.
- Navigate Library, Workshop, Display, and Settings. Command-comma should reuse
  the existing window. Close and reopen the window without quitting or crashing.
- Open and cancel Import. Search for a nonexistent local title, clear the search,
  and confirm the collection returns. Single-click a wallpaper and refresh:
  selection should survive. Double-click must not close the window.
- Check Library/Workshop at 1240×800, 960×640, and 760×560 in light/dark mode. Inspectors stay
  present; panes resize without losing the target or primary actions. Command-F,
  grid arrows, Return/Space, text editing, and VoiceOver names remain scoped correctly.
- Search Workshop, edit an unsubmitted query, then advance a page: pagination must
  still use the displayed query. Submit to switch queries. Navigate away and back;
  query/page/selection should stay. A failed request's Retry repeats that request.
  Open and dismiss download setup.
- Select a target display and apply; other displays keep their assignments.
  Disconnected, disabled, or mirror targets are not silently redirected to primary.
  Pause/resume and relaunch; expected wallpaper/playback state should return.
- Leave invalid scaling text, refresh or change routes, then return: preserve text
  and disable Apply Changes. Return stages only that field, not unrelated properties.
  Check immediate audio/FPS/scaling-mode semantics versus pending Apply/Revert.
- Install or locate SteamCMD in Settings and use the same runtime in Workshop
  without restarting. Installation itself must not log in or start a download.
  A blocked download remains present across relaunch/retry. Only explicitly confirm
  Allow This SteamCMD after checking the shown path/fingerprint and understanding
  the risk. Global Gatekeeper/signature checks remain enabled; updated bytes need
  another approval. Verify category-sidebar filters never activate wallpapers.
- Queue at least four Workshop items. Confirm three active transfers and one
  waiting item, then cancel one active item and check the queued item starts while
  peers continue. Cancel queued work and confirm it never starts. Dismiss details,
  change search/page, and reopen each transfer from Downloads for its own Steam
  Guard prompt. Verify independent retry, completion, and scene-assets setup.
  Saved sign-in settings stay locked until all pending work finishes; quitting
  stops all transfers. Routine synthetic-process tests do not prove Steam CDN
  throughput, simultaneous live-account authentication, or visual behavior.
- Start a disposable download, close details and navigate elsewhere. The activity
  bar restores its prompts; cancellation stops it without changing the old library.
  Downloads do not auto-apply. Show in Library can reveal an item excluded by filters
  and return to the original results; deleting it removes Workshop's installed badge.
- Try invalid media and missing scene assets: show actionable failures without
  blocking videos or losing an already downloaded scene. A valid wallpaper remains usable.
- When relevant, check each connected display and sleep/wake behavior. Restore
  your original wallpaper configuration afterward.
- Native desktop posters: create multiple Desktops, apply a video and immediately
  open Mission Control WITHOUT switching Desktops. Apply a different scene and
  repeat, including rapid A→B→C changes. All desktop thumbnails should update from
  the new renderer's first frame, with no 400 ms debounce or two-second sampling
  cooldown. Check the actual rendered image (not its Workshop cover), including
  Fill/Match/Stretch, scaling and flipping. Check different and mirrored wallpapers
  on connected displays, pause/resume, and a newly created Desktop. Eject a
  wallpaper and check all Desktops recover their previous native image/scaling.
  Quit/reopen to check restoration journaling. Also change a native wallpaper
  outside the app and verify quitting does not overwrite it.

Mission Control posters are sampled still frames, not live animation. Updates
begin as soon as a rendered frame is available; rendering/PNG encoding and the
system's thumbnail compositor still take time (zero-millisecond visual latency
cannot be guaranteed). The app uses dynamically resolved
`CGSCopyManagedDisplaySpaces` / `DesktopPictureSetDisplayForSpace` to target all
normal desktop Spaces directly, including inactive ones. It restores them on
eject/quit, preserves full native options and the old journal format, and never
switches Spaces, restarts Dock/WallpaperAgent, or edits Apple's wallpaper plist.
These are non-public APIs: if unavailable on a future macOS, the app logs the
limitation and falls back to NSWorkspace's current-Space behavior. Originals and
posters live under `~/Library/Application Support/mac-wallpaper-engine/DesktopPosters`.
Read-only inspection confirmed the symbols and four desktop Space IDs on macOS
26.6.2 (built with the 26.5 SDK); the native setter and GPU/Mission Control appearance were NOT exercised by
routine verification. Pixel/ledger/coordinator tests do not prove visual timing.

These visual and OS-integration checks are not proven by passing native tests.
Keep UI wiring, window behavior, and visible rendering explicitly unverified if
no manual or explicitly requested desktop check was performed.

## Animated lock screen

The opt-in native extension uses private `WallpaperExtensionKit` XPC types and a
remote `CAContext` containing the existing renderer's `CAMetalLayer`. Ordinary
desktop windows are unchanged. Native PNG poster synchronization is suspended
before native extension selection, without an intermediate legacy image restore.
Poster files and their original-selection journal remain available while the
extension owns Desktop/Idle. Disable restores those entries and resumes PNG
synchronization; quit restores the native provider before attempting poster
restoration. A rejected legacy restore is still logged and its journal retained.
Unlike the PNG-only path described above, enabling
this feature edits explicit display/Space entries in the wallpaper store and
reloads only the positively identified user-owned WallpaperAgent.

Activation waits for a revision-matched, GPU-ready non-preview surface
acknowledgement. Missing/failed native loading and global linked wallpaper
conflicts are errors, not successful enablement. Restoration preserves external
changes and handles macOS copying the selection into SystemDefault. The extension
validates its Apple host using the connection audit token, rejects invalid private
type layouts, reads isolated relative asset paths, and does not access credentials
or change authentication. Lock-screen sound, audio input and media data are off.

Native regression tests exercise per-display ownership, independent originals,
external Desktop changes, journal recovery after service-reload failure, inherited
Space cleanup, system-copied fallback restoration, and global linked conflicts.
The poster handoff regression covers a pathless original, retention of its poster
and recovery journal, and rejection of delayed encoding completions after suspension.
The Rust lock-screen export regression checks committed-versus-draft scaling,
pause/resume and ejection. Tests do not select real wallpapers.

Orphaned native selections now recover only app-owned Desktop/Idle fields from
surviving native fallback selections, preserving external fields. Space display
entries prefer the physical display, then their Space default, then SystemDefault
and AllSpacesAndDisplays. Missing fallback data still blocks activation without
changing the store; this cannot reconstruct a lost per-Space original exactly.
Space defaults are journaled before activation alongside SystemDefault so copied
providers restore on disable or relaunch. Regression fixtures cover orphaned Idle
recovery with an unchanged Desktop, copied Space defaults across relaunch, and
refusal when no native fallback survives. All 86 native tests passed in
`build/Tests-20260915-143525-634854.xcresult`; live wallpaper/lock-screen behavior
was not exercised.

Explicitly authorized local experiments on macOS 26.6.2:

- Private context and IOSurface payloads passed real anonymous XPC round trips.
- Bundled video and Lonely Cat produced distinct GPU-fenced frames in remote
  layers. The actual native adapter produced four distinct scene snapshots and
  passed pause/clear/replacement readiness with the hosted context retained.
- Ad-hoc-signed sandboxed Release extension was launched by WallpaperAgent;
  video and scene separately acknowledged 3456×2234 rendered frames. Actual
  lock transitions reached `mode=locked`, `activity=active`, playback unpaused.
- A synthetic native provider was visually observed changing colors on the
  desktop. macOS refused screenshots while locked, so the final lock-screen
  appearance/smoothness is **not visually verified**.
- Another active wallpaper manager re-established global linked choices during
  continuous switch testing. Those runs ended with a reported conflict and
  ownership-aware restoration, not a claim of uninterrupted end-to-end playback.

Local evidence is under `build/verification/lock-screen/` (logs only are retained;
private captures, fixtures and executable experiment scaffolding are disposable).
The feature stays off by default and must not run alongside a competing global
wallpaper manager. Multi-display hardware, long-duration power use, sleep/wake,
and the final settings UI have not received full visual release verification.

