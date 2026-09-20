# Web wallpapers

Wallpaper Engine projects with `"type": "web"` are HTML pages (`"file"` names the
entry page, usually `index.html`) that talk to their host through
`window.wallpaperPropertyListener`. MacWallpaperEngine renders them in a
`WKWebView` hosted by the app; the vendored scene renderer never opens a window
for them.

## What the user sees

- Web wallpapers import, download and apply like scene and video wallpapers, and
  their user properties (combos, sliders, colors, text, booleans) are edited in the
  same inspector. Apply pushes the committed values into the running page.
- Play/Pause, the presentation policy (occluded desktop, display sleep, session
  lock), display assignment, mirroring, and Space posters apply to web wallpapers
  the same way they apply to renderer wallpapers. Occlusion is per display: a
  window covering the wallpaper on one screen suspends that page and leaves the
  page on another screen running.
- The Workshop badge reads *Web · built-in web view*; the inspector notes that
  mouse input and audio response reach the page while keyboard input does not.
- Mouse input reaches the page: hover, clicks, drags, right clicks and scrolling
  over the desktop are mirrored into the wallpaper. Finder keeps its icons and
  the desktop keeps every system behavior, so a click on an icon also reaches
  the page. Settings › General › *Keep windows in place when clicking the
  wallpaper* turns off macOS's "Click wallpaper to reveal desktop" option (the
  same value System Settings › Desktop & Dock writes) so a click no longer
  slides every window aside.

## Host protocol

The page is loaded from `file://` with sibling-file access, matching Wallpaper
Engine's CEF host: ES modules, `fetch()` and media inside the project folder work,
and `location.protocol` is `file:`. A document-start script installs the host side:

| Call into the page | When |
|---|---|
| `wallpaperPropertyListener.applyUserProperties({ id: { value } })` | After load and after every Apply; colors are `"r g b"` floats in 0–1 as in `project.json` |
| `wallpaperPropertyListener.applyGeneralProperties({ fps })` | After load and when the display's target FPS changes |
| `wallpaperPropertyListener.setPaused(bool)` | Play/Pause, presentation suspension |
| `wallpaperPropertyListener.userDirectoryFilesAddedOrChanged(property, files)` / `userDirectoryFilesRemoved(property, files)` | A watched `fetchall` folder gained or lost files |

Values are replayed to a listener that registers after the first push, so pages
that install the listener from a deferred module still start correctly. The top
frame cannot navigate away from the entry page; subframes and network requests are
unrestricted (macOS ATS applies, so plain `http://` requests fail).

The author-facing APIs are installed on the wallpaper web view at document start.
A page may call `wallpaperRegisterAudioListener`, the five
`wallpaperRegisterMedia*Listener` functions and
`wallpaperRequestRandomFileForProperty`. `window.wallpaperMediaIntegration`
exposes the playback constants under both documented spellings:
`PLAYBACK_PLAYING` / `PLAYBACK_PAUSED` / `PLAYBACK_STOPPED` and
`playback.PLAYING` / `.PAUSED` / `.STOPPED`, with values 0, 1 and 2.

Registering a listener replaces the previous one rather than adding to it, and
each listener fires only when its own part of the state changed. A page that
registers after the document loaded is given the current state, so an
asynchronously registered listener still starts.

Audio, media and directory delivery all stop while a page is suspended and
resume when it comes back. Media state is re-derived on resume; directory
additions and removals are ordered, so they are held across the suspension and
replayed rather than collapsed.

The wallpaper web view has exactly one `WKScriptMessageHandler`, named
`mweWallpaper`, carrying listener registration and random-file requests. It is
removed when the page stops. It is not the control panel's channel; `WebUI/` is
a separate web view with its own handler.

## Runtime shape

- Rust (`crates/bridge`): `WallpaperProjectType::Web` entries are `supported`.
  `ActivationInputs::build()` routes web projects away from the scene engine and
  `build_web()` yields one `WebWallpaperDesc` per assigned display (mirrors
  included). The uniffi call `web_wallpapers()` exposes them as
  `BridgeWebWallpaper` (display id, project path, entry file, fps, paused,
  effective property values as the `applyUserProperties` payload). Active ids
  include configured web wallpapers; lock-screen scenes never do.
