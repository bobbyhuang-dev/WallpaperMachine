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

## 2026-09-22 — Branding and icon selection rebased onto localization updates

- Rebased the branding and selectable Dock icon changes onto origin/main at 0e85acc; retained remote UI copy and translations alongside the icon picker and welcome branding.
- Merged verification histories without dropping entries; retained ten active entries and archived older entries with existing link-rewriting rules.
- python3 scripts/test.py — exit 0; all Python suites passed; native 538 passed, 0 failed, 11 skipped of 549. Build log reports 35 warning lines.
- No renderer source edits during integration; renderer gate not rerun. No Release rebuild, application launch/restart or desktop verification; existing Release app remains unchanged.

## 2026-09-22 — Consistent Dock icon frame weight

- Changed Minimal to reuse the regular native frame-and-gear geometry used by Day and Night; preserved blue-on-white styling and left panel/menu-bar glyphs unchanged.
- python3 scripts/brand.py — exit 0; regenerated native and Dock assets.
- Rendered PNG smoke measurement: Minimal top frame 61 source pixels, Day/Night 59; the small difference is the wallpaper's inner-edge overlap, below 0.3 px at picker size. Inspected all three generated artwork files.
- Added rendered thickness comparison to the existing Dock artwork regression; initial one-pixel tolerance failed on the wallpaper overlap, corrected to three source pixels.
- python3 scripts/test.py — exit 0; all Python checks passed, including 4 brand tests; native 536 passed, 0 failed, 11 skipped of 547.
- No app launch, desktop capture or live Dock check; in-app visual behavior unverified. No Release rebuild; running app remains unchanged.

## 2026-09-22 — Release delivery of selectable Dock icons

- Pre-build verification: the preceding feature gate passed with 536 native tests passed, 0 failed, 11 skipped; Python checks passed. No behavioral source changes followed that gate.
- python3 scripts/build.py --swift-only --configuration Release — exit 0; built version 0.5.0 (16) at build/Build/Products/Release/WallpaperMachine.app; build reported 25 warning lines.
- All 14 bundled WebUI files match current source byte-for-byte, including Settings > Appearance > App icon and Minimal/Day/Night PNG assets. codesign --verify --deep --strict passed.
- Refreshed the delivered bundle timestamp and Launch Services registration; removed the competing Debug registration without deleting files. A fresh NSWorkspace lookup resolves app.wallpapermachine to the Release bundle.
- No app launch/quit, Dock restart, installation, live icon selection or desktop capture. User must quit and reopen the Release app to verify the picker; live Dock presentation remains unverified.

## 2026-09-22 — Selectable Minimal Day and Night Dock icons

- Added a localized Settings > Appearance icon picker; choice persists independently of panel appearance and applies at startup/change through NSApplication.applicationIconImage. Finder, menu-bar symbol and signed bundle remain unchanged; reset restores Day.
- python3 scripts/brand.py — exit 0; generated shared 1024px Minimal/Day/Night PNGs with transparent macOS outer margins. Minimal reuses the blue About glyph; fixed Day/Night reuse current native geometry.
- python3 -m unittest discover -s scripts/tests -p test_brand.py — exit 0; 4 passed, including variant color/interior, gear hub and transparent margin checks.
- python3 scripts/test.py --only AppThemeTests --only ControlPanelShellTests/testAppearanceControlsPersistAndFollowNativeAppearanceWithoutWindow — exit 0; 5 passed. Native WebKit exercises Night selection, preview decoding, reset and Minimal recovery; no window.
- python3 scripts/test.py — exit 0; Python checks passed; native 536 passed, 0 failed, 11 skipped of 547. Reported warnings concern existing media isolation, update-test return values and AppIntents metadata.
- Headless browser: visually inspected actual settings in light English and compact dark Simplified Chinese; all previews loaded, no horizontal overflow. Keyboard selection retained focus; rejected save restored prior choice; reset selected Day. Preview bridge simulated only for browser interaction checks.
- Isolated AppKit smoke — exit 0; assigned each PNG to applicationIconImage at 512-point Retina size and read back distinct 1024px native images. Process remained activation-prohibited with no windows or Dock entry. Initial smoke assumptions about setActivationPolicy return value and representation size were corrected before the successful run.
- Impeccable detector for settings.js/settings.css returned no findings. Updated appearance documentation; closed browser and preview server. clean.py --dry-run identified 1.60 GB including unrelated evidence, so broad cleanup was not performed; no throwaway source files were left.
- No Release rebuild, app launch/restart, Finder custom-icon change, Dock restart, installation or desktop capture. Live Dock presentation remains unverified; the previously delivered Release app does not include this picker.

## 2026-09-22 — Release delivery of enlarged centered app icon

