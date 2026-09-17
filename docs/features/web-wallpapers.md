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
  mouse input reaches the page while audio response and keyboard input do not.
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

Values are replayed to a listener that registers after the first push, so pages
that install the listener from a deferred module still start correctly. The top
frame cannot navigate away from the entry page; subframes and network requests are
unrestricted (macOS ATS applies, so plain `http://` requests fail).

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

## Not yet supported

- `wallpaperRegisterAudioListener` and the media-integration listeners are not
  installed; pages that feature-detect them run without audio response.
- Keyboard input is not forwarded; the wallpaper window never becomes key.
- Pointer events are mirrored, not captured: Finder still selects icons and
  rubber-bands, and a click on an icon reaches the page too. The middle button
  arrives without its button number.
- Per-wallpaper volume and mute are not applied to page media.
- `wallpaperRequestRandomFileForProperty` and directory properties are not
  serviced.

## Verification

`Tests/Unit/WebWallpaper/WebWallpaperPageTests.swift` drives a real offscreen
`WKWebView` (no desktop window): module loading from the project folder,
late-listener replay, pause composition, top-frame navigation lockdown, and
forwarded clicks and right clicks reaching page listeners with the native
context menu suppressed. `WebWallpaperMouseRoutingTests.swift` pins the
desktop-only routing policy.
`crates/bridge/src/tests/apply_options.rs::web_wallpaper_apply_bypasses_engine_and_exports_host_inputs`
proves the bridge contract. Desktop behavior needs an authorized manual run; see
the [verification log](../testing/verification-log.md).

Back to the [project README](../../README.md).