- Swift (`App/Services/WebWallpaper/`): `WebWallpaperHost` re-reads
  `webWallpapers()` on every snapshot and diffs it against one
  `WebWallpaperWindow` (`MWEWebWallpaperDesktopWindow`, desktop level, all Spaces,
  mouse-transparent) per display. `WebWallpaperPage` owns the `WKWebView`, the
  host script, property/pause delivery, host-side suspension and
  content-process recovery.
- Suspension does not rely on the page cooperating. `setPaused` is an optional
  listener callback, so a page can ignore it; alongside it the host suspends all
  media playback (suspend and unsuspend, so media the user had paused is not
  started by a resume) and removes the web view from the window tree, which is
  the documented condition for `WKPreferences.inactiveSchedulingPolicy`
  (`.suspend`). A snapshot taken before detaching stays on screen as a
  placeholder inside the window's container view, so the Space poster sync keeps
  identifying the surface by the same content layer, and a suspended page
  receives no pointer events. The document is never reloaded to suspend it, so
  its JavaScript state survives. How much WebKit then throttles the page is its
  own decision and has not been measured here.
- A content process that keeps terminating is restarted on a windowed budget
  with exponential backoff rather than forever; the budget returns only after a
  document has run without interruption for the stable-run threshold.
- Committed host state (properties, fps, pause) is replayed in full on every new
  document, so a reload after a crash restores the page even though nothing in
  the descriptor changed.
