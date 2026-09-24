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

## 2026-09-24 — Equal-quality push integrated with concurrent download settings

- The first normal push was rejected because origin/main advanced to 9b07191 while integration checks ran. Rebased again without force-pushing, preserving the remote Workshop download-concurrency feature and both complete verification histories.
- The incoming commit changes Workshop queue/store, panel bridge/settings/localization and their tests; renderer sources are unchanged from the preceding integrated renderer gate.
- python3 scripts/test.py --only DownloadQueueTests --only WorkshopStoreTests --only ControlPanelShellTests --only AdapterSystemMediaProviderTests: 44 passed, 0 failed, 0 skipped on the final integrated tree. This is targeted follow-up, not a second full-gate claim; the preceding 5f05973 integration entry records the completed full native/renderer gates.
- Used the existing verification-log rotation helper to retain ten active entries and preserve every retired entry in the archive. No binaries, private inputs, raw power artifacts or credentials are included in the commit.
- No Release rebuild, desktop app restart or new power measurement. The previously delivered executable predates the remote parallax and download-concurrency changes; prior power observations are not relabeled as measurements of the final integrated source.

## 2026-09-24 — Downloads at once setting (1–6) and live SteamCMD concurrency measurement

- Live, on the user's account with an isolated harness (copied saved sign-in, private staging, nothing written back): 12 Workshop items of 1–10 MB took 67.7 s with 3 sessions and 47.0 s with 6; 24/24 succeeded, no 'logged in elsewhere', no rate limit. Sign-in took 9–13 s at 3 sessions, 13–22 s at 6.
- D (+@cMaxInitialDownloadSources 15, default -1): one 150 MB item gave 9.3/14.4 MB/s off and 4.3/16.3 MB/s on, which is network noise, so the convar is not set. Two 342 MB attempts failed with Steam 'No Connection' on this network (a system proxy is active); a small item succeeded right after.
- WorkshopDownloadManager.setMaximumConcurrentDownloads (clamped 1...6); WorkshopStore persists WallpaperMachine.concurrentDownloads; Settings → Library & Steam → Downloads at once; zh-Hans strings added.
- New tests: DownloadQueueTests.testChangingTheCeilingStartsQueuedWorkAndNeverStopsARunningTransfer, WorkshopStoreTests.testConcurrentDownloadsChoiceSurvivesRelaunchAndStaysInRange, ControlPanelShellTests.testDownloadsAtOnceChoiceReachesTheQueueAndSurvivesTheNextSnapshot.
- python3 scripts/test.py: 572 passed, 0 failed, 11 skipped of 583; Python suites OK.
- Not run: Release build, desktop/visual check of the new Settings row, a live batch through the app itself at 6 slots, and anything above 6 sessions.

## 2026-09-24 — Equal-quality optimization integrated with remote parallax fix before push

- Rebased the equal-quality optimization commit onto origin/main 5f05973, preserving e1e176a (first-run guide test surface) and 5f05973 (camera parallax scene-position correction). Source merged automatically; provenance retains the remote JSON values plus the local optimization note. Every remote verification-history entry and all three new local entries are preserved across the active log/archive.
- Rebuilt script_runtime_compat_test and audio_tests in a separate Release CMake output using scripts/build.py environment. ShaderValueUpdaterCompat.*, ShaderValuePacking.* and ComposeBackgroundUsesScreenCameraAndParentTransform: 10 passed, including CameraParallaxPlacesAChildLayerByItsScenePosition. AudioResponseMonoTest.*: 22 passed.
- python3 scripts/check_renderer.py: exit 0; 452 passed, 3 optional asset cases skipped; 10 generated pooled/isolated cases match independent pixel expectations, and 8 projects reload twice without errors.
- python3 scripts/test.py: exit 0; 152 Python cases passed; native 571 passed, 0 failed, 11 opt-in skipped (9 native media, 2 live Workshop). This fresh gate covers the integrated sources, not just the pre-rebase tree.
- No Release rebuild, app restart, desktop automation or additional power sampling during commit/push integration. The running/delivered app and earlier power records still identify executable c03902bfae6dddf9cdd929a2dfc73056280dfbe82b7241478d4e86bf048aadbc; they do not include or verify the newly integrated remote parallax change.
- Commit scope excludes binaries, private wallpaper/input copies, raw power records and credentials. Historical measurements remain observations with their original source/binary identity and attribution limits; no energy-saving percentage is claimed.

## 2026-09-24 — Candidate desktop power observations versus preserved old baseline

