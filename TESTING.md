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
lifecycle, authentication, saved sessions, scene-asset installation, and GitHub
Release update discovery/download state. App-update tests use fixture JSON and a
fake client: they never contact GitHub, download a real archive, or replace the
running app. They cover version comparison, asset selection, host allowlisting,
progress clamping, classified errors, and install retry/timeout. Live GitHub
checks, archive extraction, and Applications replacement remain a manual smoke. Download
tests exercise serial private terminals, per-job secrets, saved-sign-in handoff to
the next job, cancellation, duplicate-click suppression, FIFO handoff after
failure/cancel, shutdown without launching queued work, staging reclaim limited to
directories nothing is writing to, and protection against stale credential
rejections erasing a newer session. Import tests cover complete atomic adoption,
concurrent destinations, and rejection of linked, special, or incomplete content.
Workshop service tests cover search and pagination beneath the UI (two tests use live Steam
responses and therefore require network access). These remain in routine coverage.

Deterministic Workshop tests additionally cover committed-query pagination,
superseded requests, cancellation, and exact failed-request retry through the real
page parser. Editor-state tests cover locale-specific scaling, invalid raw text,
and independent wallpaper/field drafts.

Download-flow verification (2026-09-15): `python3 scripts/test.py` passed all
162 native tests and 34 Python script tests. Evidence:
`build/Tests-20260915-232543-966074.xcresult`. Retained-intent tests cover
setup/account progression, explicit shared-resource consent (including reinstall),
resource-job deduplication, account correction, and removal preventing resumption.
The bundled WKWebView regression opens no window and checks setup dismissal,
snapshot updates without reopening, resumption, and request removal. Queue tests
exercise saved-session handoff through local PTY fixtures, not a real Steam account.
JavaScript syntax checks passed. Desktop visual presentation and live Steam
authentication/downloads remain unverified; no Release build was performed.

SteamCMD setup tests use isolated preferences/directories, URLProtocol archives,
real system tar, and owned child processes. They cover publication/replacement,
invalid discovery, traversal/link/archive-size boundaries, the updater's
contained sibling Frameworks link, network failures, signature-policy blocking,
cancellation, and no late writes. Runtime fixtures exercise canonical macOS path
aliases and nested Mach-O executable dependencies. Approval fixtures also cover
signed command-line assessment output that must not require Allow This SteamCMD.
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

SteamCMD universal-signature regression (2026-09-15): macOS `codesign --verify
--deep --strict` returned an internal error for the installed Valve-signed
`steamclient.dylib`, while explicit Intel and ARM slice verification both passed.
Runtime validation now checks every CPU/subtype independently, retains deep
framework resource checks, and leaves Gatekeeper and content-bound approval intact.
The read-only production-service smoke passed all installed-runtime signatures and
stopped at the existing macOS approval gate; it did not execute or modify SteamCMD.
Evidence: `build/verification/steamcmd-signatures/validation.log`.

All 13 `SteamCMDApprovalTests` passed in an isolated XCTest bundle built from the
production runtime/runner and the existing test file (`regressions.log` in that
directory). The new universal-library regression uses disposable signed fixtures,
rejects corruption in either architecture even with an existing approval, and fails
with the old combined-verification loop (`before-regression.log`). The normal
`scripts/test.py` run and Swift-only Release build were attempted but blocked by
concurrent `WebControlPanel.swift` compilation errors at lines 107 and 126; the app
was not updated. Native test bundle: `build/Tests-20260915-215713-080771.xcresult`.
Desktop presentation and a real Workshop download were not exercised.

WebKit interface migration (2026-09-15): `python3 scripts/test.py` passed all 152
native tests in `build/Tests-20260915-223145-387538.xcresult`, and
`python3 scripts/build.py --swift-only --configuration Release` succeeded,
updating `build/Build/Products/Release/MacWallpaperEngine.app` (quit and reopen
the app to load it). The bundled interface was additionally exercised outside the
app against a synthetic state fixture in a local browser: tab routing, tag
filtering re-querying the Workshop, property and display actions carrying their
identifiers, and layout at 1240×800 and 760×560 without horizontal overflow. That
fixture proves markup and script behavior only, with placeholder thumbnails; real
previews, desktop presentation, downloads, and the XCUITest suite were not
exercised.

