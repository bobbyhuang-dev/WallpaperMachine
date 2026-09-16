# Control panel

The app window is a bundled HTML/CSS/JS interface rendered by `WKWebView` from
[`WebUI/`](../../WebUI), served over the app-private `mwe-ui:` scheme and driven
by [`App/Views/ControlPanel/`](../../App/Views/ControlPanel). Menus, windows,
file pickers and security confirmations stay native — the web layer never draws
a system dialog and renderer content is never loaded into the web view.

## Layout

| Region | Contents |
| --- | --- |
| Top tabs | **Discover**, **Installed**, **Settings** |
| Top bar | Product name and version, target-display picker, downloads button, link to the renderer source |
| Browser column | Search field, sort menu, filters, tile grid, result summary, Workshop pagination |
| Left sidebar | Workshop tag filters (Discover only) |
| Inspector | Preview, title, kind, creator, tags, actions, and the selected wallpaper's options and properties |
| Activity bar | Pause/resume playback, import status, download progress |

Wallpapers appear as square, image-first tiles with a transparent title overlay.
Arrow keys, `Home` and `End` move focus across the grid; `Escape` closes an open
filter disclosure or popover.

## Tabs

- **Discover** browses the Steam Workshop. See
  [Workshop downloads](workshop-downloads.md).
- **Installed** shows the local library.
- **Settings** replaces the browser with a sectioned native-feeling settings
  view (General, Appearance, Displays, Library & Steam, Storage, About).
  **About** is where in-app updates live: **Check for Updates** reads the latest
  GitHub Release, and download / restart-install happen only after confirmation.
  The application menu item **Check for Updates…** opens this section.

## Selection versus apply

Selecting a tile only selects it: the inspector updates and nothing changes on
screen. Activation is explicit.

- **Apply wallpaper** activates the selected wallpaper on the current target
  display; for the wallpaper already active there it reads **Reapply wallpaper**.
- Double-clicking a tile on the Installed tab activates it as well. Double-click
  does not close the window.
- Apply is unavailable when the target display is disabled, is mirroring another
  display, or when the wallpaper kind cannot be rendered (Web, Application,
  Unknown).

The inspector also offers favorites, **Show in Finder** and moving the wallpaper
to the Trash.

## Target display

The top bar picker chooses which display Apply acts on. Disabled and mirrored
displays are listed but not selectable, annotated `(disabled)` or `(mirrored)`.
Per-display enablement, independent/mirror mode, mirror source, scaling, scale
factor, frame rate, mute and volume live in **Settings -> Displays**.

## Filtering

- Installed: a compact filter popover narrows the collection by wallpaper type,
  favorites only, and active-on-target; sort is Title or Type. Filtering never
  activates a wallpaper. **Clear filters** resets the popover.
- Discover: the sidebar carries the Workshop type menu and multi-select tag
  groups; sort is Trending this week, Most subscribed, Newest or Relevance.

## Properties

The inspector's **General configuration** section holds mute, volume and
[Audio response](audio-response.md). **Displays** holds the per-display playback
configuration for that wallpaper. **Wallpaper properties** renders the
wallpaper's own authored controls — booleans, sliders, combo menus, colors, text
fields and image pickers, each with a **Reset** to its default.

Audio, scaling mode and frame rate take effect immediately. Everything else is
pending until committed:

- **Apply changes** saves pending properties and scaling factors.
- **Revert** discards pending changes.

Unsubmitted text stays with its wallpaper when navigating between pages.

## Downloads and import

The downloads popover opens from the top-bar downloads button or from the
activity bar, and from **Show in downloads** in the inspector. The import
popover opens from **Import** in the Installed toolbar; imports copy source
files into the library and leave the originals untouched, with a duplicate
policy of **Skip duplicates** or **Keep both copies**. Closing a popover never
cancels work.

## Verification

Panel behavior is covered by the unit and UI suites and by the manual desktop
checklist; see [Testing](../testing/README.md) and the
[verification log](../testing/verification-log.md) for current evidence.

Back to the [project README](../../README.md).