- First Release inspection exposed a macOS 26-only issue: appearance recoloring filled the open frame stroke. Replaced the native stroke with a filled outline; website and tray glyphs retain their existing stroke geometry.
- Pinned icon regressions to Icon Composer --design-generation 26. The gear-clearance assertion failed in both appearances before the outline fix, then all 3 branding tests passed.
- Final python3 scripts/test.py — exit 0; Python checks passed; native 535 passed, 0 failed, 11 skipped of 546.
- Final python3 scripts/build.py --swift-only --configuration Release — exit 0; delivered build/Build/Products/Release/WallpaperMachine.app.
- Visually inspected corrected macOS 26 Default/Dark exports and extracted final bundled AppIcon.icns. Bundled 256 px fallback has equal 61/61 px display-frame margins on both axes, including the system outer inset, and a clear gear cutout.
- Assets.car contains the updated native mark vector in both Aqua and DarkAqua groups; all 11 bundled WebUI files match source byte-for-byte. codesign --verify --deep --strict passed.
- Removed temporary layer-isolation icon documents; retained disposable render evidence. No app launch/quit, installation, desktop capture, icon-cache reset or system appearance change. User must quit and reopen the delivered app; live Dock/Finder presentation remains unverified.

## 2026-09-22 — Larger seamless app icon with centered display frame

- python3 scripts/brand.py — exit 0; regenerated native vector layers with approximately 24% larger artwork, joined panel/frame edges and an explicit gear cutout.
- Rendered centering regression failed before the placement fix in both appearances: opposing horizontal margins were 49/40 px.
- python3 -m unittest discover -s scripts/tests -p test_brand.py — final exit 0; 3 passed, covering light/dark backgrounds, matching display-frame margins, seam-free joins, gear clearance, tray alpha and ICO payloads.
- Icon Composer offscreen exports at 256, 64 and 32 px succeeded in Default and Dark. Visually inspected final 256 px appearances and the 32 px light icon; measured frame margins were 44/44 px on both axes in both 256 px appearances.
- python3 scripts/test.py — exit 0; Python checks passed; native 535 passed, 0 failed, 11 skipped. Full gate completed before the subsequent user-requested centering correction; final centering was verified with the targeted branding suite and native icon exports.
- python3 scripts/clean.py --dry-run — exit 0; broad cleanup would remove 1.66 GB including unrelated evidence, so it was not executed. No throwaway source scripts were created.
- No Release rebuild, app launch/restart, desktop capture or appearance change. Live Dock/Finder presentation remains unverified; the running app retains its existing icon.

## 2026-09-22 — Release app rebuilt with refreshed native icon

- python3 scripts/test.py — exit 0; 535 passed, 0 failed, 11 skipped. All Python script suites passed, including the three brand export tests.
- python3 scripts/build.py --swift-only --configuration Release — exit 0; delivered build/Build/Products/Release/WallpaperMachine.app.
- Verified Release Info.plist references AppIcon and Assets.car contains Aqua white and DarkAqua black native background layers. Extracted the bundled AppIcon.icns and visually confirmed the new fallback artwork.
- Verified all 11 bundled WebUI files match current WebUI source byte-for-byte; codesign --verify --deep --strict passed.
- NSWorkspace initially resolved the previous two-background icon from cache. Touched only the rebuilt app bundle and ran lsregister -f on that bundle; a fresh NSWorkspace lookup then resolved the updated single-white-background icon, visually inspected via image export.
- No app launch or quit, desktop capture, appearance change, Finder/Dock restart or installation performed. User must quit and reopen the delivered Release app; live post-launch presentation remains unverified.

## 2026-09-22 — Single-background light and dark app icons

- Replaced flattened AppIcon.appiconset PNGs with generated App/Resources/AppIcon.icon; white/light and black/dark native backgrounds, contrasting frame and gear, unchanged aurora panel.
- python3 scripts/brand.py — exit 0; generated native vector layers and tray assets.
- python3 -m unittest discover -s scripts/tests -p test_brand.py — exit 0; 3 passed, including native rendered-pixel checks for both appearances, transparent corners, uniform backgrounds and colored wallpaper panel.
- xcrun actool — exit 0; compiled the native icon for macOS 26. Icon Composer Default/Dark exports and the small compiled ICNS fallback were visually inspected without desktop capture.
- Debug bundle inspection confirmed CFBundleIconName AppIcon and compiled Aqua white / DarkAqua black background layers.
- First python3 scripts/test.py run: 534 passed, 1 failed, 11 skipped; ControlPanelSyncTests.testHiddenPanelContinuesSetupAndObservesNestedDownloadChanges reported InvalidTransition idle to failed(deinit). Isolated retry passed without code changes.
- Second python3 scripts/test.py run — exit 0; 535 passed, 0 failed, 11 skipped. Final branding-only rerun also passed after comment/docstring cleanup.
- No Release build, app restart, desktop appearance change or live Dock/Finder verification. Cleanup dry-run included unrelated existing artifacts; broad deletion was not performed.

## 2026-09-22 — Release build with transparent tray icon

- Prior python3 scripts/test.py gate passed: Python checks passed; native 535 passed, 0 failed, 11 skipped.
- python3 scripts/build.py --swift-only --configuration Release succeeded.
- Offscreen AppKit rendering of TrayIcon loaded from the Release bundle at 16px and 32px matches source alpha within one 8-bit level; background and interior are transparent.
- Initial bitmap-representation inspection was unsuitable for catalog-backed NSImage; verification used actual offscreen drawing instead.
- Delivered build/Build/Products/Release/WallpaperMachine.app. App not launched or restarted; live menu bar verification left to user.
