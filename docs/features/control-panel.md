# Control panel

The app window is a bundled HTML/CSS/JS interface rendered by `WKWebView` from
[`WebUI/`](../../WebUI), served over the app-private `mwe-ui:` scheme and driven
by [`App/Views/ControlPanel/`](../../App/Views/ControlPanel). Menus, windows,
file pickers and security confirmations stay native — the web layer never draws
a system dialog and renderer content is never loaded into the web view.

## Language

The app ships in English and Simplified Chinese (简体中文), including navigation,
filters, wallpaper options, download/sign-in guidance, settings, accessibility
labels, menus and dialogs. **Settings → General → Language** offers **System
(Auto)** and every shipped language, each listed under its own name:

- **System (Auto)** (default) follows the macOS language list as macOS matches
  it to the app: `zh-CN`, `zh` and `zh-Hans-TW` reach Simplified Chinese;
  Traditional Chinese and any other language fall back to English. A per-app
  choice made in **System Settings → General → Language & Region →
  Applications** is honoured the same way.
- Choosing a language switches the panel immediately, without a reload, and is
  remembered. Native menus and dialogs use the new language the next time the
  app is opened, because macOS fixes a process's localization at launch.
  Returning to **System (Auto)** hands the choice back to macOS.

Steam's own language is not involved. Unsupported languages and missing keys
fall back to English. Wallpaper titles, descriptions, creator names, custom
property labels and upstream diagnostic details remain as supplied; this does
not translate third-party wallpaper content. Steam filter values and bridge
action identifiers remain unchanged when labels are translated. How the layers
fit together and how to add a language: [Localization](../localization.md).

## Layout

| Region | Contents |
| --- | --- |
| Top tabs | **Discover**, **Installed**, **Settings** |
| Top bar | Sits in the window's title-bar strip beside the traffic lights: tabs on the left, product name, version and a GitHub button (opens the repository in the default browser) centered, target-display picker and a downloads button (only while there is download activity) on the right. The side groups never shrink below their content, so a long display name nudges the brand off-center rather than under the controls; in windows up to 840px wide the name and version hide and only the GitHub button stays. The renderer's own repository is linked from Settings → About. Its background drags the window and follows the system double-click action |
| Browser column | Filter button, search field, sort menu, tile grid, result summary, Workshop pagination with an editable page number. On Discover a page is one Steam page of 30 square tiles (at most 1,000 pages); the grid shows as many columns as fit, never fewer than three, and scrolls the rest |
| Left sidebar | Workshop filters (Discover only), mirroring Wallpaper Engine's sidebar: Show only, Type, Age rating, Resolution and Tags tick boxes. Fixed width; the sidebar button in its heading collapses it to a narrow labelled rail that expands it again when clicked, and that choice is remembered across launches |
| Inspector | Preview, title, kind, creator, tags, actions, and the selected wallpaper's options and properties. Its width is a function of the window width alone and cannot be dragged: 260px at the 760px minimum, `15vw + 146px` in between (290px at 960px, 386px at 1600px) and 420px from about 1830px on, the same on Discover and Installed. Nothing is stored, so a given window size always yields the same layout. Inside, the panel adapts to its own width: past 360px the insets widen and a display's scale factor and frame rate share a row |
| Activity bar | Pause/resume playback, import status, download progress |

