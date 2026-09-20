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
- replace or restart the installed `/Applications/MacWallpaperEngine.app`.

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
| Swift unit/integration | `Tests/Unit/<Domain>/` | `python3 scripts/test.py` (`MacWallpaperEngineTests`) |
| XCUITest (desktop) | `Tests/UI/` | `python3 scripts/test.py --ui` — opt-in only |
| Media/device integration | `Tests/Unit/NativeVideo/` | `MAC_WALLPAPER_ENGINE_MEDIA_TESTS=1 python3 scripts/test.py` — opt-in only |
| Rust crates | `upstream/renderer/crates/` | `cargo test --release -p wallpaper-core --lib`, `cargo test --release -p wallpaper-bridge --lib`, `cargo test -p shader --test pipeline -- --nocapture` |
| C++ renderer tests | `upstream/renderer/external/open-wallpaper-engine` | `python3 scripts/check_renderer.py` builds and runs them; see [renderer.md](renderer.md) |
| Headless GPU probes | same CMake tree | explicitly invoked executables (`offscreen_scene_probe`, `scene_reload_cycle_probe`, `playback_gpu_test`, `wpdump`); see [renderer.md](renderer.md) |

`python3 scripts/test.py` is the routine gate: it runs the Python script tests,
runs `xcodegen generate`, then builds and runs `MacWallpaperEngineTests` only.
Cargo and CMake commands need the Homebrew environment that `scripts/build.py`
assembles; run the Rust commands from `upstream/renderer`. Build prerequisites
are in [../build.md](../build.md).

`Tests/Unit/` is grouped by domain: Appearance, Desktop, Diagnostics, GitHub,
Library, LockScreen, NativeVideo, Panel, Steam, WebWallpaper, Workshop.

`NativeVideoPlayerMediaTests` is the one opt-in layer inside `Tests/Unit/`. It
drives the real `AVQueuePlayer`, `AVPlayerLooper`, `AVPlayerLayer` and video
output against generated silent clips, which means real video decoding on this
machine's media hardware, so it skips itself unless
`MAC_WALLPAPER_ENGINE_MEDIA_TESTS=1` is set. It still opens no window, changes
no wallpaper and configures no audio session; it is not a desktop test and is
not a substitute for one.

## Evidence

| Artifact | Produced by |
| --- | --- |
| `artifacts/tests/Tests-<timestamp>.xcresult` | `python3 scripts/test.py` |
| `artifacts/tests/UI-<timestamp>.xcresult` | `python3 scripts/test.py --ui` |
| `artifacts/renderer/<run>/` | `python3 scripts/check_renderer.py` |
| `artifacts/renderer/bin/` | renderer check binaries |
| `build/Build/Products/{Debug,Release}/MacWallpaperEngine.app` | `python3 scripts/build.py` |

`artifacts/` and `build/` are both Git-ignored and disposable; `python3
scripts/clean.py` removes them. Result bundles are local: cite the numbers and
the command, not a bundle path, when you report a result. Private GPU output,
local asset inventories, screenshots, and traces stay out of Git.

## Current native coverage

Swift tests cover, without starting the app:

- **Library** — complete atomic adoption, concurrent destinations, duplicates,
  cancellation, and rejection of linked, special, or incomplete content;
  deletion; scene-asset installation.
- **Workshop** — search and pagination beneath the UI, committed-query
  pagination, window-sized pages cut from cached Steam pages (including a size
  change while a page loads), superseded requests, cancellation, and exact
  failed-request retry through the real page parser. Two tests use live Steam responses and therefore
  require network access. Thumbnail cache: CDN scaling only for Steam image
  hosts, still-frame JPEG extraction from animated previews (skipping a black
  fade-in, keeping frame 0 for bright, uniformly dark or still sources), one download per
  URL under concurrent requests, disk hits across instances, fallback when the
  CDN refuses scaling, no cache entry after a failed fetch, the concurrency cap
  and oldest-first pruning; the animated relay returns Steam's bytes on its own
  lane and refuses single-frame sources without a request; the scheme handler
  refuses thumbnail and animated ids it has not announced. An offscreen WebKit
  regression (`ControlPanelLayoutTests`) checks that Discover tiles load the
  still first, admit the animation beneath it, fade the still out only for a
  bright animation and never for a black one, and skip single-frame previews.