- User-restarted candidate PID 68021: loaded Mach-O UUID E0DC12BC-236F-360E-9AC8-ABBFD228B6C6 matches delivered executable SHA-256 c03902bfae6dddf9cdd929a2dfc73056280dfbe82b7241478d4e86bf048aadbc; fresh process sample contains Native Metal drawFrame. Saved wallpaper/config hashes and display geometry match the baseline: one online 4112x2658 scaled-pixel display, panel label 3456x2234, 120 Hz mode. This is runtime-path evidence, not actual presentation or visual equivalence.
- Reused scripts/power_benchmark.py --configuration Release --measure 60 --condition T3 --powermetrics --note "equal-quality candidate ..." three times after 120 seconds of quiet stabilization. Windows were 60.01, 60.01 and 60.00 seconds; no builds, source scans, GPU probes, app control or setting changes during sampling.
- App CPU mean: old 28.833% [27.0,30.0], candidate 31.933% [28.2,34.0], +3.100 percentage points. App GPU busy: old 20.267% [18.4,22.4], candidate 22.300% [18.6,25.5], +2.033 points. These observations do not show reduced application workload.
- WindowServer CPU mean: old 45.700% [45.2,46.0], candidate 46.333% [44.5,49.2]. GPU busy: old 18.567% [16.8,20.8], candidate 28.200% [22.2,35.6]. CoreAudio CPU: old 9.533% [9.0,9.9], candidate 18.767% [17.7,20.2]. All same-name WebContent CPU: old 0.233% [0.2,0.3], candidate 0.633% [0.3,1.3]. CoreAudio/WebContent GPU and absent extension remain unavailable, not zero.
- Whole-machine load mean: old 46.334 W [44.045,49.293], candidate 30.721 W [26.096,37.272], observed difference -15.613 W. Adapter input: old 55.557 W [53.736,58.331], candidate 30.721 W [26.096,37.272]. Old windows were finishing charge at 99-100%; new windows were charged at 100%. Adapter input differences are not an optimization result.
- Package power remains unmeasured: bounded sudo -n sampling required a password; no credential was passed through tools. No thermal warnings were reported. Brightness, audio content, panel visibility and other-app load were not independently fixed/observed, and the old windows were taken hours earlier. No paired app-quit reference or actual displayed-frame feedback exists.
- Conclusion: candidate runtime and three bounded power-observation windows now verified; no causal same-quality energy-saving claim is supported. Application CPU/GPU busy means were higher, while whole-machine telemetry was lower under different conditions. Prior allocation/FIFO/artwork work-elimination evidence remains valid; desktop visual equivalence and attribution of the power difference remain unverified.

## 2026-09-24 — Equal-quality verification: test-host launch boundary

- Clarification of the preceding equal-quality entry: python3 scripts/test.py launched its isolated unit-test host processes, as expected. No ordinary desktop playback app was launched, quit or restarted by the agent; no desktop automation, screenshot or audio-hardware test was performed. All recorded verification results and the explicit candidate desktop/power gaps are unchanged.

## 2026-09-24 — Equal-quality uniform, audio FIFO and artwork optimization

- Baseline: compiled Release CMake check executables from the complete current source tree before product edits; source/input and executable SHA-256 manifests include relevant untracked files. Preserved the existing desktop bundle separately; its source correspondence remains unconfirmed.
- Uniform probes: real warmed Metal and Vulkan UpdateUniforms boundaries each performed 64 writes; callback-construction allocations fell 64 -> 0, body allocations stayed 0, and alternating GPU colors remained correct. 4,329 float bit patterns match the old Ref algorithm; fixed direct/product/inverse packing passes 1,024 repetitions under EIGEN_RUNTIME_NO_MALLOC; the old algorithm aborts as expected.
- Audio probes: every one of 41 stereo windows matched all reference spectra (maximum difference 0); generation 41, accepted 9,024, retained 824. Tail movement per channel fell 135,136 -> 26,368 bytes, with FFT copies unchanged at 167,936 bytes. Oversized/latest-only input each drains 115 windows; tail movement per channel fell 5,704,000 -> 0 bytes.
- python3 scripts/test.py --only AdapterSystemMediaProviderTests: 6 passed, 0 failed/skipped. Identical 100-message artwork replay: base64 decoding and thumbnail/hash queries 100 -> 1; timeline events remain 100, final position 99. Clear/restore, re-subscription, failed input and old stream callbacks covered.
- Explicit renderer behavior filters: 35 passed (9 matrix/updater/camera, 22 audio, 1 Vulkan live-update and 3 Native Metal perspective/puppet/sprite cases). python3 scripts/check_renderer.py: exit 0, 452 passed/3 optional asset cases skipped; 10 generated pooled/isolated pixel cases agree with independent expectations, 8 projects reload twice. The optional local Native Metal case passed separately below; two text asset cases remain untested.
- python3 scripts/test.py: exit 0; 152 Python tests passed, native 571 passed/0 failed/11 skipped (9 opt-in native media, 2 live Workshop network cases). No desktop automation, app launch or audio hardware test requested or performed.
- Final five serial baseline/candidate pairs after one warmup each: synthetic silence, 4112x2658, 100% internal quality, same private input hashes and property override. Each run draws 120 Native Metal frames; 47 render passes/frame, 22 on scene output, 0 blits. Median of mean drawFrame thread-CPU times: baseline 0.89 ms [0.81,0.99], candidate 0.91 ms [0.85,1.00]. No stable timing gain measured; not whole-frame time, p95 or displayed FPS.
- Old desktop only: 120-second stabilization plus three 60.00-second windows through scripts/power_benchmark.py --configuration Release --measure 60 --condition T3 --powermetrics. App CPU/GPU busy means 28.833%/20.267%, WindowServer 45.700%/18.567%, CoreAudio CPU 9.533%, all same-name WebContent CPU 0.233%. CoreAudio/WebContent GPU and absent extension are unavailable, not zero. Whole-machine load 46.334 W [44.045,49.293]; adapter input including charging 55.557 W [53.736,58.331]. Package power unavailable; no secure credential-input channel used.
- python3 scripts/build.py --configuration Release: exit 0, full renderer/bridge and application rebuild. Delivered build/Build/Products/Release/WallpaperMachine.app; executable SHA-256 c03902bfae6dddf9cdd929a2dfc73056280dfbe82b7241478d4e86bf048aadbc; complete source-input SHA-256 fca0cce8ee498439abc2b731c759b958f1f578784b694be8523db71ed86cb465. No source input changed during the build. All 15 bundled WebUI files byte-match sources; new MatrixBase template and artwork-cache field are linked; temporary probe markers absent.
- Implementation, automated gates and bounded offscreen workload proof complete. Existing old PID remains running: candidate desktop runtime/visual/power verification is unmeasured until the user quits and reopens the delivered app. No app-quit power reference, aligned actual-presentation feedback, wallpaper-exclusive watts, savings percentage, whole-software compatibility or private-particle pixel equivalence claimed. Persisted wallpaper settings and upstream revisions unchanged.

