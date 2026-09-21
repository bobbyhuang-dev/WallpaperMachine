# Testing

How this project is verified, which layer a new test belongs in, and what
"verified" is allowed to mean in a report.

- [renderer.md](renderer.md) — headless renderer/GPU checks, probe environment
  variables, regression areas that must stay covered.
- [manual-smoke.md](manual-smoke.md) — manual release smoke checklist
  (requires authorization; not automated).
- [verification-log.md](verification-log.md) — dated history of what was
  verified, with results and explicit gaps; the ten newest entries, with older
  ones in [archive/](archive/).
- [wallpaper-corpus.md](wallpaper-corpus.md) — local regression corpus
  checklist and the environment variables that point tests at private assets.

## What "verified" means

- A claim is only as strong as the layer that produced it. Passing native tests
  do not establish visual, desktop, or OS-integration behavior.
- Report visual behavior, desktop presentation, live Steam accounts, real audio
  capture, and battery/power effects as **unverified** whenever no explicitly
  authorized manual check was performed. Do not run desktop automation to close
  that gap on your own.
- Results recorded in [verification-log.md](verification-log.md) are historical
  evidence from the branch and tree they were taken on. They are not
  verification of the current tree. Re-run the relevant non-desktop checks after
  integration and record fresh evidence as a new log entry.
- A skipped test is not a passing test. Asset-dependent cases print a reason and
  skip; read those lines before claiming coverage.
- A still screenshot does not prove animation smoothness or first-frame delivery.

## Authorization boundary

Routine verification **must not**:

- control the desktop or synthesize input,
- open application windows or capture screenshots,
- change the user's wallpapers or system appearance,
- initialize audio hardware or request system permissions,
- sign in to Steam, run a real SteamCMD login, or approve a Gatekeeper prompt,
- replace or restart the installed `/Applications/WallpaperMachine.app`.

Each of those requires an explicit user decision. `python3 scripts/test.py --ui`
and the manual smoke checklist take over the desktop and are neither part of
routine verification nor a required release gate. See
[../../AGENTS.md](../../AGENTS.md) for the agent-facing form of this rule and
[../development-tools.md](../development-tools.md) for the optional diagnostic
tooling that sits on the other side of the boundary.

The unit-test host deliberately skips app startup: it does not create the
control panel, initialize the renderer, or restore wallpapers. The default Xcode
scheme excludes UI tests.

## Test layers

| Layer | Location | Command |
| --- | --- | --- |
| Python script tests | `scripts/tests/` | `python3 scripts/test.py` (runs first, before Xcode) |
| Swift unit/integration | `Tests/Unit/<Domain>/` | `python3 scripts/test.py` (`WallpaperMachineTests`); `--only <TestClass>` for a subset |
| XCUITest (desktop) | `Tests/UI/` | `python3 scripts/test.py --ui` — opt-in only |
| Media/device integration | `Tests/Unit/NativeVideo/` | `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py` — opt-in only |
| Live Steam pages | `Tests/Unit/Workshop/WorkshopTests.swift` | `WALLPAPER_MACHINE_NETWORK_TESTS=1 python3 scripts/test.py` — opt-in only |
| Rust crates | `upstream/renderer/crates/` | `cargo test --release -p wallpaper-core --lib`, `cargo test --release -p wallpaper-bridge --lib`, `cargo test -p shader --test pipeline -- --nocapture` |
| C++ renderer tests | `upstream/renderer/external/open-wallpaper-engine` | `python3 scripts/check_renderer.py` builds and runs them; see [renderer.md](renderer.md) |
| Headless GPU probes | same CMake tree | explicitly invoked executables (`offscreen_scene_probe`, `scene_reload_cycle_probe`, `playback_gpu_test`, `wpdump`); see [renderer.md](renderer.md) |

`python3 scripts/test.py` is the routine gate: it runs the Python script tests,
runs `xcodegen generate --use-cache`, then builds and runs
`WallpaperMachineTests` only, with test classes in parallel worker processes.
The terminal gets only what matters — compile errors, failing assertions, the
`Testing failed:` block and a one-line verdict with counts — while the full
`xcodebuild` stream goes to `artifacts/tests/Tests-<timestamp>.log` next to the
result bundle. A green run prints nothing but the verdict; open the log or
rerun with `--verbose` when the raw stream is the point. `scripts/build.py`
filters the same way into `artifacts/build/<stage>-<timestamp>.log`.
Cargo and CMake commands need the Homebrew environment that `scripts/build.py`
assembles; run the Rust commands from `upstream/renderer`. Build prerequisites
are in [../build.md](../build.md).

