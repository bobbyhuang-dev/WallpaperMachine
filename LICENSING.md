# Licensing: combining the macOS Wallpaper Engine projects

Recorded: 2026-09-14
Status: deferred; unresolved before distribution.

## Intent and current decision

Explore one macOS application combining Steam Workshop browsing/downloading with native Wallpaper Engine wallpaper rendering.

Proceed with private experimentation. Revisit licensing once the implementation demonstrates that the approach works. This deferral is not permission to publish a merged repository or distribute a combined application under incompatible licenses.

## Projects and evidence

### Workshop browser: Unayung/wallpaper-engine-mac

- Repository: https://github.com/Unayung/wallpaper-engine-mac
- License: GNU GPL version 3.
- License file: https://github.com/Unayung/wallpaper-engine-mac/blob/main/LICENSE
- Relevant functionality: integrated Workshop search, filters, and SteamCMD downloads; video/web playback and limited scene rendering.

### Renderer: bigsaltyfishes/wallpaper-engine-for-macos

- Repository: https://github.com/bigsaltyfishes/wallpaper-engine-for-macos
- License file: GNU GPL version 2.
- License file: https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/LICENSE
- Workspace package metadata explicitly declares `license = "GPL-2.0-only"`:
  https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/Cargo.toml
- Relevant functionality: native scene rendering, audio response, and partial SceneScript support.

These observations describe the upstream files checked on the recorded date. The links follow mutable branches, not pinned revisions. Before importing code, record the exact revisions and retain their license notices. This is not a complete file-by-file or dependency license audit.

## License issue

GPLv2-only and GPLv3 are incompatible for distributing a single combined derivative program. Both permit modifications, but their distribution requirements cannot simply be satisfied by labeling a merged application with both licenses.

The renderer's explicit `GPL-2.0-only` declaration matters: unlike GPLv2-or-later, it does not authorize us to choose GPLv3 for the covered code. Publishing the source, preserving attribution, or including both license texts does not by itself resolve the conflict.

Private combinations are permitted under the FSF's guidance. Publishing merged source or sharing a combined binary requires resolving the distribution issue first.

References:

- GPLv2/GPLv3 compatibility: https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility
- Private combinations: https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean
- Private modifications and release obligations: https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic

## Potential resolutions to revisit

### Preferred fallback: independently implement Workshop browsing

Use the bigsaltyfishes renderer project as the base and independently implement browsing/downloading from Steam's documented interfaces under GPLv2-compatible terms. Do not copy, translate, or adapt Unayung's GPLv3 implementation into this version.

This delivers the combined functionality without directly combining the two codebases. If the private prototype contains GPLv3-derived browser code, that code must be removed and independently replaced before relying on this route. Keep prototype provenance clear; do not relabel copied code as original work.

### Alternative: obtain compatible permissions

Request permission to use the relevant renderer code under GPLv3, or the relevant browser code under GPLv2-compatible terms. Permission must cover all relevant copyright holders and inherited code, not merely the current repository maintainer's own contributions. Retain written grants and audit dependency compatibility.

### Alternative: genuinely separate applications

Keep the browser and renderer as independent programs under their respective licenses, communicating through ordinary files or a simple command-line interface.

A subprocess boundary alone is not sufficient: tightly coupled components exchanging internal data structures may still constitute one combined work. Evaluate the actual architecture before relying on aggregation.

Reference: https://www.gnu.org/licenses/gpl-faq.html#MereAggregation

## Before any distribution

- Select and document a legally compatible integration route.
- Pin imported revisions and audit the actual reused files, dependencies, and assets.
- Preserve copyright, license, and warranty notices; identify modifications as required.
- Provide corresponding source and required build/install scripts under the applicable GPL terms.
- Review Steam/API terms and separate rights to Wallpaper Engine assets and Workshop content. These projects' GPL licenses do not authorize redistribution of Valve's software, proprietary Wallpaper Engine assets, or creators' wallpapers.
- Obtain qualified legal review if relying on special permissions or a disputed program-separation boundary.

Distribution review remains deferred. The implementation below avoids directly combining the GPLv3 browser with the GPLv2-only renderer, but this is not a completed dependency or distribution audit and is not legal advice.

## Implementation record

The native application is named **MacWallpaperEngine**; the project slug is `mac-wallpaper-engine`.

- Renderer source is in `upstream/renderer`, based on revision `8c19c002ff37930c68117dd591dfe3f44792e25e`.
- The application shell in `App/` is a derived work of that renderer revision's `app/WallpaperEngine` sources, relocated out of `upstream/renderer` so the sources this project actively develops are not mixed into vendored third-party code. The relocation moves files only: GPL-2.0-only terms and the upstream copyright notices continue to apply. `upstream/provenance.json` records this under `applicationShell`.
- The native lock-screen extension is in `Extension/`, and `Extension/Phosphene-LICENSE.txt` carries the third-party notice for the reference described below.
- The Workshop browser and downloader were independently implemented for this client. No Unayung GPLv3 implementation was copied into it.
- Exact source provenance is recorded in `upstream/provenance.json`.
- Current Homebrew FFmpeg binaries include GPLv3-enabled components. The private bundle is not cleared for distribution; a GPLv2-compatible media build or appropriate permissions must be selected and audited before release.
- Valve SteamCMD is installed separately, not bundled with the application. Its copied runtime is used for authenticated downloads; the app does not distribute Workshop content or proprietary shared assets.
- The web control panel's icons are copied from [Lucide](https://lucide.dev) (ISC License, Copyright (c) Lucide Icons and Contributors); the notice travels in the header of `WebUI/icons.js`.
- Native lock-screen extension ABI research used the MIT-licensed [Phosphene](https://github.com/kageroumado/phosphene/tree/8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6) protocol/Codable layout as a reference. The app-specific asset publication, restoration and existing renderer integration are implemented here. Private `WallpaperExtensionKit` is not an Apple-supported public wallpaper API; this does not resolve the distribution issues above.

## Local build and use

This build targets Apple Silicon and macOS 26 or later, and requires Xcode and Homebrew.
Packaged renderer libraries are bundled into the app for local use only and are not cleared for distribution.

- Prerequisites, dependencies and commands: [docs/build.md](docs/build.md).
- Steam sign-in, download and scene-asset behavior: [docs/features/workshop-downloads.md](docs/features/workshop-downloads.md).

## Verification record

License-relevant local verification has been performed: the installed release at `~/Applications/MacWallpaperEngine.app` passed code signature checks and bundled dynamic-library path checks. Account-dependent Workshop download and apply verification remains open, and this record claims no working guarantee for every Workshop scene or every hardware configuration.

Dated history: [docs/testing/verification-log.md](docs/testing/verification-log.md).
