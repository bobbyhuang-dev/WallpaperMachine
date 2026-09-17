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
| Top bar | Sits in the window's title-bar strip beside the traffic lights: tabs on the left, product name, version and a GitHub button (opens the repository in the default browser) centered, target-display picker, downloads button and renderer-source link on the right. Its background drags the window and follows the system double-click action |
| Browser column | Search field, sort menu, filters, tile grid, result summary, Workshop pagination with an editable page number |
| Left sidebar | Workshop tag filters (Discover only). Fixed width; the arrow in its heading collapses it to a narrow rail whose arrow expands it again, and that choice is remembered across launches |
| Inspector | Preview, title, kind, creator, tags, actions, and the selected wallpaper's options and properties. Grows from 280px to 340px with the window width by default; dragging its left edge sets a width (240px to 45% of the window) that is remembered, and double-clicking the edge restores the fluid width. The edge is keyboard-focusable: arrow keys resize, `Home` resets |
| Activity bar | Pause/resume playback, import status, download progress |

Wallpapers appear as square, image-first tiles with a transparent title overlay.
Discover tiles show cached still thumbnails rather than Steam's full previews
(see [Workshop downloads](workshop-downloads.md#tile-thumbnails)).
Both tabs fill the grid with as many columns as the browser column can hold at a
minimum tile size that shrinks with the column, so a narrower window shows
smaller tiles and more of them rather than fewer, larger ones. The window
itself never shrinks below a 760×560 content area (capped by the visible screen
on small displays): `ControlPanelWindow` owns that floor and `AppDelegate`
enforces it in `windowWillResize`, because the SwiftUI hosting controller
resets `contentMinSize` once it attaches.
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

The inspector's action row also offers favorites, **Show in Finder** and moving
the wallpaper to the Trash.

## Deleting wallpapers

Deletion always moves the managed library copy to the Mac's Trash after a
confirmation sheet; imported source folders are never touched, and a wallpaper
playing on a display is ejected first.

- Single: the trash button in the inspector's action row (next to **Apply
  wallpaper**), or `Delete`/`Backspace` on a focused tile.
- Batch: **Select** in the Installed toolbar switches the grid into selection
  mode, where every tile shows a check box and clicking a tile toggles it;
  `Shift`-click extends across the visible range and **Select all** in the
  summary row selects every tile matching the current filters. Outside
  selection mode the check box appears on hover and `Cmd`-click toggles it. The
  summary row shows the count with **Clear** and **Move N to Trash**; `Delete`
  acts on the selection from the grid, `Escape` or **Done** leaves selection
  mode. One confirmation covers the whole batch, every wallpaper is trashed
  independently, the library refreshes once, and any wallpaper that could not
  be removed is reported in the error banner while the rest are gone.

## Target display

The top bar picker chooses which display Apply acts on. Disabled and mirrored
displays are listed but not selectable, annotated `(disabled)` or `(mirrored)`.
Per-display enablement, independent/mirror mode, mirror source, scaling, scale
factor, frame rate, mute and volume live in **Settings -> Displays**.

Display titles come from the renderer as `Vendor 1552 - Model 41055 (1 - Primary)`
because the vendored renderer only reads CoreGraphics vendor/model numbers.
`DisplayTitleResolver` (App/Services/Desktop) replaces that label with
`NSScreen.localizedName` — the name System Settings shows, such as
**Built-in Retina Display** — keeping the renderer's `(id - Primary)` suffix.
Renderer display ids are `primary`, a live CoreGraphics id or
`identity:{json}` (never the screen number for configured displays), so the
resolver matches the live id inside the title suffix and the identity UUID
against `NSScreenNumber` / `CGDisplayCreateUUIDFromDisplayID`. It applies to the
target picker, Settings -> Displays, mirror-source menus and the inspector's
per-display sections; a display without a matching screen (or an empty system
name) keeps the renderer label. The renderer's own titles and ids
are unchanged, so nothing persisted or sent over the bridge moves.

## Filtering

- Installed: a compact filter popover narrows the collection by wallpaper type,
  favorites only, and active-on-target; sort is Title or Type. Filtering never
  activates a wallpaper. **Clear filters** resets the popover.
- Discover: the sidebar carries the Workshop type menu and multi-select tag
  groups; sort is Trending this week, Most subscribed, Newest or Relevance.
  The arrow beside the sidebar heading collapses it to a 30px rail that keeps
  showing the active filter count; the rail's arrow expands it again.
  Collapsing never changes the search; the choice is stored natively (the
  panel's web storage is not persistent) and restored on the next launch.

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
