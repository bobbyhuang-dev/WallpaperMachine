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

## 2026-09-18 — Batch with a saved sign-in starts together; SteamCMD sessions log their progress

A live run of the concurrent queue on a real account (Release build from the
entry below, three Scene tiles queued) still transferred one item while the
other two sat on "Waiting for the current sign-in to finish", and the app quit
before any of them imported. The app log showed the manager holding the
siblings on that reason and nothing else: the worker logged nothing about the
running session, and the saved session was never rewritten during the run, so
the first job had not passed the point where the worker sees Steam accept the
login. Holding on that at all was the mistake when a saved sign-in already
exists: the siblings restore it themselves. `holdBehindRunningJobs` now starts
a job immediately when the saved sign-in belongs to its account, holds only
while a running job has a password/Steam Guard prompt on screen, and waits for
a running login only when there is no saved sign-in to restore.
`WorkshopDownloader` now logs, per session, the runtime preparation and
whether a saved sign-in was restored, every status change, the sign-in
handoff with the early-save result, and SteamCMD's exit status.

- A direct SteamCMD probe with a copy of the saved sign-in (to read the real
  transcript and try two sessions at once) was blocked by the harness's
  permission classifier, so SteamCMD's actual output on this machine remains
  unobserved.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 277 tests with 0 failures, including the new
  `DownloaderTests.testSavedSignInStartsAWholeBatchAtOnceWithoutWaitingForTheFirstLogin`
  (one job signs in and saves; three more then start together with
  `activeCount == 3` and no prompt while every fixture session is still
  blocked before its transfer). The fresh-sign-in batch, session-conflict,
  saved-sign-in handoff and store intent tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the built binary carries the per-session log strings.
- Not verified: the live batch itself. The next live run's log under
  **Show download logs** will carry `SteamCMD <item>: …` lines that say where
  the first session stalls.

## 2026-09-18 — Several Workshop downloads at once, sharing one accepted sign-in

