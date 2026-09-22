# WallpaperMachine

A native macOS Wallpaper Engine client with scene, video and web wallpaper rendering and
independently implemented Steam Workshop browsing and downloads. The app is a SwiftUI/AppKit
shell around a vendored Rust/C++ renderer, with an HTML control panel hosted in
`WKWebView` and a sandboxed ExtensionKit extension for the experimental animated
lock screen.

## Features

| Feature | Summary |
| --- | --- |
| [Control panel](docs/features/control-panel.md) | Discover / Installed / Settings tabs, tile grid, inspector, explicit apply, per-wallpaper properties |
| [Workshop browsing and downloads](docs/features/workshop-downloads.md) | Login-free browsing, tag filters, SteamCMD setup, concurrent downloads that share a saved sign-in |
| [Audio-responsive wallpapers](docs/features/audio-response.md) | Per-wallpaper audio response driven by system audio |
| [Animated lock screen](docs/features/lock-screen.md) | Experimental, extension-based, off by default |
| [Appearance](docs/features/appearance.md) | System/Light/Dark, accent color, surface tone |
| [Languages](docs/features/control-panel.md#language) | English and Simplified Chinese; follows macOS or an in-app choice, more languages via [localization.md](docs/localization.md) |

## Quickstart

Requires macOS on Apple silicon with Xcode, a Rust toolchain, XcodeGen, the
Homebrew dependencies listed in [docs/build.md](docs/build.md) and the project's
own LGPL FFmpeg build (`python3 scripts/install_ffmpeg.py`); scene wallpapers
additionally need shared resources from a purchased Wallpaper Engine
installation.

```sh
python3 scripts/build.py                     # renderer + bindings + xcodegen + xcodebuild
python3 scripts/build.py --configuration Release
python3 scripts/test.py                      # script tests + WallpaperMachineTests
python3 scripts/package.py --configuration Release --install
```

The app used for local delivery is
`build/Build/Products/Release/WallpaperMachine.app`. Quit and reopen it after a
successful Release build. Full toolchain, packaging and installation details are
in [docs/build.md](docs/build.md).

## Repository layout

Application sources live in `App/`, the lock-screen extension in `Extension/`,
code shared by both in `Shared/`, the HTML control panel in `WebUI/`, tests in
`Tests/`, developer commands in `scripts/`, and the vendored renderer in
`upstream/`. `build/` and `artifacts/` are disposable and Git-ignored. See
[docs/repository-layout.md](docs/repository-layout.md) for the full directory map
and [docs/architecture.md](docs/architecture.md) for runtime structure and module
boundaries.

## Documentation

- [docs/README.md](docs/README.md) — documentation index
- [CONTRIBUTING.md](CONTRIBUTING.md) — contributor working agreement
- [docs/testing/README.md](docs/testing/README.md) — test strategy, commands, evidence policy
- [docs/release.md](docs/release.md) — versioning, release notes and the CI release pipeline
- [CHANGELOG.md](CHANGELOG.md) — what changed in each published version
- [AGENTS.md](AGENTS.md) — rules for agents working in this repository

## Source, licensing and status

This repository includes the current application and renderer sources, tests,
project configuration, and bundled resources. Build outputs, caches, local
credentials, and app binaries are not published.

The source is offered under the GNU General Public License, version 2 only
([LICENSE](LICENSE)); the vendored renderer is GPL-2.0-only and the
application shell is derived from it. Upstream code keeps its own copyright and
license notices, recorded in
[upstream/provenance.json](upstream/provenance.json). Renderer and scene-engine
sources are included directly rather than as Git submodules.

The intended business is a paid official build - Developer ID signed and
notarized, with priority support - sold under the GPL: recipients keep every
right to use, modify, redistribute and resell it, and the corresponding source
is offered alongside. Neither signing nor notarization is implemented yet;
`scripts/package.py` signs ad hoc for local use.

**No binary is cleared for distribution.** Homebrew's GPLv3 FFmpeg has been
replaced by the LGPL build in `Formula/mwe-ffmpeg.rb`, but Apache-2.0
components (MoltenVK, the Vulkan loader, SPIRV-Tools, parts of glslang, the
vendored spirv_reflect) remain in every build's link closure and are not
compatible with GPLv2. [LICENSING.md](LICENSING.md) records the policy, the
sales model, each component's license, the open blockers and what would
resolve them. Publishing this source does not clear the combined program,
bundled binaries, Valve's software, Wallpaper Engine assets or Workshop content
for distribution.
