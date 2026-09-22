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

## 2026-09-22 — Control panel UI and UX refinement

- Implementation: completed the five approved WebUI steps; existing native actions, snapshot fields, defaults, window minimum and design identity retained. No frontend dependencies or production resource files added.
- Baseline: offscreen WebKit reproduced settings overflow, lock availability, welcome focus and revealed-password loss; isolated Chromium reproduced secondary-only playback and unrelated Reconnect. The native anonymous-account regression reproduced missing modal feedback.
- Targeted: python3 scripts/test.py --only ControlPanelShellTests --only ControlPanelLibraryTests --only ControlPanelDiscoverTests --only ControlPanelSyncTests --only WebPanelPerformanceSettingsTests --only WebPanelSceneSettingsTests --only WebPanelAssetPropertiesTests --only WebPanelPropertyLabelTests: 66 passed, 0 failed, 0 skipped.
- Full gate, once after integration: python3 scripts/test.py: 141 Python tests passed; 553 native passed, 0 failed, 11 skipped (2 live Workshop network and 9 NativeVideoPlayerMedia opt-ins). No --ui, network or media opt-in enabled.
- Isolated visual evidence: 13 viewport/language/theme configurations, 582 first-round captures including supplemental welcome states; consolidated fixes followed by 78 confirmation captures. Sizes 760x560, 960x640, 1440x900; English/Chinese, light/dark, warm/cool, black/white accent and reduced motion.
- Runtime: real browser pointer and keyboard exercised hover, adjacent selection, Tab/Shift-Tab, radio arrows/Home/End, focus isolation, pending navigation, prompt handoff, empty recovery, property Reset and retained import results. Narrow dialog Submit/Cancel and queue retry remain reachable by keyboard/scroll; six-second sign-in handoff observed at 6023ms.
- Motion: captured 105 Chromium screencast frames and encoded a short hover GIF; observed scale interpolation 1 to 1.08 and back, reduced-motion scale 1. The standard WebM encoder was unavailable because host ffmpeg could not load libvpx.11.dylib; no tools were installed or patched.
- Documentation: updated control-panel, workshop-downloads and native coverage owners; local link targets checked. Published changelog remains release-generated. Removed task-owned preview scripts/raw frames; retained disposable synthetic screenshots and review evidence. clean.py --dry-run also included shared artifacts, so no blanket purge was performed.
- Isolation: task-owned Chromium tab and localhost preview service released. No application launch/restart, desktop control, real Steam login, wallpaper changes or system permission approval. No Release build; the running app still has the old behavior.
- Limits: Chromium source WebUI visual/runtime evidence and offscreen WKWebView behavior only. Actual desktop WKWebView presentation, system dialogs, real Steam, wallpaper presentation and power consumption remain unverified.

## 2026-09-22 — Release build for Perfect Wallpaper compatibility repair

- Pre-build gate for the unchanged repair sources: cargo test --release -p wallpaper-bridge --lib --quiet passed 322 tests; python3 scripts/test.py passed 141 Python and 544 native tests, with 11 opt-in skips; python3 scripts/check_renderer.py passed its generated matrix with three private-corpus skips. These commands were completed before the requested build and not needlessly rerun.
- python3 scripts/build.py --configuration Release: first attempt exited 65 at CodeSign because the built app directory carried com.apple.FinderInfo and com.apple.fileprovider.fpfs#P. Removed extended attributes only from build/Build/Products/Release/WallpaperMachine.app with xattr -cr, then repeated the full command: exit 0.
- Delivered build/Build/Products/Release/WallpaperMachine.app. codesign --verify --deep --strict passed; diff -qr WebUI against the bundled Contents/Resources/WebUI returned 0.
- The final Mach-O contains ProjectProperty::web_value and ProjectModel::parse. SHA-256 of the executable: fa0a28cfc648b42c087b72f66cc3216049f30ca724f23f9983a3257f99602fbc. Repair source hashes were unchanged throughout the build.
- Build identity: pre-commit base 1d7f181423cf840c485e209cfb150e1316531bea plus the five repaired bridge source/test files; their sorted source-hash inventory SHA-256 is 9e9915a8c12771afc4754f8eaf7a6fecbba84726d7e83b0dbb3632caf0a10436. Workspace inspection found no untracked build source; one unrelated untracked document was excluded from the commit.
- No version bump, release publication, installation, app launch/quit/restart, desktop interaction, or wallpaper setting change. Runtime/visual/power limits remain those of the preceding offscreen verification; the user must quit and reopen the delivered app to load it.

## 2026-09-22 — Web wallpaper authored property compatibility

