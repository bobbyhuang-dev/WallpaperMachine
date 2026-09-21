# Current native coverage

What the Swift test bundle actually asserts, domain by domain. This is the
inventory behind `python3 scripts/test.py`; the strategy, layers, tiers and
evidence policy live in [README.md](README.md).

Read it to find out whether a behavior is already covered before adding a test,
and to see the exact limits of a claim — several entries end by naming what the
covered case does *not* establish. Nothing here starts the app, opens a window
or touches the desktop.

Swift tests cover, without starting the app:

- **Library** — complete atomic adoption, concurrent destinations, duplicates,
  cancellation, and rejection of linked, special, or incomplete content;
  deletion; scene-asset installation.
- **Workshop** — search and pagination beneath the UI, committed-query
  pagination, window-sized pages cut from cached Steam pages (including a size
  change while a page loads), superseded requests, cancellation, and exact
  failed-request retry through the real page parser. Two `testLive…` cases fetch
  Steam's real pages and are opt-in
  (`WALLPAPER_MACHINE_NETWORK_TESTS=1`, see
  [README.md](README.md#opt-in-layers)); the page format itself stays covered
  offline through `decodePage` against recorded markup. Thumbnail cache: CDN scaling only for Steam image
  hosts, still-frame JPEG extraction from animated previews (skipping a black
  fade-in, keeping frame 0 for bright, uniformly dark or still sources), one download per
  URL under concurrent requests, disk hits across instances, fallback when the
  CDN refuses scaling, no cache entry after a failed fetch, the concurrency cap
  and oldest-first pruning; the animated relay returns Steam's bytes on its own
  lane and refuses single-frame sources without a request; the scheme handler
  refuses thumbnail and animated ids it has not announced. An offscreen WebKit
  regression (`ControlPanelDiscoverTests`) checks that Discover tiles load the
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
  [renderer.md](renderer.md) for the `nettop` streaming detail). The
  downloader suites share `DownloaderTestCase` (`Tests/Unit/Workshop/`) and
  split by concern: `DownloaderLifecycleTests`, `DownloaderSessionTests`,
  `DownloadQueueTests`, `SteamCMDRuntimeValidationTests` and
  `DownloadTelemetryTests`.
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
- **Panel** — the offscreen `WKWebView` suites share `ControlPanelTestCase`
  (`Tests/Unit/Panel/`) and split by page: `ControlPanelShellTests` (window,
  language, appearance, About/update, top bar), `ControlPanelLibraryTests`
  (sorting, tile marks, filter sidebar, download setup, error dismissal),
  `ControlPanelDiscoverTests` (pagination, grid, download rings, previews) and
  `ControlPanelSyncTests` (hidden-panel pushes, option fetches, display titles).
  Offscreen `NSHostingController` layout proposals at 760×560,
  960×640, and 1240×800 in English and Chinese, asserting the root accepts each
  window width without forcing a taller window; an offscreen `WKWebView`
  regression that loads the bundled interface under its custom scheme, waits for
  the native reply bridge, routes a `navigate` message to Settings, and rejects
  a non-allowlisted external URL; an English/Simplified Chinese regression that
  checks the injected language, rendered navigation/accessibility labels, settings
  and result summary, plus locale fallback and literal placeholder substitution;
  a language-switch regression that sends `languageSetting` and confirms the
  page re-renders in place, the picker offers every shipped language under its
  own name, and an unshipped tag is refused. Panel tests that read rendered
  labels must pass `appLanguage: .english()` (`Tests/Unit/Support/TestAppLanguage.swift`)
  or a store built with explicit `systemLanguages`: the default
  `AppLanguageStore.shared` follows the developer's in-app language choice, so an
  implicit store renders Chinese on a Mac where the app was switched to 简体中文
  and English-wording assertions fail. `Tests/Unit/Localization/` covers
  the preference store: system matching, persistence, the `AppleLanguages`
  mirror and rejected tags. Python catalog checks
  (`scripts/tests/test_panel_localization.py`) require the Swift registry, the
  `i18n.js` registry, `WebUI/locales/` and both `.xcstrings` to name the same
  languages, every native key to be translated, every catalog to hold the same
  keys, and reject duplicate/empty entries, missing direct-call and
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