`WorkshopDownloadManager` runs up to `maximumConcurrentDownloads` (default 3)
private SteamCMD sessions at once. The withdrawn attempt held every sibling
until the first job *finished* because the session was only saved at the end;
now `WorkshopDownloader` saves the session the moment Steam accepts the sign-in
(`saveAcceptedSession`, then `onAuthenticated`), so siblings start silently
while the first transfer is still running. The queue holds, in order, only
while a running job is still authenticating, while the saved sign-in is not yet
on disk for the account, without **Keep me signed in**, or after Steam ended a
session with "logged in elsewhere" for another of our sessions
(`sessionConflictDetected`: the ended job goes back in line once and the queue
stays serial). Every queued job carries its hold reason
(`WorkshopDownload.hold`); starts and holds go to the app log. The snapshot
carries `downloadSlots`; `panel.js` `queueState()` sums running jobs for the
activity bar and the queue footer states the slot rule.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 276 tests with 0 failures, including the new
  `DownloaderTests.testAcceptedSignInLetsSiblingsRunSideBySideUpToTheSlotLimit`
  (limit 2: only the first job prompts, the other three hold for the sign-in,
  two transfer together once the password is accepted, the third waits for a
  slot and starts when the first releases, all four import, no staging left,
  private session permissions) and
  `testSessionConflictSerialisesTheQueueAndRetriesTheEndedJob` (a sibling
  ended with "FAILED (Logged in elsewhere)" is back in line with no error, does
  not start while the first still runs, the slot limit drops to 1, and it
  imports on its automatic retry). The serial opt-out queue, saved-sign-in
  handoff, failure-slot, shutdown and store intent tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED (the CoreDevice/CoreSimulator plug-in warnings are Xcode's); the
  built app's bundled `WebUI/panel.js` carries `downloadSlots`.
- Not verified: a live batch on a real account — whether Steam keeps two of
  the app's sessions signed in on one account, whether SteamCMD has written a
  reusable sign-in by the time it reports the login, and the activity bar with
  several real transfers. No desktop run was authorised.

## 2026-09-17 — Parallel Workshop downloads withdrawn; the queue is serial again

On a real account the parallel queue never ran a second transfer: with one
item transferring, the next two tiles stayed at the dimmed "waiting" ring until
it finished (the manager's saved-sign-in gate held them, and the downloader
writes nothing to the app log that would say why). Steam's handling of two
SteamCMD sessions sharing one saved sign-in is undocumented and could not be
tried without a live sign-in, so `WorkshopDownloadManager` is back to one
private SteamCMD session at a time (the pre-parallel version): queued jobs
start in order as each finishes and reuse the sign-in the previous job saved.
Removed with it: `maximumConcurrentDownloads`, `canJoinRunningDownloads`,
`WorkshopDownloader.promptedForSignIn` and `onAuthenticated`, the snapshot's
`downloadSlots`, and the multi-job aggregate in `panel.js` `queueState()`
(the activity bar carries the running job's own status, percentage and speed;
the queue footer states that downloads run one at a time). The disk-measured
progress, tile rings and page-size negotiation from the same batch stay.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 274 tests with 0 failures after deleting
  `DownloaderTests.testSavedSignInRunsDownloadsInParallelUpToTheSlotLimit` and
  `testStaleSavedSignInHoldsTheQueueUntilTheRenewingJobFinishes`; the serial
  queue, sign-in handoff, failure-slot and shutdown tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED (the CoreDevice/CoreSimulator plug-in warnings are Xcode's, not the
  app target's); the built app's bundled `WebUI/panel.js` no longer mentions
  `downloadSlots` and carries the one-at-a-time queue note.
- Not verified: a live batch on a real account with the serial queue. No
  desktop run was authorised.

## 2026-09-17 — Discover rows fill the grid height

A window whose grid was about a pixel short of a fourth row showed three rows
and a near-row of blank space (Discover asks for 15 tiles per page). Discover
tiles may now stretch or squash by up to 15% so the rows fill the grid exactly,
and the page-size measurement reads the grid's outer width so a classic
scrollbar appearing on a briefly overflowing page cannot flip the fit.

- A throwaway sweep of 210 web-view sizes (900–1600 × 600–1100) through the
  panel with a stand-in native reply: before the width change, two sizes at
  600pt toggled the fit every frame as a 9pt scrollbar appeared and vanished;
  after it, 0 mismatches (page size = rendered columns × rows, no overflow,
  three or more rows leave under a pixel per row). The sweep was removed; the
  kept `testDiscoverPageRowsFillTheGridHeight` checks five sizes including the
  reported one and the oscillating one.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 276 tests with 0 failures.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `WebUI/panel.js` carries the row-fit (`fitRows`).
- Not verified: the live app at the reported window size with overlay
  scrollbars and real thumbnails. No desktop run was authorised.

## 2026-09-17 — Parallel Workshop downloads re-verified on the integrated tree

Re-ran the routine gate and the Swift-only Release build on the tree that
carries the parallel download manager, the disk-measured transfer progress,
the Discover page-size negotiation and the tile download ring together.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  executed 273 tests with 0 failures, including both parallel-queue tests in
  `DownloaderTests` and the disk-progress tests.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED (Xcode's CoreDevice/CoreSimulator plug-in warnings are unrelated
  to the app target). The built app's bundled `WebUI/panel.js` contains
  `queueNote()` and the `downloadSlots` slot rule, and its binary carries the
  queued-status string.
- Not verified: a live batch of several Steam transfers on a real account, the
  activity bar with more than one running job, and Steam-side limits on
  concurrent SteamCMD sessions. No desktop run was authorised.

## 2026-09-17 — Workshop progress capped by bytes received over the network

Workshop transfer progress was the allocated bytes under the staging's
`steamapps/workshop` tree alone. Steam can allocate a file's full length before
its chunks arrive, so that figure could claim 99% of an item at once and sit
there. `NetworkReceiveMeter` now also totals the bytes the SteamCMD process
receives (`bytesReceived`, exposed through `ProcessNetworkMonitoring`), and
`WorkshopDownloader.sampleWorkshopDisk` reports the smaller of the tree and
that total, both capped at the listed `file_size`; without a meter the tree
alone is used, as before. `nettop`'s first delta row for a process carries
everything it received since launch, so it anchors the timeline and neither
the rate nor the total includes it.

- Probe of `/usr/bin/nettop -P -L … -p <pid> -n -x -d -s 1 -J bytes_in`
  against a rate-limited `curl` child started 3 s earlier: header `,bytes_in,`
  then `curl.<pid>,<bytes>,` rows, no time column; the first row held ~6.6 MB
  (everything since the process began), later rows ~2.06 MB each at the 2 MB/s
  limit. A real Workshop browse page carried `file_size` as a decimal string.
- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  ran 275 tests with 0 failures, including the new
  `DownloaderTests.testPreallocatedWorkshopFilesReportOnlyBytesThatCrossedTheNetwork`
  (2048 bytes on disk at once with the meter at 0 → 0%, then 512 → 25%,
  1536 → 75%, a meter beyond the tree → 99% at the tree's 2048, a meter that
  stops reporting falls back to the tree, cleared on shutdown) and
  `testNetworkReceiveMeterTotalsEveryRowAfterTheFirst` (first row dropped,
  foreign/malformed rows ignored, out-of-window and same-timestamp rows still
  counted, the total survives the oversized-output reset). The existing
  disk-growth, rate and monitor tests pass unchanged.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED from the edited tree; the Release binary is stripped, so its
  contents were not inspected beyond the build's own output.
- Not verified: a live SteamCMD transfer (whether Steam's macOS writer really
  preallocates, and how far compressed chunks put the network total behind
  the listed size). No desktop run was authorised.

## 2026-09-17 — Parallel Workshop downloads gated on a saved sign-in

`WorkshopDownloadManager` runs up to `maximumConcurrentDownloads` (default 3)
private SteamCMD sessions at once instead of one. A queued job joins running
downloads only when it can sign in silently: **Keep me signed in** is on, the
saved sign-in belongs to its account, and no running job is still
authenticating or was prompted (`WorkshopDownloader.promptedForSignIn`, set by
any password/code/approval prompt). The worker's new `onAuthenticated` hook
re-pumps the queue when Steam accepts a sign-in, so the first job of a batch
authenticates alone and the rest reuse what it saves on completion; without a
saved sign-in behaviour is unchanged (serial). The panel snapshot carries
`downloadSlots`; `panel.js` `queueState()` aggregates every active job (mean
of measured percentages, summed speeds, "N downloading") for the activity bar
and badge, and the queue footer states the slot rule.

- `python3 scripts/test.py`: Python suites and XcodeGen passed; native suite
  ran 273 tests with 0 failures, including the new
  `DownloaderTests.testSavedSignInRunsDownloadsInParallelUpToTheSlotLimit`
  (limit 2: the fresh sign-in runs alone, two jobs transfer together once it
  saved, the fourth waits for a slot, all four import, no staging left,
  private session perms) and
  `testStaleSavedSignInHoldsTheQueueUntilTheRenewingJobFinishes` (a rejected
  saved sign-in keeps `activeCount == 1` through the prompt and through the
  transfer that follows it; siblings start silently after it finishes). The
  existing serial, session-handoff, failure-slot and intent-ladder tests pass
  unchanged.
- Throwaway Bun evaluation of `queueState()`/`queueNote()` extracted from
  `WebUI/panel.js`: two active jobs at 20%/60% with 1 MB/s + 500 KB/s summarise
  as "2 downloading · 40% · Network speed: 1.5 MB/s", badge count 3 with one
  queued; a single authenticating job keeps its status text with no percentage.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the built app's binary carries the new queued-status string and
  its bundled `WebUI/panel.js` contains `queueNote()` and the multi-job
  `queueState()` summary.
- Not verified: the live activity bar with several transfers, and real Steam
  behaviour for concurrent SteamCMD sessions on one account (each session uses
  its own private copy of the saved sign-in; Steam-side session limits or rate
  limits would surface as per-job failures). No desktop run or Release build
  was authorised.

## 2026-09-17 — Larger, steady Discover download ring with transfer speed

The Discover tile ring (`.tile-download`) is redrawn closer to Wallpaper
Engine's own: 72px (64/60px in the narrow tile breakpoints), the still dims
behind it, no chip until hover, a 4px accent stroke on a faint track, the
percentage centred with the transfer speed beneath it (speed alone while the
percentage is unknown; hidden at the 116px tile size where it cannot fit).
Hover fills the chip and shows the cancel mark. The shimmer is gone because
nothing rotates any more: the value circle uses `pathLength="100"` so progress
is a plain dash offset, and the busy sweep animates `stroke-dashoffset` instead
of a `rotate()` transform on a layer centred between device pixels. Attention
and failed states colour the track instead of a box-shadow ring; the attention
pulse is a sonar ripple. `speed()` formats the compact value; `rate()` keeps
its "Network speed:" prefix for the activity bar and queue.

- `python3 scripts/test.py`: Python suite and XcodeGen passed; native suite
  ran 271 tests with 0 failures, twice (before and after extending
  `ControlPanelLayoutTests.testDiscoverTilesCarryDownloadRingsAndOnlySteamRequestsOpenTheDialogWithoutWindow`
  to assert `.ring-speed` reads "600 KB/s" beside the 42% label and alone while
  authenticating without a percentage; `.ring-label` still reads "42%" and the
  progress dash offset stays positive).
- `.agents/skills/impeccable/scripts/impeccable detect --json WebUI/panel.css WebUI/panel.js`:
  no findings.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `WebUI/panel.js` and `panel.css` in the built app
  contain the new ring markup and styles.
- Not verified: the rendered ring, hover state and the absence of shimmer on a
  live panel. No desktop run or screenshot was authorised; the offscreen
  WKWebView tests cover markup and state only.

## 2026-09-17 — Tile download rings, double-click download, measured Workshop progress

Discover tiles now carry their download state as a ring over the thumbnail
(`.tile-download`: percentage + filling stroke, spinning arc, queued arrow,
pulsing shield, retry mark; `.tile-installed` check for library items), a
double-click on a Discover tile requests the download (or applies an installed
item), the top-bar downloads button appears only while downloads exist, and the
sign-in dialog no longer opens for every hand-off: it opens by itself only when
a job carries a password prompt or Steam Guard challenge, **Not now** silences
that exact request, and it closes once Steam is satisfied. Workshop transfer
progress is measured on disk: `WorkshopDownloader` sums allocated bytes under
the staging's `steamapps/workshop` tree twice a second while Steam reports
"downloading item" and divides by the Workshop `file_size`, capped at 99% until
Steam's own success line; items without a listed size stay indeterminate.

- `python3 scripts/test.py`: Python suite and XcodeGen passed; native suite
  ran 246 tests with 5 failures, all in
  `WorkshopStoreTests.testPanelPageSizeComposesPagesFromCachedSteamPages`,
  which belongs to an uncommitted, concurrent panel page-size change in
  `WorkshopStore.swift` / `WorkshopStoreTests.swift` that this work did not
  touch. New and changed tests passed:
  `DownloaderTests.testWorkshopDiskGrowthReportsProgressAgainstListedSize`
  (512/2048 → 25%, 1536/2048 → 75%, over-listed bytes stay at 99%, cleared on
  shutdown), `testWorkshopDiskGrowthWithoutListedSizeStaysIndeterminate`, and
  `ControlPanelLayoutTests.testDiscoverTilesCarryDownloadRingsAndOnlySteamRequestsOpenTheDialogWithoutWindow`
  (ring percentage and cancel action, no dialog while authenticating with no
  prompt, auto-open on a password prompt, Not now stays quiet for the same
  prompt, reopens for a mobile challenge, closes when the job resumes, retry
  ring after failure, check once installed).
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled `WebUI/panel.js` in the delivered app contains the
  tile ring code.
- Not verified: the ring against a live SteamCMD transfer (no desktop run
  requested), and whether Steam's macOS content writer ever block-preallocates
  Workshop files, which would inflate the on-disk measurement.

## 2026-09-17 — Discover pages sized to the grid

A Discover page held Steam's fixed 30 items, so wide windows ended in a partial
row and empty space. The panel now measures its grid (columns × full rows of
square tiles, empty-state box while the grid is hidden, `ResizeObserver` plus a
re-measure after each grid render, 120ms debounce) and sends `workshopPageSize`.
`WorkshopStore.setPageSize` cuts pages of that size from a per-query cache of
Steam pages, fetching only the missing ones (the first alone while Steam's page
count is unknown, the rest concurrently, in-flight fetches joined rather than
repeated); a size change keeps the first visible tile by remapping the page
number, restarts a loading page at the new size, and a fully cached page is
published synchronously without a loading state. The snapshot carries the
current `pageSize` and a `reachable` count for the Steam cap note.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (271 tests, 0 failures). New
  `testPanelPageSizeComposesPagesFromCachedSteamPages` drives pages of 40 across
  Steam pages 1–3, a shrink to 30 served from cache with no request, a fresh
  search discarding the cache, and a grow to 35 while page 3 loads. New
  `testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes` checks the page's
  reported size equals resolved columns × full rows at 960×640, that exactly
  that many tiles neither scroll nor leave a full row empty, that nothing is
  re-requested, and that a 1400×900 resize reports a larger size that the store
  adopts.
- Earlier attempts of the WebUI test failed on non-numeric fixture ids (the
  parser drops them) and on measuring after the native reply had re-rendered
  Installed; both were test-side fixes.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the delivered app carries the new WebUI and store.
- Not verified: the live window's look while resizing (no desktop run
  requested).

## 2026-09-17 — Filter sidebar arrow rail and draggable inspector edge

Follow-up to the collapse/fluid-width entry below: the toolbar **Filters**
toggle moved into the sidebar as an arrow (heading arrow collapses to a 30px
rail, rail arrow expands), and the inspector's left edge became a drag handle
(`#inspector-resizer`, `role="separator"`, arrow keys and `Home`). A dragged
width is clamped to 240px–45vw, sent natively once on release
(`inspectorWidth` action, `UserDefaults`, snapshot field `inspectorWidth`,
double-click clears it). Sidebar widths in the narrow media queries moved to
`--filters-width` so the rail width wins there too.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (267 tests, 0 failures). The extended
  `testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth`
  now also drives the rail (first column 30px while collapsed), a synthetic
  60px pointer drag (260px → 320px, persisted as 320), a double-click reset
  back to the fluid width, and a stored width surviving a relaunched controller.
- Two earlier single-test runs failed on the way: a wait condition that could
  never be met once the native reply re-rendered on Installed, and the 148px
  sidebar literal in the ≤1040px media query overriding the rail; both fixed.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; the bundled WebUI files match the source tree.
- Not verified: pointer feel of the drag handle in the live window (no desktop
  run requested).

## 2026-09-17 — Panel icons switch to vendored Lucide glyphs

The hand-drawn SVG path map in `panel.js` is replaced by `WebUI/icons.js`,
22 glyphs copied from the locally cached `lucide-react` 1.45.0 package (ISC
notice in the file header; the GitHub brand mark stays as before because
Lucide ships no brand icons). `icon(name)` now renders Lucide's 2px stroke
and `WebPanelAssets` serves the new module.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (267 tests, 0 failures). The new
  `testServesEveryBundledPanelModule` checks every bundled page module,
  including `icons.js`, routes to a file and an unknown name is refused.
- `node --check WebUI/panel.js` and importing `icons.js` under Node both
  succeed (22 glyph entries, none empty).
- Not checked: visual rendering in the app; no build or desktop run was
  requested.

## 2026-09-17 — Discover filter sidebar collapses; inspector width is fluid

Instead of drag-resizable sidebars, Discover's toolbar gained a **Filters**
toggle that hides the fixed-width filter column (stored in `UserDefaults`
because the panel's website data store is non-persistent, exposed as
`workshopFiltersCollapsed` in the snapshot), and the inspector column now uses
`clamp(280px, 22vw, 340px)` so wide windows stop leaving a fixed strip.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (266 tests, 0 failures). The new
  `testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth`
  checks the toggle releases the grid column, the flag persists across a
  relaunched controller, Installed never carries the Discover-only class, and
  the inspector measures 260px at 960px and 340px at 1600px.
- First run of the same command failed
  `ControlPanelWindowSizingTests/testHostedPanelWindowKeepsItsSizeFloor`
  (untracked test from concurrent minimum-size work, unrelated to this
  change); it passed on the immediate re-run.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD SUCCEEDED;
  the delivered app bundles the updated `panel.js`.
- Not verified: the live window (no desktop run requested).

## 2026-09-17 — Control-panel window can no longer shrink below 760×560

The window set `contentMinSize` to 760×560, but the panel could still be
dragged down to a stub showing only the traffic lights. A hosted test showed
why: after `NSHostingController` attaches, it resets `contentMinSize` to
`(0, 0)` even with `sizingOptions = []`. Window construction now lives in
`ControlPanelWindow`, and `AppDelegate.windowWillResize` clamps every user
resize to the floor (minimum content size plus chrome, capped by the visible
screen frame). `constrainToScreen` still grows a restored frame on reopen.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (266 tests, 0 failures), including the new
  `ControlPanelWindowSizingTests` (offscreen hosted window: resize proposals
  clamp to the floor, larger proposals pass through, reopen grows a shrunken
  frame). A first full run failed once in the pre-existing
  `testWorkshopFilterSidebarCollapsesPersistsAndInspectorGrowsWithWidth`
  (inspector 260 vs 280 px); it passed alone and on the second full run.
- Not verified: dragging the live window by hand (no desktop run requested);
  no Release build was made.

## 2026-09-17 — Display titles use the system display name

The panel showed the renderer's raw `Vendor 1552 - Model 41055 (1 - Primary)`
label for the built-in display because the vendored renderer never fills a
display name. `DisplayTitleResolver` now maps a display to
`NSScreen.localizedName` and rewrites the title in the page snapshot (target
picker, Settings -> Displays, mirror targets, inspector display sections),
keeping the `(id - Primary)` suffix. A first cut keyed only on the settings
row id and changed nothing in the delivered app: configured rows carry
`primary` / `identity:{json}` ids, not the screen number. The resolver now also
matches the live id in the title suffix and the identity UUID against
`NSScreenNumber` / `CGDisplayCreateUUIDFromDisplayID`. Unmatched ids keep the
renderer label; the bridge and persisted state are untouched.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (264 tests, 0 failures), including the new
  `DisplayTitleResolverTests` (suffix handling, primary/identity selector
  ids, unmatched ids, blank names, system names keyed by screen number and
  UUID) and `testDisplayTitlesUseTheSystemNameEverywhereTheRendererLabelAppears`.
- `python3 scripts/build.py --swift-only --configuration Release` after the
  fix: BUILD SUCCEEDED, delivered to
  `build/Build/Products/Release/MacWallpaperEngine.app`. The user's own
  Release build of the first cut still showed the vendor/model label, which
  is what exposed the id mismatch.
- Not run: a desktop check of the rebuilt panel; the name shown depends on
  `NSScreen.localizedName` on the user's Mac.

## 2026-09-17 — Tile grid density follows the browser column width

The Discover grid no longer switches between fixed column counts that divide
the 30-item page (2 / 3 / 5 / 6 / 10) at hard container breakpoints, which made
tiles balloon just below each breakpoint (two ~227px tiles per row in a 890px
window). Both grids now use `repeat(auto-fill, minmax(var(--tile-min), 1fr))`
with a container-driven minimum (154px, 130px under 560px, 116px under 440px),
so a narrower browser column shows smaller tiles and more of them. A full
Workshop page may end in a partial row.

- `python3 scripts/test.py`: Python suite, XcodeGen and native unit tests
  passed (250 tests, 0 failures).
- Not checked: the live layout in a running window (no desktop run was
  requested); the sizes above are computed from the CSS.

## 2026-09-17 — Cached still thumbnails for Discover tiles

Discover tiles used Steam's full-size `preview_url` directly. Measured on the
live "Trending this week · Scene" page 1: 30 items, 22.8 MB, 17 of them GIFs
(14.7 MB); the CDN's `imw/imh` scaling shrinks JPEG/PNG about 9× but leaves
GIFs at 12.7 MB. Tiles now load `mwe-ui://thumbnail/<id>`, served by the new
`WorkshopThumbnailCache` actor (scaled download, first frame via ImageIO, JPEG
on disk under `Cache/WorkshopThumbnails`, four downloads at a time, oldest-first
pruning at 128 MB). The scheme handler only resolves ids in the current
snapshot; tiles pulse their placeholder while loading.

- `curl` probes against `images.steamusercontent.com`: the scaling query
  returns 200 for JPEG and GIF previews; no query parameter converts a GIF to a
  still image, hence the local first-frame extraction.
- `python3 scripts/test.py`: Python script tests OK, XcodeGen OK, native
  suite 258 passed, 0 failed, 0 skipped (adds `WorkshopThumbnailCacheTests`
  ×7 and `WebPanelAssetsTests` ×1). First run failed only on a synthetic
  size assertion (a flat test GIF compresses smaller than its JPEG); the
  assertion was removed and the suite re-run.
- Follow-up the same day: animated previews return on demand. The tile under
  the mouse pointer (180 ms dwell) or keyboard focus renders a `tile-live`
  `<img>` with Steam's full preview over its still and fades it in on load;
  leaving removes it. `node --check WebUI/panel.js` OK;
  `python3 scripts/test.py` re-run after the change (see result below).
- Not verified: the thumbnails and hover animation inside the running app on a
  throttled link (no desktop run, no Release build requested).

## 2026-09-17 — Top bar in the title-bar strip, centered brand, GitHub link

The control-panel window now hides its native title (transparent title bar, an
empty unified toolbar sizing the strip to 52px) and the page's top bar occupies
that strip: tabs after the traffic lights, whose measured inset arrives in every
snapshot as `windowControlsInset`; product name, version and a GitHub button
(`repositoryURL`, opened through the existing `openExternal` allowlist) on the
window's horizontal center; picker, downloads and renderer link on the right.
Background presses on the bar post `dragWindow` / `titleDoubleClick`, which the
host answers without a snapshot (`performDrag`, system double-click action).

- `python3 scripts/test.py` (twice, after the final test edit): Python script
  tests OK; native **250 passed, 0 failed, 0 skipped**, including the new
  `testTopBarCentersTheBrandBesideARepositoryLinkAndOwnsTitleBarGesturesWithoutWindow`
  (repository link equals `AppUpdateConfiguration.repositoryURL` and passes the
  allowlist, brand center within 1px of the bar center at 1240px, inset 0 and
  gesture replies empty without a window, background press posts no snapshot).
- No Release build or desktop run. Unchecked on a real window: traffic-light
  vertical alignment against the 52px bar on macOS 26, click pass-through in
  the toolbar strip, and the measured inset value.

## 2026-09-17 — Workshop page jump and Steam's 1,000-page cap

The Discover pagination showed **Page 1 of 1000** against millions of results.
Live probes of `steamcommunity.com/workshop/browse` (app 431960, trend sort)
confirmed the cap is Steam's: `total_pages` is 1000 for `total_count`
2,891,159, `p=1001` and `p=5000` both return page 1000, and `numperpage`
above 30 is clamped back to 30. The panel now exposes an editable page number
(Return or **Go**, clamped to the last page) and, when the count exceeds
`totalPages × pageSize`, a note that only the first 30,000 results are
reachable. `WorkshopService.pageSize` feeds both the browse URL and the
snapshot's new `pageSize` field.

- `python3 scripts/test.py`: Python script tests OK; native **249 passed,
  0 failed, 0 skipped**, including the new
  `testWorkshopPageJumpClampsToSteamsPageLimitAndExplainsTheCap` (typed 5000
  requests page 1000, cap note names 30,000 of 2,891,159, no note and a
  disabled field for a single page).
- No Release build or desktop run; visual layout of the inline number field is
  unchecked on a real window.

## 2026-09-17 — Delete affordances moved into view

Moved the inspector's **Show in Finder** / trash buttons into the heading
action row beside **Apply wallpaper** (previously below the options, off-screen
once options loaded) and added a toolbar **Select** / **Done** toggle that keeps
every tile's check box visible and makes plain clicks toggle selection.

- `python3 scripts/test.py`: native **248 passed, 0 failed, 0 skipped**.
- Headless-Chromium smoke with the stubbed `native` handler: trash button
  renders in the inspector action row without scrolling; **Select** turned on
  persistent check boxes, two plain tile clicks produced
  `2 selected · Select all · Clear · Move 2 to Trash`; **Done**/`Escape` leave
  the mode. Harness removed afterwards. No Release build or desktop run.

## 2026-09-17 — Library batch deletion and tile multi-select

Added `BridgeStore.deleteWallpapersAsync(ids:recycle:)` (per-wallpaper failure
tolerance, one library refresh), the `deleteMany` panel action with a single
confirmation and a combined failure message, and WebUI selection (tile check
buttons, Cmd/Shift-click, Select all, Clear, `Delete`/`Escape` on the grid).

- `python3 scripts/test.py`: native **248 passed, 0 failed, 0 skipped**,
  including new `BatchDeletionTests` (continues past an invalid id and a
  recycle failure, refreshes once; skips refresh when nothing was trashed).
- WebUI smoke in a headless Chromium against a throwaway copy of `WebUI/` with
  a stubbed `native` handler: check click + Shift-click selected `w1…w3`, the
  summary row showed `3 selected · Select all · Clear · Move 3 to Trash`,
  **Move to Trash** posted `{action:"deleteMany", ids:["w1","w2","w3"]}` and the
  grid dropped the returned ids; `Escape` cleared the selection and `Delete` on a
  focused tile posted a one-id `deleteMany`. Harness removed afterwards.
- Not exercised: the native NSAlert confirmation sheet (needs a window), the
  real Trash move inside the app, and Release build/desktop run.

## 2026-09-17 — Scripted vector constants and timeline events

Follow-up to the entry below, which reported both defects and deferred them.
Source-only. No Release build, application launch, desktop automation,
screenshot, wallpaper change, audio hardware, permission prompt or install.

### Scripted material constants kept their component count

`MakeMaterialConstantDynamicValue` treated only three-or-more components as a
vector and sent everything else through `ResolveStringSetting`. `WPJson`'s
`std::vector<float>` overload converts the authored `"0.79139 0.44186"` through
`utils::StrToArray`, so these constants really do have two components; the
script was still handed `parse_string` of the array — the text
`[0.79139,0.44186]` — and `value.x` was `undefined`. That is both reported
symptoms: `g_Point2=[nan,nan,0]` on layer 503 `中-菜单-浮动`, and
`g_Point1=[0]` on the page-fold pass, where `ShaderValueFromDynamicValue` parses
a string that starts with `[` and yields one zero.

Constants now resolve at the authored count through the new
`ResolveVectorSetting`: one component as a float, two and four as vectors, three
unchanged. After the change the same probe run reports `g_Point2=[0,0]` — the
authored `"0.00000 0.00000"` — and no `nan` appears anywhere in either package's
dumped pass constants. Diffing all 146 dumped passes of `3292361861` before and
after gives **0 changed constants**, so its four scripted scalars and three
scripted `vec3`s are unaffected.

### Timeline events now reach the layer

`options.events` is parsed into `ScalarAnimation::events`, and
`ScalarAnimationPlayback::Advance` queues each crossed marker as a whole
`ScalarAnimationEvent`: the authored `AnimationEvent` carries `frame` beside
`name`, so a handler can tell two markers apart in one tick. Departure is
exclusive and arrival inclusive. A loop is treated as a circle and the distance
to each marker is measured along the direction of travel, which keeps reverse
travel symmetric and makes a wrap, an exact landing on the seam and a marker
authored at the period the same point; travelling a whole period reports each
marker once, not once per lap; `SetFrame` reports nothing because a seek is not
playback.

`SceneRuntimeContext::Tick` drains the queue after advancing the clocks **and**
re-evaluating the scripted values: a property script initializes lazily on its
first evaluation, so a marker crossed by the first tick would otherwise reach an
uninitialized handler. The `engine.on`/`scene.on` list is global to the shared
context, so it is run once per marker from the runtime rather than inside each
matching `SceneScriptProgram` — two bound scene scripts would otherwise repeat
every listener, and none would silence them entirely. That runner also
refreshes the `engine` object before calling the listeners: a global listener
can be a marker's only consumer, and nothing else would have updated
`engine.runtime`/`engine.frametime` this tick.

`scene.getAnimation(name)` did not exist: `getAnimation` was only on the layer
object. A null layer argument to `__animationControl` now means a scene-wide
name match (`SceneRuntimeContext::FindAnimationByName`).

### Commands and results

- `cmake --build artifacts/renderer/bin --target scene_schema_tests
  script_runtime_compat_test media_thumbnail_texture_smoke mouse_input_test
  mdl_schema_tests playback_gpu_test render_target_lifetime_test
  text_object_runtime_test shader_cache_metadata_test
  scenescript_sound_layer_smoke particle_mouse_controlpoint_test` then each
  binary: **68 / 66+1 / 10 / 11 / 52 / 31 / 4 / 60 / 1 / 8 / 38 passed**. The
  single failure is the documented pre-existing
  `ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`.
  `tex_schema_tests` does not build in this checkout (`lz4.h` not found) before
  or after this change and was not touched.
- Non-vacuity, one targeted mutation at a time with a rebuild between each:
  restoring the old `value.size() >= 3` rule fails the scripted-vector test;
  removing the `DispatchPendingAnimationEvents()` call fails both crossing
  tests; forcing the loop direction forward or making arrival exclusive fails
  the reverse/exact-wrap test; dropping `frame` from the event object fails the
  marker-tally test; removing the runtime's single
  `RunAnimationEventCallbacks` call fails the global-listener test; pinning
  `scene_wide` to false fails the scene-wide lookup test; and moving the drain
  back ahead of `reevaluate()` fails the initialization test (`-1` instead of
  `7`); and dropping the `UpdateEngineObject` call from the global runner makes
  a global-only listener read `engine.runtime`/`engine.frametime` as `0`
  instead of `2`.
- `python3 scripts/check_renderer.py --project …/2887099508/project.json
  --project …/3292361861/project.json`: ten generated cases pass with no
  diagnostics; `2887099508` `pixels_equal=true` with **7** pre-existing
  SceneScript diagnostics (8 before: the `animationEvent` `TypeError` is gone);
  `3292361861` `pixels_equal=false` with its 28 pre-existing diagnostics.
  Reload cycles: 0.
- `python3 scripts/build.py --renderer-only`: succeeded. `python3
  scripts/test.py`: Python **39 passed**, native **246 passed, 0 failed,
  0 skipped**.

### The two-phase page turn now completes on the original package

`offscreen_scene_probe` on `2887099508` with its saved overrides,
`WE_TEST_CLICK_LAYER=384`, `WE_TEST_FRAME_STEP=0.0333` and
`WE_TEST_DUMP_PASSES=1`. The dumped pass lines now also carry live visibility,
which the prepare-time listing and `nodes.txt` cannot show — `nodes.txt` is
written once before the frame loop.

The first attempt looked finished at the layer swap but was not: the probe log
still carried `ScriptEngine[animationEvent]: TypeError: not a function` at
`<property-script-factory>:25:8526`, the `thisScene.getAnimation('111')` call
that starts the second fold. The swap happens before that line, so it succeeded
while the rest of the handler did not.

With the scene-wide lookup in place the probe logs **zero** `animationEvent`
errors and the whole authored sequence runs:

- frame 28: `page首`'s perspective pass is `visible=1` mid-fold
  (`g_Point1=[0.280963, 0.344198]`); `page` is `visible=0`.
- frame 30, `houye`: the two swap, and `111` starts on `page`.
- frame 45: `page` is `visible=1` with its own corners moving —
  `g_Point0` has left its static `0.26795,0.34444` for `0.187791,0.399638` and
  `g_Point3` `0.38914,0.94238` for `0.358402,0.855579`.
- frame 60, `yeshu`: `page` goes `visible=0`. Frame 90 holds it, and the thin
  white sliver that the unfinished handoff left at the page edge is gone.

Desktop presentation is still **unverified**; no application was launched.

## 2026-09-17 — Vector material constant timelines (page-fold corners)

Source-only work on the local tree. No Release build, application launch,
desktop automation, screenshot, wallpaper change, audio hardware, permission
prompt or install. Scaling settings were read, never written: both reported
wallpapers keep `fill` at factor `1.0` and their saved property overrides.

### What changed

`ResolveScalarAnimation` takes a component index and reads `c0`–`c3` plus the
matching entry of a vector initial value. `MaterialConstantAnimation` holds one
`ScalarAnimation` per component beside the single shared
`ScalarAnimationPlayback`; `SceneRuntimeContext` binds and samples every
component, reusing the sampled `ShaderValue` while the shared frame is
unchanged. `WPSceneParser::RegisterMaterialConstants` resolves
`options.parent.key` to a root inside one material pass and registers one clock
per root. `offscreen_scene_probe`'s `WE_TEST_DUMP_PASSES` now dumps only the
last sampled frame and appends each dumped pass's material slot constants to
`passes.txt`. `tests/CMakeLists.txt` links `nlohmann_json` into
`media_thumbnail_texture_smoke`, which failed to compile before this change too.

### Commands and results

- `python3 scripts/check_renderer.py` **before** the C++ change: the new
  `generated-perspective-animation` case failed its pixel assertions while the
  other nine passed. Its `frame-2.ppm` had the clear colour at the centre
  (26,51,77) and white at (48,32) — no page, wedge in the margin, 9984 white
  pixels. **After**: all ten generated cases pass; the same frame has white at
  the centre, the clear colour at both margin samples and 26112 white pixels,
  which is exactly the authored quad's area (0.265625 × 384 × 256).
- `python3 scripts/check_renderer.py --project …/2887099508/project.json
  --project …/3292361861/project.json`: ten generated cases pass with no
  diagnostics; `2887099508` `pixels_equal=true` with 8 pre-existing SceneScript
  `TypeError` diagnostics; `3292361861` `pixels_equal=false` with 28
  pre-existing diagnostics (SceneScript errors plus one workshop clipping-mask
  shader that fails to compile). Those two scenes run clock- and random-driven
  scripts, so their pooled/isolated pixels are not expected to match and the
  criterion was not relaxed. Reload cycles: 0.
- `cmake --build artifacts/renderer/bin --target scene_schema_tests
  script_runtime_compat_test media_thumbnail_texture_smoke mouse_input_test
  mdl_schema_tests playback_gpu_test` then each binary: **67 / 58+1 / 10 / 11 /
  52 / 31 passed**. The single failure is the documented pre-existing
  `ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`.
- Non-vacuity was checked by stashing only the changed sources and rebuilding:
  the four new parser cases fail there, reading the static values (0.375, 9),
  and `SceneSchema.OneBrokenVectorTimelineGroupIsReportedOnce` reports 2 errors
  instead of 1 when the unusable parent is not memoized.
- `python3 scripts/build.py --renderer-only`: succeeded, regenerated bindings.
- `python3 scripts/test.py`: Python **39 passed** (1 + 24 + 4 + 10), native
  **246 passed, 0 failed, 0 skipped**.

### Original-asset attribution: the reported wedge, reproduced and fixed

All `offscreen_scene_probe` runs used `2887099508` with its saved overrides
(`audioline`/`insert`/`randomchat`/`renwu`) and exited 0.

The authored trigger was traced by running every script-bearing setting of the
packaged scene under a recording stub (80 settings). The page turn is not a
timed effect: the `cursorClick` export on node 384's perspective `point1`
constant does `thisLayer.visible = true`, `thisObject.getAnimation('900').play()`
and plays the `翻页mp3` layer, while the `cursorClick` on the same node's
`visible` setting plays the `hand turn` puppet animation on `hand book`. Node
384's `visible` is authored `value:false` with a script that exports only
`cursorClick` and `animationEvent` — no `update` — so the layer is simply hidden
until a click, and the 164 `ScriptEngine[update]` errors in the log belong to
other layers, not to this one. An idle sample therefore cannot show the page at
all, and `nodes.txt` is written once before the frame loop, so it is a snapshot
at the click point, not proof about the whole sample.

Driving that trigger with `WE_TEST_CLICK_LAYER=384`, `WE_TEST_FRAME_STEP=0.0333`
and `WE_TEST_DUMP_PASSES=1` reproduces the report and shows it fixed. `nodes.txt`
records `384 page首 visible=1 effective=1` and the perspective pass turns
`visible=1` in both builds, so this is not a hidden layer:

- pre-fix, frames 14 and 30: `g_Point1=[0]` — a one-component value, because no
  timeline was ever registered for a two-component constant, so the layer's own
  `getAnimation('900').play()` found nothing — and `g_Point2=[0.44054, 0.89494]`,
  the static value. The corners never move. `squareToQuad` gives
  `w = [1, 0.333, -0.819, -0.152]`; the two negative terms invert the quad, and
  both the perspective pass and the final composite show a large white spike
  shooting off the top of the screen — the reported 巨大白色尖三角 and the
  content that leaves the frame.
- post-fix: `g_Point1=[0.79139, 0.44186]`/`g_Point2=[0.90044, 0.95983]` while
  paused (`w = [1, 1.025, 1.069, 1.044]`), `[0.524352, 0.390766]`/
  `[0.662799, 0.9263]` mid-fold (`w = [1, 0.977, 0.965, 0.988]`), and the
  authored last key `[0.2746, 0.34298]`/`[0.44054, 0.89494]` at frame 30
  (`w = [1, 0.825, 0.469, 0.644]`). Every sampled pose is a valid quad; the
  spike is gone from the perspective pass and from the final composite, and the
  page renders and folds as a page. Near-white in the final frame drops from
  4.24% to 3.36% mid-fold and 4.14% to 3.00% at the end.

Idle sampling (`WE_TEST_FRAMES=21`, `WE_TEST_FRAME_STEP=1`, cold then warm cache
in one directory plus a separate `WE_TEST_NO_REUSE=1` directory) holds the paused
first key for all 21 seconds instead of running to the last key. The author's
opening zoom is intact: the first sampled frame is still zoomed in at 3× and the
21-second frame is fully zoomed out. `3292361861` has no perspective pass at all
and renders unchanged; its source canvas stays 3840×2160 and no camera, layer or
scaling behaviour was touched.

### Residual defects found here

Both were left for a separate change and are resolved in the next entry above:
the page turn never completed because `options.events` was not read and no
`animationEvent` export was dispatched, and the visible
`workshop/2872021376/effects/perspective` pass on layer 503 `中-菜单-浮动`
reported `g_Point2=[nan,nan,0]` identically before and after this change.

The SceneScript `TypeError` diagnostics were not silenced or worked around; no
wallpaper ID branch, hidden layer or asset edit was used.

## 2026-09-17 — Playback optimization rebased onto web-wallpaper main

Before publishing, remote `main` advanced to `6a7ce92` (the Web wallpaper
implementation and version `0.3.2`). Rebased the playback optimization onto it
without force-pushing or dropping either side's changes. The two textual
conflicts were the verification log and renderer provenance note; both histories
and both modification descriptions were preserved.

Fresh integration verification:

- `cargo test --release -p wallpaper-bridge --lib`: **224 passed**, including
  Web wallpaper host routing and committed pointer-consumer polling behavior.
- `python3 scripts/build.py --renderer-only`: succeeded; generated bridge
  bindings from the integrated static library.
- `python3 scripts/test.py`: Python **35 passed**; native **246 passed,
  0 failed, 0 skipped**, including the windowless Web wallpaper tests and
  lock-screen persistence/monitor regressions.
- Kept XcodeGen's regenerated target ordering; no hand-edit of the project.
  No Release app build, normal application launch or desktop run.

The incoming commits did not change the C++ renderer or core input sources;
the earlier GPU/CPU measurements below were not rerun or relabeled as new
measurements during this publishing rebase.

## 2026-09-17 — Continuous-playback work reduction, synchronized baseline

Source-only implementation on the refactored `986f2e6` workspace. No fetch,
branch change, normal application launch, desktop automation, swapchain test,
screen/audio capture, wallpaper-service reload, administrator sampling or
Release app delivery. The native gate used its normal non-windowed test host.

Implemented the approved GPU, input, lock-screen and scene-CPU paths. Source
review also found a cross-boundary button-latch defect in capability gating:
discarding inactive Rust edges alone could leave native `down` stuck or lose a
held button's later release. A level-only native baseline now reconciles the
geometry-resolved sample before its unchanged transitions, with retry on failure;
pending accepted edges survive. Native pending edges are cleared only on a
successful scene commit involving a non-consumer, not on failed or
interactive-to-interactive commits.

### Commands and correctness results

All Cargo commands used `scripts/build.py::build_environment()`,
`CARGO_NET_OFFLINE=true` and `cwd=upstream/renderer`; CMake used the root working
directory and the existing GoogleTest 1.14.0 cache with FetchContent fully
disconnected. The renderer/scene-engine provenance notes were updated without
changing source pins or licensing boundaries.

- `cargo build --release -p shader --features ffi` and the approved Release
  CMake configuration succeeded. Step 0's production libraries and probes were
  built before optimization; **22 private GPU tests passed**, then separate
  baseline executables/raw samples were preserved.
- Explicitly built all 16 approved targets: `playback_gpu_test`,
  `scene_schema_tests`, `script_runtime_compat_test`, `mdl_schema_tests`,
  `particle_mouse_controlpoint_test`, `mouse_input_test`, `timer_tests`,
  `audio_tests`, `render_target_lifetime_test`, `text_object_runtime_test`,
  `shader_cache_metadata_test`, `offscreen_scene_probe`,
  `scene_reload_cycle_probe`, `vulkan_render_batch_planner_smoke`,
  `video_texture_submission_smoke`, `scenescript_sound_layer_smoke`.
- Final direct runs: GPU **31**, scene schema **62**, MDL **52**, particle mouse
  **38**, mouse input **11**, timers **6**, mono audio **19**, target lifetime
  **4**, shader-cache metadata **1**, video submission **5**, sound layer
  **8** passed. The batch-planner standalone smoke exited **0**.
  `audio_tests` ran only `--gtest_filter=AudioResponseMonoTest.*`.
- `script_runtime_compat_test`: **56 passed, 1 failed**. The unchanged
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors` still references
  undeclared `scriptProperties`; it was run, not excluded. All new script,
  binding, rollback, audio and puppet regressions passed.
- `text_object_runtime_test`: **60 passed, 2 skipped** because the opt-in local
  wallpaper projects were not supplied. No full wallpaper-corpus claim.
- `python3 scripts/check_renderer.py --skip-build`, using the freshly built
  same-tree binaries and existing shared assets: **9 generated GPU cases**
  passed independent known-pixel assertions and pooled/isolated byte equality,
  **0 case diagnostics**; **8 projects × 2 reloads** passed.
- `cargo test --release -p wallpaper-core --lib`: **197 passed**.
  `cargo test --release -p wallpaper-bridge --lib`: **223 passed**.
- `python3 scripts/build.py --renderer-only` succeeded and regenerated the
  Swift bridge from the current static library. This is not a Release app.
- `python3 scripts/test.py`: Python **35 passed**; native **239 passed,
  0 failed, 0 skipped**. Includes isolated lock-screen journal/timer/readiness
  failures and recovery, the real local `nettop`/private-PTY streaming test, and
  CRLF/split-line-ending coverage. Existing public Steam search tests also ran;
  no live login was performed.

Initial validation caught new-fixture mistakes, not hidden by filtering:
unsupported `texture2DLod`, a VMA image-creation failpoint that bypassed device
dispatch, browser-style storage methods, writes to copied JS vector components,
missing parser runtime bootstrap, and named targets reused without graph
retirement before resize. Fixtures were corrected to the real APIs and rebuilt/
rerun. The shared viewport extraction also needed mutable values for vvk's span
interface; the corrected source compiled and passed the final matrix.

### Deterministic work elimination

- Valid pre-clears decreased **2→1** for hidden clear-only output and **1→0**
  for a normal first-clear writer. Reader, alias and boundary cases retain the
  required clear. Direct presentation decreased **2→1 render passes/draws**,
  with **one successful draw submit per frame** in every variant.
- The isolated Rust iterator driver emitted **730,000 ordered transitions**
  over **40,000 iterations**, with **0 allocator requests**.
- An instrumented copy of the actual private pose evaluator checked full affine
  results and control mutations: after one prime, **16 same-State copy lookups
  caused 0 additional solves**. The complete mutation/independent-State matrix
  made **27** actual evaluator calls; no production counter was added.
- Audio initialization allocated **one 1,024-byte scratch buffer** on first
  spectrum discovery. No-audio and repeated/rediscovered initialization allocated
  **0**; **1,080** steady disabled-spectrum callbacks allocated **0**. Fresh
  active-spectrum packing also dropped **12→0 C++ `new` requests per call**.
- Core/bridge tests verify no periodic ask without consumers, independent pause
  policy, successful-input deduplication, bounded relay delivery and activation
  edge semantics. Lock-screen tests verify no off-state timer and no unchanged
  journal rewrite; no production preferences/store were used.

### Fixed-simulation timing samples

CPU: 60 warm frames then **180 samples × 3 interleaved blocks per variant**,
`t=frame/60`, with checked outputs outside timing. Values are aggregate
**median / p95 in microseconds**, baseline → optimized:

| Synthetic workload | Baseline | Optimized | C++ `new` requests |
| --- | ---: | ---: | ---: |
| 64 init-only property programs | 63.333 / 75.000 | 16.917 / 18.375 | 128→0 |
| 64 real update programs | 65.541 / 72.292 | 63.500 / 72.208 | 128→128 |
| 64 absent hover handlers | 97.084 / 108.583 | 0.125 / 0.125 | 0→0 |
| 128 steady TRS/material bindings | 13.125 / 42.750 | 3.666 / 3.750 | 0→0 |
| 128 changed/overwritten destinations | 14.458 / 14.958 | 5.500 / 6.250 | 128→128 |
| 16 copies, 64 bones and attachments | 61.291 / 68.167 | 2.917 / 3.083 | 0→0 |
| FrameBegin plus 16 bone uniform consumers | 66.334 / 72.917 | 8.458 / 8.792 | 16→16 |
| Fresh 16/32/64-bin audio packing | 3.958 / 11.583 | 1.375 / 4.542 | 12→0 |
| Disabled audio packing | 1.688 / 2.125 | 0.500 / 0.959 | 12→0 |
| 128 unlinked particle subsystems | 2.958 / 4.875 | 0.334 / 2.041 | 0→0 |
| 128 linked particle subsystems | 3.166 / 3.542 | 2.833 / 6.250 | 0→0 |

The linked-particle control's block medians were **3.166/3.083/3.417 →
2.833/2.375/5.292 µs**: one block regressed while two improved, so no speedup is
claimed for that path. The required-update script control is also within small
timing variation. Allocation counts cover intercepted current-thread C++ `new`,
not QuickJS/Eigen `malloc`, worker threads or whole-process memory.

GPU: **3840×2160**, **180 frames/block**, three reversed-order baseline/optimized
pairs, each with three rotating blocks (**1,620 samples per variant**).
Vulkan timestamps reported **64 valid bits, 1 ns period**. Aggregate
**median / p95 in microseconds**, baseline → optimized:

| Path | CPU recording | Submit + wait | GPU timestamp elapsed |
| --- | --- | --- | --- |
| Hidden clear-only | 2.667 / 11.375 → 2.291 / 8.333 | 694.438 / 1996.250 → 600.021 / 1439.166 | 207.937 / 1323.583 → 166.542 / 676.375 |
| Normal + final copy | 2.667 / 8.416 → 2.250 / 7.334 | 716.625 / 1964.584 → 596.167 / 1586.792 | 237.354 / 1302.584 → 167.104 / 750.792 |
| Multi-writer fallback | 3.875 / 12.333 → 2.750 / 8.792 | 824.542 / 2348.917 → 654.979 / 1615.750 | 280.687 / 1646.542 → 207.021 / 812.166 |
| Direct versus its normal reference | 2.667 / 8.416 → 1.417 / 4.583 | 716.625 / 1964.584 → 493.145 / 1242.792 | 237.354 / 1302.584 → 73.105 / 505.791 |

Raw samples, each block's median/p95/min/max, command traces, build manifests
and comparison order were preserved in the session's raw-evidence archive before
repository byproduct cleanup. The benchmark executables were kept separate
through measurement. GPU timing remains noisy; some CPU recording rounds were
slower despite the removed work. These uncapped fixed-simulation samples do not
measure real 60 fps playback, watts, GPU residency or battery life.

### Remaining boundaries

Actual Vulkan layer enumeration returned **no layers**, so synchronization
validation was unavailable and not installed. Disposable command traces checked
real RAW/WAR ordering, stage/access scopes and mip ranges; pixel equality alone
was not treated as synchronization proof. Invalid feedback cases were recorded
and discarded rather than submitted as undefined GPU work.

Independent failure injection for FinPass's second vertex allocation, each
individual immediate CPU staging write, and framebuffer-cache `std::bad_alloc`
was not available through the permitted device-dispatch seam. Their return/
ownership checks are source-reviewed; real pending-storage, image-view,
descriptor/pipeline/framebuffer, submit/wait/reset and device-failure scenarios
were exercised where the existing fixture exposes them. Actual AppKit
acquire/present, poster output, Spaces, renderer first-ready failure suppression
through a real swapchain, desktop visuals, live audio and real power remain
unverified. No normal application was quit, reopened or installed.

Cleanup: after confirming no peers were running and preserving the raw archive,
`python3 scripts/clean.py --dry-run` followed by `python3 scripts/clean.py`
removed **1.78 GB** of disposable artifacts/old test results and temporary
drivers. Built app products and current renderer/bridge outputs were retained.
The relative `CLAUDE.md → AGENTS.md` symlink, 20 local documentation links and
unchanged vendored source revisions were checked.


## 2026-09-17 — Web wallpapers receive mouse input; desktop-click setting

Workshop 3799142774 (*Rhine Lab · 莱茵生命交互桌面 | Interactive Desktop*) rendered
but ignored the mouse. `WebWallpaperMouseForwarder` now mirrors desktop pointer
events into the page from a global `NSEvent` monitor (nothing consumed, no
permission prompt); `WebWallpaperWindow` reports `isKeyWindow` so WebKit
hit-tests hover; the host script cancels `contextmenu` defaults. Settings ›
General gained *Keep windows in place when clicking the wallpaper*, which writes
`com.apple.WindowManager EnableStandardClickToShowDesktop`
(`DesktopClickRevealPreference`). See
[features/web-wallpapers.md](../features/web-wallpapers.md).

Verified:

- `python3 scripts/test.py`: Python script tests passed; `xcodegen generate`;
  `MacWallpaperEngineTests` **232 passed**, 0 failed, 0 skipped (~90 s). New
  `WebWallpaperMouseRoutingTests` (desktop-only routing, press/drag/release
  continuity per button, single hover exit, cross-display exit) and
  `WebWallpaperPageTests.testForwardedPointerEventsReachThePageWithoutANativeContextMenu`
  (windowless `WKWebView`: forwarded left click at CSS (100,100) and right click
  reach page listeners in order; `contextmenu` arrives default-prevented).
- Throwaway probe binaries (deleted after the run) against a `WKWebView` in a
  desktop-level, mouse-transparent window: `NSEvent.mouseEvent` replays produce
  `mousedown`/`mouseup`/`click`/drag `mousemove` at the expected CSS point;
  hover only reaches JS through `_simulateMouseMove:` and only while the window
  reports `isKeyWindow` (plain `mouseMoved(with:)` is dropped by `WKWebView`,
  and WebKit routes inactive-window moves to scrollbars only); `:hover` matches
  in standards mode; `_simulateMouseExit:` fires `mouseout`; a copied scroll
  `CGEvent` located at (x, primary height − y) converts to the wallpaper-local
  point and fires `wheel` at the correct coordinates. `NSWindow.windowNumber(at:)`
  plus `CGWindowListCopyWindowInfo(.optionIncludingWindow, id)` classified an
  application window (layer 0) and listed Finder's desktop at layer
  −2147483603 (`CGWindowListCreateDescriptionFromArray` returned nothing on this
  build, hence the `optionIncludingWindow` lookup).
- Not verified: the running app on the desktop (global monitor delivery, hover
  over the real Finder desktop, multi-display coordinates) and whether
  WindowManager applies `EnableStandardClickToShowDesktop` without a re-login
  on this build; no desktop run was authorized and the preference was not
  written during development.
- `python3 scripts/build.py --swift-only --configuration Release`: BUILD
  SUCCEEDED; delivered `build/Build/Products/Release/MacWallpaperEngine.app`
  with the changes above (existing renderer/bindings reused).

## 2026-09-16 — Web wallpapers render in a host WKWebView

`type: "web"` projects (e.g. Workshop 3799142774, *Rhine Lab · 莱茵生命交互桌面*)
were library-only. The bridge now marks them supported, keeps them out of
engine reconciliation and exposes `web_wallpapers()`; Swift hosts one
desktop-level `WKWebView` window per display (`App/Services/WebWallpaper/`),
pushes `applyUserProperties`/`applyGeneralProperties`/`setPaused`, joins the
presentation policy and answers Space-poster requests with page snapshots.
See [features/web-wallpapers.md](../features/web-wallpapers.md).

Verified:

- `cargo test -p wallpaper-bridge --release --lib` (build env from
  `scripts/build.py`): **215 passed**, 0 failed, including the new
  `web_wallpaper_apply_bypasses_engine_and_exports_host_inputs` (no engine
  scene, active id, lock screen empty, properties payload, pause, eject).
- `python3 scripts/build.py --renderer-only` regenerated `App/Bridge/Generated`
  with `webWallpapers()` / `BridgeWebWallpaper`.
- `python3 scripts/test.py`: Python script tests passed; `xcodegen generate`;
  `MacWallpaperEngineTests` **227 passed**, 0 failed, 0 skipped (~90 s). New
  `WebWallpaperPageTests` load a synthetic project offscreen: ES module from the
  project folder, late-listener replay of properties/fps/pause, presentation
  suspension composed with user pause, top-frame navigation lockdown, no window.
- Throwaway offscreen smoke (deleted after the run) against a local copy of the
  Rhine Lab GitHub release: page loaded from `file:`, 74 user properties
  delivered, fps 30, app mounted 21 nodes into `#stage`, snapshot 3456×2234 with
  99.5 % lit pixels showing the wallpaper's opening screen.
- Not verified: desktop windows, Space posters, multi-display and
  presentation-policy behavior in the running app (no desktop run authorized);
  no Release build was requested.

## 2026-09-16 — Panel selects share button metrics

The Discover sort select (and every other `select` in `panel.css`) kept
WebKit's native `menulist` appearance, so macOS painted its own pop-up
button inside the padded, bordered 30 px box — a shorter control-in-a-box
beside the `Search` and refresh buttons. `select` now uses `appearance:
none` with an inline SVG chevron and a hover border, matching the button
height and edges. CSS-only; `settings.css` is untouched.

Verified:

- `.agents/skills/impeccable/scripts/impeccable detect --json WebUI/panel.css` → no findings.
- `python3 scripts/test.py` → 225 tests, 0 failures.
- Not verified: visual render in the running panel (no desktop run authorized).

## 2026-09-16 — Discover grid fills full Workshop pages

Discover used the shared `auto-fill` tile grid, so a 30-item Workshop page
left a partial last row (e.g. 7 columns → 4 full rows + 2 tiles) and a
visible void beside the pagination bar. `.browser-column` is now an
inline-size container and `.discover .wallpaper-grid` picks a column
count that divides 30 (2 / 3 / 5 / 6 / 10) by container width, keeping
the 154 px minimum tile; the Installed grid is unchanged.

Verified:

- `python3 scripts/test.py`: Python script tests **24** and **10** passed;
  `xcodegen generate`; `MacWallpaperEngineTests` **225 passed**, 0 failed,
  0 skipped (~90 s).
- `impeccable detect --json WebUI/panel.css`: no findings.
- No renderer or bridge changes; `python3 scripts/check_renderer.py` not run.
- Not visually verified in the running app (no desktop run authorized);
  breakpoints derived from tile minimum, 12 px gap and 16 px grid padding.
## 2026-09-16 — Cursor mapping rebased onto the coverage-mask work

`fix(scene): map cursor input through the presented wallpaper` was rebased onto
`2385923` (script side-effect writes, puppet animation layers, cursor coverage).
Conflicts resolved by hand: `CursorHitsLayer` now runs the content check before
the incoming hit-mask lookup, and both `provenance.json` notes and both
`renderer.md` coverage rows were kept.

Re-verified on the merged tree:

- `mouse_input_test` **9**, `script_runtime_compat_test` **39 passed, 1 failed**
  (the pre-existing `HostVectorUpdates…`), `scene_schema_tests` **53**,
  `scenescript_sound_layer_smoke` **8**, `particle_mouse_controlpoint_test`
  **35**, `text_object_runtime_test` **60 passed, 2 skipped**.
- `python3 scripts/test.py`: native **225 passed**, 0 failed, 0 skipped.
- `python3 scripts/check_renderer.py` (full): **9 generated GPU cases** passed
  known-pixel assertions and pooled/isolated byte comparisons; **8 projects × 2
  reloads** passed; the three test binaries exited 0.
- `python3 scripts/build.py --configuration Release` rebuilt
  `build/Build/Products/Release/MacWallpaperEngine.app` from the merged tree;
  the binary exports both this change's cursor symbols and the merged
  `PuppetAnimationControl`. The app was not launched or quit.

## 2026-09-16 — Cursor hit testing follows the presented wallpaper

Renderer source and native checks only; no desktop input, capture or delivery.

Problem: `SceneRuntimeContext::SetCursorInput` mapped the window-normalized
cursor onto the raw scene canvas. The wallpaper is presented through the global
camera rectangle and `ComputeWallpaperScalingLayout`, which `FILL` pushes
outside the window to crop, so on any scene whose aspect differs from the
display every `cursorEnter`/`cursorLeave` box was squeezed toward the screen
centre. Hovering the middle of a text layer enlarged it; hovering the same text
a few centimetres left or right did nothing.

Changes:

- `ComputeWallpaperCursorMapping` inverts the presentation transform
  (window pixel → viewport fraction → camera world coordinate) and reports the
  drawn content rectangle alongside the window rectangle.
- `VulkanRender::CursorMapping` computes it from the current output extent,
  scaling mode/factor and the global camera; `SceneWallpaper` pushes it into
  `SceneRuntimeContext::SetCursorViewport` before each frame's cursor dispatch.
  Without a valid mapping the runtime keeps the canvas rectangle.
- Named layers only take cursor events while the cursor is inside the drawn
  content. Coordinates still extrapolate past it, but letterbox bars no longer
  reach layers whose box crosses the canvas edge.
- `scripts/check_renderer.py` runs Cargo from `upstream/renderer` so rustup
  resolves that tree's `rust-toolchain.toml`; `scripts/build.py` already did.
- `scenescript_sound_layer_smoke` now links `nlohmann_json`; it did not compile.

Results:

- A disposable CPU-only probe parsed the selected local 7680×2160 package and
  walked the cursor across the **visible** width of its weekday text, using the
  configuration its own run log records (`output_px=4112x2658`,
  `display_scale=2.000`, scaling mode `fill`, factor `1.000`). Before: **4 of
  11** samples enlarged the layer, which is drawn across 0.4561–0.5503 of the
  window width. After: **11 of 11**, the date layer likewise, zero script
  errors. The probe was removed.
- `mouse_input_test` **9 passed**, including three new cases.
  `LayerHitTestingFollowsWhereTheWallpaperIsPresented` fails without the
  viewport mapping; `LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge`
  fails without the content check (verified by disabling each in turn).
- `script_runtime_compat_test` **35 passed, 1 failed**. The new
  `HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper` drives the
  existing synthetic hover script through `SetCursorInput` at the recorded
  display configuration and fails without the mapping. The failure is the
  pre-existing `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
  recorded in `renderer.md`.
- `scene_schema_tests` **51**, `scenescript_sound_layer_smoke` **8**,
  `particle_mouse_controlpoint_test` **35**, `text_object_runtime_test`
  **60 passed, 2 local-asset cases skipped**.
- `python3 scripts/check_renderer.py` (full, including the Cargo build): all
  **9 generated GPU cases** passed known-pixel assertions and exact
  pooled/isolated comparisons with no diagnostics; **8 projects × 2 reloads**
  passed; lifetime, text and shader-cache binaries exited 0.
- `python3 scripts/test.py`: Python **24** and **10** passed; native
  **225 passed**, 0 failed, 0 skipped.
- `python3 scripts/build.py --configuration Release` succeeded and refreshed
  `build/Build/Products/Release/MacWallpaperEngine.app`. The delivered binary
  exports `ComputeWallpaperCursorMapping`,
  `SceneRuntimeContext::SetCursorViewport`,
  `SceneRuntimeContext::CursorInsidePresentedContent` and
  `VulkanRender::CursorMapping`, so it contains this change. The app was not
  launched or quit.

Toolchain note: before the `cwd` fix the checker's Cargo step ran from the
repository root and picked the default stable toolchain, which fails with
`E0463`. On this machine stable **rustc 1.97.0** and **1.84.1** emit proc-macro
dylibs that dyld on macOS 27.0 refuses to load (`mis-aligned LINKEDIT string
pool`); a minimal throwaway proc-macro crate reproduced it outside the
repository, under the project build environment and a plain one, and with
`-ld_classic` and `strip=debuginfo`. The pinned nightly toolchain produced a
loadable dylib. `scripts/build.py` already ran Cargo from `upstream/renderer`,
so the application build path was never affected by this, and the Release build
above confirms it.

Not verified: real cursor capture, rendered pixels, multi-display or mirrored
layouts, non-default scaling modes on a real display, and the lock-screen
extension. No desktop automation, wallpaper change or app launch was performed;
the delivered bundle was checked by symbol inspection, not by running it.

## 2026-09-16 — Restore Settings → About update controls

The WebKit control panel still held `AppUpdateStore` and the application
menu still had **Check for Updates…**, but Settings → About never drew
the updater after the native SwiftUI settings were removed. The About
page now shows check / download / restart-install, and the menu item
opens that section.

Verified:

- `python3 scripts/test.py`: Python script tests **24** and **10**
  passed; `xcodegen generate`; `MacWallpaperEngineTests` **225 passed**,
  0 failed, 0 skipped (~95 s of test execution). New coverage:
  `testUpdateSnapshotExposesCheckDownloadAndReadyActions` and
  `testAboutUpdateControlsCheckDownloadAndBlockInstallWithoutWindow`
  (offscreen `WKWebView`; fake GitHub client; install confirmation
  refused without a window).
- No renderer or bridge changes; `python3 scripts/check_renderer.py`
  was not run.

Not verified: live GitHub Releases, archive extraction, replacement of
an app in Applications, or visual layout of the About page in a real
window. No desktop automation, wallpaper change, or Release delivery
was performed.
## 2026-09-16 — Script side-effect writes, puppet animation layers, cursor coverage

"流萤 夏日沙滩" (`3292361861`, the wallpaper applied on this machine) reported
three defects. All three were scene-engine bugs, none package-specific:

1. **Viewing mode + "无遮" hid the character.** The layer is authored
   `visible: false` and driven by the workshop "video texture controls" script
   (`thisLayer.visible = false` in `init()`, `thisLayer.visible = alpha != 0`
   in `update()`, no return value). `ScriptedDynamicValue` only overrode
   `update(const DynamicValue&)`, so the typed `update(bool)` that
   `SetNodeVisible` calls never reached its base value; the next
   `Evaluate` fed the stale `false` back in and reverted the write every tick.
   Resolved by the concurrent "persist state across frames" change (entry
   above), which evaluates from the live dynamic value; this entry's
   regression test covers the visibility case on that implementation.
2. **Double-click on the character did nothing.** `getAnimationLayer(name)` was
   a JavaScript stub whose `play()` was empty. `WPPuppetLayer` copies now share
   one playback state, the parser registers it with the runtime, and the shim is
   backed by `SceneRuntimeContext::PuppetAnimationControl` (play/pause/stop,
   frame, rate, blend, visible, isPlaying). Single-shot layers hold their last
   frame and report stopped so `play()` restarts them. The same path binds
   `animationlayers[].visible/rate/blend` to user properties, which this
   package uses to switch the "健全/无遮" idle animations in interactive mode.
3. **Both triangle buttons fired on one click.** The two buttons are
   interlocking triangles whose bounding boxes overlap by roughly half; the hit
   test was a world-space AABB. It now runs in the layer's local plane and, for
   image layers whose scripts handle cursor events, consults a coverage mask
   sampled from the albedo alpha at parse time (RGBA8/BC2/BC3, ≤256 px/side).

Verified:

- `offscreen_scene_probe` on `3292361861`, `WE_TEST_PROPERTIES` for all four
  mode/outfit combinations. Before: viewing + 无遮 rendered no character and
  `nodes.txt` had `293 … visible=0 effective=0`. After: `visible=1 effective=1`
  and the frame shows the character; interactive frames now differ between the
  two outfit values (**9576** sampled pixels vs **7** before), i.e. the bound
  animation layers switch. Diagnostics are the pre-existing set (media-player
  scripts, `clipping_mask` shader, `MediaPlaybackEvent`); nothing new.
- `offscreen_scene_probe` clicks with the new `WE_TEST_CLICK_OFFSET`: clicking
  `468` at `+150 0` (inside its rectangle, in its transparent half, over the
  other triangle) leaves `interactiveLayer1 visible=1`; clicking it at `0 -60`
  (covered texels) switches to `viewingLayer1 visible=1`. Two clicks on `232`
  raise no cursor script errors.
- `script_runtime_compat_test`: **36 tests, 35 passed**; the four new
  regressions `UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined`,
  `PuppetAnimationLayerPlayRestartsFinishedSingleShotForAllCopies`,
  `PuppetAnimationLayerVisibilityFollowsUserProperty` and
  `CursorHitTestRespectsCoverageMask` pass. The first was confirmed failing
  (`visible=0` on every tick) against the pre-fix engine through a throwaway
  harness. The one failure is the documented pre-existing
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`.
- `mdl_schema_tests` **45 passed**, `scene_schema_tests` **53 passed**,
  `mouse_input_test` **6 passed** after the `WPPuppetLayer` blend refactor.
- `python3 scripts/check_renderer.py --project …/3292361861/project.json`: the
  three test binaries pass, all nine generated cases pooled/isolated equal with
  0 diagnostics and pixel assertions met, reload cycles 0. The `3292361861`
  case reports `pixels_equal=false`; two consecutive pooled runs of that scene
  also differ (wall-clock text and randomised script delays), so the mismatch
  is inherent to the package, not the change.
- `python3 scripts/test.py`: Python script tests, `xcodegen generate`, then
  **223 native tests passed, 0 failed, 0 skipped**.

Not verified: no desktop run, no live mouse input, no Release build. The
delivered app still carries the old renderer until
`python3 scripts/build.py --configuration Release` is run. The `clipping_mask`
shader failure (`!float` in the translated vertex shader) is pre-existing and
only affects effects this package leaves disabled.

## 2026-09-16 — Hidden-by-default visibility scripts and lost alignment anchors

"On the way" (`3798819887`) rendered nothing but `general.clearcolor`
(`0.7 0.7 0.7`, the reported plain grey). Three scene-engine defects, none
specific to that package:

1. `WPSceneParser` dropped *every* dynamic binding — `visible`, `origin`,
   `scale`, `angles`, queued scene scripts — of a layer whose `visible` setting
   combined a `script` with a falsy `value`. The authored value is the script's
   initial value, not a licence to run it, so the three weather layers stayed at
   their authored `false`/`false`/`true` and the day layer could never appear.
   The gate and the `allow_script_update` parameter it fed through
   `ResolveBoolSetting`/`ResolveVec3Setting`/`ResolveStringSetting` are gone.
2. Image-layer alignment was baked into the node translate by `LoadAlignment`,
   so the first tick of a scripted origin overwrote it and the layer rendered
   half a canvas off. `SceneRuntimeContext` now owns the anchor for image layers
   (`SetNodeAnchorAlignment`, renamed from `SetNodeTextAlignment`) and
   re-derives `origin + size * scale * 0.5`; center alignment keeps the old
   direct path.
3. `RegisterNode` re-seeded the anchor origin from `node->Translate()` on every
   call, and `RegisterNodeVisibility`/`Translate`/`Scale`/`Rotation` each call it
   again for the same node. Once an anchor is registered that translate already
   holds the offset, so the next `ApplyNodeTransform` added a second one. It now
   re-seeds only when the bound node changes or no anchor exists, and
   `SetNodeAlignment` no longer forces `size_anchor = false` on an anchored node.
   This also fixes pre-existing double-counting on *text* layers, whose anchor is
   registered before their translate/scale bindings.

Verified:

- `offscreen_scene_probe` on `3798819887`: before, `nodes.txt` reported
  `TramDay/TramRain/TramNight` all `visible=0 effective=0` and `frame-2.ppm`
  sampled **1 distinct colour** (`178,178,178`). After, `TramDay` is
  `visible=1 effective=1 translate=1280 540`, the frame has **0 fully grey rows**
  and **2719 distinct sampled colours**, and the PNG shows the authored tram,
  rice fields and sky.
- `scene_schema_tests`: **53 tests passed**, including the two new regressions
  `HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin` and
  `ImageAlignmentAnchorSurvivesScriptedOriginAndScale`. Both fail against the
  pre-fix engine with the expected values (origin `0` instead of `30`, anchor
  `y=0` instead of `16`, `x=42` instead of `74`). The anchor test also covers a
  static origin with a scripted scale, which fails with `90` instead of `26`
  when `RegisterNode` re-seeds the anchor.
- Local corpus A/B, **21 scene wallpapers**, run in a detached worktree at
  `HEAD` so concurrent edits in the main tree could not leak into either arm;
  both arms carry the same probe, so only the engine change differs.
  `nodes.txt` (visibility, translate, scale) differs in **4 of 21** scenes:
  `3798819887` gains its visible day layer and its anchor; `2887099508` and
  `3292361861` restore anchors on menu/overlay layers and finally run the origin
  scripts of previously frozen click-activated panels; `3799253558` moves two
  media-info text layers back onto their authored anchor (`259` → `154.5` and
  `235.85` → `142.925`, each exactly one half-width of double count). No
  previously hidden layer became visible. Frame hashes differ for **7** scenes,
  **six** of which are the known wall-clock/RNG scenes (three distinct hashes
  across three runs of one binary); the only time-independent frame change is
  `3798819887`. `3292361861`'s `Audio Bars` now lands on
  `-155.18878 + 512 × 0.45 / 2 = -39.9888` instead of the double-counted
  `88.0112`.
- `python3 scripts/check_renderer.py`: 9 generated cases pooled vs isolated
  **pixel-equal**, known-pixel assertions passed, **0 diagnostics**,
  `render_target_lifetime_test`/`text_object_runtime_test`/
  `shader_cache_metadata_test` and the reload cycles all exit `0`. Re-run with
  `--project .../3798819887/project.json`: pixel-equal, **0 diagnostics**,
  reload cycles `0`.
- C++ binaries: `scene_schema_tests` 53, `mdl_schema_tests` 45,
  `script_runtime_compat_test` 32 passed with only the documented pre-existing
  `HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors` failure,
  `render_target_lifetime_test` 4, `shader_cache_metadata_test` 1,
  `audio_tests` 38, `mouse_input_test` 6,
  `particle_mouse_controlpoint_test` 35, `timer_tests` 6.
- `python3 scripts/test.py`: Python script tests, `xcodegen generate`, then
  **223 native tests passed, 0 failed, 0 skipped** in **99 s**.
- `offscreen_scene_probe` now requests the production device extensions
  (`VK_EXT_metal_objects`), so scene video textures import headlessly instead of
  logging `failed to import initial video frame`. That alone removed pre-existing
  probe-only diagnostics from `3147346398`, `3292361861`, `3800572533` and
  `3801438494` without touching the engine.

The renderer checks, the C++ binaries and the corpus A/B above were all run in a
detached `HEAD` worktree carrying only this change, so concurrent edits in the
main tree could not leak into either arm. Another agent was editing
`SceneRuntimeContext`, `ScriptedDynamicValue`, `WPPuppet`, `WPImageObject`,
`ScriptEngine` and `WPSceneParser` throughout; their work is preserved (this
change to `SceneRuntimeContext.cpp` was re-applied by hand after a stash
collision). Once the main tree compiled again it was re-verified on the merged
sources: `scene_schema_tests` 53, `mdl_schema_tests` 45,
`script_runtime_compat_test` 32 with only the documented pre-existing failure,
`render_target_lifetime_test` 4, `shader_cache_metadata_test` 1, `audio_tests`
38, `mouse_input_test` 6, `particle_mouse_controlpoint_test` 35, `timer_tests`
6; `scripts/check_renderer.py --skip-build` pixel-equal on all 9 cases with
**0 diagnostics** and reload cycles `0`; and `3798819887` still reports
`TramDay visible=1 effective=1 translate=1280 540`.

Not verified: on-desktop presentation. No Release build, no app launch, no
wallpaper change and no screenshot. Pre-existing gaps observed while building the
vendored tests, untouched: `tex_schema_tests` fails to compile (`lz4.h` not on
its include path) and `scenescript_sound_layer_smoke`,
`scenescript_media_event_smoke`, `media_thumbnail_texture_smoke` and
`rendergraph_smoke` do not link `nlohmann_json`, so none of them build here;
`scripts/check_renderer.py` does not build them either. Removing the visibility
gate also exposes an unimplemented `thisLayer.getParent()` in `3292361861`
(**23** `cannot read property 'multiply' of undefined` update errors per run,
alongside the **17** `init` failures that scene already logged); that layer keeps
its authored value, so its rendered output is unchanged.

## 2026-09-16 — Build stamp resolves the repository, not the pinned renderer

`scripts/build.py` computed `GIT_SHORT_COMMIT` with the working directory set to
`upstream/renderer`. That directory carries its own Git checkout at the pinned
vendored revision, so the stamp was frozen at the upstream revision on any
machine where that checkout exists, and Settings reported it as `Git revision`.
The stamp is now resolved with `git -C <repository root>` through a new
`repository_commit()` helper; the renderer layout and vendored sources were left
unchanged.

Verified:

- Reproduction in the linked artifact: `strings` on the previously built
  `upstream/renderer/target/release/libwallpaper_bridge.a` matched the pinned
  revision `8c19c00` **5 times** and the repository HEAD `2916c00` **0 times**.
  `shadow_rs` resolved the same checkout for its `SHORT_COMMIT` fallback
  (`8c19c002`).
- `python3 scripts/tests/test_build.py`: **1 test passed**. It builds a
  throwaway repository containing a second checkout at `upstream/renderer` and
  asserts the outer commit is reported; the previous working-directory
  behaviour returns the nested commit and fails it.
- `python3 scripts/test.py`: Python script tests, `xcodegen generate`, then
  **223 native tests passed, 0 failed, 0 skipped** in **94 s**.
- `python3 scripts/build.py --renderer-only`: only `wallpaper-bridge`
  recompiled (**6.38 s**), because cargo records `# env-dep:GIT_SHORT_COMMIT`
  from `option_env!` and invalidates just that crate. The rebuilt static library
  now contains `2916c00`, and `uniffi-bindgen` regenerated
  `App/Bridge/Generated` with no diff.

Not verified: the on-screen Settings `Git revision` row. No app build beyond the
Debug test run, no Release build, no app launch and no desktop automation. The
vendored `shadow_rs` fallback still resolves the pinned checkout, so a bare
`cargo build` outside `scripts/build.py` continues to stamp `8c19c002`; the
vendored crates were deliberately not modified.

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
