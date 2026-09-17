# Improvement plan implementation progress

Implementation record for the work packages in
[mac-wallpaper-engine-improvement-plan.md](mac-wallpaper-engine-improvement-plan.md).
Task IDs are the plan's own. The plan itself is not rewritten; corrections to it
are recorded here.

Scope of this round: phase A (M00, V01, V02, W01, V03) and phase B (P01, W02,
P02 first version, A01 consumer gating, E01). Phases C/D/E are out of scope.

## Evidence vocabulary

Each task carries these fields separately, as the plan requires. A single "pass"
is never written in place of them.

| Field | Meaning |
|---|---|
| source-confirmed | The reviewed control flow was found in the current tree |
| counter-example | A test that fails before the change and passes after it exists |
| fixed-in-production | The fix is on the production call path, not a test helper |
| tests-passing | Which suites actually ran green in this environment |
| visually-verified | Real rendered output compared. Requires desktop authorization |
| power-verified | Equal-quality paired power measurement. Requires authorization |

## Environment and authorization

Working tree started at `6dc8c327c6f7e2594d84722413f11d7168eb5898`, which is the
plan's fixed baseline, so no problem needed re-confirmation against a newer main.

Available: `cargo`, `cmake`, `xcodegen`, `xcodebuild`, Homebrew `ffmpeg@8`,
`quickjs-ng`, `glslang`, `molten-vk`.

One environment trap worth recording: the shell had `CARGO_TARGET_DIR` pointing
at a sandbox cache, so early `cargo build` runs left
`upstream/renderer/target/release/libwallpaper_bridge.a` untouched and the
regenerated bindings did not contain the new API. Every renderer build below was
re-run with that variable unset. GPU tests also fail with
`VK_ERROR_INCOMPATIBLE_DRIVER` inside the command sandbox and must run outside
it; they create only private GPU images.

Not available or not authorized this round, so every item depending on them is
recorded as blocked rather than failed:

- Desktop control, window/occlusion driving, Spaces, lock and unlock.
- Screen capture, screenshots, wallpaper changes, app install or replacement.
- System audio capture and audio hardware.
- `powermetrics`, Instruments and any elevated sampling.
- `python3 scripts/test.py --ui` (takes over the desktop).

**No power number, watt figure or saving percentage is reported anywhere in this
document.** Counters and unit tests bound what is claimed.

## Status by task ID

| ID | Phase | Status | Power evidence |
|---|---|---|---|
| M00 | A | Implemented (minimal, as instructed) | n/a — makes measurement recordable |
| V01 | A | Implemented | correctness fix, not a saving |
| V02 | A | Implemented | correctness fix, prerequisite for V05/R04 |
| V03 | A | Implemented | correctness fix, not a saving |
| W01 | A | Implemented | removes repeated page rebuilds; unmeasured |
| P01 | B | Implemented | unmeasured |
| W02 | B | Implemented | unmeasured; page-side effect needs a desktop run |
| A01 | B | Consumer gating implemented; real-time path untouched | unmeasured |
| E01 | B | Implemented | unmeasured |
| P02 | B | First version implemented (content-rate pacing) | unmeasured |

## Commands actually run

| Command | Result |
|---|---|
| `python3 scripts/test.py` (baseline, before any change) | Pass, 267 tests |
| `python3 scripts/test.py` (after phase A, P01, W02, A01) | Pass, 299 tests |
| `python3 scripts/test.py` (final, with E01) | Pass, 310 tests, 0 failed |
| `python3 scripts/check_renderer.py` | Pass, exit 0; 10 generated cases `pixels_equal=true`, 0 diagnostics; all seven test binaries exit 0 |
| `cargo test --release --workspace` (renderer, `CARGO_TARGET_DIR` unset) | Pass; 233 bridge cases, all other crates green |
| `python3 scripts/build.py --renderer-only` | Pass; bindings regenerated with the new API |
| `python3 scripts/tests/test_power_benchmark.py` | Pass, 11 cases |
| `artifacts/renderer/bin/tests/video_decode_pump_test` | Pass, 13 cases |
| `artifacts/renderer/bin/tests/video_color_conversion_test` | Pass, 9 cases |
| `artifacts/renderer/bin/tests/playback_gpu_test` (outside the sandbox) | Pass, 32 cases |
| `artifacts/renderer/bin/tests/timer_tests` | Pass, 11 cases (6 pre-existing, 5 new) |

