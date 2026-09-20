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

`AdapterSystemMediaProvider` runs the pinned BSD-3-Clause
`upstream/mediaremote-adapter` stream through `/usr/bin/perl`. Xcode builds and
embeds `MediaRemoteAdapter.framework` without linking it into the application;
the Perl entry point loads it in its own process. This accommodates the private
MediaRemote interface's restrictions on direct application access since macOS
15.4. It is still a private interface and future OS changes can make it
unavailable. The app does not invoke the adapter's playback commands or its
test client, which would create a synthetic system Now Playing session.

The stream runs only while a host has consumers. Complete JSON snapshots are
decoded with an 8 MiB pending-input bound. Artwork is downscaled to 256 pixels;
track changes clear stale covers, canceled subscriptions ignore late messages,
and a failed helper stops without an automatic restart loop. Toggle integration
off and on to retry. A playing timeline is interpolated from the reported
position, timestamp and playback rate, bounded by duration.

Web wallpapers receive the existing `wallpaperRegisterMedia*Listener` events.
`SceneMediaCoordinator` checks for opted-in running scene wallpapers once a
second, subscribes on demand, and delivers snapshots through the bridge and
core actors. The bridge rechecks consent before delivery. SceneScript receives
`mediaStatusChanged`, `mediaPropertiesChanged`, `mediaPlaybackChanged`,
`mediaTimelineChanged` and `mediaThumbnailChanged`; the cover updates
`$mediaThumbnail`, retaining the preceding cover in `$mediaPreviousThumbnail`
for authored transitions. Clearing artwork clears both textures. Repeated artwork does not rebuild the scene graph, and a
recreated renderer receives the current snapshot again. The lock-screen
extension does not load the provider or adapter.

## Verification

`AdapterSystemMediaProviderTests` uses a fake stream to cover fragmented JSON,
timeline progression, paused playback, missing artwork, empty players,
consumer lifetime, late callbacks and unexpected exit. Rust bridge tests cover
consent, disabling/clearing, invalid states, nonfinite times and artwork bounds.
`scenescript_media_event_smoke` and `media_thumbnail_texture_smoke` exercise
script delivery and runtime textures without invoking a real player.

Live Spotify, Apple Music, browser and local-player integration requires an
explicit desktop run. Passing the simulated tests is not proof that a particular
player or OS version publishes all fields.