## 2026-09-24 — Interleaved feedback-copy fix and timing-evidence corrections

- `MetalSceneDraw.InterleavedFeedbackCopiesPreserveEachReadersImage` compares both A/B targets to the blit path over four frames with both blits removed; restoring single-prefix overwrite semantics fails A's pixel comparison, and the restored per-reader implementation passes.
- `python3 scripts/check_renderer.py` — exit 0; every recorded binary exited 0, Metal scene smoke 36 passed / 1 local-project skip, generated pairs pixel-equal and 8-project x2 reload cycles passed.
- Separate local-project harness for 3620484312 (seed 1, 3456x2234 surface): 120 frames, 47 render passes/frame (22 scene-output), 0 blits/frame; `cmp` against the original baseline PPM exited 0.
- `python3 scripts/test.py` — exit 0; Python suites passed, native 569 passed / 0 failed / 11 skipped.
- `python3 scripts/build.py --configuration Release` — exit 0 after both gates; delivered build/Build/Products/Release/WallpaperMachine.app. Binary newer than build start and changed from the previous delivery; linked texture-pair vector insertion/erase symbols confirm the pending-copy collection is included.
- Correction to previous power reports: 45–52 draws/s is an observation, not proof that each frame adds its work time to 16.7 ms. ThreadTimer schedules from last_tick, set before the asynchronous DRAW callback; FrameEnd wakes only an outstanding request. No frame-clock code was changed.
- Correction to prior “exact power window” / “matched throughput” claims: delayed diagnostics and the benchmark start independently and only approximately overlap; equal diagnostic-window draw rates do not prove equal throughput during the power window. Presented FPS remains unavailable; no new watt-saving or memory/display attribution is claimed.
- No app launch/quit, desktop setting changes, on-screen visual checks or new power measurements in this correction. Renderer provenance and owning documentation updated; historical measurements are superseded by the corrections above.

## 2026-09-24 — Power follow-up: window-aligned measurement, feedback-copy texture trade, what the wallpaper costs

On battery, built-in display only, other applications in use; every app run relaunched the Release build, which opens its control panel at launch.

