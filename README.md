# MacWallpaperEngine

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

## Quickstart

Requires macOS on Apple silicon with Xcode, a Rust toolchain, XcodeGen and the
Homebrew dependencies listed in [docs/build.md](docs/build.md); scene wallpapers
additionally need shared resources from a purchased Wallpaper Engine
installation.

```sh
python3 scripts/build.py                     # renderer + bindings + xcodegen + xcodebuild
python3 scripts/build.py --configuration Release
python3 scripts/test.py                      # script tests + MacWallpaperEngineTests
python3 scripts/package.py --configuration Release --install
```

The app used for local delivery is
`build/Build/Products/Release/MacWallpaperEngine.app`. Quit and reopen it after a
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
- [docs/release.md](docs/release.md) — versioning and the CI release pipeline
- [AGENTS.md](AGENTS.md) — rules for agents working in this repository

## Source, licensing and status

This repository includes the current application and renderer sources, tests,
project configuration, and bundled resources. Build outputs, caches, local
credentials, and app binaries are not published.

This is a source snapshot, not a verified binary release. No build or desktop
tests were run as part of publishing it.

Renderer and scene-engine sources are included directly in this snapshot rather
than as Git submodules.

See [LICENSING.md](LICENSING.md) for implementation provenance and unresolved
distribution considerations, and
[upstream/provenance.json](upstream/provenance.json) for upstream revisions.
Upstream source retains its license and copyright notices. Publishing this source
snapshot does not mean that bundled binaries or third-party wallpaper assets are
cleared for distribution.
