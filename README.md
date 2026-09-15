# MacWallpaperEngine

A native macOS Wallpaper Engine client with scene rendering and independently implemented Steam Workshop browsing and downloads.

Workshop supports up to three simultaneous downloads by default, with additional
requests queued in the order added. Close wallpaper details to keep browsing; the Downloads panel
retains each item’s progress, Steam Guard prompts, retry, and cancellation controls.
Quitting stops active and queued work. SteamCMD and an account that owns Wallpaper
Engine are required; each transfer may need its own Steam Guard approval.

Completed Workshop downloads are validated and moved atomically into the library
without copying their payload again. Fresh downloads no longer request SteamCMD’s
optional extra validation pass. These changes reduce local disk work; network
throughput still depends on Steam and your connection. Manual file imports remain
non-destructive copies.

## Audio-responsive wallpapers

For scene wallpapers with authored audio effects, open the wallpaper's
**General Configuration → Audio Response** switch. The setting is saved per
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

Apply a video or live scene, then enable **Settings → Power Settings → Animate
Lock Screen**. This uses a sandboxed native wallpaper extension; it does not draw
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

- Library: choose an enabled independent display in the inspector, then click an
  installed wallpaper to apply it there. Double-clicking does not close the window.
  The context menu offers inspect-only selection, favorites, Finder, and Trash.
  The sidebar includes All Wallpapers, Favorites, active-on-target, and type categories.
- Properties: audio, scaling mode, and FPS take effect immediately. Apply Changes
  saves pending properties and scaling factors; Revert discards pending changes.
  Unsubmitted text stays with its wallpaper when navigating between pages.
- Workshop: browsing needs no Steam login. Install SteamCMD in Settings or download
  setup, or locate a complete existing macOS runtime. Installation is a separate,
  no-login operation. Signature, dependency, and Rosetta checks remain required.
  Policy-blocked downloads stay at the same path across restarts and retries.
  You can follow Apple's guidance or explicitly confirm **Allow This SteamCMD**:
  the app then removes quarantine only from that verified copy and records its
  content fingerprint. Global Gatekeeper stays enabled; changed files require
  another approval. The app never re-signs SteamCMD or silently grants an exception.
- Downloads use a bounded queue with up to three concurrent transfers by default,
  each using a private SteamCMD session and an account that owns Wallpaper Engine.
  Additional requests wait in order. Keep browsing and reopen each item's Download
  Details from Downloads or the activity bar for password or Steam Guard prompts.
  Closing details does not cancel work; cancelling one item leaves peers running,
  and quitting stops both active and queued downloads. Downloads do not subscribe
  on Steam or apply automatically; use Show in Library or explicit Apply. Scene
  wallpapers additionally need shared scene assets; videos do not.

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

Tagging `vx.y.z` also creates a GitHub Release. Settings → About can check that
release, download `MacWallpaperEngine-x.y.z-arm64.zip` after confirmation, and
restart-install an Applications copy. Attach the zip from
`python3 scripts/package.py --configuration Release` so in-app download has an
asset; without it the app opens GitHub Releases for a manual update.
