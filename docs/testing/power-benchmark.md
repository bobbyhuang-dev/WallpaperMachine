# Power benchmarking

How to make a power claim about this project believable. Nothing in this
document has been measured yet: it defines the configuration record, the
counters, the condition matrix and the comparison rules that a measurement has
to satisfy before it may be reported.

Test strategy and the layers around this one: [README.md](README.md).

## Why a manifest comes first

Two runs are comparable only when the content, the real presented frame rate,
the output geometry and the machine state match. Brightness, HDR, an external
display's own panel power, charging state and thermal history all move the
result more than most renderer changes do. `python3 scripts/power_benchmark.py`
writes that configuration to `artifacts/power/manifest-<timestamp>.json`:
commit and whether the tree was dirty, build configuration, chip and memory,
macOS build, every online display's pixel geometry and refresh rate, charging
and low-power state, recorded thermal warnings, the Homebrew library versions
actually linked, and the pinned `upstream/` revisions.

The script measures nothing. Every condition is written as
`"measured": false`, and `measurement_tool` stays `null` until a run attaches a
real tool to the manifest. `--print-only` emits the manifest without writing an
artifact.

## Runtime counters

Two counter surfaces answer two different questions, and a power claim needs
both. A suspend decision recorded on one side proves nothing about the work on
the other.

`Shared/RuntimeCounters.swift` holds the in-process counters for what the
application decided and what the web host did. They are **off by default**:
`record` does nothing outside a session opened with `startSession(duration:)`,
and the session expires on its own so a forgotten switch cannot keep counting.
Counts are per surface — `RuntimeSurfaceKey(kind:displayID:generation:)`, where
the generation separates two surfaces that reused one display id across a
hot-plug or wallpaper switch — and the surface table is bounded at
`RuntimeCounters.maximumTrackedSurfaces`, reporting `droppedSurfaceEvents`
rather than growing without limit.

The renderer counts its own work: the frame clock's wakeups and draw requests,
draws executed and dropped, queue submissions, present requests, frame-fence
completions, simulation ticks, the effective pause reasons as independent bits,
and the decoder's outputs, seeks, selected/reused/skipped frames, conversions
and imports. Those are also **off by default** — one relaxed atomic load gates
each increment — and reading them is a pull: nothing is pushed to the UI, logged
per frame or written to disk, and enabling starts no thread and no timer.

The two groups inside a renderer row are deliberately separate.
`timer_wakeups` through `simulation_ticks` are work a surface performs alone and
must stop when nobody can see it. The `video_*` values describe the decoded
source, which may legitimately keep running while one of its consumers is
hidden, provided another consumer still presents it. Collapsing them would make
a correctly suspended surface look busy.

`RuntimeDiagnosticsSession` opens both halves for a bounded window and produces
one aggregated report. The application starts one when
`WALLPAPER_MACHINE_DIAGNOSTICS=<seconds>` is set in the environment; without
that variable nothing is started, nothing counts and no timer exists.

The counters exist to answer one question per condition: did the work for a
surface nobody can see actually stop? A count that keeps rising for an occluded
surface falsifies the change regardless of what a CPU graph shows.

### What the platform cannot report

`present_requests` counts requests to present. Whether the compositor ever put
a frame on a display is a different measurement, and this backend — MoltenVK
over a `CAMetalLayer` swapchain — has no presentation-feedback source for it.
The report says `presented_frames=unavailable`; the request count is never
relabelled as displayed frames, and no frame-rate claim may be derived from it.

### A/B comparison entry points

Two switches make a comparison measure one change in one binary rather than two
builds. Both cover a strategy only: neither restores a resource-lifetime or
decode-correctness defect.

| Switch | Off (default) | On |
|---|---|---|
| `WALLPAPER_MACHINE_CONTENT_PACING=1` | Tick at the configured ceiling | Pace video to its observed content rate |
| `experimental.native_video_backend` in the app config | Every wallpaper on the scene engine | Eligible plain local videos on the platform player |

Demand-driven pacing is off by default because its remaining exposure cannot be
bounded here: the content period only reaches the frame clock after a completed
frame, so a rate that turns out tighter than the interval being waited out loses
every frame produced during the remainder of it. The native video backend is off
by default because it has never been visually verified and supports a declared
subset only.

A four-way attribution therefore needs: the baseline; baseline plus R02;
baseline plus I01; and the native backend opted in. R02 and I01 are not switched
— they are correctness and resource changes, so comparing them needs a separate
build directory or worktree. Whichever way two versions are compared, they need
isolated `WALLPAPER_MACHINE_HOME` directories and must be measured serially,
never concurrently.

### What the native backend cannot report

Decode and present counts inside AVFoundation are not observable from outside
the framework, so they are reported as unavailable rather than invented.
`AVPlayerLooper` keeps more than one copy of its template item queued to make
the loop seam gapless, so the queued-item count is reported as the system gives
it and is never claimed to be one with no pre-buffering.

## Condition matrix

| ID | Condition | What it separates |
|---|---|---|
| B0 | Application quit, system static wallpaper | System and display noise floor |
| B1 | Application running, no active wallpaper, panel closed | Host baseline cost |
| B2 | Same content, static poster only | Animation cost versus image and compositing cost |
| T1 | Single display, static or low-frequency scene | Idle ticks and dirty propagation |
| T2 | 1080p/4K/ultrawide video at 24/30/60 FPS | Decode, conversion, frame rate, pool budget |
| T3 | Simple, multi-layer post-processed, particle and video-texture scenes | CPU versus GPU versus bandwidth |
| T4 | Web wallpaper with and without a cooperating pause listener | Whether host-side suspension is real |
| T5 | Two displays, one visible one occluded, then both occluded | Per-surface policy and shared consumers |
| T6 | Lock screen, unlock, display sleep, system preview | Joint app/extension presentation ownership |
| T7 | Rapid wallpaper switching, hot-plug, window and resolution changes | Reclaim, recovery, leaks |
| T8 | Broken input, unsupported format, repeated web crashes | Whether error paths keep burning power |

Wallpaper material comes from the local corpus
([wallpaper-corpus.md](wallpaper-corpus.md)) or synthetic fixtures. Copyrighted
Workshop assets are never committed.

## Comparison rules

```text
incremental average power = condition average - paired baseline average
incremental energy        = ∫(condition power - paired baseline power) dt
saving                    = (old incremental - new incremental) / old incremental
```

- Compare equal content, equal output geometry, equal **real presented** frame
  rate, equal scaling and equal color contract. A change that lowers frame rate,
  resolution, animation speed or effect count is a quality tier, not an
  equal-quality saving, and must be reported as such.
- Observe the application, any renderer helper, `WebContent` and the lock-screen
  extension **and** `WindowServer`. The main process alone proves nothing.
- Report absolute differences and spread. When the old incremental power is at
  or below the noise floor, do not report a percentage.
- Warm shaders, caches and temperature first; report cold start, first decoded
  frame and first shader compile separately from the steady-state window.
- Activity Monitor's Energy Impact is not watts, and GPU utilization is not
  energy.

## Authorization boundary

`scripts/power_benchmark.py` is safe to run: it only reads configuration.
Everything that produces an actual power number is out of scope for routine
verification and needs explicit authorization, because it requires controlling
the desktop, changing the user's wallpaper, or elevated sampling:

- `powermetrics` (root), Instruments/`xctrace`, Power Profiler, external meters.
- Setting a wallpaper, unlocking or locking the session, or driving Spaces.
- Screen capture and audio capture.

Until then, a power result is recorded as unverified, never as a pass. The
boundary itself is described in
[../development-tools.md](../development-tools.md).
