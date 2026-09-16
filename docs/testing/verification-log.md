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
