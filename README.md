# MacWallpaperEngine

A native macOS Wallpaper Engine client with scene rendering and independently implemented Steam Workshop browsing and downloads.

Choose **Download** once. If SteamCMD, sign-in, or shared scene resources are
needed, a focused setup dialog guides the next step and keeps the wallpaper request.
**Not now** closes the dialog without removing the request; resume it from Downloads.
Transfers run one at a time so each can reuse the previous job's saved Steam sign-in.
Steam may still require another approval. Quitting stops active and queued work.

Completed Workshop downloads are validated and moved atomically into the library
without copying their payload again. Fresh downloads no longer request SteamCMD’s
optional extra validation pass. These changes reduce local disk work; network
throughput still depends on Steam and your connection. Manual file imports remain
non-destructive copies.

## Audio-responsive wallpapers

For scene wallpapers with authored audio effects, select the wallpaper and turn on
**General configuration → Audio response** in the inspector. The setting is saved per
wallpaper and also applies to its mirrored displays. Capture starts only while
an enabled wallpaper is active; macOS requests system audio recording permission
at capture startup. If access is denied, check **System Settings → Privacy &
Security → Screen & System Audio Recording**, then retry the switch.

The input is sound playing in other apps, not the microphone or the wallpaper's
own playback. Wallpaper mute/volume controls remain independent. Supported paths
include shader spectrum effects, SceneScript `engine.registerAudioBuffers()` at
16/32/64 bands, and box/sphere particle emitters with audio frequency, bounds and
exponent settings. Capture is downmixed to mono, so left/right/average buffers
contain the same signal. Pre-rendered videos do not gain reactive effects, and
this does not add web-wallpaper rendering. The lock-screen extension does not
capture system audio.

Audio activation errors are reported rather than silently ignored. Capture stops
when its final wallpaper is disabled or removed. Synthetic offscreen checks cover
audio-driven shader color and SceneScript scale; live capture and desktop behavior
require a separately authorized manual check. See `TESTING.md` for evidence.

## Animated lock screen (experimental)

Apply a video or live scene, then enable **Settings → General → Animate lock
screen**. This uses a sandboxed native wallpaper extension; it does not draw
an ordinary app window over the login UI. The native desktop remains a still
frame while the existing desktop renderer continues playing. Lock-screen audio,
audio input and media integration are disabled.

The feature is off by default. macOS private APIs and wallpaper-store formats may
change. System-wide linked wallpapers or another wallpaper app can prevent
activation; the app reports the conflict instead of overwriting those choices.
“Enabled” requires the system extension to acknowledge a rendered frame.
Disabling or quitting restores native selections still owned by this app.
Assets are isolated copies (APFS clones where available), requiring additional
storage. See `TESTING.md` for the exact tested behavior and visual limitations.

## Source snapshot

This repository includes the current application and renderer sources, tests, project configuration, and bundled resources. The files omitted from the initial partial snapshot are now included. Build outputs, caches, local credentials, and app binaries are not published.

This is a source snapshot, not a verified binary release. No build or desktop tests were run as part of publishing it.

See `LICENSING.md` for implementation provenance, local build requirements, and unresolved distribution considerations, and `upstream/provenance.json` for upstream revisions. Upstream source retains its license and copyright notices. Publishing this source snapshot does not mean that bundled binaries or third-party wallpaper assets are cleared for distribution.

Renderer and scene-engine sources are included directly in this snapshot, rather than as Git submodules. See `LICENSING.md` for local build instructions and `TESTING.md` for verification guidance.

## Local app workflow

- Interface: the window is a bundled HTML/CSS/JS interface rendered by WKWebView;
  menus, windows, file pickers, and security confirmations remain native. Top tabs
  switch between Discover, Installed, and Settings, alongside the product name and
  version, the current target display, downloads, and a link to the renderer source.
  Wallpapers appear as square image-first tiles with a transparent title overlay;
  the right inspector shows the preview, title, kind, tags, actions, and the
  selected wallpaper's options and properties.