Control-panel layout tests measure offscreen NSHostingController proposals at
760×560, 960×640, and 1240×800 in English and Chinese, asserting the root accepts
each window width without forcing a taller window. A companion offscreen WKWebView
regression loads the bundled interface under its custom scheme, waits for the
native reply bridge, routes a `navigate` message to Settings (checking the returned
page, the visible settings panel, and native navigation selection), and asserts a
non-allowlisted external URL is
rejected. Both open no window, take no screenshot, and start no renderer.
They establish layout and bridge bounds, not visual or desktop-integration
correctness.

Theme coverage in `AppThemeTests` checks preference recreation, rejection of invalid
changes without overwriting saved values, recovery from a damaged saved accent,
and reset isolation. The offscreen appearance regression in `ControlPanelLayoutTests`
commits the actual Appearance controls through the native bridge, checks the white
canvas, changes accent/tone, resets, simulates live native appearance changes on
the detached view, verifies explicit Light wins over Dark, and reloads through the
WebContent recovery path with saved customizations intact. It never changes the
system appearance, creates a window, captures a screenshot, or alters wallpapers.

Theme verification (2026-09-16): `python3 scripts/test.py` passed 215 native tests
and 34 script tests; evidence: `build/Tests-20260916-172417-035420.xcresult`.
After the final contrast adjustments, the 10 `AppThemeTests` and
`ControlPanelLayoutTests` passed again; evidence:
`build/Logs/Test/Test-MacWallpaperEngine-2026.09.16_17-26-53-+0800.xcresult`.
A throwaway, scheme-matched offscreen WebKit probe exercised 48 light/dark,
surface-tone, and extreme-accent combinations at 760/960/1240px, then 768 combinations
using deterministic sampled accent colors. Computed text and primary-label contrast
exceeded 4.5:1; focus, custom primary boundaries, and progress indicators cleared
3:1 in the checked combinations. Appearance content did not overflow horizontally.
The probe was removed. These are non-visual checks; desktop presentation, native
color-picker interaction, and titlebar appearance remain visually unverified.
No Release build was requested or delivered.

A third regression drives the reply bridge's `dismissError` command directly: a
library-refresh failure and a download failure raised through the real download
path are reported once, stay suppressed in later snapshots after dismissal, and
surface again when the same failure recurs after a successful refresh.

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

## Presentation suspension and scene timing

Desktop presentation suspension is separate from user/battery playback state.
Lock-screen scene exports retain only the latter, so hiding or locking the
desktop does not pause the visible lock-screen provider. Presentation changes
invalidate in-flight reconciliation through the existing generation guard;
stale completion restores committed configuration with the current effective
pause. A failed audio restart compensates renderer/capture changes and restores
capture intent. The Swift policy serializes delivery and tracks acknowledged
state separately from desired visibility. Failed or withheld delivery remains
pending for the next evaluation, including unchanged visibility and canceled
shutdown, instead of being mistaken for a successful resume.

Frame timing keeps render cost separate from animation time. Dropped busy ticks
remain included in the elapsed delivered-frame delta; restarting excludes paused
time. Deterministic timer regressions cover dropped ticks, restart, FPS changes,
and long gaps without using desktop surfaces or audio devices.

Verification (2026-09-16):

- `python3 scripts/test.py`: 192 native tests and 34 Python tests passed.
  Result bundle: `build/Tests-20260916-111442-571839.xcresult`.
- With the Homebrew environment from `scripts/build.py`,
  `cargo test --release -p wallpaper-bridge --lib`: 206 passed;
  `cargo test --release -p wallpaper-core --lib audio`: 23 passed.
- The renderer's CMake `timer_tests` target: all six `FrameTimerTest` cases passed.
- An isolated production-timer smoke at 30 FPS with 40 ms simulated draws
  advanced 2.215159 seconds of scene time over 2.215392 seconds of wall time
  (ratio 0.999895); the first delta after a 500 ms pause was 0.033333 seconds.
  Production-policy smoke checks delivered the withheld resume after canceled
  shutdown and retried an injected asynchronous audio-start failure without a
  visibility change. Throwaway probe programs were removed.

