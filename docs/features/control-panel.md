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
not translate third-party wallpaper content, only the two label stand-ins the
panel supplies itself (see [Properties](#properties)). Steam filter values and bridge
action identifiers remain unchanged when labels are translated. How the layers
fit together and how to add a language: [Localization](../localization.md).

## Layout

| Region | Contents |
| --- | --- |
| Top tabs | **Discover**, **Installed**, **Settings** |
| Top bar | Sits in the window's title-bar strip beside the traffic lights: tabs on the left, product name, version and a GitHub button (opens the repository in the default browser) centered, target-display picker and a downloads button (only while there is download activity) on the right. The side groups never shrink below their content, so a long display name nudges the brand off-center rather than under the controls; in windows up to 840px wide the name and version hide and only the GitHub button stays. The renderer's own repository is linked from Settings → About. Its background drags the window and follows the system double-click action |
| Browser column | Filter button, search field, sort menu, tile grid, result summary, Workshop pagination with an editable page number. On Discover a page is one Steam page of 30 square tiles (at most 1,000 pages); the grid shows as many columns as fit, never fewer than three, and scrolls the rest |
| Left sidebar | Filters on both library pages, mirroring Wallpaper Engine's sidebar: Show only, Type, Age rating, Resolution and Tags tick boxes on Discover; the same boxes minus Resolution (plus Favorites and Active in Show only) on Installed, applied to the library in the page. Fixed width; the toolbar's Filter button opens and closes it, and that choice is remembered per page across launches |
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

## First run

The first time the panel opens, a guide covers the whole window, top bar
included (`WebUI/welcome.js` + `welcome.css`; `#welcome` is fixed-position
over the app, pure black or white by the resolved appearance, and its top strip
stands in for the title bar: draggable and clear of the traffic lights). It is
a page, not a modal dialog; the download dialog can still open over it for an
unrelated job. A five-step indicator at the top names the pages and jumps
between them; every page has **Back**, and the pages that decide something have
**Skip**:

1. **Language & appearance.** Radio tiles for the language (**System (Auto)**
   plus every shipped language under its own name) and the appearance mode
   (**System (Auto)**, **Light**, **Dark**, each with a drawn miniature). A
   choice applies at once through the `languageSetting` / `themeSetting`
   actions, so the page repaints in the chosen language and theme. **Skip**
   puts back whatever was in force when the guide opened and moves on.
2. **Steam.** Explains in plain words that browsing is free and that downloading
   needs a Steam account that owns Wallpaper Engine, with **Create a Steam
   account** (`store.steampowered.com/join/`) and **Buy Wallpaper Engine** (the
   store page) beside that explanation. The form takes the account name (login
   name, not profile name), the password (with a show/hide toggle) and **Keep me
   signed in on this Mac** (on by default). **Sign in** sends only the account
   name and the remember choice (`steamSignIn`); the password is held in the
   page until Steam's own password prompt arrives on the sign-in job and is then
   submitted through `downloadInput` exactly once, so it is never part of a
   snapshot, an action payload or the DOM markup. Without SteamCMD the button
   reads **Install SteamCMD and sign in** and the page installs it first
   (`setupInstall`, with the Gatekeeper approval and locate-a-copy paths when
   they apply). Steam Guard (mobile approval, authenticator or emailed code)
   is shown with the same guides as the download dialog; **Cancel** stops the
   session. Success shows **Signed in as …** with **Use a different account**
   (`logOutSteam`); a saved sign-in from an earlier run shows the same state
   straight away. **Skip for now** (or **Skip and cancel sign-in** while one
   runs) leaves Steam for the first download to ask about. See [Steam sign-in](workshop-downloads.md#steam-sign-in)
   for the sign-in-only session itself.
3. **Preferences.** Launch at login, Pause on battery, Reduced quality on
   battery and Keep windows in place when clicking the wallpaper, as switches
   with one-line explanations. They are drafts: **Continue** commits only the
   ones that changed (`setting` actions), **Skip** discards them. Launch at
   login is disabled with its reason while the app is outside Applications;
   when renderer settings are unavailable the page says so and disables the
   switches.
4. **Tips.** Five short usage tips (Discover, download then apply, one
   wallpaper per display, import, pause) and the open-source pointer with
   **Open on GitHub** and **Report an issue** (`state.repositoryURL` and its
   `/issues` page).
5. **Start.** A recap of what the guide set (language, appearance, Steam) and
   the two ways in: **Browse the Workshop** opens Discover, **Import
   wallpapers** opens the import popover on Installed; **Start using the app**
   simply closes it.

Leaving the guide by any of the closing actions is stored natively
(`WebPanelController.welcomeSeenKey`, sent as the `welcomeSeen` action and
reported in every snapshot), so the guide is shown on its own exactly once per
Mac. **Settings → Library & Steam → Welcome guide → Show again** brings it
back from the first page; closing it then does not touch the stored flag. Every
link passes the same external-URL allowlist as every other link in the panel,
and the whole guide is translated with the rest of the UI. While the guide is
open the panel's document-level handlers stay out of `#welcome`; the guide owns
its own events, and the download dialog does not surface the sign-in job's
prompts (the guide answers them). A finished sign-in-only job is not listed as
a download.

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

- Installed: the sidebar carries Discover's boxes and rules (see below), applied
  in the page to each wallpaper: **Show only** starts with Favorites and Active
  on target display, then Approved, Audio responsive and Customizable; **Type**
  (Scene, Video, Web) reads the wallpaper's kind; **Age rating** and **Tags**
  read its `project.json`, which `LibraryMetricsService` turns into Steam's tags
  (`tags` in the snapshot: the manifest's genre tags, `contentrating`, `Approved`,
  `Audio responsive` for `general.supportsaudioprocessing` and `Customizable` for
  user properties beyond `schemecolor`); a wallpaper without a genre counts as
  Unspecified. A manifest carries no resolution or Workshop category, so those
  boxes are Discover-only. Every box starts ticked (a library hides nothing by
  default), a ticked Show only box requires its tag and an unticked box hides
  every wallpaper carrying that tag, case-insensitively; **Clear** resets the
  sidebar. Search matches titles and tags. Filtering never activates a
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

Authors write those labels as HTML, and Workshop authors use them as a layout
surface: colour tags, `<br>` runs, `<hr>` rules and image strips hosted on image
boards. The panel shows text, so a label is reduced to the words it carries —
breaks and block ends become spaces so neighbours do not merge, every other tag
drops out, and the entities the Wallpaper Engine editor emits are decoded. A
label that is only decoration reduces to nothing: a text property with no words
is left out, a control keeps its row under **Unnamed option**, and a section with
nothing left in it is not shown. The property's id is never used as a name — the
editor derives ids from the markup, so they read as `imgsrchttpphoto…`.

Audio, scaling mode and frame rate take effect immediately. Everything else is
pending until committed:

- **Apply changes** saves pending properties and scaling factors.
- **Revert** discards pending changes.

Unsubmitted text stays with its wallpaper when navigating between pages.

A `scenetexture` property's image picker fills the material slot that names it,
so a wallpaper built around "choose your own picture" shows the picture. The
choice takes effect on **Apply changes**, which reloads the scene; the picker
stores the path, not a copy, so moving or deleting the file leaves that slot on
the artwork the author shipped. A picture outside the app's own storage is not
readable from the sandboxed lock-screen extension, which keeps the authored
texture there.

## Downloads and import

Discover tiles show their own download ring (progress, cancel, sign-in needed,
retry). Before any bytes move, the ring sweeps and names the current SteamCMD
step inside it (Preparing, Connecting, Updating, Signing in, Requesting) from
the job's `phase`; a transfer without a percentage yet shows its speed instead,
and after the last byte the full ring reads Finishing while the files are
validated and imported. The full status sentence stays in the tooltip, the
inspector and the downloads list. Several tiles download at once; the activity
bar sums them. The
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
