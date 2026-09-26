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

## 2026-09-26 — Release build: welcome guide changes

- python3 scripts/build.py --swift-only --configuration Release: OK after the passing full gate (581 passed, 0 failed, 11 skipped).
- The bundled Contents/Resources/WebUI welcome.js, welcome.css and locales/zh-Hans.js are byte-identical to WebUI/.
- The app was not launched; its visual behavior was not checked in the delivered app.

## 2026-09-26 — Welcome guide: lock-screen switch, shorter tips, compatibility card

- python3 scripts/test.py: 581 passed, 0 failed, 11 skipped (592).
- ControlPanelShellTests (19/19): guide shows lock switch off/disabled when unavailable; native refusal keeps it off with the error shown; drafts untouched; Tips has 3 rows and 2 allowlisted GitHub links.
- Throwaway headless-Chromium harness (stubbed bridge, deleted): lock switch applies at once, Skip reverts it, busy status has no doubled ellipsis; Tips fits 760x560 without scrolling in en/zh-Hans, light/dark.
- impeccable detect on welcome.js/welcome.css: 0 findings. The in-browser overlay was blocked by the CSP (no wasm-unsafe-eval).
- Not verified: WKWebView rendering in the real app and actually enabling the lock screen. No Release build.

## 2026-09-26 — Quit restores inherited Spaces to the real wallpaper

- Bug: Spaces journaled with a pathless (inherited) original, or showing an unjournaled poster, kept a poster after quit.
- Fix: DesktopWallpaperLedger substitutes the display's first real original (then any display's) at capture and restore.
- python3 scripts/test.py --only DesktopWallpaperTests: 29/29 pass; the 2 new regression tests fail on the HEAD ledger.
- Read-only dry run against the live journal/Spaces: old restore wrote {} to display 2 Spaces BCDD1D84/83FBBBB8, new restores Big Sur Coastline.heic on all 4.
- python3 scripts/test.py: 581 passed, 0 failed, 11 skipped.
- Not run: real quit on the desktop (no wallpaper-change authorization); Release app not rebuilt.

## 2026-09-26 — Release build with wallpaper-window canHide fix

- python3 scripts/build.py --configuration Release: OK (cargo, uniffi-bindgen, xcodegen, xcodebuild; pre-existing warnings only); generated bindings unchanged.
- Built binary 2026-09-26 18:56 contains the setCanHide: selector reference.
- Delivered: build/Build/Products/Release/WallpaperMachine.app. Not launched; two-display apply/hide behavior not checked on the desktop.

## 2026-09-26 — Wallpaper windows survive app hide (canHide=false)

- Bug: after an activation NSApp.hide(nil) (e8aab7b) also hid every wallpaper window (AppKit canHide default YES); occlusion then suspended both displays. Evidence: app log 20260926-180315 shows 'presentation suspended for displays [1, 2]' after each of 5 activations; no [1, 2] suspension in any session before 2026-09-26 14:24.
- Fix: canHide=false on MWEWallpaperDesktopWindow (crates/core window.rs), MWEWebWallpaperDesktopWindow, MWENativeVideoDesktopWindow; provenance note and architecture.md updated.
- python3 scripts/build.py --renderer-only: passed (pre-existing unused-code warnings only).
- cargo test --release -p wallpaper-core --lib window: 12 passed.
- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped.
- Not run: desktop hide/apply check on two displays (needs desktop authorization); no Release build.
- Separate finding, not changed: each scene's text worker reads the 78 MB PingFang fallback font twice per text update under the process-wide g_freetype_mutex (TextLayer.cpp CreateFallbackFace); a sample showed the two scenes' workers waiting on each other (333 mutex-wait samples).

## 2026-09-26 — Top bar/About version display + Release build

- Removed top-bar version and GitHub button; About shows 'beta (unreleased)' and component versions 0.1.0 (display-only); removed bigsaltyfishes renderer row.
- Updated ControlPanelShellTests top-bar tests (repository link removed).
- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped.
- python3 scripts/build.py --swift-only --configuration Release: OK; bundled WebUI identical to WebUI/.
- Not checked: visual rendering of Settings/About on a desktop run.

## 2026-09-26 — Release pipeline follow-ups: reference bytes, real transport, safer rebuild

After review: the .DS_Store and alias writers are held to ds_store 1.3.3 / mac_alias 2.2.3 output, the model call has a 600 s deadline and claim rules, --rebuild-changelog never calls the model and keeps recorded sections, the image copy sheds extended attributes, and DMG inputs are checked in the packaging preflight. Python-only changes after the previous entry's full gate.

- `python3 scripts/tests/test_release_notes.py` — exit 0; 45 tests, including the real HTTP request against a local server (headers, the gateway's 401 message, the deadline)
- `python3 scripts/tests/test_dmg.py` — exit 0; 11 tests: writers byte-identical to the reference goldens; a bundle carrying Finder info round-trips and verifies
- `test_brand.py` 6 and `test_publish_release.py` 13 — exit 0
- `python3 scripts/package.py --configuration Release --check` — exit 0; preflight including the DMG inputs, bundle unchanged
- `release_notes.py --ai --tag v0.6.0 --to HEAD` through the real request — 37 s; opt-in features read optional and off by default, no power claims
- Native suite not rerun: no Swift change since the previous entry's full gate

## 2026-09-26 — Release pipeline: drag-to-install disk image and model-written release notes

The distributable is now WallpaperMachine-<version>-arm64.dmg (scripts/lib/dmg.py, standard library only) and the in-app updater installs from it; release notes are written by claude-opus-5-5 through the sub2api gateway and recorded once in CHANGELOG.md. The Release app in build/ was running and was neither rebuilt nor packaged.

- `python3 scripts/test.py` — exit 0; 14 script test modules OK (test_dmg 7, test_release_notes 41, test_brand 6, test_publish_release 13); native 579 passed, 0 failed, 11 skipped of 590
- `python3 scripts/test.py --only AppUpdateTests --only ControlPanelShellTests` — exit 0; 48 passed, including installs from real hdiutil images that end detached
- scripts/lib/dmg.py against dmgbuild 1.6.7 in a throwaway venv (not a dependency) — .DS_Store (16388 bytes) and background alias (394 bytes) byte-identical for the same inputs; a built image's records equal dmgbuild's
- scripts/package.py run on a copy of the Release app outside build/ — preflight, 19 relocated dylibs, ad-hoc signing, 33 MB ULFO image, mounted verification, `shasum -a 256 -c` OK; nothing left attached
- `release_notes.py --ai --tag v0.6.0 --to HEAD` against the gateway — 93 commits, summary plus 14 New / 8 Improved / 20 Fixed, streamed in 44 s
- Finder window of that image — checked and confirmed by the user on macOS 27.2 beta; not checked on macOS 26.x
- Not run: the CI workflows (Build stays behind the LICENSING.md gate; the RELEASE_NOTES_API_KEY repository secret is not set yet)

## 2026-09-26 — Hide app after wallpaper activation

- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped
- python3 scripts/build.py --swift-only --configuration Release: OK
- Manual check of hide-on-activate pending (user verifying)

## 2026-09-26 — Release build after syncing origin/main (6106f50)

- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped
- python3 scripts/build.py --configuration Release: OK (renderer changes pulled, full build)
- Not launched; check_renderer.py not run