Nothing was skipped silently. The local wallpaper corpus was not exercised; that
is a skip, not a pass.

---

## M00 — power baseline, per-backend counters, signpost

**Status: implemented (minimal form).**

- source-confirmed: the tree had no runtime counter surface and no benchmark
  configuration record. `AppLog` carries lifecycle text only.
- fixed-in-production:
  - `App/Services/Diagnostics/RuntimeCounters.swift` — per-surface counters
    behind a self-expiring session, off by default, bounded surface table with a
    `droppedSurfaceEvents` overflow count, and an aggregated (never per-frame)
    report. `RuntimeSurfaceKey` keys on kind + display id + generation so a
    reused display id across a hot-plug is not merged. Incremented by the
    presentation policy (P01), the web host and page (W01, W02).
  - `scripts/power_benchmark.py` — writes the configuration manifest from §6.1
    of the plan to `artifacts/power/`. It measures nothing: every condition is
    written `measured: false` and `measurement_tool` stays `null`.
- new tests: `Tests/Unit/Diagnostics/RuntimeCountersTests.swift` (8 cases),
  `scripts/tests/test_power_benchmark.py` (11 cases).
- docs: `docs/testing/power-benchmark.md`, indexed in `docs/README.md`.
- power-verified: **no**, by design.
- rollback: delete the two sources, the two test files, the doc and the
  `docs/README.md` row.

Deliberately not built: signpost instrumentation of the renderer and per-backend
GPU counters. Those need the GPU/desktop layer that is unavailable here.

---

## V01 — FFmpeg EAGAIN, EOF drain, cancellation state machine

**Status: implemented.**

- source-confirmed: in `FfmpegVideoTextureSource.cpp`, `decodeNextFrame()` called
  `av_packet_unref` immediately after `avcodec_send_packet` regardless of
  `AVERROR(EAGAIN)`, so a rejected packet was dropped; on `AVERROR_EOF` from
  `av_read_frame` it seeked and called `avcodec_flush_buffers` without ever
  sending a drain packet, discarding reordered tail frames; and neither the
  outer read loop nor the inner receive loop checked for cancellation.
- counter-example: `tests/video_decode_pump_test.cpp` reproduces the previous
  order in `LegacyDecodeNextFrame` and asserts it loses the rejected packet's
  frame (`received_frames == [2]`) and the reordered tail of every loop
  (`[1, 2, 5, 6]` instead of `[1, 2, 3, 4, 5, 6]`), while the new pump produces
  every frame. The fixture therefore distinguishes the two algorithms.
- fixed-in-production:
  - `src/Video/VideoDecodePump.{hpp,cpp}` — receive-first state machine over an
    abstract `VideoDecodeSource`. A packet is released exactly once and only
    after the decoder accepts it; the drain request is sent once per end of
    input; the stream restarts only after the decoder reports end of stream;
    cancellation is polled between every step; consecutive no-progress steps are
    bounded and reported as a failure; `ResetForSeek` and `fail` both release a
    held packet exactly once, tracked separately from the phase.
  - `FfmpegVideoTextureSource.cpp` — `Impl::DecodeSource` implements that
    interface over libavformat/libavcodec, skipping foreign-stream packets
    within a bound; the format context is allocated up front so an
    `AVIOInterruptCB` can abort a stalled read; `stop()` publishes an atomic
    cancel flag before taking the lock; `decodeNextFrame` returns
    `Frame/Cancelled/Failed` so a stop records no user-visible error; a minimum
    playback position that no frame satisfies stops being enforced after one
    full loop instead of filtering forever.
- new tests: 13 cases in `tests/video_decode_pump_test.cpp`, built and run by
  `scripts/check_renderer.py`.
- tests-passing: yes (13/13, and the renderer gate is green).
- not done: no synthetic H.264/HEVC B-frame clip is decoded end to end. The
  reordering contract is covered at the state-machine level with a scripted
  decoder, not with a real codec. Recorded as a gap, not a pass.
