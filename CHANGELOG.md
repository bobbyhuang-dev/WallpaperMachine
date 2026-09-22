# Changelog

Every published version, newest first. Sections are written by
[`scripts/release_notes.py`](scripts/release_notes.py) from the commits between two
version tags, so this file and the GitHub Release body always say the same thing.
Documentation, test and tooling commits are counted rather than listed. See
[docs/release.md](docs/release.md) for how a version is cut.

## 0.5.0 — 2026-09-18

### New

- **panel** — Steam sign-in guides, logout wording, filter rail and top bar ([`bda404d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/bda404d))
- **scene,web** — Static subgraph reuse, web audio/media APIs, user file properties ([`dd01e58`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/dd01e58))
- **quality** — Internal render scale, quality settings, shared video decode ([`48b8df2`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/48b8df2))
- **native video** — Enhance rejectNativeVideo method with admission key and update related structures ([`47b12b1`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/47b12b1))
- **native video** — Implement native video wallpaper support and diagnostics ([`c0461f7`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/c0461f7))
- **presentation** — Enhance wallpaper suspension with per-display control ([`e39f0c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/e39f0c4))

Plus 2 documentation, test and tooling commits.

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.4.0...v0.5.0

## 0.4.0 — 2026-09-18

### New

- **workshop** — Concurrent downloads, tile download rings and grid-sized Discover pages ([`b0eaeed`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b0eaeed))
- **panel** — Batch deletion, cached thumbnails, resizable layout and display names ([`6dc8c32`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/6dc8c32))

### Fixed

- **renderer** — Drive vector material timelines and their events ([`511f59d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/511f59d))

### Performance

- **playback** — Reduce steady-state rendering and input work ([`084c054`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/084c054))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.3.2...v0.4.0

## 0.3.2 — 2026-09-17

### New

- **web** — Host web wallpapers in WKWebView with mouse input ([`42a8fd8`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/42a8fd8))

### Fixed

- **scene** — Map cursor input through the presented wallpaper ([`3bb8899`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3bb8899))
- **renderer** — Script side-effect writes, puppet animation layers, cursor coverage ([`2385923`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/2385923))

Plus 1 documentation, test and tooling commit.

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.3.1...v0.3.2

## 0.3.1 — 2026-09-16

### Fixed

- **updates** — Restore Settings About check-for-updates controls ([`3a653ec`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3a653ec))

### Other changes

- Update property-script evaluation to persist state across frames ([`169eba6`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/169eba6))
- **workspace** — Reorganize the tree and build a documentation set ([`518ff23`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/518ff23))

Plus 1 documentation, test and tooling commit.

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.3.0...v0.3.1

## 0.3.0 — 2026-09-16

### New

- **appearance** — Add light theme, system adaptation and customization ([`07ba75e`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/07ba75e))
- **downloads** — Report real transfer speed and byte progress ([`d22b49b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/d22b49b))

### Fixed

- **downloads** — Expose NetworkReceiveMeter initializer ([`fca8f87`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/fca8f87))
- **text** — Center each line inside the layer box ([`4cb3819`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/4cb3819))
- **scene** — Leave callback-only property scripts on their base value ([`8a09bd9`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8a09bd9))
- **scene** — Drive the global camera from the general.zoom animation ([`c0a9641`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/c0a9641))
- **mdl** — Keep the authored MDLS3 skeleton and pivots ([`463b4c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/463b4c4))

### Other changes

- 0.3.0 ([`fadecdb`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/fadecdb))
- Optimize continuous playback resource reuse ([`8f53466`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8f53466))
- Reduce idle wallpaper background work ([`b03f6c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b03f6c4))

Plus 2 documentation, test and tooling commits.

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.2.1...v0.3.0

## 0.2.1 — 2026-09-16

### Fixed

- **lockscreen** — Always hand the desktop back to the poster provider ([`9e21b68`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/9e21b68))
- Keep Workshop page turns off the main tab path ([`7525e25`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7525e25))

### Other changes

- 0.2.1 ([`7180677`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7180677))
- Fix presentation suspension and frame timing regressions ([`f56e00d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/f56e00d))
- Add WallpaperPresentationPolicy to suspend rendering when occluded ([`7db2382`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7db2382))

Plus 1 documentation, test and tooling commit.

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.2.0...v0.2.1

## 0.2.0 — 2026-09-15

### Other changes

- 0.2.0 ([`ccda129`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/ccda129))
- Replace native SwiftUI panels with the WebKit control panel ([`7b83b4e`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7b83b4e))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.8...v0.2.0

## 0.1.8 — 2026-09-15

### Other changes

- Hand the staging claim to SteamCMD and fail closed without it ([`180fc3c`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/180fc3c))
- Require proof nothing is writing before reclaiming staging ([`8ac6f88`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8ac6f88))
- Reclaim download staging stranded by a crash ([`eeb5e88`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/eeb5e88))
- Pin the Download Details sheet environment with an offscreen test ([`57aa2eb`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/57aa2eb))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.5...v0.1.8

## 0.1.5 — 2026-09-15

### Other changes

- Give sheet content the environment it reads ([`3987685`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3987685))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.4...v0.1.5

## 0.1.4 — 2026-09-15

### Other changes

- Drop the download mark from the private SteamCMD copy ([`15cf07f`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/15cf07f))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.3...v0.1.4

## 0.1.3 — 2026-09-15

### Other changes

- Keep the library grid out of the type checker's limit ([`59857dd`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/59857dd))
- Validate SteamCMD the way dyld does and build releases in CI ([`b0bc639`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b0bc639))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.1...v0.1.3

## 0.1.1 — 2026-09-15

### Other changes

- Fix one-click SteamCMD install for signed CLI tools and updater links ([`3a4033b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3a4033b))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.0...v0.1.1

## 0.1.0 — 2026-09-15

### Other changes

- Remove unused updater leftovers and ignore local verification artifacts ([`eb72174`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/eb72174))
- Add confirmed GitHub Release updates so installed builds can download and restart-install ([`3338eb8`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3338eb8))
- Add version bump CI triggered by release: commits ([`d882916`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/d882916))
- Improve native wallpaper workflows and SteamCMD installation ([`aa7c22c`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/aa7c22c))
- Integrate native lock-screen wallpapers and harden audio capture lifecycle ([`ecfe88f`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/ecfe88f))
- Document native verification, renderer probes, and desktop tooling ([`311ab7a`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/311ab7a))
- Queue concurrent Workshop downloads and safely adopt completed imports ([`db27a08`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/db27a08))
- Fix renderer compatibility and render-target lifetime regressions ([`e455b6b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/e455b6b))
- Publish complete project snapshot including completed agent changes ([`1fb3048`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/1fb3048))
- Publish initial source snapshot excluding concurrent agent work ([`9f33787`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/9f33787))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/commits/v0.1.0
