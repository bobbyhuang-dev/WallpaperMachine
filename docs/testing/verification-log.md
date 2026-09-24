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

## 2026-09-22 — Current Release built and old build residue cleared

- Requested build and cleanup. Prebuild gate: python3 scripts/test.py: 142 Python tests passed; 563 native passed, 0 failed, 11 skipped of 574. No desktop UI, network or media opt-ins enabled.
- Build: python3 scripts/build.py --swift-only --configuration Release: exit 0; reused the existing renderer archive and generated bindings. Delivered build/Build/Products/Release/WallpaperMachine.app, version 0.5.0 (16).
- Bundle identity: all 15 WebUI source files, including property-label.js, match Contents/Resources/WebUI byte-for-byte via diff -rq. Sorted relative-path/file-digest manifest SHA-256: a4afba8dc4ef327abbb53118a2f5658861aa82ccd7f66dbe4c4bf88abd49d2bc.
- Compiled Chinese localization verified with plutil: the normal no-update message is 暂无可用更新，可继续使用当前版本。 The Release now includes the updater feedback correction and integrated remote UI/property-label changes.
- Cleanup previewed with scripts/clean.py --dry-run and --derived --dry-run. python3 scripts/clean.py --derived removed old artifacts, Python caches and Xcode module/index/compilation/SDK/log caches; script reported 1.38 GB reclaimed.
- Also removed the inspected build/Build/Intermediates.noindex compiler tree (308168 KiB by du before deletion) and obsolete MacWallpaperEngine_macosx27.0-arm64.xctestrun. Combined cleanup approximately 1.7 GB; accounting is logical/script-estimated size, not a filesystem free-space benchmark.
- Kept build/Build/Products/Release and Debug, the renderer release outputs and generated bindings. Did not use --all, --user-assets or --managed-user-assets; wallpapers, managed imports, settings and unrelated source/document work were not cleanup targets.
- After cleanup: python3 -B scripts/clean.py --derived --dry-run reported Nothing to remove; WebUI diff and codesign --verify --deep --strict both exited 0. Release executable SHA-256 stayed 5b98ef7bb3de794d47df2aa0bd3edf2e9dd2daaeb123e2ffa45046cf338e16b0.
- No package/install step, application launch/quit/restart or desktop control performed. User must quit the old running copy and reopen the delivered Release. Actual desktop presentation and power remain unverified.

## 2026-09-22 — Safe integration of remote UI and property-label changes

- Push of local commit 2dd31b0 was rejected because origin/main advanced from 80f191b to 30e2ac7. Fetched the remote and rebased without force-pushing or dropping the upstream commit.
- Merged upstream PropertyImageCache, inert rich-label rendering and allowlisted image routes, independent inspector scrolling/fixed footer, settings navigation/disclosures and branding work with local macOS-oriented styling, accessible Modified flags, recovery/focus fixes and noRelease updater handling.
- Pre-integration full gate on the local change: python3 scripts/test.py: 141 Python passed; 557 native passed, 0 failed, 11 skipped. That result predates the fetched upstream changes; integration coverage below is scoped to affected domains.
- Integrated native regression run: python3 scripts/test.py --only AppUpdateTests --only ControlPanelShellTests --only ControlPanelLibraryTests --only ControlPanelDiscoverTests --only ControlPanelSyncTests --only ControlPanelWindowSizingTests --only PropertyImageCacheTests --only WebPanelAssetsTests --only WebPanelPerformanceSettingsTests --only WebPanelSceneSettingsTests --only WebPanelAssetPropertiesTests --only WebPanelPropertyLabelTests --only WebPanelDeliveryStatusTests: 106 passed, 0 failed, 0 skipped.
- Incoming script changes/catalog integration: python3 scripts/tests/test_brand.py and python3 scripts/tests/test_panel_localization.py: 5 passed each.
- After final merged-label wrapping and popup-menu spacing adjustments: python3 scripts/test.py --only ControlPanelShellTests --only WebPanelPropertyLabelTests --only AppUpdateTests: 44 passed, 0 failed, 0 skipped.
- Isolated source UI: 760x560 and 960x640 retained three columns, one activation control, safe author presentation without author controls/scripts, separate localized Modified flags, non-overlapping fixed editor footer, Advanced disclosure and no-release Check Again. Final 760px menu padding is 26px; Modified wraps without splitting Movement.
- Verification histories from both branches preserved, exact duplicates removed and ten active entries retained. Only existing recorded sections were reconciled; this record is appended through log_verification.py. The unrelated untracked power-regression document is retained outside this commit.
- No live GitHub update probe, author-image CDN traffic, real Steam, desktop control, app restart or Release build. Integration preview tab/service released; current desktop presentation and power remain unverified.

## 2026-09-22 — Integrated settings and inspector commit with remote main

- Rebased the approved UI, branding and property image changes onto origin/main, preserving remote release-note UI and authored property compatibility changes. Resolved the settings CSS overlap by retaining readable disclosure text and the release-note rules; preserved both verification histories.
- python3 scripts/test.py passed on the integrated tree: 142 Python tests; 550 native passed, 0 failed, 11 opt-in skipped of 561.
- No new renderer changes authored during integration. No Release rebuild, installation, app launch, restart, screenshots or desktop changes as part of commit and push. The earlier built app predates this remote integration.

## 2026-09-22 — Normal no-release update feedback before commit