- visually-verified / power-verified: **no.**
- rollback: revert the two new files, the `Video/VideoDecodePump.cpp` line in
  `src/CMakeLists.txt`, the test target, and the `FfmpegVideoTextureSource.cpp`
  hunks.

---

## V02 — Core Video / Metal resource lifetime and FrameLease

**Status: implemented.**

- source-confirmed: `CreatePixelBufferBackedMetalTexture` released the
  `CVMetalTextureRef` before returning, keeping only the vended `MTLTexture`.
  Apple documents the wrapper as the object whose lifetime governs the texture.
- fixed-in-production:
  - `FfmpegVideoInterop.mm` — `AppleVideoFrameLease` owns the `MTLTexture`, the
    Core Video texture wrapper per plane, and the `CVPixelBuffer` (an imported
    frame outlives the decoder slot it came from). `CreateAppleVideoFrameLease`
    replaces `CreateAppleVideoMetalTextureForDevice`;
    `AppleVideoFrameLeaseTexture` borrows the texture;
    `TakeAppleVideoFrameLeaseDestination` hands a poolable conversion
    destination to the pool exactly once; `ReleaseAppleVideoFrameLease` releases
    everything once. The unused `CreateAppleVideoMetalTexture` was removed
    rather than left as a shim.
  - `Vulkan/TextureCache.{cpp,hpp}` — `ImportedVideoFrame::frame_lease` holds the
    lease; its deleter returns the destination to the pool before releasing.
  - `tests/playback_gpu_test.mm` migrated to the lease API.
- tests-passing: `playback_gpu_test` 32/32 outside the command sandbox, covering
  pool reuse, generation dedup, cache eviction, recording-discard recovery and
  fault injection.
- not done: no Metal API-validation or leak-instrumented run. Release/retain
  balance is argued from the code and from the passing lifetime tests, not from
  a validation layer. Recorded as a gap.
- rollback: revert `FfmpegVideoInterop.{hpp,mm}`, `TextureCache.{cpp,hpp}` and
  the GPU test hunk.

---

## V03 — limited-range colour conversion, CPU and Metal

**Status: implemented.**

- source-confirmed: both the CPU converter and the `nv12_to_bgra` kernel read
  chroma as `sample/255 - 0.5` while applying limited-range luma handling and
  the standard coefficients. Limited-range 8-bit chroma spans 224 code values
  around 128, so every studio-swing frame was desaturated and shifted.
- counter-example: `VideoColorConversion.LimitedRangeChromaUsesItsOwnExcursion`
  asserts the reference result for BT.709 `Y=126, Cb=128, Cr=160` is
  `(185, 111, 128)` and that the previous formula gives `(179, 113, 128)` — the
  same two values the plan derived by hand.
- fixed-in-production:
  - `src/Video/VideoColorConversion.{hpp,cpp}` — one description
    (matrix, range, bit depth, whether the matrix was inferred) and one
    parameter struct with independent luma and chroma offset and scale, derived
    from the Kr/Kb coefficients. Unspecified metadata is inferred from the
    resolution and logged once per distinct colorimetry instead of silently
    using BT.601. Constant-luminance BT.2020 is substituted with NCL and marked
    inferred rather than claimed as supported.
  - `FfmpegVideoInterop.mm` — the CPU NV12 and planar paths call the shared
    conversion; the Metal kernel takes the same struct, field for field.
- new tests: `tests/video_color_conversion_test.cpp` (9 cases: the worked
  example, neutral chroma, studio black/white with clamping, full-swing range,
  75% colour bars round-tripped from their RGB primaries, matrix separation,
  resolution inference, bit-depth scaling) plus
  `PlaybackGPU.MetalConversionMatchesTheCpuColorReference`, which compares the
  Metal kernel against the CPU reference for six sample triples across both
  ranges and BT.601/709/2020.
- tests-passing: yes (9/9 headless, and the GPU comparison passes).
- visually-verified: **no.** No real wallpaper was displayed or compared; there
  is no authored reference frame for a Wallpaper Engine video in this repo.
