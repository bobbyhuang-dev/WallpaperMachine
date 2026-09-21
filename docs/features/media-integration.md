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

Listening and consuming are separate votes, counted in separate key spaces.
`WebWallpaperHost` registers one listener for all of its pages and then counts
consumers per page, so a listener key is never itself a consumer key: the relay
hands every event to every listener, and a listener with nothing to feed drops
it. `SceneMediaSink` does exactly that while its scenes are paused or
suspended, so no cover is copied, no JSON encoded and no bridge call made for a
surface nobody can see. Its deliveries are also chained rather than raced: the
engine shows whatever arrives last, so a cover the engine is slow with must not
be overtaken by the one that replaced it. A delivery already inside the engine
when the scene pauses cannot be taken back, but everything after that await is
retired — decided by a counter that only moves forward on demand changes, since
a flag would read "consuming" again the moment the scene resumed. Each listener
holds a strong token and derives its key from it, because an `ObjectIdentifier`
taken from a temporary is an address the next allocation may reuse.

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

Consent is the only thing that starts a source, and presenting is the only
thing that keeps it running. `WallpaperBridge.systemMediaSceneHandles()` names
the applied desktop Scenes that have the setting on **and** are actually
presenting; the host starts and stops its provider from that answer plus web
consumers, so a machine where every wallpaper has it off never loads the
adapter, never sends an Apple Event and is never asked for Automation
permission. Pausing playback, a battery or power-policy suspend, a global
presentation suspend and a single occluded display each remove their scenes
from that answer, which releases the adapter process, its timeline ticker and
every fan-out once nothing visible is left — a web wallpaper that is still on
screen keeps its own vote. The last state is kept, not queued: resuming makes
those handles new again and replays the current state once.

`systemMediaConsentHandles()` is the separate question of what the user
permitted, and it does not shrink when playback stops. An incoming
`engine.openUserShortcut` is judged against that, because a button press must
be refused for want of permission, never for want of presentation.

A scene the host has not fed yet — a replacement wallpaper, a newly lit
display, a rebuild — is replayed the current state instead of waiting for the
track to change.

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

A new cover is pixels, not a new scene. `PublishSystemMediaArtwork` replaces
the image behind `$mediaThumbnail` and moves the outgoing one to
`$mediaPreviousThumbnail`; each renderer notices the version move and swaps the
texture on its next frame — Vulkan from the pass's per-frame update, Metal from
`refreshRuntimeImages`. The render graph is not rebuilt for it, so a track
change no longer idles the GPU, destroys every pipeline, drops every uploaded
texture and reopens every video. A cover is also the one command excluded from
the blanket "any command may have changed the frame" wake, because it is the
one that routinely carries no change: publishing a cover byte-identical to the
one already showing does nothing at all, not even ask for a frame, which is
what makes the replays above free and stops a wallpaper cross-fading a cover
into itself.

Two cover slots exist. `$mediaThumbnail` is the current cover;
`$mediaPreviousThumbnail` is the one it replaced, which is what a wallpaper
cross-fades from. Both are 1×1 transparent before any track, so a layer that
binds either always has an image. The previous slot is an alias of the image
the current slot used to hold, not a second copy. Clearing artwork clears both
textures. Repeated artwork does not rebuild the scene graph, and a recreated
renderer receives the current snapshot again.

Because the previous slot is an alias, both names resolve to one cached
texture until the next change. A binding therefore shares ownership of the
image it samples rather than borrowing a handle from the cache: replacing
either name retires that name, and the image itself is released only when the
last binding using it lets go. Without that, whichever of the two bindings
refreshed second would free the image the first had just bound to, and the
first would never refresh again — its own key had not changed.

A wallpaper's own transport buttons call `engine.openUserShortcut` with the
name of one of its `usershortcut` properties. The engine resolves that property
against the wallpaper's own declarations -- naming another throws -- and reports
the request with the property's **value**, which is the user's choice. The
property reaches the panel as a picker offering no action, play / pause, next
track and previous track.

An author ships these empty, because Wallpaper Engine has the user bind them
in its own editor. Honouring that literally leaves every transport button dead
until its user finds the picker, so an unbound shortcut starts on the action
its own name states -- `playpausebutton`, `nextsongbutton` and
`previoussongbutton` begin bound to play / pause, next and previous. A name
that says nothing stays unbound rather than guessing. This is a starting value
only: the user's choice is stored as an override and always wins, including
choosing no action, and dispatch still carries the **value**, never the name,
so rebinding a button really rebinds it.

That default has to be sent to the scene engine, which parses the project file
for itself and would otherwise read the author's empty value however the panel
shows the binding. A host-supplied default is therefore included in the scene's
property overrides even when the user has none of their own, with the user's
overrides applied on top.

A button's release is delivered to whatever took its press, wherever the cursor
has since gone, rather than being hit-tested again on the way up. These buttons
scale themselves down while held -- this one to a tenth of its size -- and
restore themselves from `cursorUp`, so re-testing the layer loses the release
for exactly the buttons that need it: the press moves them out from under the
cursor, and they stay shrunk for good. Anything that did not take the press
still has to be under the cursor to hear a release, and a scene-wide script
with no layer of its own still hears one from anywhere.

`WallpaperBridge.next_user_shortcut` long-polls for those presses and drops any
from a wallpaper the user has not consented to media integration for. The wait
belongs to `SceneMediaSink`, which is the object that already holds the one
live session, so the command goes to whichever provider is actually answering
and cannot land on a player that is not the one being reported.

Each hop of a press is logged, which is proportionate because a press is a rare
and deliberate act: what `openUserShortcut` resolved the property to, whether it
crossed the main looper with a callback installed, whether consent dropped it,
and what was finally carried out. Without that trail an unbound button, a
request that never reached the host and a command nothing executed all look
exactly alike.

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