- `power_benchmark.py` — 21 tests; a refused powermetrics now waits out the window (new mocked-clock test fails pre-fix at 0.2 s); system power from AppleSmartBattery accumulators; coreaudiod role
- `WALLPAPER_MACHINE_DIAGNOSTICS_DELAY` + `window elapsed_ms`: draws counted over exactly the power window; `python3 scripts/test.py` — exit 0, 569 passed, 0 failed, 11 skipped
- `python3 scripts/check_renderer.py` — exit 0 (metal_scene_draw_smoke 35); feedback trade test fails with the opening copy removed; harness: 21 → 0 blits/frame, 47 render passes, PPM identical to baseline and with `WALLPAPER_MACHINE_FEEDBACK_COPIES=1`
- `python3 scripts/build.py --configuration Release` — built 09:39; binary contains the trade, the A/B switch and the delayed window
- Trade vs copies at matched throughput (51.31/51.30 draws/s): app GPU 38.6 → 33.0 %, CPU 43.8 → 40.4 %, package 2.51 → 2.34 W, system 23.7/24.4 W (noise); an unmatched pair (52.1/51.0): GPU 33.1 → 24.4 %, system 28.8/28.7 W
- Whole wallpaper: app quit 9.6–24.8 W system, 0.9–1.3 W package (busy spell 3.4 W); default 60 fps ceiling = 44.8–52.1 draws/s, 21.4–28.8 W system, 2.3–3.5 W package; 30 fps: 17.5/18.9 W, 1.7/2.6 W; 1 fps: 17.6 W, 0.9 W
- coreaudiod 13–17 % CPU whenever this audio-reactive wallpaper runs, even at 1 fps; control panel busy in some runs (WebContent 8–13 %, WindowServer ~+20 points), inferred from its animated GIF previews
- Not measured: a second display (configured with the same wallpaper), AC power with charging, presented frames (unavailable)

## 2026-09-24 — Power hotspots: Metal render-pass sharing, per-frame CPU, poster retention

Scene 3620484312 on the built-in 3456×2234 display, 60 fps cap, AC power, other applications running; every desktop run relaunched the app, which opens its control panel at launch.

- `python3 -m unittest discover -s scripts/tests -p test_power_benchmark.py` — 17 passed; `power_benchmark.py --measure 5 --condition T3 --print-only` reports app/WindowServer CPU and GPU %
- `python3 scripts/check_renderer.py` — exit 0, every binary 0 (metal_scene_draw_smoke 34, static_subgraph_cache_test 26, metal_backend_test 35), generated cases pixel-equal; the new batching test fails with sharing disabled (3 render passes, expected 1)
- `python3 scripts/test.py --only DesktopWallpaperTests` — 27 passed; `python3 scripts/test.py` — exit 0, 566 passed, 0 failed, 11 skipped
- Harness `WE_TEST_METAL_PROJECTS` (seed 1, 3456x2234): 179.0 → 47.0 render passes/frame (154 → 22 into the scene image), 21 blits unchanged, 1.82 → 0.75 ms CPU per drawFrame; PPM byte-identical to the baseline (two baseline runs identical)
- Grouping scene-output passes first (plan step 5) was reverted: no change, the 21 remaining scene-image passes each follow a full-frame copy a clipping-mask effect reads
- `python3 scripts/build.py --configuration Release` — built; app binary newer than the build start and contains the renderer change
- Desktop `power_benchmark.py --measure 60 --powermetrics`, increments over paired B0: native Metal before app CPU 38.2/37.6 %, GPU 65.1/62.9 %, package +7.11/+6.95 W; after 27.7/27.8 %, 19.4/24.2 %, +4.85/+3.00 W; Compatibility +1.58 before, +2.64 W after. Not a same-throughput comparison: draws over the power window were not counted
- Draws executed per 180-s diagnostics session, start-up included: 9155/7435 before, 9313/7885 after (corrected: an earlier draft of this line divided by timer wakeups, which are not elapsed time, and reported 60.0/50.6 fps). Presented frames unavailable. WindowServer CPU 44–47 % in every run including app-quit B0, not attributable; package CPU power moved ±1 W between repeats
- DesktopPosters: 351 PNGs (3.2 GB) → 4 (50 MB) at the first launch of the new build (its display is on the bounded-retention path)
- Not verified: on-screen visual equality beyond the harness PPM, other scenes, and a Space-change or wake on the real desktop

## 2026-09-23 — Release build after pulling 5a4201f

- git pull --ff-only: main fast-forwarded to 5a4201f (27 files: panel/settings/welcome WebUI, GitHub update feed, tests, docs); no project.yml, renderer, bridge or upstream changes.
- First python3 scripts/test.py: 562 passed, 1 failed, 11 skipped. ControlPanelShellTests.testFirstRunGuideCoversTheWindowWalksFivePagesAndReturnsFromSettings still expected a pure black/white guide canvas; 5ca5ca3 moved WebUI/welcome.css to --welcome-bg: var(--bg) (library window surface).
- Fix: the test now asserts the guide background equals the document root background and is opaque rgb(), instead of hard-coded #000/#fff.
- python3 scripts/test.py --only ControlPanelShellTests: 18 passed. Full python3 scripts/test.py: 563 passed, 0 failed, 11 skipped.
- python3 scripts/build.py --swift-only --configuration Release: OK, build/Build/Products/Release/WallpaperMachine.app 0.5.0 (16).
- diff -rq WebUI vs Contents/Resources/WebUI: identical.
- Not run: check_renderer.py (no renderer change), UI/desktop tests, launching the app; guide visuals not checked by eye.