- rollback: revert the two new files, the `src/CMakeLists.txt` line, the test
  target and the `FfmpegVideoInterop.mm` colour hunks.

---

## W01 — Web identity, committed-state replay, crash budget

**Status: implemented (all three sub-items).**

### W01-a entry identity

- source-confirmed: `WebWallpaperHost.apply` compared
  `window.page.entryURL.lastPathComponent == wallpaper.entryFile`, so an entry
  such as `sub/index.html` never matched itself and every reconcile rebuilt the
  page.
- fixed-in-production: `WebWallpaperPage.canonicalEntryURL(projectURL:entryFile:)`
  resolves symlinks, standardizes the path, rejects an absolute entry and
  rejects anything outside the project folder; the host compares that value and
  reports a rejected entry instead of opening a page.
- counter-example / tests: `testRepeatedIdenticalReconcilesDoNotRebuildANestedEntryPage`
  fails on the old comparison (`webPageCreated` would rise per reconcile) and
  passes now; plus nested/normalized/escaping-entry cases.

### W01-b committed-state replay

- source-confirmed: `flush()` cleared the pending property, general and paused
  values, and `didFinish` re-flushed an empty set, so a reload after a crash
  restored nothing; the host's descriptor diff sends nothing when nothing
  changed.
- fixed-in-production: the page keeps one `CommittedState` snapshot and replays
  all of it on every new document generation; every async host call carries the
  generation it was issued for and is dropped if the document moved on;
  `load()` and `stop()` both advance the generation.
- tests: `testAReloadedDocumentGetsTheWholeCommittedStateBack`,
  `testUserPauseSurvivesAReloadAndPresentationResume`,
  `testLoadInvalidatesHostCallsIssuedForTheOldDocument`.
- plan deviation: the plan asks for `committedSnapshot` plus `pendingDelivery`.
  A separate pending layer turned out to be unnecessary — "not yet loaded" is
  the only pending state, and the committed snapshot already coalesces repeated
  values — so there is one layer plus an `isLoaded` gate.

### W01-c crash budget

- source-confirmed: `didFinish` reset `recoveryAttempted` to false, so a page
  crashing after each successful load could be restarted forever.
- fixed-in-production: a time-windowed restart history with exponential backoff
  capped at `maximumBackoff`, a failure reported once the budget is spent, and a
  budget that is only returned when the previous document ran for
  `recovery.stableRun` — measured from the clock at the crash, not from a timer
  that a test or a fast crash could collapse.
- tests: `testRepeatedCrashesAfterASuccessfulLoadExhaustTheBudget`,
  `testAStableRunReturnsTheRestartBudget`,
  `testCrashesOutsideTheWindowDoNotCountAgainstTheBudget`,
  `testStoppingAPageCancelsAPendingRestart`.
- not done: the static-poster degradation the plan mentions for an exhausted
  budget. The current behaviour reports the failure and leaves the last frame;
  it does not save and install a poster for that case.
- rollback: revert `WebWallpaperWindow.swift`, `WebWallpaperHost.swift` and
  `Tests/Unit/WebWallpaper/WebWallpaperRecoveryTests.swift`.

---

## P01 — per-surface and per-display presentation suspension

**Status: implemented.**

- source-confirmed: `WallpaperPresentationPolicy` held a single `isSuspended`
  and `desktopIsVisible()` returned true when *any* wallpaper window was
  visible; the bridge held a single `presentation_suspended` bool and applied it
  with `set_all_paused`; `WebWallpaperHost` pushed one `suspended` value to
  every page.
- fixed-in-production:
  - Swift `WallpaperPresentationPolicy` now maps display id to
    `WallpaperSurfaceVisibility`, keeps global reasons (display sleep, session
    lock) apart from per-display occlusion, resumes immediately but debounces
    occlusion-driven suspension, drops state for displays that disappear,
    serializes delivery with one transition in flight, and does not retry a
    rejected transition in a loop. `stop()` resumes every surface it suspended.
  - Rust: `BridgeActorState.suspended_displays` beside the global flag;
    `ActivationInputs` resolves each scene's and web descriptor's paused state
    from its own display, mirrors included; `EngineFacade::set_display_paused`
    maps a display to its scene handle; a global resume re-applies the displays
    that are still hidden; the new uniffi
    `set_display_presentation_suspended(display_id, suspended)` carries one
    display's decision. Mouse polling follows whether any display still
    presents.
  - `WebWallpaperHost.setPresentationSuspended(_:forDisplay:)` and
    `AppDelegate` wiring deliver the per-display decision to both the pages and
    the renderer.