Logs and the report are under
`build/verification/presentation-fixes-20260916-105151/`.
Desktop presentation, real CoreAudio restart failures, and native lock-screen
integration were not exercised; their regression coverage uses injected state
and failures. No Release application build was performed or delivered.

## Wallpaper properties

The bridge exposes authored combo labels and editable values to native menu
pickers. Property snapshots evaluate authored visibility conditions against all
effective draft values, so language-specific rows follow the wallpaper's language
selector. Hidden values remain in the draft; switching languages does not erase
them. Informational text properties are displayed as labels.

Bridge regressions in `tests::property_snapshot` cover combo selection, conditional
rows after edits/default restoration/discard, hidden-value preservation, and
malformed-condition fail-open behavior. From `upstream/renderer`, run
`cargo test --release -p wallpaper-bridge --lib` with the Homebrew environment in
`scripts/build.py`.

A read-only Lonely Cat probe exercised all six authored language options through
the headless bridge: each returned its matching 13 properties, and every visible
combo contained its current selection. `build/verification/property-bridge.log`
records 202 passing checks (201 permanent tests plus the removed local-asset probe).
No desktop, wallpaper setter, or real UI was exercised. Manually check the Language,
Clock Location, and Bar Style menus and language-row changes after reopening the app.

Native verification passed all 86 tests in
`build/Tests-20260915-161710-193905.xcresult`. The full
`python3 scripts/build.py --configuration Release` build succeeded, regenerating
Swift bindings and updating `build/Build/Products/Release/MacWallpaperEngine.app`.
Quit and reopen the app to load this build.

## Audio responsiveness

Audio Response defaults to enabled for new wallpaper configurations and missing
saved fields; an explicitly saved `false` remains disabled. The application-level
preference controls activation; low-level renderer and lock-screen extension
defaults remain disabled so they do not independently opt into audio capture.
A device-free configuration smoke run verified missing-field handling and saved
opt-out round trips. The default-scene activation test verifies capture starts
without a manual toggle. The bridge run passed 201 tests; the separate
`local_lonely_cat_language_smoke` probe failed because its private project-path
environment variable was absent, not because of audio behavior.

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
audio-reactive scene, leave Audio Response enabled, grant system audio recording access,
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
- Puppet attachments use the animated bone affine each frame while preserving the
  child layer's authored/script transform. Character-sheet reference poses are
  decoded separately from cut-up bind geometry so additive and non-additive
  animations reassemble correctly. Synthetic regressions cover declaration order,
  animated translation/rotation/scale, repeated same-time samples and local edits.
- Scalar material timelines preserve paused first keys and authored Bezier handles;
  SceneScript named animation controls drive play/replay, pause, stop, seek and rate.
  Puppet animation deltas use the skeleton reference pose, not the first animation
  sample, preserving initially collapsed eyelids and authored rotations.

Animation-fix evidence: `build/verification/render-animation-fix/` contains private
before/after GPU frames. The corrected scene rendered 71 samples at 0.1-second
intervals; inspected samples show no permanent chromatic distortion or triangular
face artifact during blinking. Authored background shake remains enabled.
All 44 model schema tests, two timeline runtime regressions and the parser-to-material
timeline regression passed. The broader 133-case scene/script/text run had one
known failure (`HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`) and two
asset-dependent skips. No desktop automation was used.
`build/verification/adaptive-20260915-215052/report.json` records eight generated
scenes and Sparkle passing pooled/isolated pixel equality without diagnostics,
plus repeated scene-load checks. The full Release application build succeeded.

- `scene_reload_cycle_probe` parses every selected project twice in one process,
  each parse on a fresh thread with fresh VFS mounts, the way a wallpaper switch
  builds a new `SceneWallpaper`. It catches per-process state that survives a
  scene teardown and stalls the next load; a stall is reported as a probe
  timeout. It covers scene parsing and script compilation only, not presentation.

Latest evidence: `build/verification/adaptive-20260915-214143/report.json`.
All eight generated cases and two local scenes passed allocation pixel equality
without renderer diagnostics. The Sparkle scene also rendered 150 60 FPS samples
and a 240-frame 30 FPS cycle through `offscreen_scene_probe`; sampled output shows
the attached mask/body and character-sheet pieces assembled, with no renderer
errors. Reload cycles passed for both local scenes. This proves offscreen
animation and reload state, not desktop presentation or audio.
The Release application build succeeded at `build/Build/Products/Release/`.

