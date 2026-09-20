# Music information in wallpapers

Enable **Media integration** in a scene or web wallpaper's inspector to share
the system's current song title, artist, album, artwork and available timeline.
It is off by default. The wallpaper must contain its own music display; this
setting does not add an overlay to arbitrary wallpapers.

The source is macOS Now Playing. Spotify, Apple Music, browsers and local media
players can supply data through it. An MP3 is supported through the application
playing it, provided that application publishes Now Playing information. Only
the current system player is reported, not every audible tab or application.
Missing metadata or artwork is not invented. Changing to a track without a
cover, stopping playback, or disabling integration clears the previous data.
This feature does not capture audio and does not control playback.

## Implementation

`DesktopMediaSession` owns one `SystemMediaProvider` and fans events out to
every desktop consumer that has the setting on. Web wallpapers attach through
`WebWallpaperHost`; scene wallpapers attach through `SceneMediaSink`. Neither
constructs a second player subscription.

The primary provider is `AdapterSystemMediaProvider`. It runs the pinned
BSD-3-Clause `upstream/mediaremote-adapter` stream through `/usr/bin/perl`.
Xcode builds and embeds `MediaRemoteAdapter.framework` without linking it into
the application; the Perl entry point loads it in its own process. This
accommodates the private MediaRemote interface's restrictions on direct
application access since macOS 15.4. It is still a private interface and future
OS changes can make it unavailable. The app does not invoke the adapter's
playback commands or its test client, which would create a synthetic system Now
Playing session.

If the adapter cannot answer, and only then, `FallbackSystemMediaProvider`
asks the music players that are **already running**. Membership is decided from
`NSWorkspace.runningApplications` by bundle identifier (`com.apple.Music`,
`com.spotify.client`): an Apple Event sent to an application that is not
running launches it, and a wallpaper must never start the user's music player.
The first running player with a loaded track wins, and the first query to it
can prompt macOS Automation permission. The app declares
`NSAppleEventsUsageDescription`; without it macOS refuses every Apple Event
before the Automation prompt can appear.

The stream runs only while a host has consumers. Complete JSON snapshots are
decoded with an 8 MiB pending-input bound. Artwork is downscaled to 256 pixels;
track changes clear stale covers, canceled subscriptions ignore late messages,
and a failed helper stops without an automatic restart loop. Toggle integration
off and on to retry. A playing timeline is interpolated from the reported
position, timestamp and playback rate, bounded by duration.

Consent is the only thing that starts a source.
`WallpaperBridge.systemMediaSceneHandles()` names the applied desktop Scenes
that have the setting on, and the host starts and stops its provider from that
answer plus web consumers, so a machine where every wallpaper has it off never
loads the adapter, never sends an Apple Event and is never asked for Automation
permission. A scene the host has not fed yet — a replacement wallpaper, a newly
lit display, a rebuild — is replayed the current state instead of waiting for
the track to change.

The lock-screen extension does not load the provider or adapter. Lock-screen
scenes force the setting off after apply, even if the stored desktop config has
it on.

## Scene wallpapers

A Scene wallpaper gets events when it is applied to a display and its own
setting is on. `SceneMediaSink` forwards SceneScript
`mediaStatusChanged`, `mediaPropertiesChanged`, `mediaPlaybackChanged`,
`mediaTimelineChanged` and `mediaThumbnailChanged`. JSON is forwarded
verbatim so `subTitle`, `albumArtist`, `genres` and `contentType` are not
dropped. `MediaPlaybackEvent.PLAYBACK_PLAYING` / `PAUSED` / `STOPPED` are
0 / 1 / 2. Color arrays are exposed as `Vec3` (`.x` / `.y` / `.z`). Artwork is
uploaded as RGBA before `mediaThumbnailChanged` so `$mediaThumbnail` is valid
when the script reads it.

Two cover slots exist. `$mediaThumbnail` is the current cover;
`$mediaPreviousThumbnail` is the one it replaced, which is what a wallpaper
cross-fades from. Both are 1×1 transparent before any track, so a layer that
binds either always has an image. The previous slot is an alias of the image
the current slot used to hold, not a second copy. Clearing artwork clears both
textures. Repeated artwork does not rebuild the scene graph, and a recreated
renderer receives the current snapshot again.

A wallpaper's own transport buttons call `engine.openUserShortcut` with the
name of one of its `usershortcut` properties. The engine resolves that property
against the wallpaper's own declarations -- naming another throws -- and reports
the request with the property's **value**, which is the user's choice. The
property reaches the panel as a picker offering no action, play / pause, next
track and previous track; it defaults to no action, so a button does nothing
until its user binds it.

`WallpaperBridge.next_user_shortcut` long-polls for those presses and drops any
from a wallpaper the user has not consented to media integration for. The app
carries the bound action out through whichever media provider is currently
answering, so a command cannot land on a player that is not the one being
reported.

### Rendering one without a desktop

`offscreen_scene_probe` takes the same events the app would send, so a media
wallpaper can be rendered and inspected without a system media source or
Automation permission. Add these to the probe's usual
`WE_TEST_PROJECT` / `WE_TEST_ASSETS` / `WE_TEST_OUTPUT`
(see [renderer testing](../testing/renderer.md)):

```sh
WE_TEST_MEDIA_ARTWORK="512x512:e8503a" \
WE_TEST_MEDIA_EVENTS='[{"type":"mediaPropertiesChanged","title":"Track"},
                       {"type":"mediaPlaybackChanged","state":0},
                       {"type":"mediaTimelineChanged","position":71.5,"duration":354}]'
```

`WE_TEST_MEDIA_EVENTS` is a JSON array of SceneScript media event objects,
dispatched in order; `WE_TEST_MEDIA_ARTWORK` is `<width>x<height>:<rrggbb>` and
publishes one opaque cover through the same path the app uses.

## Web wallpapers

Web delivery is unchanged: listeners on `window`, PNG data-URL artwork, and the
constants under `window.wallpaperMediaIntegration`. The status listener reports
the user's own setting, not the system's capability. With the setting on and no
provider available, status stays `enabled: true` while properties are empty,
playback is `PLAYBACK_STOPPED`, and the timeline listener does not fire at all.
See [Web wallpapers](web-wallpapers.md).

## Verification

`AdapterSystemMediaProviderTests` uses a fake stream to cover fragmented JSON,
timeline progression, paused playback, missing artwork, empty players,
consumer lifetime, late callbacks and unexpected exit.
`FallbackSystemMediaProviderTests` covers the adapter-to-AppleScript switch.
Rust bridge tests cover consent, disabling/clearing, invalid states, nonfinite
times and artwork bounds. `scenescript_media_event_smoke` and
`media_thumbnail_texture_smoke` exercise script delivery and runtime textures
without invoking a real player.

Live Spotify, Apple Music, browser and local-player integration requires an
explicit desktop run. Passing the simulated tests is not proof that a particular
player or OS version publishes all fields.