Wallpapers appear as square, image-first tiles with a transparent title overlay
(Discover tiles may deviate from square by up to 15% so a page's rows fill the
grid; see [Workshop downloads](workshop-downloads.md#discover)).
Discover tiles show cached still thumbnails first and then, for tiles on
screen, play Steam's animated preview beneath the still, which only fades out
while the animation is bright (see
[Workshop downloads](workshop-downloads.md#tile-thumbnails)).
Both tabs fill the grid with as many columns as the browser column can hold at a
preferred tile size that shrinks with the column, and never fewer than three,
so a narrower window shows smaller tiles and more of them rather than fewer,
larger ones; the grid scrolls vertically for whatever rows that takes. The window
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
  view (General, Appearance, Performance, Displays, Library & Steam, Storage,
  About). **General** starts with the [Language](#language) picker.
  **Performance** holds the video backend choice, the internal render scale,
  the opt-in battery quality profile and the experimental content-pacing and
  shared-video-decode switches. See [Performance settings](performance.md).
  **About** is where in-app updates live: **Check for Updates** reads the latest
  GitHub Release, and download / restart-install happen only after confirmation.
  The application menu item **Check for Updates…** opens this section.

## Thumbnail corner marks

Installed and Discover show status marks at the thumbnail's upper-left corner:

- A pink heart identifies a local favorite, including the same item when it
  appears in Discover. Use the heart button on an Installed tile (visible on
  hover or keyboard focus), or the inspector's favorite action, to toggle it.
  This is the app's saved favorite list, not Steam-account favorites.
- A green trophy identifies **Approved** wallpapers. Discover uses Steam's
  `Approved` tag. Installed reads `approved: true` or an `Approved` tag from the
  local `project.json`, off the snapshot thread; wallpapers without that local
  metadata have no trophy. The app does not fetch missing approval metadata for
  imported wallpapers.
- Discover also retains a check for items already in the library.

Multiple marks stack vertically. On Installed they move aside when the
multi-select check appears, and the Active badge sits alongside rather than
covering them. Tile accessibility labels announce the marks; overlay colors stay
readable against artwork in both light and dark appearance.

## Selection versus apply

Selecting a tile only selects it: the inspector updates and nothing changes on
screen. Activation is explicit.

- **Apply wallpaper** activates the selected wallpaper on the current target
  display; for the wallpaper already active there it reads **Reapply wallpaper**.
- Double-clicking a tile on the Installed tab activates it as well. Double-click
  does not close the window. On Discover, double-click downloads the tile (or
  applies it once it is in the library); see
  [Workshop downloads](workshop-downloads.md#one-decision-per-download).
- Apply is unavailable when the target display is disabled, is mirroring another
  display, or when the wallpaper kind cannot be rendered (Web, Application,
  Unknown).

The inspector's heading is one centered column, laid out like Wallpaper Engine's
own sidebar: square preview, title, creator (Discover), a facts line (type, size,
subscribers), pill tags, then the actions. The primary action (**Apply
wallpaper** or **Download**) spans the full width; the row under it holds
**Show in Finder**, favorites and the trash on Installed, or **View on Steam
Workshop** on Discover.

That row ends with **Report a problem on GitHub** (warning-triangle icon). It
opens the repository's new-issue form in the browser with the wallpaper's title,
Workshop link or id, type and the app version pre-filled. Nothing is submitted by
the app; the user edits and sends the issue on GitHub. The button is hidden when
the snapshot carries no `https` repository URL.

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

Both library pages share one filter sidebar on the left of the grid (the
inspector keeps the right). Its only switch is the toolbar's **Filter** button:
the first control in the toolbar, filled in the accent colour with a funnel
glyph, the label "Filter" and, when filters are active, their count in a pill.
Open, the button reads as pressed (`aria-expanded`) beside the sidebar; closed,
the sidebar leaves the layout and the grid takes its column. The sidebar itself
has no collapse control and no rail. Each page remembers its own choice natively
(`filters` action, `filtersCollapsed` in the snapshot; the panel's web storage is
not persistent) and restores it on the next launch. Closing never changes the
search or the filters.

- Installed: the sidebar narrows the collection by wallpaper type, favorites
  only, and active-on-target; **Clear** resets it. Filtering never activates a
  wallpaper. The toolbar's sort menu offers Name, Type, Favorites, File size and
  Date added, with a direction button beside it. Choosing a key starts in the
  direction people ask for it (names A→Z; favorites, largest and newest first)
  and the button flips it; names break ties. File size is the wallpaper folder's
  total and Date added is when the folder entered the library (download or
  import), both measured off the main thread by `LibraryMetricsService` and
  re-checked only after a library reload; wallpapers not yet measured sort last.
- Discover: the sidebar is Wallpaper Engine's own filter list — Show only
  (required tags), then Type, Age rating, Resolution and Tags as tick boxes
  whose unticked entries are excluded (see
  [workshop-downloads](workshop-downloads.md)); sort opens on Most popular this
  year and offers Highest rated, Most popular today, Trending this week, Most
  popular this month, Most popular this year, Most subscribed, Newest or Relevance.

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

Discover tiles show their own download ring (progress, cancel, sign-in needed,
retry). Several tiles download at once; the activity bar sums them. The
downloads popover opens from the activity bar, from the top-bar
downloads button while downloads exist, and from **Show in downloads** in the
inspector. The import
popover opens from **Import** in the Installed toolbar; imports copy source
files into the library and leave the originals untouched, with a duplicate
policy of **Skip duplicates** or **Keep both copies**. Closing a popover never
cancels work. The Steam sign-in dialog uses a guide card (glyph plus numbered
steps) for Steam Guard stages; account and password prompts are just the
labelled field. Once Steam accepts the sign-in, it confirms that the download
is running before it closes; see
[workshop downloads](workshop-downloads.md#the-download-queue).

## Verification

Panel behavior is covered by the unit and UI suites and by the manual desktop
checklist; see [Testing](../testing/README.md) and the
[verification log](../testing/verification-log.md) for current evidence.

Back to the [project README](../../README.md).