- Mouse input (`WebWallpaperMouseForwarder`): the windows stay mouse-transparent
  and nothing is consumed, so no Accessibility or Input Monitoring grant is
  needed. A global `NSEvent` monitor observes desktop pointer events;
  `WebWallpaperMouseRouting` forwards them only while the window the system
  would hit is below layer 0 (Finder's desktop, the system wallpaper, widgets),
  keeps a forwarded press's drags and release, and sends one exit when the
  pointer leaves the desktop. Events are rebuilt in wallpaper-window
  coordinates (`NSEvent.mouseEvent`; scroll wheels copy their `CGEvent`) and
  replayed through the responder methods. Hover has no public entry point on
  `WKWebView`, so it uses `_simulateMouseMove:`/`_simulateMouseExit:` when the
  running WebKit responds to them, and `WebWallpaperWindow` reports
  `isKeyWindow` as true because WebKit hit-tests hover only for active windows
  (the window still cannot become key, so keyboard focus is never taken).
  The host script cancels `contextmenu` defaults so WebKit's own menu never opens.
- `DesktopClickRevealPreference` (`App/Services/Desktop/`) reads and writes
  `com.apple.WindowManager EnableStandardClickToShowDesktop` for the Settings toggle.
- `WallpaperPresentationPolicy` counts both window classes when deciding whether
  a wallpaper pixel is visible; `DesktopWallpaperSync` asks a web surface for a
  `WKWebView` snapshot through the same poster request it sends to Metal layers.

## Audio response

Per wallpaper, off unless the user turns it on in the inspector's *General
configuration*. The switch is consent to capture, not a promise of delivery: the
page receives nothing until it calls `wallpaperRegisterAudioListener`, and a
wallpaper that never asks stays silent however the switch is left. The panel
reports the live state from the running host, so three cases stay distinct: the
switch is on and the page has registered a listener; the switch is on and the
page has not, which is the wallpaper's choice rather than a fault; and no
desktop wallpaper is running, in which case the panel says it cannot tell rather
than reporting an absence it never observed.

The listener receives the documented 128-float array: indices 0–63 the left
channel, 64–127 the right, low index first within a channel. Delivery is capped
at 30 Hz, skips generations the analyser did not recompute, and happens only
while the page has a registered listener, the user has audio response enabled for
that wallpaper, and the page is not suspended. One shared poller serves every
display and does not exist while nothing is subscribed; the system capture tap is
opened and closed from that same demand, and a page counts as a consumer only
once it has subscribed. Mute and volume do not affect it: a silenced wallpaper
still analyses what the system is playing.

Capture uses a CoreAudio process tap created with
`initStereoGlobalTapButExcludeProcesses:` and is genuinely two-channel — left and
right are analysed by separate FFTs. If that initialiser is absent or the created
tap reports fewer than two channels, capture falls back to a mono tap, left and
right are then equal, and nothing reports that as stereo. The spectrum's `stereo`
flag describes how the PCM was submitted, not whether the content happens to
differ. Values reaching the page are clamped to 0.0–1.0 by the renderer's
spectrum entry point; the official protocol says values may occasionally exceed
1.0 and tells pages to clamp themselves, so this is a documented deviation rather
than a match.

## Media integration

Off by default, per wallpaper. Web pages still register
`wallpaperRegisterMedia*` listeners as documented above. The now-playing source
is shared through `DesktopMediaSession` and also feeds Scene wallpapers that
have the same toggle on. Sources, lifetime, lock-screen policy and tests are
documented in [media-integration.md](media-integration.md).

The status listener describes the user's setting, independently of provider
availability. With integration enabled but no data, properties are empty,
playback is stopped and there is no timeline. An empty thumbnail string clears
the previous cover. Pages must tolerate absent metadata and timelines.

## User-selected files and folders

`file` and `directory` wallpaper properties let the page read a file the user
chose from anywhere on disk. A `WKWebView` only grants `file://` reads below the
root passed to `loadFileURL(_:allowingReadAccessTo:)`, and that root has to be an
ancestor of the entry page, so a page can never read outside its own project
folder; widening the root to a common ancestor would hand every wallpaper the
whole application-support tree. A symlink placed inside the root is resolved by
WebKit and refused, a hard link is not. Both were measured, and together they fix
the design.

- `App/Services/UserAssets/ManagedUserAssetStore.swift` holds the app's own copy of
  each chosen file under `~/Library/Application Support/mac-wallpaper-engine/UserAssets/`
  (`MAC_WALLPAPER_ENGINE_HOME` relocates it), laid out as
  `<stableWallpaperId>/<propertyId>/<assetId>/<fileName>` with a `manifest.json` per
  wallpaper. The manifest, not the wallpaper package, is the system of record: it
  records the asset id, the user's original path, the size, the modification time, a
  SHA-256 content digest, and whether the import was a file or a folder. Keying on the
  stable wallpaper id rather than the display name or entry file name is what lets an
  import survive a Workshop update or a delete-and-re-download. Importing clones the
  user's file with `clonefile` where the filesystem supports it, and copies otherwise;
  the user's original is never moved, renamed or written to.
- `App/Services/UserAssets/UserAssetStore.swift` keeps a **derived** bridge at
  `<project>/.mwe-user-assets/<propertyId>/`, as a hard link onto the store's copy when
  the project shares its volume and a byte copy when it does not. The bridge exists only
  because of the WebKit read-access rule above, and holds nothing of its own: deleting
  all of it loses nothing, because the next import rebuilds it from the manifest. Data
  flows store → bridge only. No authored wallpaper file is touched; the dot directory is
  the only thing created inside the project.
- A round-6 staging directory is absorbed into the store once, and only when the
  property's original source no longer resolves. Nothing in the old location is deleted,
  and the manifest records that the migration happened, so it never runs twice. If the
  copy or the record fails, the old staged entry is still exactly where it was and still
  loads.
  A bridge this build writes drops a hidden `.managed-by` naming the wallpaper it
  belongs to, so a different wallpaper id cannot mistake it for a round-6 staging
  directory and adopt files that are not its own. A genuine round-6 bridge has no such
  marker, which is exactly what makes it migratable.
- An asset whose original path no longer resolves but which is still in the store stays
  usable, served from the store. One that is in neither place is reported as missing —
  `assetMissing` on the property descriptor — rather than silently cleared.
- The value handed to the page is the staged absolute path with its leading `/`
  removed and `%`, `#` and `?` percent-escaped, so the page's `'file:///' + value`
  resolves. Spaces, non-ASCII, `+`, `&` and `'` are left literal, because a page
  that treats the value as a plain path must still see them.
- Only image (`jpeg jpg png pnga bmp gif svg webp`) and video (`webm ogg ogv`)
  extensions are staged, case-insensitively; a property that declares no file type
  accepts the union of the two, never an arbitrary file. A folder is read one level
  deep and capped at `UserAssetStore.defaultDirectoryFileLimit` (4096) entries;
  hitting the cap is reported rather than silently dropping files.
- A `fetchall` folder is watched with FSEvents, never polled. A burst of changes is
  debounced into a single added/removed diff, which re-stages added or rewritten
  files, drops the links for removed ones, and reaches the page as
  `userDirectoryFilesAddedOrChanged` / `userDirectoryFilesRemoved`.
- Lifetime: the store outlives the project, the bridge outlives the process, the
  in-memory index does not. `WebWallpaperHost` re-imports on next use — which is what
  rebuilds a missing bridge — and discards the store handle for a project nothing
  displays any more. Changing the pick replaces that property's assets in both places;
  clearing a property removes them from both.
  `python3 scripts/clean.py --user-assets` removes every `.mwe-user-assets` bridge in
  the imported library and the Steam workshop folder, which the app rebuilds on next
  load. `python3 scripts/clean.py --managed-user-assets` is the destructive one: it
  deletes the app's own copies, which nothing regenerates. Neither the default pass nor
  `--all` nor `--derived` reaches either of them.
- The control panel's Storage row shows the managed directory, reveals it in Finder, and
  offers a purge that reclaims only stored bytes no manifest still lists — an orphaned
  `assetId` folder, a property the manifest no longer mentions, a wallpaper folder with
  no manifest. A referenced asset is never a purge candidate, which matters most for the
  property whose original has gone and whose stored copy is now the only one.
- The lock-screen extension is sandboxed
  (`Extension/WallpaperExtension.entitlements`) and cannot read either the store or the
  bridge. For a committed **video or scene** wallpaper, the assets that wallpaper
  actually references are republished into the extension container as their own
  `Documents/revisions/<fingerprint>/` tree and the property values are rewritten to
  point at that copy; the fingerprint is taken over the recorded content digests, so an
  unchanged selection is recognised and nothing is copied again. Revisions the published
  configuration no longer names are collected after each successful publish.
  **Web** wallpapers have no lock-screen support at all: that combination is reported as
  not applicable, never as a failure.

### In the inspector

A `file` property shows a read-only field with the chosen file's own name — never
the staged path the page reads — a *Choose…* button, a *Clear* button, and the
extensions the property accepts, taken from its `fileFilter`. An absent filter
means the author declared no file-type option, which the protocol defines as both
kinds it knows, so both lists are offered.

A `directory` property adds how many files in the chosen folder the importer would
take, whether the folder holds more than the import limit, and what the wallpaper
does with them: a `fetchall` folder is handed to the page whole, an `ondemand`
folder is one the page picks from itself. The count is the panel's own measurement
of the chosen folder, applying the same screens the importer applies — first level,
accepted extensions, no hidden entries, regular files only, readable only — and it
is kept until the chosen path changes, so a folder is not walked on every
re-render. It describes the folder, never the outcome of an import the panel cannot
observe: a single entry whose link and copy both fail is skipped and logged by the
importer. A folder that cannot be read is reported as unreadable rather than as
empty.

Both persist through `setPropertyPath`; *Clear* sends `nil` and the engine writes
the property's own default back. A choice the app cannot honour — a wallpaper
folder that is missing or read-only, so nothing can be staged inside it — is
reported beside that control rather than in the window-wide banner, and the path
is not sent. `texture` and `scenetexture` properties are a separate kind: they keep
the scene texture picker they always had and are refused by the path editor.

## Not yet supported

- Keyboard input is not forwarded; the wallpaper window never becomes key.
- Pointer events are mirrored, not captured: Finder still selects icons and
  rubber-bands, and a click on an icon reaches the page too. The middle button
  arrives without its button number.
- Per-wallpaper volume and mute are not applied to page media.

## Verification

`Tests/Unit/WebWallpaper/WebWallpaperPageTests.swift` drives a real offscreen
`WKWebView` (no desktop window): module loading from the project folder,
late-listener replay, pause composition, top-frame navigation lockdown, and
forwarded clicks and right clicks reaching page listeners with the native
context menu suppressed. `WebWallpaperMouseRoutingTests.swift` pins the
desktop-only routing policy.
`Tests/Unit/Panel/WebPanelAssetPropertiesTests.swift` covers the inspector side:
what `Choose…` and `Clear` send, the refusal of a `texture` property by the path
editor, the folder measurement published to the page, and a chosen name carrying
markup reaching the DOM as text.
`crates/bridge/src/tests/apply_options.rs::web_wallpaper_apply_bypasses_engine_and_exports_host_inputs`
proves the bridge contract. Desktop behavior needs an authorized manual run; see
the [verification log](../testing/verification-log.md).

Back to the [project README](../../README.md).