- Installed: choose an enabled independent display as the target, then select a
  wallpaper. Selecting a tile only selects it — **Apply wallpaper** (or **Reapply
  wallpaper** for the active one) activates it on that target, and double-clicking
  activates it too. Double-clicking does not close the window. The inspector also
  offers favorites, Show in Finder, and Trash. A compact filter popover narrows the
  collection by type, favorites, and active-on-target; filtering never activates a
  wallpaper.
- Properties: audio, scaling mode, and FPS take effect immediately. Apply changes
  saves pending properties and scaling factors; Revert discards pending changes.
  Unsubmitted text stays with its wallpaper when navigating between pages.
- Discover: browsing the Workshop needs no Steam login. A left filter sidebar groups
  multi-select tags — resolution, ultrawide/portrait, genre, age rating, and category
  — and queries Steam with `requiredtags[]`, so Steam returns only items matching
  every selected tag; Clear filters removes them. A download can guide you through
  installing SteamCMD or locating an existing macOS runtime. Setup also remains
  available in Settings. Installation itself needs no login; pending download
  requests continue when their prerequisites are met. Signature, dependency, and
  Rosetta checks remain required.
  Official signed SteamCMD is a command-line tool, so one-click Install does not
  wait for an extra Allow step after Valve's signature checks pass. Copies that
  Gatekeeper actually rejects stay at the same path across restarts and retries.
  You can follow Apple's guidance or explicitly confirm **Allow This SteamCMD**:
  the app then removes quarantine only from that verified copy and records its
  content fingerprint. Global Gatekeeper stays enabled; changed files require
  another approval. The app never re-signs SteamCMD or silently grants an exception.
- Downloads appear in a compact popover from the toolbar or bottom activity bar.
  Each transfer uses a private SteamCMD session and an account that owns Wallpaper
  Engine. Additional requests wait in order; only one transfer authenticates or
  downloads at a time, so a queued job can reuse the sign-in the previous one saved.
  Passwords and Steam Guard codes belong to that exact job.
  Closing the popover or sign-in dialog does not cancel work. Removing a waiting
  request prevents it from starting; cancelling the active transfer releases the
  next queued item after session cleanup. Quitting stops all transfers.
  Downloads do not subscribe on Steam or apply automatically; use Show in library,
  then Apply. Scene wallpapers request explicit consent before downloading missing
  shared resources, with one resource job shared by waiting scenes. Videos skip
  that step. A resource failure does not discard an already downloaded wallpaper;
  scene playback remains unavailable until its resources are installed.
  A download interrupted by a crash leaves staging behind; the app reclaims only
  staging directories it can prove nothing is writing to.

The app used for local delivery is
`build/Build/Products/Release/MacWallpaperEngine.app`. Quit and reopen it after a
successful Release build. See `TESTING.md` for non-desktop verification and the
manual UI/display checklist.

## Versioning

App and lock-screen extension versions are `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `project.yml`. Push to `main` with this commit
format (subject, a body line, or a squash-merge title) to bump them:

- `release: patch` — 0.1.0 → 0.1.1
- `release: minor` — 0.1.0 → 0.2.0
- `release: major` — 0.1.0 → 1.0.0
- `release: 1.2.3` or `release: v1.2.3` — set that marketing version (must not go backwards)

The Version workflow updates `project.yml` and the generated Xcode project,
increments the integer build number, commits `chore: bump version to x.y.z`,
and tags `vx.y.z`. Several `release:` lines in one push take an explicit
`x.y.z` if present, otherwise the highest of major / minor / patch.

Run the same bump locally with `python3 scripts/bump_version.py --spec patch --apply`,
or from **Actions → Version → Run workflow**. The workflow needs permission to
push to `main` (contents write, and branch protection must allow GitHub Actions).

Tagging `vx.y.z` publishes a GitHub Release. The Version workflow calls the Build
workflow for the tag it just pushed, because a tag pushed with `GITHUB_TOKEN` never
starts another workflow; a hand-pushed tag goes through the Release workflow instead.
Build runs on a `macos-26` runner, produces `MacWallpaperEngine-x.y.z-arm64.zip` with
`scripts/build.py` and `scripts/package.py`, and uploads it to the release. Settings →
About checks that release, downloads the zip after confirmation, and restart-installs
an Applications copy; with no asset the app opens GitHub Releases for a manual update.
