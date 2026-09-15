# MacWallpaperEngine

A native macOS Wallpaper Engine client with scene rendering and independently implemented Steam Workshop browsing and downloads.

Workshop supports three simultaneous downloads, with additional requests queued in
the order added. Close wallpaper details to keep browsing; the Downloads panel
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