`Tests/Unit/` is grouped by domain: Appearance, Desktop, Diagnostics, GitHub,
Library, LockScreen, NativeVideo, Panel, Steam, WebWallpaper, Workshop.

### Opt-in layers

Two layers inside `Tests/Unit/` skip themselves unless asked for, because they
reach past this tree: they depend on the machine's media hardware and on Valve's
live pages, so a failure there is not evidence about the code and a red gate
invites a pointless re-run.

- `WALLPAPER_MACHINE_MEDIA_TESTS=1` — `NativeVideoPlayerMediaTests` decodes
  real video. It still opens no window, changes no wallpaper and configures no
  audio session; it is not a desktop test and not a substitute for one.
- `WALLPAPER_MACHINE_NETWORK_TESTS=1` — the two `testLive…` cases in
  `WorkshopTests` fetch Steam's real community pages. Steam's page *format*
  stays covered offline: `decodePage` runs against recorded markup in
  `WorkshopStoreTests`, so only the assumption that Valve still serves that
  shape goes untested by default. Run them before a release, after touching the
  Workshop parser, and whenever search results look wrong in the app.

Both are forwarded into the test host by `scripts/test.py`; setting them in your
shell is enough. A skipped test is not a passing test — read the skip lines
before claiming coverage.

### Parallel execution

Test classes run in parallel worker processes (`-parallel-testing-enabled YES`),
which cuts the native phase roughly in half: most of its wall clock is spent
waiting on debounce intervals and child-process reaping rather than on CPU.
This is safe only as long as every suite keeps isolating its own state —
`WALLPAPER_MACHINE_HOME`, a temporary directory, a per-test `UserDefaults`
suite — and never asserts on a process-wide singleton, a fixed port or a shared
path. A test that passes alone but fails in the gate is the symptom; reproduce
it with `python3 scripts/test.py --serial` and fix the shared state rather than
the scheduling. UI runs are always serial: they drive one desktop.

The per-test `UserDefaults` suite is not only a parallelism concern: the unit
bundle runs inside the real app as its test host, so `UserDefaults.standard`
*is* `app.wallpapermachine`, the preferences of the installed app. Any
`WebPanelController` (or other store) built without `defaults:` writes there —
the first-run welcome's `welcomeSeen` flag, sidebar choices, favorites — and
silently changes what the app does at the next launch. Pass the test's own
suite everywhere; `PanelFixture` does.

The same rule covers a second shape: a test that measures a *wall-clock window*
rather than shared state. It is still a race, it can lose alone as well as in
the gate, and widening the sleep only moves the threshold. Two in
`ControlPanelShellTests` were fixed rather than tolerated, and both fixes are
the pattern to copy. One latched a snapshot count, submitted a form and read
the count 50 ms later, so a push already in flight when the count was latched
was indistinguishable from one the submit caused; it drains with
`panel.quiet()` before the window. The other read `getBoundingClientRect`
straight after `setFrameSize`, catching the layout before the page had
reflowed; it waits for `window.innerWidth` to reach the new width. Measure
"what did this action cause" from a settled state, and wait for a state the
page can report rather than for a duration.

Before blaming your own change for a timing-shaped gate failure, confirm
ownership: revert the change and run the gate again. A failure that survives
the revert is not yours, and that check is what separated a renderer dispatch
fix from an unrelated panel race here. Check the load average too — a gate
taking three to five times its usual wall clock is measuring contention.

## Verification tiers

The full gate compiles the Debug app and test bundle and then runs ~530 native
tests, several of which drive offscreen WebKit or a real PTY downloader; on this
machine the test phase takes about 90 seconds in parallel, before any Release
build. Match the effort to the change:

