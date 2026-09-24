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

## 2026-09-24 — First-seen displays start enabled with the primary wallpaper

- Change: bridge MonitorCfg::for_connected_display enables never-configured displays with the primary's wallpaper (mirror kept); enabled_selectors skips mirror monitors.
- cargo test --release -p wallpaper-bridge --lib: 323 passed (baseline 322).
- New test first_seen_display_starts_with_primary_wallpaper_and_keeps_opt_out_after_reconnect fails on HEAD rows.rs (enabled=false), passes after.
- native_video_routing mirror-group tests failed with only the default change (apply flipped mirror back to independent); pass after the enabled_selectors mirror filter.
- python3 scripts/test.py: 572 passed, 0 failed, 11 skipped (Swift links the previously built bridge lib; no Swift change).
- python3 scripts/check_renderer.py: 10 generated cases pooled/isolated exit 0, pixels_equal, reload cycles 0.
- Not run: wallpaper-core suite (core unchanged); Release build not requested, running app unchanged.
- Gap: configs saved by 0.5.0 with enabled=false for auto-added displays are not migrated.

## 2026-09-24 — Release build: lock-screen texture prefetch and acquire-failure reporting

- `python3 scripts/build.py --configuration Release` — exit 0; delivered `build/Build/Products/Release/WallpaperMachine.app`
- Bundle check: app and extension binaries each contain 17 `TexturePrefetch` symbols, linked 19:43 after the last renderer edit (19:35); the extension contains the new `Acquire failed display=` diagnostic
- After review, `TexturePrefetch` keeps the workers that started when a thread fails to start; `texture_prefetch_test` — 7 passed (new `WithoutWorkersEveryImageIsLeftToTheCallerAtOnce`), 3 runs
- Not run: the app was not launched and the lock screen was not re-enabled; Debug and Release copies of the extension are both still registered

## 2026-09-24 — Lock screen: parallel texture decode at pass preparation; extension reports acquire failures

Animate Lock Screen failed for a private 943 MB puppet scene (122 embedded PNG textures). Confirmed: WallpaperAgent abandoned the extension's acquire after about 31 s with no frame. Likely contributor, not measured inside the extension: the offscreen probe needs 15.6 s to its first frame, dominated by single-threaded stb_image PNG decode. The extension sent no readiness error, so the app showed its generic 'macOS did not load' message.

- `python3 scripts/check_renderer.py` — exit 0; 25 binaries including new `texture_prefetch_test` (6 tests); 10 generated cases pooled/isolated pixels equal, 0 diagnostics; reload cycles 8x2 clean; no `--project` corpus; asset checks skipped: `MetalSceneDraw.LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend` (no `WE_TEST_METAL_PROJECTS`), `TextObjectRuntime.LonelyCatHeadlessRegression` (no local fixture), `TextObjectRuntime.Workshop3409533530FullSceneKeepsClockRenderPassAndTexture` (package absent)
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped of 585
- `offscreen_scene_probe` on the private scene, warm shader cache — first frame 15.6 s before, 14.7 s with the `FindTex` check, 3.6 s with `TexturePrefetch`; frame SHA-256 identical; peak RSS about 0.8 to 1.1 GB
- Mutation: admitting past the byte budget fails `HoldsDecodingAndUntakenImagesWithinTheBudget` and `AdmitsAnImageLargerThanTheBudgetOnItsOwn`
- `python3 scripts/build.py --renderer-only` — exit 0; `libwallpaper_bridge.a` contains `TexturePrefetch`
- Not run: lock-screen activation through WallpaperAgent (changes the system wallpaper; not authorized) and a Release build (not requested); first-frame time inside the extension is unmeasured

## 2026-09-24 — Requested full Release rebuild after equal-quality and remote integration

- Requested a new build after committing/pushing the equal-quality work and integrating the remote parallax and Workshop download-concurrency changes. Used the full renderer/bridge build, not --swift-only.
- Prebuild python3 scripts/test.py: exit 0; 152 Python cases passed, native 574 passed, 0 failed, 11 opt-in skipped of 585 (9 native media, 2 live Workshop). No desktop UI or opt-in network/audio-hardware run.
- python3 scripts/build.py --configuration Release: exit 0; Cargo workspace rebuilt, Swift/FFI bindings regenerated, XcodeGen and Release app/extension build succeeded. Delivered build/Build/Products/Release/WallpaperMachine.app, version 0.5.0 (16).
- Complete current source-input SHA-256 d9600b9b572197f6d1627ac05d6977be82354ed454137f0d2bbb0b56526137a0, covering 1036 source/config/test files including relevant untracked files. Before/after manifests show no source drift during the gate and build. New executable SHA-256 173c1d51889243657a5d4990bd5b6d43e176abde45abfc6d7e5127a7abca7cbf.
- All 15 bundled Contents/Resources/WebUI files byte-match the current WebUI sources, including the new download-concurrency settings row. codesign --verify --deep --strict build/Build/Products/Release/WallpaperMachine.app: exit 0.
- No install, ordinary app launch/quit/restart, desktop visual check or power measurement. User must quit and reopen the delivered app. Earlier power results refer to executable c03902bfae6dddf9cdd929a2dfc73056280dfbe82b7241478d4e86bf048aadbc, not this rebuilt executable.

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