- invariants held by tests: a hidden display does not pause a visible one
  (`testHidingOneDisplayLeavesTheOtherRunning`,
  `suspending_one_display_leaves_the_other_rendering`); a visible display does
  not resume a hidden one (`testRevealingOneDisplayResumesOnlyThatDisplay`,
  `resuming_one_display_does_not_resume_a_display_that_is_still_hidden`); a
  global resume keeps a covered display paused
  (`a_global_resume_keeps_a_display_that_is_still_covered_paused`,
  `testGlobalSuspensionDoesNotClearAPerDisplaySuspension`); a user pause is
  never cleared by visibility (`a_user_pause_survives_per_display_resume`);
  hot-plug and occlusion flapping settle without a burst of transitions; a
  rejected transition rolls back and is retried later.
- two real defects were found by these tests and fixed: the delivery queue did
  not drain after a successful transition (only one display would ever be told),
  and a decision that changed while in flight was dropped.
- tests-passing: yes — Swift policy suite and
  `crates/bridge/src/tests/display_presentation.rs`.
- **counters do not yet prove the renderer stopped.** The assertions are on the
  decision and on the descriptor state the next reconcile builds. Whether
  `render_submission` and `present` actually stop for a hidden surface needs the
  renderer-side counters (M00's unbuilt half) and a desktop run. Unverified.
- power-verified: **no.**
- rollback: revert `WallpaperPresentationPolicy.swift`, the `AppDelegate` and
  `BridgeStore` hunks, `WebWallpaperHost.swift`, and the Rust hunks in
  `actor/{state,messages,bridge}.rs`, `engine/{facade,activation}.rs`,
  `api/mod.rs`; then rerun `scripts/build.py --renderer-only` to regenerate
  bindings without the new method.

---

## W02 — real web suspension

**Status: implemented; the page-side effect is unverified here.**

- source-confirmed: `setPresentationSuspended` only reached the page's optional
  `wallpaperPropertyListener.setPaused`, so a page that ignores it kept its
  timers, workers, WebGL and media running.
- fixed-in-production, three host-side controls that do not need the page's
  cooperation:
  1. `WKWebView.setAllMediaPlaybackSuspended(true/false)` — suspend and
     unsuspend, never `pauseAllMediaPlayback`, so media the user had paused is
     not started by a resume.
  2. The web view is removed from the window tree, which is the documented
     trigger for WebKit's inactive scheduling policy, and
     `WKPreferences.inactiveSchedulingPolicy = .suspend` is set on the
     configuration. `WebWallpaperWindow` now hosts the web view inside a stable
     container view so the desktop poster sync keeps identifying the surface by
     the same content layer.
  3. A snapshot taken before detaching stays on screen as a placeholder; a
     resume that overtakes the asynchronous snapshot cancels the detach through
     a generation counter.
  Pointer delivery is gated: a suspended page receives no events.
- no `requestAnimationFrame` wrapper and no signal to the shared WebContent
  process are used.
- tests: `Tests/Unit/WebWallpaper/WebWallpaperSuspensionTests.swift` — detach
  and reattach with the placeholder installed and removed, counters per surface,
  flapping settling attached, pointer gating, and a surface that is already
  hidden never attaching in the first place. The document generation is asserted
  unchanged across a suspension, so suspension does not silently reload the page
  and lose its state.
- **not verified here:** that the page's own rAF, timers, CSS animations, WebGL,
  media and workers actually stop. Two observations from this round bound what
  can be claimed: a detached web view with `.suspend` stops answering
  `callAsyncJavaScript` at all (consistent with suspension, and the reason the
  headless tests assert host state instead), and in a windowless test container
  script execution is unreliable even before detaching. A real measurement needs
  a desktop window and `WebContent` process observation. Recorded as unverified.
- not done: the third tier the plan describes — destroying and rebuilding the
  web view for a page that still cannot be suspended, under an explicit user
  choice.
- rollback: revert the `WebWallpaperWindow.swift` suspension section, the
  container change, the `inactiveSchedulingPolicy` line and the test file.

---

## A01 — audio consumers

**Status: consumer control implemented; the real-time path is untouched.**

- source-confirmed: `apply_engine_pause` called
  `set_audio_capture_suspended(paused)` with the same global pause flag, so
  system audio capture followed the pause bool rather than whether anything
  consumed audio.
- fixed-in-production: `BridgeActor::audio_capture_suspended()` derives the
  decision from the built scene list — a scene counts as a consumer only when it
  has `audio_response_enabled` **and** is not paused for its own display — and
  falls back to the global condition when the scene list cannot be resolved.
  Both the global and the per-display transition apply it.
- tests: `audio_capture_stops_when_the_only_audio_consumer_is_hidden`,
  `a_presentation_transition_never_opens_the_tap_without_a_consumer`,
  `muting_a_wallpaper_does_not_stop_its_audio_response`.
- one existing test was updated, not deleted:
  `presentation_suspension_pauses_without_changing_playback_state` asserted
  `audio_capture_suspend_calls() == [true, false]` for a bridge with no
  wallpapers at all. Under A01 a resume with no consumer must not open the tap,
  so it now asserts `[true, true]` with that reason stated in the test.
- deliberately **not** done, as instructed: the real-time callback was not
  rewritten. There is no SPSC ring, no worker-thread FFT, no resampler buffer
  reuse and no anti-aliasing review. `AudioCaptureController`'s existing
  enabled-handle and global-suspend design is unchanged apart from what feeds
  it.
- web pages are not counted as audio consumers; web audio response is still
  unimplemented, as `docs/features/web-wallpapers.md` states.
- power-verified: **no.**

---

## E01 — desktop, lock screen and preview presentation ownership

**Status: implemented.**

- source-confirmed: `Extension/WallpaperSurface.applyPolicy()` computed

  ```swift
  scene.paused || displaysAsleep || activity == "suspended"
    || (!preview && !locked && presentation != "locked" && presentation != "idle")
  ```

  The `!preview &&` guard makes the whole consumer clause false for a preview,
  so **a preview surface was never suspended by presentation state**: once it
  produced its readiness frame it kept rendering for as long as it existed.
  That is exactly the plan's "first-frame success must not become a permanent
  right to keep presenting". Non-preview surfaces were already correct — the
  policy is applied after the readiness frame, and the desktop is a frozen
  poster — so that half was not re-implemented.
- source-confirmed: there was no way to observe both processes together.
  `RuntimeCounters` was application-only, so "no instance keeps presenting with
  no consumer" could not be read from the extension at all.
- fixed-in-production:
  - `Shared/WallpaperPresentationAuthority.swift` — one presentation-eligibility
    rule set compiled into both targets. Reasons are an `OptionSet`
    (`userPaused`, `displaysAsleep`, `hostSuspended`, `noConsumer`,
    `previewBudgetSpent`) so clearing one never clears another and the user's
    pause stays independent of visibility. A lock-screen surface presents only
    while the session is locked or the host reports a presenting mode; a preview
    presents for a bounded `previewBudget` (10s) and then holds its last frame,
    unless continuous preview is explicitly requested. `nextReevaluation` tells
    the caller when the decision changes on its own, so nothing polls.
  - `Extension/WallpaperSurface.swift` — builds that request, applies the
    decision, and schedules its own preview expiry so a preview stops without
    waiting for a host update that may never arrive. `presentingSince` is set by
    the first frame and is separate from the readiness reply, and the readiness
    frame is counted as `readinessFrameRendered` rather than as authorized
    presentation. `releaseRenderer` cancels the expiry task and clears the
    presenting clock.
  - `Shared/RuntimeCounters.swift` — moved from `App/Services/Diagnostics/` so
    both processes count the same events through one implementation instead of
    evolving separate vocabularies; `presentationAuthorized` and
    `readinessFrameRendered` were added for the extension's surfaces.
    `WallpaperController` passes the surface revision as the counter generation.
- new tests: `Tests/Unit/LockScreen/WallpaperPresentationAuthorityTests.swift`
  (11 cases): lock-screen consumer conditions and unlock, display sleep and host
  suspension overriding a visible lock screen, the user's pause surviving
  visibility changes in both directions, every reason reported rather than the
  first, the preview budget and its expiry, the readiness frame not buying
  permanent playback, explicit continuous preview still yielding to a user
  pause, a closed preview stopping immediately rather than waiting out its
  budget, and which requests schedule their own re-evaluation.
- tests-passing: yes. `scripts/test.py` builds the embedded extension, so the
  shared files are also confirmed to compile under
  `APPLICATION_EXTENSION_API_ONLY`.
- **not verified:** no lock, unlock, display-sleep or preview-close transition
  was exercised against the real extension, and no joint per-process submission
  count was captured. The rules are tested; the extension's behaviour under
  those system events needs an authorized desktop run. The app and extension
  still do not exchange presentation state at runtime — the shared rule set
  makes them agree by construction rather than by negotiation, which is weaker
  than the plan's "bounded generation authorization" and is recorded as such.
- rollback: revert `Extension/WallpaperSurface.swift` and
  `Extension/WallpaperController.swift`, delete
  `Shared/WallpaperPresentationAuthority.swift` and the test file, and move
  `Shared/RuntimeCounters.swift` back to `App/Services/Diagnostics/`.

## P02 — demand-driven scheduling (first version)

**Status: first version implemented — content-rate pacing for the one scene
whose demand is provable. No static-scene classification was attempted.**

Two findings shaped the scope, and both are worth keeping:

1. **Pausing already stops the clock.** `SceneWallpaper`'s `CMD_STOP` handler
   calls `frame_timer.Stop()`, and `FrameTimer` is a condition-variable timer,
   so a paused or render-blocked scene is not ticking at all. The plan's
   "suspended surfaces stop producing work" is therefore already true for the
   pause path that P01 now drives per display. Not re-implemented.
2. **The tick rate was the user/display ceiling, not the content rate.** The
   required FPS comes from `config.fps` (the monitor's target clamped to the
   display refresh rate), so a 30 fps video on a 60 fps target rendered twice
   per decoded frame and presented a duplicate every other frame. That is the
   plan's own acceptance item about a 24/30/60 fps video not being driven by the
   display refresh rate, and it is what this first version fixes.

- source-confirmed: `FrameTimer`'s tick period was always `m_ideatime`, derived
  only from `SetRequiredFps`. Nothing in the engine reported how often content
  could change.
- fixed-in-production:
  - `src/Scene/Timer/FrameTimer.{hpp,cpp}` — a `FrameDemand` value carrying a
    `content_period`, pushed with `SetFrameDemand` and resolved into the tick
    interval by `ResolveInterval`. The period can only **lengthen** the
    interval: it is ignored unless it exceeds the ideal frame time, so the
    user's and the display's ceiling always wins, and it is clamped to
    `MAX_FRAME_DURATION` (5s) so a bad period cannot stall a scene. Zero or
    negative means unknown and keeps the fixed cadence. `TickInterval()` exposes
    the result. The single-DRAW-in-flight backpressure is untouched.
  - `src/Scene/include/Scene/Scene.h` — `single_video_source`, set **only** by
    `CreateVideoProjectScene`, next to the construction that justifies it: one
    video texture, a copy shader, a `NoOpShaderValueUpdater`, and no script,
    particle, audio or pointer input. Authored scenes never set it.
  - `src/Video/VideoTextureSource.hpp` + `FfmpegVideoTextureSource` —
    `frameDurationSeconds()` reports the **shortest** plausible period
    (`min` over `avg_frame_rate` and `r_frame_rate`), not the average. A
    variable-frame-rate clip whose average is longer than its tightest gap would
    otherwise lose the frames inside that gap; the shortest period can only ever
    render more often than needed. Zero before priming, which reads as unknown.
  - `src/Vulkan/TextureCache.cpp` — `ShortestVideoFramePeriod()` returns the
    shortest period across live video sources, and returns 0 (unknown) if **any**
    source cannot report one, because pacing on the others could skip its
    changes.
  - `src/Scene/VulkanRender/VulkanRender.cpp` — forwards it.
  - `src/Scene/SceneWallpaper.cpp` — `refreshFrameDemand()` pushes the period
    from the **render thread** after each completed frame and on every
    stop/resume transition. It reports a period only for a `single_video_source`
    scene with an initialized renderer; every other scene reports nothing and
    keeps the fixed cadence, because an authored scene may change on a time
    uniform, a script write, a particle system, audio reactivity or a feedback
    texture that this code does not enumerate. The demand is pushed rather than
    pulled precisely so the timer thread never reaches into scene or renderer
    state.
- new tests: 5 cases in `tests/timer/frame_timer_test.cpp` —
  content that changes less often lowers the tick rate; the configured FPS stays
  the ceiling (a 60 fps video does not make a 30 fps wallpaper render at 60); an
  unknown, zero, negative or absurdly long period cannot stall the scene (1h is
  clamped to 5s); dropping the demand restores the fixed cadence rather than
  inheriting the previous scene's; and pacing does not change how many draws may
  be in flight. `timer_tests` was added to `scripts/check_renderer.py`, which did
  not previously run it.
- tests-passing: yes (11/11 in `timer_tests`; the renderer gate is green with
  `pixels_equal=true` on all ten generated cases and no diagnostics).
- **not verified:** that a real video wallpaper now renders once per decoded
  frame. The interval arithmetic and its bounds are tested; the end-to-end
  effect needs a desktop run reading the existing video submission counters, and
  it must be checked against equal presented frame rate and identical pixels.
  Recorded as unverified.
- invariant check: this does **not** lower FPS, resolution or quality to fake a
  saving. It removes renders that would present pixels identical to the previous
  frame, for a scene whose only time-varying input is the video, and it cannot
  raise or lower the rate outside the ceiling and the 5s floor.
- deliberately not done: static-scene classification. A `KnownStatic` verdict
  needs a positive answer about every dynamic render-graph input — time
  uniforms, SceneScript writes, particles, audio reactivity, feedback textures,
  dynamic visibility — and a wrong verdict freezes a live wallpaper. The
  mechanism is in place for it; the classifier is not, and `Unknown` stays
  conservative.
- rollback: revert `FrameTimer.{hpp,cpp}`, the `Scene.h` field and its assignment
  in `SceneWallpaper.cpp`, `refreshFrameDemand` and its two call sites, the
  `frameDurationSeconds` additions in `VideoTextureSource.hpp`/
  `FfmpegVideoTextureSource.{hpp,cpp}`, `ShortestVideoFramePeriod` in
  `TextureCache` and `VulkanRender`, the `SyntheticVideo` override in
  `playback_gpu_test.mm`, the five timer cases, and the `timer_tests` entries in
  `scripts/check_renderer.py`.

---

## Next actionable task

Every task ID in this round's scope is implemented. What remains is verification
that this environment cannot provide, and it should come before any further
optimisation:

1. **An authorized desktop run.** Drive window occlusion on two displays,
   Spaces, lock/unlock, display sleep and hot-plug, with a
   `RuntimeCounters` session open, and confirm that a hidden surface's counters
   stop rising while a visible one's keep going. This is what turns P01, W02 and
   E01 from "the decision is correct" into "the work actually stopped".
2. **A paired power measurement** against a manifest from
   `scripts/power_benchmark.py`, following
   [testing/power-benchmark.md](testing/power-benchmark.md): equal content,
   equal output geometry, equal real presented frame rate, observing the
   application, `WebContent`, the extension and `WindowServer`. Until then no
   task in this document may claim a saving.
3. **P02's second version**, only once 1 and 2 exist to measure it: the
   conservative static classifier described above, and the renderer-side
   counters that M00 left unbuilt (`render_requested`, `render_submitted`,
   `presented`, `duplicate_content_presented`) so a static verdict can be
   falsified rather than trusted.