### Large-scene first-frame startup

The surface-free `offscreen_scene_probe` reports `startup parsed`, `prepared`,
and `first-frame` timings. Use a fresh `WE_TEST_OUTPUT` directory for a cold
shader-cache run and repeat the same output directory for a warm run.
No application windows, audio devices, or desktop wallpaper setters are used.

The Sparkle apply-timeout investigation identified quadratic staging-buffer
growth: each fixed-size extension zeroed a temporary CPU vector and copied the
entire previous allocation twice. Geometric blocks and direct replacement-buffer
copying preserve existing offsets/data without that repeated work. The 20-second
Apply deadline and rollback behavior remain unchanged.

Evidence in `build/verification/sparkle-fix/`: the original probe produced its
first image at about 43.2 seconds; the allocator-only repair (without the discarded
pipeline-cache experiment) reached its first frame at 4.31 seconds. Three rendered
frames before/after the allocation change were byte-identical. These are private
GPU results, not verification of desktop presentation.

The final shader repair also handles undersized cross-stage varying declarations,
conditional helper headers, source-defined `log10`, legacy scalar/vector argument
conversion, compound assignment narrowing, and scalar initializer conversion.
Shader pipeline revision 4 invalidates old compiled programs. The final Sparkle
probe logs no shader/effect errors: cold first frame 5.00 seconds, warm 2.41 seconds
(`scene-ready-cold.log`, `scene-ready-warm.log`). The portable Rust shader suite
passes; the three existing asset-dependent pipeline cases for genericimage4 and
Workshop 3414858021 were excluded because their referenced files are absent.
Generated pooled/isolated renderer checks also passed all eight pixel cases.

Delivery build: `python3 scripts/build.py --configuration Release` succeeded.
Native verification (`build/Tests-20260915-162715-751354.xcresult`) ran 87 tests:
86 passed; `LockScreenWallpaperTests.testWallpaperRevisionInvalidatesEverySpaceAndKeepsRestorationOriginals`
failed its configuration-data inequality assertion. That test exercises native
selection fixtures, not the shader or staging-buffer paths changed here; it was
not altered as part of this renderer fix. Desktop presentation remains untested.

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

## Translucent coverage regression (red contours around soft art edges)

`SetBlend` used `VK_BLEND_FACTOR_SRC_ALPHA` for both the color and the alpha
factor of `BlendMode::Translucent`, so every translucent draw wrote
`As*As + Ad*(1-As)` instead of source-over's `As + Ad*(1-As)`. Partially covered
texels therefore lost coverage each time a layer was composited, and nested
compose layers multiplied the loss. Wherever the puppet's own parts overlap along
a soft (anti-aliased) seam, the deficit let the layer's background show through as
a thin saturated line: the reported red outline around the eyes, nose bridge and
cheek patches of `3226487183`. The color factors are unchanged, so opaque and
fully transparent texels render exactly as before; only alpha accumulation is
corrected. This is a renderer-wide compositing fix, not a per-wallpaper rule.

`scripts/test-renderer.py` grows a ninth generated GPU scene (`generated-alpha`)
that composites a half-covered source over transparent, half-covered and opaque
destinations inside a compose layer, then samples the composed alpha back as RGB.
Expected readback is 128/191/255; the pre-fix binary produced 64/96/191 and fails
the case. It uses only synthetic shaders and no workshop content.

Private before/after evidence for the reported scene is
`build/verification/eye-outline/{crop,frame}-{prefix,postfix}.png` with a
red-excess contour metric of 10509 px before and 3395 px after (the remainder is
authored eyeliner, not a contour). The full matrix plus that scene passed in
`build/verification/adaptive-20260915-235447/report.json` (pooled/isolated pixel
equality, no diagnostics, reload cycles clean), and local scenes `3799253558`,
`2309704117`, `3219398263`, `3299228616` still render without new diagnostics
(their MDLA, Rust `light_map` compile and shader-value alias errors are
pre-existing and untouched by this change). Offscreen GPU only; desktop
presentation remains unverified.

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
- Switch between the Discover, Installed, and Settings tabs, and through the six
  Settings categories (General, Appearance, Displays, Library & Steam, Storage, About).
  Command-comma should reuse the existing window. Close and reopen the window
  without quitting or crashing.