- Implementation: preserve fractional property order and all distinct IDs at tied or missing positions; restore authored combo JSON types only at Web export, retaining existing string editor/persistence keys. Owning Web documentation and renderer provenance updated.
- Regression proof: both new failure cases failed before the fix (discarded properties and stringified numeric modes). cargo test --release -p wallpaper-bridge --lib --quiet: 322 passed, 0 failed, 0 ignored.
- Runtime proof: the actual installed Perfect Wallpaper project was parsed by production ProjectModel and loaded through production WebWallpaperPage in an offscreen WKWebView. Parsed properties increased from 100 to 172; exported runtime values from 73 to all 137 authored runtime properties. The saved image-12 selection changed the page background from imgs/1.jpg to imgs/12.jpg; the image decoded at 2560x1080. All combo payload types matched their authored options.
- python3 scripts/build.py --renderer-only: exit 0; renderer archive and Swift bindings regenerated. No Release application build or delivery, installation, app launch, restart, wallpaper setting, or author-asset modification.
- python3 scripts/test.py: exit 0; 141 Python tests passed; 544 native tests passed, 0 failed, 11 skipped (9 opt-in media tests and 2 live Workshop network tests).
- python3 scripts/check_renderer.py: exit 0; all test/probe processes returned 0; ten generated pooled/isolated pairs were pixel-equal with expected pixels and no diagnostics; eight generated projects completed two reload cycles. Three private-corpus cases skipped: LonelyCat, Workshop3409533530, and local Metal projects.
- Verification limits: page state/resource loading only, not desktop presentation, animation smoothness, video playback, real audio response, or power. Diagnostic network access was blocked and media playback suspended; resulting media play rejections and author-caught uninitialized timer logs were not treated as host failures.
- Cleanup: throwaway Rust/Swift diagnostic sources and the standalone Swift executable removed. python3 scripts/clean.py --dry-run inspected successfully; broad cleanup was not run because it would remove shared verification artifacts. Published changelog remains release-generated.

## 2026-09-22 — Release system: generated notes, draft-first publishing, deleted old releases

Reworked the release system end to end. scripts/release_notes.py writes the GitHub Release body and CHANGELOG.md from the commits between two tags; scripts/publish_release.py refuses a live release and cannot let Latest go backwards; build.yml gates on the test suite, verifies the unpacked archive and attests provenance; Settings -> About shows what the newest release changed. All thirteen releases through v0.5.0 were deleted at the owner's request, tags kept.

- `python3 scripts/test.py` — exit 0; 554 tests: 543 passed, 0 failed, 11 skipped
- `scripts/tests/test_release_notes.py` — 25 tests: classification, rendering, changelog ordering and range resolution against a throwaway git repository
- `scripts/tests/test_publish_release.py` — 13 tests: a live release is refused before any mutation, a failed upload never reaches --draft=false, an older version finishing last gets --latest=false
- Offscreen WebKit (ControlPanelShellTests) drives Settings -> About and asserts the What's new title, heading and lines, and that it stops at the install footer
- Both CI invocation shapes exercised locally: `--tag vX --to HEAD --changelog --apply` (Version) and `--tag vX --release-body --built-from --output` (Build)
- Release deletion verified: `gh release list` empty, `git ls-remote --tags origin` still 13 version tags, releases/latest 404, v0.1.0 and v0.5.0 still resolve to eb72174b0 and 66cfd6e0d
- Provenance claim corrected against actions/toolkit packages/attest/src/provenance.ts: the SLSA predicate records claims.ref/claims.sha (the triggering push), not the bump commit the tag points at; the built revision is recorded in the release body instead
- Not verified: no CI run (publishing remains blocked by the LICENSING.md gate), no Release build, no desktop run

## 2026-09-22 — Requested Release build with improved Settings

- python3 scripts/test.py passed: 104 Python tests; 544 native passed, 0 failed, 11 skipped of 555. Opt-in media and live-network checks remain skipped.
- python3 scripts/build.py --swift-only --configuration Release succeeded using the existing renderer and generated bindings. Xcode reported 26 warning lines; build completed successfully.
- diff -qr WebUI build/Build/Products/Release/WallpaperMachine.app/Contents/Resources/WebUI passed with no differences: all bundled WebUI files match current source, including the improved Settings page.
- codesign --verify --deep --strict build/Build/Products/Release/WallpaperMachine.app passed.
- Delivered build/Build/Products/Release/WallpaperMachine.app. Did not launch, quit, install or restart the app; user must quit and reopen this built app. Desktop visuals and live wallpaper behavior were not checked.