| Change | While iterating | Before reporting |
| --- | --- | --- |
| Bug fix, refactor, test-only, one domain | `python3 scripts/test.py --only <TestClass>` (repeatable; `Class/testMethod` also works) | full gate once; no Release build, no log entry unless asked or a documented behavior changed |
| New feature or cross-domain change | targeted runs as above | full gate once, log entry; Release build only if delivery was requested (`.omp/rules/release-build-on-request.md`) |
| Renderer / bridge | `cargo test` in the touched crate | full gate plus `scripts/check_renderer.py` |
| Docs / skills only | link, path and command check | nothing else |

`--only` skips the Python script tests and prints a warning: it is an
iteration tool, not evidence. Rerun the full gate only when it failed; a second
identical run adds minutes and no information. `xcodegen generate --use-cache`
(what `scripts/test.py` now runs) leaves the project untouched when
`project.yml` has not changed, so Xcode's incremental build survives between
runs.

`NativeVideoPlayerMediaTests` is the one opt-in layer inside `Tests/Unit/`. It
drives the real `AVQueuePlayer`, `AVPlayerLooper`, `AVPlayerLayer` and video
output against generated silent clips, which means real video decoding on this
machine's media hardware, so it skips itself unless
`WALLPAPER_MACHINE_MEDIA_TESTS=1` is set. It still opens no window, changes
no wallpaper and configures no audio session; it is not a desktop test and is
not a substitute for one.

## Evidence

| Artifact | Produced by |
| --- | --- |
| `artifacts/tests/Tests-<timestamp>.xcresult` and `.log` | `python3 scripts/test.py` (five newest kept) |
| `artifacts/tests/UI-<timestamp>.xcresult` and `.log` | `python3 scripts/test.py --ui` |
| `artifacts/build/<stage>-<timestamp>.log` | `python3 scripts/build.py` (cargo, bindgen, xcodegen, xcodebuild) |
| `artifacts/renderer/<run>/` | `python3 scripts/check_renderer.py` |
| `artifacts/renderer/bin/` | renderer check binaries |
| `build/Build/Products/{Debug,Release}/WallpaperMachine.app` | `python3 scripts/build.py` |

`artifacts/` and `build/` are both Git-ignored and disposable; `python3
scripts/clean.py` removes them. Result bundles are local: cite the numbers and
the command, not a bundle path, when you report a result. Private GPU output,
local asset inventories, screenshots, and traces stay out of Git.

## Current native coverage

The domain-by-domain inventory of what the Swift bundle asserts, and the limits
of each claim, is in [coverage.md](coverage.md). Check it before writing a test:
most behaviors already have a home, and several entries name explicitly what
they do not establish.

## Adding a test

1. **Pick the lowest layer that can observe the behavior.** Renderer semantics
   go to Rust or C++; bridge state goes to `wallpaper-bridge`; app services,
   stores and panel bridging go to `Tests/Unit/<Domain>/`; developer-script
   behavior goes to `scripts/tests/`. `Tests/UI/` is a last resort — it controls
   the desktop and therefore cannot be part of routine verification.
2. **Keep it device-free.** No windows, no screenshots, no audio device, no
   swapchain, no real wallpaper setter, no real Steam account. Use injected
   services, unattached layers, `URLProtocol` archives, local PTY/socket
   fixtures, and disposable directories.
3. **Assert something a consumer observes**, and make blank or corrupt output
   fail. Two equally empty results must not both pass.
4. **Never hardcode a home directory.** Resolve private assets from the
   environment and skip with a printed reason when they are absent, so a clean
   checkout runs green — see [wallpaper-corpus.md](wallpaper-corpus.md).
5. **Use original synthetic fixtures** when you need content; do not check in
   Workshop packages or other copyrighted assets.
6. **Record the result** in [verification-log.md](verification-log.md) with the
   counts, the command, and what you did not verify. Keep it to about ten
   lines; a fact that outlives the round belongs in the doc that owns it, not
   in the log. Use `python3 scripts/log_verification.py --title "…" --line "…"`
   (repeat `--line`; `--context` for one paragraph; `--dry-run` to preview): it
   prepends the entry, keeps the ten newest and moves the rest into
   [archive/](archive/) with links fixed, so nobody has to read the log to
   write to it.

Naming, style and review rules are in [../conventions.md](../conventions.md);
the contributor workflow is in [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