- Fixed missing latest-release handling: fetchLatestRelease returns an optional result; a GitHub latest-release 404 is normal only after the repository endpoint returns successful valid metadata. Inaccessible repositories, failed lookups and malformed metadata remain failures.
- State/presentation: noRelease uses neutral localized feedback and Check Again without manual-install recovery. Existing equal/older latest releases remain upToDate. No normal absence is represented as an update error, and no transport/configuration error is relabeled as upToDate.
- Regression baseline: python3 scripts/test.py --only AppUpdateTests: 22 passed, 2 failed of 24, reproducing the missing-release error state and incorrect classification of the repository-lookup failure.
- Targeted after fix: python3 scripts/test.py --only AppUpdateTests --only ControlPanelShellTests: 41 passed, 0 failed, 0 skipped. Real URLSession requests use per-fixture URLProtocol responses; no GitHub connection. About is exercised through offscreen WKWebView, including checking again after an empty result.
- Final gate once: python3 scripts/test.py: 141 Python tests passed; 557 native passed, 0 failed, 11 skipped of 568. No desktop UI, network or media opt-ins enabled.
- Isolated source-UI smoke: English and Simplified Chinese no-release, up-to-date and network-error states rendered with real WebUI modules; actual Check Again click and accessibility snapshot verified. Normal states show only Check Again; failures retain Retry and Open GitHub Releases.
- SourceKit reported no references/definitions for known updater symbols despite a ready server; reported to tool QA, used scoped source discovery, migrated every conformer and relied on the full compiler/test gate.
- Cleanup/limits: updater preview tab and task-owned localhost service released; temporary message fixture removed. Native action/payload shapes, download validation and install confirmation unchanged. No Release rebuild for this fix; the previously delivered app still contains the earlier updater behavior.

## 2026-09-22 — Release rebuilt with macOS and Wallpaper Engine UI blend

- Requested delivery build; production changes are WebUI presentation with existing renderer/bindings. Confirmed cached libwallpaper_bridge.a and all generated Swift/FFI binding files exist.
- Prebuild gate: python3 scripts/test.py: 141 Python tests passed; 553 native passed, 0 failed, 11 skipped. No --ui, network or media opt-ins enabled.
- Build: python3 scripts/build.py --swift-only --configuration Release: exit 0. Delivered build/Build/Products/Release/WallpaperMachine.app, version 0.5.0 (16).
- Bundle verification: diff -rq WebUI build/Build/Products/Release/WallpaperMachine.app/Contents/Resources/WebUI: exit 0; all 14 current source files, including any untracked files, match the bundle byte-for-byte.
- WebUI identity: SHA-256 of the sorted relative-path/file-digest manifest is 60d34fccb1a33e37a35c3572070c686fd8bfef383cd8b52c5de2a2e9420d6696; no mismatches. Identity was computed from actual filesystem contents, not only Git revision/diff.
- Signing: codesign --verify --deep --strict build/Build/Products/Release/WallpaperMachine.app: exit 0.
- No packaging/install step and no application launch, quit or restart performed. User must quit the running copy and reopen the delivered app to load the changes.
- Limits: this proves the Release build and bundled source identity, not actual desktop presentation, live Steam, wallpaper rendering or power consumption.

## 2026-09-22 — Wallpaper Engine workflow with macOS visual treatment

- Direction: Wallpaper Engine image-first gallery/filter/inspector structure with macOS-oriented system typography, neutral selected navigation, restrained accent use, grouped settings and setup-assistant surfaces. Not a Windows window/control skin.
- Implementation: existing panel/settings/welcome CSS updated; presentation-only JS adjusts anchor-aware popover sizing, real DOM order for trailing default dialog actions, and secondary styling for already-installed resource re-download. Native action names, payloads, persistence, theme contrast algorithm and existing state/security fixes unchanged.
- Initial targeted iteration: python3 scripts/test.py --only ControlPanelShellTests --only ControlPanelLibraryTests --only ControlPanelDiscoverTests --only ControlPanelSyncTests: 40 passed, 0 failed, 0 skipped.
- Final gate after corrections, once: python3 scripts/test.py: 141 Python tests passed; 553 native passed, 0 failed, 11 skipped (2 live Workshop network and 9 NativeVideoPlayerMedia opt-ins). No --ui, network or media opt-in enabled.
- Isolated visual pass: 152 captures across eight viewport/language/theme configurations; 760x560, 960x640, 1440x900 en-light/zh-dark plus 960 zh-light/en-dark. One consolidated correction batch and 56 confirmation captures; two independent reviewers scored their five library/settings and three flow findings resolved.
- Observed: settings menu indicators and left-aligned category labels, artwork-independent selection ring, single-line 12px captions at narrow widths, complete import failure feedback, visible trailing Submit and matching DOM/Tab order. Three square columns and no horizontal overflow retained at 760px.
- Real browser input: hover reached scale 1.08, reduced motion stayed 1; arrow-key tile navigation and keyboard icon focus ring worked; selection did not apply; welcome radio navigation/inert background remained intact. Enter still routed downloadInput and cleared the synthetic response; rejected actions remained visible in the dialog.
- Popover stress: with a multiline business-error banner shifting the Import trigger, the anchor-derived popover stayed inside the viewport. No fixed trigger-height assumption or periodic measurement/timer added.
- Cleanup: owning control-panel documentation and local link targets updated; temporary preview fixture removed. Task-owned headless reference/preview tabs and localhost service released. Synthetic screenshot evidence remains disposable; no shared artifact purge.
- Limits: offscreen WKWebView behavior and isolated Chromium source-UI visuals only. No desktop control, real Steam login, wallpaper changes, permission approval or app restart. Real desktop presentation and power remain unverified. No Release build; the running app does not automatically acquire these source changes.
