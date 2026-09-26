# Repository layout

What each directory holds, where new code goes, and which paths are generated or disposable.
For how the pieces interact at runtime, see [architecture.md](architecture.md).

## Tree

```
AGENTS.md                          agent rules; authoritative for automated contributors
CLAUDE.md -> AGENTS.md              Claude entry point; relative symlink, same rules
CHANGELOG.md                       published versions, newest first; written by scripts/release_notes.py
CONTRIBUTING.md                    contributor working agreement
LICENSE                            GNU GPL version 2 text; the license of this repository's source (verbatim copy of upstream/renderer/LICENSE)
LICENSING.md                       GPL-2.0-only policy, Supporter model, component licenses and distribution blockers
README.md                          product overview after the website, build quickstart, FAQ, sponsor list, documentation index
project.yml                        XcodeGen spec: the only source of truth for targets/settings/versions
WallpaperMachine.xcodeproj/    generated from project.yml by xcodegen; committed, never hand-edited
App/                               WallpaperMachine application target sources only
  WallpaperEngineApp.swift         @main AppKit entry point; no scene/UI logic
  AppDelegate.swift                lifecycle, menu bar, window and shutdown ordering
  Bridge/                          BridgeEnvironment.swift (Vulkan ICD) and Generated/ (uniffi output; not hand-edited)
  Logging/                         AppLog.swift; the only Swift logging entry point
  Services/Appearance/             AppTheme.swift: theme preference model and store
  Services/Desktop/                desktop picture APIs, original-wallpaper ledger, poster sync, presentation policy
  Services/Diagnostics/            runtime diagnostics session and counter sampling
  Services/GitHub/                 GitHub release client, update models, update store, installer
  Services/Library/                ClientPaths and library import/deletion; owns the app-support layout
  Services/Localization/           AppLanguage.swift: shipped-language registry and the language preference store
  Services/LockScreen/             lock-screen selection overrides and configuration publishing
  Services/NativeVideo/            AVFoundation video backend: admission, player and host window
  Services/Steam/                  SteamCMD runtime discovery and setup state
  Services/SystemMedia/            shared now-playing session (MediaRemote, Music/Spotify
                                   AppleScript fallback) and artwork for Web and Scene media integration
  Services/UserAssets/             importing, watching and picking for file/directory wallpaper properties;
                                   owns the app's copies under <support>/UserAssets/ and the derived,
                                   regenerable <project>/.mwe-user-assets/ bridge a page can read
  Services/WebWallpaper/           WKWebView host windows and page protocol for web wallpapers
  Services/Workshop/               Workshop query model, browse store, downloader and queue
  ViewModels/                      BridgeStore and editor draft state; observable, no view code
  Views/ControlPanel/              SwiftUI container, WKWebView host, snapshot builder, action handlers
  Resources/                       Info.plist, string catalogs, Assets.xcassets; app resources only
Extension/                         WallpaperMachineExtension sources, Info.plist, entitlements, bridging header,
                                   its own string catalog (Localizable.xcstrings)
Shared/                            contracts compiled into both targets: LockScreenConfiguration,
                                   RuntimeCounters, WallpaperPresentationAuthority
WebUI/                             HTML/CSS/JS control panel; bundled verbatim as the app resource folder WebUI
  locales/                         one panel catalog module per shipped language (zh-Hans.js), registered in i18n.js
Resources/StarterWallpaper/        bundled sample wallpaper (Aurora.mp4, preview.jpg, project.json)
Tests/Unit/<Domain>/               WallpaperMachineTests, grouped Appearance, Desktop, Diagnostics, GitHub,
                                   Library, Localization, LockScreen, NativeVideo, Panel, Steam, SystemMedia,
                                   UserAssets, WebWallpaper, Workshop; hosted in the app binary
Tests/UI/                          WallpaperMachineUITests; desktop-driving XCUITest suite
docs/                              all project documentation; see docs/README.md for the index
  archive/                         retired plans and records; rg skips them (repository .ignore, `rg -u` to search)
scripts/                           developer command line; Python only
  lib/                             shared helpers (glyphs.py status markers, paths.py repo paths,
                                   xcode.py quiet runner: full tool output to artifacts/, failures on screen,
                                   dmg.py drag-to-install disk image: .DS_Store layout, build, verify)
  tests/                           unit tests for the scripts, run by scripts/test.py
Formula/                           mwe-ffmpeg.rb: the LGPL-2.1-or-later FFmpeg build the app links (scripts/install_ffmpeg.py)
Packaging/dmg/                     disk-image window background (background.png, @2x); generated by scripts/brand.py --dmg
upstream/                          vendored third-party code only
  provenance.json                  repositories, pinned revisions, modification status
  renderer/                        Rust workspace (crates/), C++ scene engine (external/), cargo target/;
                                   trimmed to what the build and renderer checks use
  mediaremote-adapter/             ungive/mediaremote-adapter, BSD-3-Clause, unmodified; built as an embedded framework
artifacts/                         Git-ignored: all test and verification evidence
build/                             Git-ignored: Xcode derived data and built products only
.agents/                           agent skills and agent-tooling notes
.github/workflows/                 CI: build.yml, release.yml, version.yml
```

