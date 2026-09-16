# Animated lock screen (experimental)

The app can animate the macOS lock screen. The feature is off by default.

## Enabling it

Apply a video or live scene to a display, then enable **Settings -> General ->
Animate lock screen**. A status row next to the switch reports the current
state, and a **Retry** action appears when activation failed.

This uses a sandboxed native wallpaper extension — the
[`Extension/`](../../Extension) ExtensionKit target — rather than drawing an
ordinary app window over the login UI. While it is active the native desktop
remains a still frame, while the existing desktop renderer keeps playing.
Lock-screen audio, audio input and media integration are disabled; see
[Audio response](audio-response.md).

"Enabled" is not claimed optimistically: it requires the system extension to
acknowledge a rendered frame.

## Caveats

- Lock-screen animation uses private macOS wallpaper APIs and wallpaper-store
  formats that may change; it may stop working after an OS update, and rendering
  is not guaranteed on every macOS release.
- It replaces the Desktop and Idle provider on active wallpaper displays and
  reloads the wallpaper service.
- System-wide linked wallpapers, or another wallpaper app, can prevent
  activation. The app reports the conflict instead of overwriting those choices.
- Playback respects the pause and battery settings.

## Turning it off

Disabling the feature or quitting the app restores the native selections that
are still owned by this app. Wallpaper changes made elsewhere are preserved.

## Storage

Lock-screen assets are isolated copies, using APFS clones where available. They
still require additional disk space.

## Verification

See [Testing](../testing/README.md) for the exact tested behavior and visual
limitations, and the [verification log](../testing/verification-log.md) for
recorded runs.

Back to the [project README](../../README.md).
