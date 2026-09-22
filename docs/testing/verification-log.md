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

## 2026-09-22 — Integrated settings and inspector commit with remote main

- Rebased the approved UI, branding and property image changes onto origin/main, preserving remote release-note UI and authored property compatibility changes. Resolved the settings CSS overlap by retaining readable disclosure text and the release-note rules; preserved both verification histories.
- python3 scripts/test.py passed on the integrated tree: 142 Python tests; 550 native passed, 0 failed, 11 opt-in skipped of 561.
- No new renderer changes authored during integration. No Release rebuild, installation, app launch, restart, screenshots or desktop changes as part of commit and push. The earlier built app predates this remote integration.

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

## 2026-09-22 — Bound and cancel shared property image loads

- PropertyImageCache now tracks per-URL consumers, limits active transfers to four across hosts, cancels abandoned queued/active loads, and retains retiring slots until worker completion. Generation identity prevents stale completions affecting a replacement load.
- python3 scripts/test.py --only PropertyImageCacheTests --only WebPanelAssetsTests — exit 0 after correcting an initializer shadowing error and continuation type inference; 8 passed, 0 failed, 0 skipped.
- Delayed URLProtocol regressions exercise cancellation with an incomplete response, transport stop, same-URL retry, a 12-request/two-host burst capped at four transfers, queued cancellation without network work, and reuse of all four slots. Fixture sessions never reach the network.
- python3 scripts/test.py — exit 0; Python suites passed; native 544 passed, 0 failed, 11 opt-in tests skipped.
- Updated control-panel cache lifecycle documentation. No temporary smoke files created; shared test evidence retained. No Release build, desktop interaction, renderer run, or live-network test.

## 2026-09-22 — Settings full gate and branding test review

- Inspected the reported website-icon failure against current generated output: the 256px Day raster contains an opaque black centered frame spanning 61–194 on both central axes. Unmodified current branding suite passed all five tests; the earlier missing-frame result was not reproduced on the current tree.
- Revised scripts/tests/test_brand.py to assert a visible opaque frame, opposing margin symmetry and colored opaque interior rather than pinning artwork to a 61px inset. Branding generator and production artwork were not changed.
- Throwaway mutation check: centered artwork at another scale passed; shifted, missing and solid-black artwork each failed the revised test. Temporary outputs removed.
- python3 scripts/test.py passed: 104 Python tests; 542 native passed, 0 failed, 11 skipped of 553. This supersedes the earlier settings verification blockers.
- Skipped: nine opt-in NativeVideoPlayerMediaTests and two live-network WorkshopTests. Offscreen panel navigation and settings regression passed in the full gate.
- Settings layout/interactions retain the headless evidence recorded in prior entries. Desktop visual inspection, screenshots, real Steam/audio operations and live wallpapers were not exercised. No Release build or app restart.

## 2026-09-22 — Wallpaper Engine style property inspector

- Focused native gate: WebPanelPropertyLabelTests, PropertyImageCacheTests and WebPanelAssetsTests — exit 0; 8 passed, 0 failed, 0 skipped.
- python3 scripts/test.py — exit 0; Python suites passed; native 542 passed, 0 failed, 11 skipped (9 opt-in media/device cases, 2 live Steam cases).
- Isolated native image-loader smoke fetched all six author artwork files from the selected local wallpaper: four GIFs (7, 9, 26 and 60 frames) and two PNGs; all decoded successfully.
- Headless Chromium loaded all 14 authored image placements using those fetched bytes; exercised checkbox labels, keyboard slider changes, combo selection, reset, author links, Apply and Revert against an isolated bridge recorder.
- DOM geometry at window widths 760, 960, 1280 and 1830: no property overflow or label/control overlap; edit footer remained visible and stationary during scrolling. Light/dark theme and keyboard reset visibility checked.
- Impeccable detector over panel.css, panel.js and property-label.js — exit 0, no findings.
- No desktop interaction or screenshots; live WKWebView visual appearance and animation smoothness were not visually verified. No renderer/corpus run or Release rebuild.
- Removed the owned smoke runner and downloaded private artwork; preserved other sessions' artifacts after clean.py --dry-run listed 1.65 GB of shared evidence.

## 2026-09-22 — Settings verification after panel dependency integration

- The concurrently added WebUI/property-label.js is now present. Added its exact filename to WebPanelAssets.files; no routing policy or origin checks changed. Removed one duplicate Chinese translation introduced during concurrent catalog edits.
- python3 scripts/test.py --only ControlPanelShellTests: current-source offscreen WebKit run passed 11 tests, 0 failed, 0 skipped, including settings keyboard navigation, scroll reset, focus and disclosure preservation.
- python3 scripts/test.py: latest full-gate attempt stops in scripts/tests/test_brand.py::BrandTests.test_website_icon_centers_the_display_frame (Day icon must have a black display frame). Branding implementation and tests are outside the Settings change and were left untouched. Full gate is not passing; no native results are claimed for that attempt.
- Settings headless geometry and interaction coverage is recorded in the preceding settings entry: all seven categories, English/Chinese, light/dark, minimum/wide windows, long content and renderer-unavailable state. Final isolated settings check passed 42 layout cases after navigation alignment fix.
- Documentation updated in control-panel.md and performance.md. Owned smoke tabs and local server closed; no temporary source files created.
- No desktop screenshots, live wallpaper changes, real Steam/audio integration, Release build, or app restart. Running app retains the old behavior.

## 2026-09-22 — Website icons synchronized with centered native variants

- python3 scripts/brand.py --skip-app --website ../WallpaperMachineWebiste — exit 0; updated brand images, all three SVG/PNG appearances, favicons, touch icons and manifest without rewriting app resources.
- New rendered website regression failed against the old charcoal artwork; final python3 -m unittest discover -s scripts/tests -p test_brand.py passed all 5 tests.
- Headless Chromium decoded all three PNG/SVG variants and browser icons. At 256 px, all six variant renders have equal 61/61 px display-frame margins on both axes and transparent corners; canvas contact sheet visually inspected.
- Browser pixel checks also confirmed equal frame margins for 16/32 px favicons, SVG favicon, 180 px touch icon and 192/512 px manifest icons.
- Website variant PNGs match WebUI/app-icons/{minimal,day,night}.png byte-for-byte; default app-icon.png matches Day.
- python3 scripts/test.py — exit 0; Python checks passed; native 539 passed, 0 failed, 11 skipped of 550.
- Impeccable detector on the website asset directory returned no findings. Website contains assets only, no pages or separate product photos.
- No Release rebuild, desktop capture, app launch/restart or appearance change. Native app resources intentionally unchanged.