- In Appearance, choose Light and Dark, then System and change macOS appearance.
  Check the titlebar, menus, controls, dialogs, inspector, and download popover.
  Set an accent and surface tone; relaunch and confirm both persist. Try white and
  black accents, then Reset appearance; wallpapers and playback must not change.
- Open and cancel Import. Search for a nonexistent local title, clear the search,
  and confirm the collection returns. Select a wallpaper and refresh:
  selection should survive. Selecting must not activate a wallpaper; Apply/Reapply
  and double-click activate it, and double-click must not close the window.
- Check Discover/Installed at 1240×800, 960×640, and 760×560 in light/dark mode.
  The inspector stays present; panes resize without losing the target or primary
  actions. Command-F,
  grid arrows, Return/Space, text editing, and VoiceOver names remain scoped correctly.
- Search Discover, edit an unsubmitted query, then advance a page: pagination must
  still use the displayed query. Submit to switch queries. Navigate away and back;
  query/page/selection should stay. A failed request's Retry repeats that request.
  Open and dismiss the Downloads/Import pane.
- Select tags in the Discover filter sidebar across the resolution, ultrawide/portrait,
  genre, age-rating and category groups: results must only contain items matching every
  selected tag, and Clear filters must restore the unfiltered query.
- Select a target display and apply; other displays keep their assignments.
  Disconnected, disabled, or mirror targets are not silently redirected to primary.
  Pause/resume and relaunch; expected wallpaper/playback state should return.
- Leave invalid scaling text, refresh or change routes, then return: preserve text
  and disable Apply changes. Return stages only that field, not unrelated properties.
  Check immediate audio/FPS/scaling-mode semantics versus pending Apply/Revert.
- Install or locate SteamCMD in Settings → Library & Steam or the download setup
  dialog and use the same runtime without restarting. Installation itself must
  not log in; a retained wallpaper request continues once its prerequisites are met.
  Official signed CLI SteamCMD should finish from Install without an extra Allow
  step. A blocked download remains present across relaunch/retry. Only explicitly
  confirm Allow This SteamCMD after checking the shown path/fingerprint and
  understanding the risk, when Gatekeeper actually rejects a copy. Global
  Gatekeeper/signature checks remain enabled; updated bytes need
  another approval. Verify filter changes never activate wallpapers.
- Queue at least four Workshop items. Confirm one active transfer and the rest
  waiting; cancel the active item and check the oldest queued item starts after
  cleanup. Remove queued work and confirm it never starts. Complete one sign-in and
  check that the next job attempts saved-session reuse. Steam may still ask again.
  Close the Downloads popover, change search/page, and reopen the active transfer's
  sign-in dialog. Verify independent retry, completion, and scene-resource consent.
  Saved sign-in settings stay locked until pending transfers finish; quitting
  stops all transfers. Synthetic-process tests do not prove Steam CDN throughput,
  live-account session reuse, or visual behavior.
- With setup missing, click Download, dismiss with Not now, and navigate elsewhere.
  The request must remain in Downloads; Continue setup resumes it. Removing it
  must prevent later automatic continuation. Completing setup/account/resource
  consent continues without another Start download button. Downloads do not auto-apply.
  Show in library can reveal an item
  excluded by filters and return to the original results; deleting it removes
  Discover's installed badge.
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

Each published lock-screen revision also updates the native choice configuration
for the selected display and every existing Space override. Keeping a constant
`current` choice while replacing only the extension's renderer left inactive-Space
thumbnails cached. Revision changes use the existing journaled store update and
WallpaperAgent reload; unchanged reconciliation does not reload the service.
The regression reproduces unchanged choices before the fix, then verifies all
selected choices change, repeated reconciliation is inert, and relaunch restores
the original selections. All 87 native tests passed in
`build/Tests-20260915-162934-166821.xcresult`. Actual Mission Control cache refresh
and visual timing remain unverified. With Animate Lock Screen enabled, manually
apply A then B without visiting other Spaces and inspect every desktop thumbnail.

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