Things that must not appear:

- No product code under `upstream/` — it is vendored renderer code only.
- No app-target code under `Shared/`; it must stay compilable with
  `APPLICATION_EXTENSION_API_ONLY`.
- No generated Xcode settings edited in `WallpaperMachine.xcodeproj`; change `project.yml`.
- No test output, logs or `.xcresult` bundles anywhere but `artifacts/`.
- No shell scripts in `scripts/`; the command surface is Python.

## Where does new code go?

| You are adding | Put it in | Notes |
|---|---|---|
| App service or domain logic | `App/Services/<Domain>/` | Reuse an existing domain folder before creating one; a new domain needs a new folder plus a matching `Tests/Unit/<Domain>/` |
| View or panel-hosting feature | `App/Views/ControlPanel/` | Page state belongs in the snapshot builder, actions in the action handlers |
| Observable app state | `App/ViewModels/` | Keep renderer calls behind `BridgeStore`; no views here |
| Web-panel UI | `WebUI/` | Extend `panel.js`/`settings.js`/`welcome.js` plus the matching CSS; new files must be added to the served allow list in `WebPanelAssets` and to the file list in `scripts/tests/test_panel_localization.py`. Icons come from the vendored Lucide set in `icons.js`, never hand-drawn SVG |
| A language | `WebUI/locales/<tag>.js`, `WebUI/i18n.js`, `App/Services/Localization/AppLanguage.swift`, both `.xcstrings` | Follow [localization.md](localization.md); the allow list and Settings picker derive from `AppLanguage.supported` |
| Code shared with the extension | `Shared/` | Only if both targets genuinely need it, and it must build extension-API-only |
| Lock-screen extension behaviour | `Extension/` | Nothing here may depend on app-only APIs or app-private files |
| Unit test | `Tests/Unit/<Domain>/` | Same domain folder name as the code under test |
| UI test | `Tests/UI/` | Runs only via `scripts/test.py --ui`; it takes over the desktop |
| Developer script | `scripts/<name>.py` | `snake_case.py`, argparse flags, no shell wrappers |
| Shared Python helper | `scripts/lib/` | With a test in `scripts/tests/` |
| Documentation | `docs/` (or `docs/testing/`) | Add it to the index in [README.md](README.md); one topic per file |
| Renderer, scene-engine or shader change | `upstream/renderer/` | Vendored: keep changes minimal and reflect them in `upstream/provenance.json` |
| Generated code | nowhere by hand | Regenerate via `scripts/build.py`; commit only what the tooling produces |
| Evidence, logs, result bundles | `artifacts/` | Disposable; never committed |

## Generated, vendored and ignored

| Path | Status |
|---|---|
| `WallpaperMachine.xcodeproj/` | Generated by `xcodegen generate` from `project.yml`, and committed. Regenerate rather than edit. |
| `App/Bridge/Generated/` | Produced by `scripts/build.py` (`uniffi-bindgen` over `libwallpaper_bridge.a`). Hand edits are overwritten. |
| `upstream/` | Vendored third-party code, governed by `upstream/provenance.json` and [../LICENSING.md](../LICENSING.md). |
| `Formula/` | `mwe-ffmpeg.rb`, the LGPL-2.1-or-later FFmpeg build the app links; installed by `scripts/install_ffmpeg.py`. |
| `Packaging/dmg/` | Generated by `python3 scripts/brand.py --dmg` and committed; `scripts/package.py` lays the disk-image window over it. Regenerate rather than edit. |
| `artifacts/` | Disposable, Git-ignored. Test and verification evidence, including the full `xcodebuild`/`cargo` logs the scripts keep off the terminal; removable with `scripts/clean.py`. |
| `build/` | Disposable, Git-ignored. Xcode derived data and built products only. |
| `.ignore` | Paths `rg`/`fd` skip by default: `docs/archive/`, `docs/testing/archive/`, `App/Bridge/Generated/`, `upstream/`. `rg -u` searches them. |

## Naming

| Kind | Convention |
|---|---|
| Swift source | `UpperCamelCase.swift` matching its primary type (`BridgeStore.swift`, `WallpaperSurface.swift`) |
| Swift files holding a family of types | Named after the concept, not one type (`AppTheme.swift`, `AppUpdateModels.swift`) |
| Swift tests | `<Subject>Tests.swift`, in the domain folder of the code under test |
| Python scripts and helpers | `snake_case.py` (`build.py`, `check_renderer.py`, `bump_version.py`, `release_notes.py`, `publish_release.py`, `lib/xcode.py`, `lib/dmg.py`) |
| Python tests | `test_<module>.py` under `scripts/tests/` |
| Web panel files | lowercase, one concern per file (`panel.js`, `settings.css`, `theme.js`) |
| Markdown under `docs/` | lowercase-hyphenated (`repository-layout.md`, `development-tools.md`); `README.md` is the only uppercase name |
| Root Markdown | uppercase (`README.md`, `AGENTS.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSING.md`); the license text is the extensionless `LICENSE` |
| Bundle identifiers | `app.wallpapermachine` and `app.wallpapermachine.wallpaper-extension` |