- **Downloads** — private terminals per job, transfers side by side up to the
  slot limit once the first job's sign-in is accepted and saved (siblings start
  silently while it still transfers), the queue waiting behind a job that is
  still authenticating or renewing a stale sign-in, serial order without a
  saved sign-in, a Steam "logged in elsewhere" kick re-queuing the ended job
  and turning the queue serial, per-job secrets,
  saved-sign-in handoff to the next job, cancellation, duplicate-click
  suppression, FIFO handoff after failure/cancel, shutdown without launching
  queued work, staging reclaim limited to directories nothing is writing to,
  protection against stale credential rejections erasing a newer session,
  retained-intent setup/account progression, explicit shared-resource consent
  including reinstall, resource-job deduplication, account correction, removal
  preventing resumption, and download-speed sampling (see
  [renderer.md](renderer.md) for the `nettop` streaming detail).
- **Steam runtime** — SteamCMD setup against isolated preferences/directories,
  `URLProtocol` archives, real system `tar`, and owned child processes:
  publication/replacement, invalid discovery, traversal/link/archive-size
  boundaries, the updater's contained sibling Frameworks link, network failures,
  signature-policy blocking, cancellation, and no late writes. Runtime fixtures
  exercise canonical macOS path aliases and nested Mach-O executable
  dependencies. Approval tests use isolated fixtures only: exact SHA-256
  receipts, signature/policy-failure rejection, stale candidates, changed
  resources, private copies, quarantine scope, same-path retry/relaunch, and
  explicit discard. An installation-to-downloader regression launches the
  published executable through the real PTY downloader and asserts imported
  manifest and media bytes. Fixtures do not prove that Valve's current
  distribution passes this Mac's policy.
- **GitHub updates** — fixture JSON and a fake client: version comparison, asset
  selection, host allowlisting, progress clamping, classified errors, install
  retry/timeout. They never contact GitHub, download a real archive, or replace
  the running app.
- **Panel** — offscreen `NSHostingController` layout proposals at 760×560,
  960×640, and 1240×800 in English and Chinese, asserting the root accepts each
  window width without forcing a taller window; an offscreen `WKWebView`
  regression that loads the bundled interface under its custom scheme, waits for
  the native reply bridge, routes a `navigate` message to Settings, and rejects
  a non-allowlisted external URL; an English/Simplified Chinese regression that
  checks the injected language, rendered navigation/accessibility labels, settings
  and result summary, plus locale fallback and literal placeholder substitution.
  Python catalog checks reject duplicate/empty entries, missing direct-call and
  static-markup translations, and placeholder mismatches; an About-updates regression that checks,
  downloads, and refuses to install without a window, plus a snapshot mapping of
  idle/available/ready actions; a `dismissError` regression where a
  library-refresh failure and a download failure raised through the real
  download path are reported once, stay suppressed after dismissal, and surface
  again when the same failure recurs after a successful refresh; and a hidden
  download fixture that observes password-prompt/downloading transitions.
  Editor-state tests cover locale-specific scaling, invalid raw text, and
  independent wallpaper/field drafts.
- **Appearance** — preference recreation, rejection of invalid changes without
  overwriting saved values, recovery from a damaged saved accent, reset
  isolation, plus an offscreen appearance regression that commits the real
  Appearance controls through the native bridge, changes accent/tone, resets,
  simulates live native appearance changes on a detached view, verifies explicit
  Light wins over Dark, and reloads through the WebContent recovery path with
  saved customizations intact.
- **Desktop posters** — synthetic renderer pixels and an in-memory workspace:
  lossless PNG dimensions/channel order/orientation, malformed frames,
  synchronous frame requests (no Apply debounce), first-frame delivery to all
  Spaces without a Space-change event, stale old-layer completion, automatic
  retry, independent display/Space originals, duplicate-frame suppression,
  immutable frame URLs with reference-aware cleanup, legacy journal migration,
  relaunch recovery, external wallpaper changes, and write failures. Topology
  and native option/path translation use fixtures, including empty
  inherited/default native selections, exact pathless-option restoration across
  relaunch, rejected native acknowledgements, and unreadable-original errors.
  Empty native dictionaries are retained verbatim rather than replaced with a
  guessed static default image. Coordinator tests use unattached
  `CAMetalLayer`s and injected notification/encoding services.
- **Lock screen** — per-display ownership, independent originals, external
  Desktop changes, journal recovery after service-reload failure, inherited
  Space cleanup, system-copied fallback restoration, global linked conflicts,
  and a poster-handoff regression covering a pathless original, retention of its
  poster and recovery journal, and rejection of delayed encoding completions
  after suspension. No test selects a real wallpaper.

What native tests do **not** establish: macOS acceptance/restoration of native
wallpaper selections, live GitHub release install, archive extraction and
Applications replacement, Steam CDN throughput, live-account session reuse,
Mission Control cache refresh, and any visual timing. Those stay on
[manual-smoke.md](manual-smoke.md).

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
   in the log.

Naming, style and review rules are in [../conventions.md](../conventions.md);
the contributor workflow is in [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
