# Workshop browsing and downloads

Workshop browsing and downloading are implemented independently of the Steam
client. Browsing needs no Steam login; downloading does, because Steam enforces
that the account owns Wallpaper Engine.

The bundled Aurora Drift wallpaper can be applied immediately from Library
without any download. Public browsing also needs no Steam Web API key.
Credentials for a download are entered only in the app's own local prompts.

## Discover

The **Discover** tab searches the Workshop and pages through results with
previous/next buttons or by typing a page number and pressing Return. A page
is exactly one Steam page of 30 tiles, and the panel never offers more than
1,000 pages (`WorkshopStore.maxPages`, mirrored in the snapshot as `maxPages`):
the page number, the jump field and the native `workshopPage` action all clamp
to that limit. Fetched pages are cached per query, so paging back never touches
the network; a new search always starts a fresh cache. Nothing about a page
depends on the window: the grid lays its 30 tiles out in as many columns as its
width holds and scrolls the rest, so resizing only reflows the tiles and never
re-fetches or re-cuts a page. Tiles are always exactly square, on both Installed
and Discover, and there are never fewer than three per row: the grid's track
minimum is the smaller of the preferred tile size (154px, smaller in narrow
columns) and a third of the grid's width, so the 760px window minimum still
shows three columns and wider windows add columns as they fit. The grid
reserves its scrollbar gutter so the columns hold still whether or not a page
scrolls, and the column count is a pure function of the grid's width, so the
layout cannot flap. Steam's public browse page clamps every query to
1,000 pages of 30 items, so at most 30,000 results are reachable per query
(the snapshot's `reachable` count) and the page jump clamps to that. The
filter sidebar on the left (opened and closed with the toolbar's **Filter**
button, see [control-panel](control-panel.md#filtering)) mirrors Wallpaper
Engine's own sidebar, tag for tag and default for default (Installed reuses the
same boxes against the library, see
[control-panel](control-panel.md#filtering)):

| Group | Boxes | Default |
| --- | --- | --- |
| Show only | Approved, Audio responsive, Customizable | all off |
| Type | Scene, Video, Web; Wallpaper, Preset | all on |
| Age rating | Everyone (G), Questionable (PG-13), Mature (R-18) | Everyone only |
| Resolution | Widescreen (Standard definition, 1280 x 720, 1366 x 768, 1920 x 1080, 2560 x 1440, 3840 x 2160), Ultrawide (standard, 2560 x 1080, 3440 x 1440), Dual monitor (standard, 3840 x 1080, 5120 x 1440, 7680 x 2160), Triple monitor (standard, 4096 x 768, 5760 x 1080, 7680 x 1440, 11520 x 2160), Portrait monitor / phone (standard, 720 x 1280, 1080 x 1920, 1440 x 2560, 2160 x 3840), Other resolution, Dynamic resolution | all on |
| Tags | Abstract, Animal, Anime, Cartoon, CGI, Cyberpunk, Fantasy, Game, Girls, Guys, Landscape, Medieval, Memes, MMD, Music, Nature, Pixel art, Relaxing, Retro, Sci-Fi, Sports, Technology, Television, Vehicle, Unspecified genre | all on except Unspecified |

A ticked **Show only** box is sent to Steam as `requiredtags[]`, so every ticked
one must be on an item. Every other box starts ticked and unticking it sends the
tag as `excludedtags[]`: Steam drops an item carrying *any* excluded tag, so a
group with everything ticked filters nothing and unticking Anime hides every
item tagged Anime whatever else it carries. Resolution sub-groups and Tags have
**All** / **None** shortcuts. Application and Asset items are never offered, so
those two tags are always excluded (`WorkshopStore.defaultExcludedTags` holds
the out-of-the-box list: Application, Asset, Questionable, Mature,
Unspecified). A tag that is both required and excluded would empty the result,
so the required one wins and it is not sent as excluded. The toolbar's filter
count is the number of boxes that differ from the defaults; **Clear** restores
them. Results open on Most popular this year and can be sorted by Highest
rated (Steam's all-time `toprated`), Most popular today / Trending this week /
Most popular this month / Most popular this year (Steam's `trend` sort with a
`days` window of 1, 7, 30 or 365), Most subscribed, Newest or Relevance.
Steam's public browse page has no "most voted" sort; unknown `browsesort`
values silently fall back to trending, so none is offered. Wallpaper Engine's
"mobile compatible" box has no Steam tag behind it, so it is not offered.

### Tile thumbnails

Steam's `preview_url` is the full-size preview, and most trending previews are
animated GIFs of roughly a megabyte each. Tiles load `mwe-ui://thumbnail/<id>`
instead: the panel's scheme handler asks `WorkshopThumbnailCache` for the
item, which downloads the preview **once, exactly as Steam published it**, and
keeps both halves under `Cache/WorkshopThumbnails` in the app-support folder:
one still frame decoded with ImageIO and stored as a 512px JPEG (`<key>.jpg`),
and, when the preview is animated, the original bytes beside it (`<key>.anim`).
A single-frame preview gets an empty `<key>.still` marker instead.

The original is fetched on purpose. Steam's CDN serves it from its edge in
0.15–0.3 s, whereas a scaled variant (`?imw=512…`) makes the CDN re-encode the
whole GIF on a cold path: measured on 2026-09-19 at 2–5 s per tile for about a
quarter fewer bytes, 14.0 s for a cold 29-tile page at four at a time against
1.1 s for the originals at eight at a time. Asking for the scaled variant and
then the original for the animation also downloaded every animated tile twice.

Many animated previews fade in from black, so the still is not simply the
first frame: the cache measures the mean luminance of up to eight evenly spaced
frames on a 32px decode and keeps the earliest one that is nearly as bright
(at least 60%) as the brightest sample. A preview that starts bright, is dark
throughout, or is a still image keeps frame 0.

At most eight previews download at once, concurrent requests for the same tile
share one download, cache hits cost no network at all and survive relaunches,
and the folder is trimmed to 512 MB oldest-first (stills and animations age
independently; a hit keeps its entry young). Only ids announced in the current
snapshot (results, queued downloads and pending requests) resolve; a tile
pulses its placeholder until its image arrives and hides a failed image.

Nothing waits for the web view to ask. `WorkshopStore.onPreviewsAvailable`
hands every Steam page's preview URLs to `WorkshopThumbnailCache.warm` the
moment the page is decoded, and with `prefetchesNextPage` (both set by
`WebControlPanel.makeCoordinator`) the store fetches the page after the one on
show in the background, so paging forward is served from the page cache and its
tiles from disk, like paging back. A failed prefetch is silent; the page is
simply loaded normally when the user gets there.

The animation follows the stills. Discover stills load eagerly, and no
animation is requested until every still on the page has settled (loaded or
failed). After that, for each tile on screen, the panel requests
`mwe-ui://animated/<id>`, six at a time, which is normally a local read of the
`.anim` file the still pass left behind (an animation asked for while its still
is still downloading waits for that download rather than starting another). It
is fetched again, two at a time on its own lane and then kept, only when that
copy was pruned or the still predates this layout; a preview the still pass
found to be a single frame is refused without a request. The animation is
placed beneath the still, not over it. Steam's GIFs often open on, and loop
back through, black frames, so the panel samples each playing animation four
times a second on a 16px canvas (both images are served with CORS headers, so
the canvas stays readable) and fades the still out only while the animation is
at least 60% as bright as the still, fading it back in below 40%. A tile
therefore never shows black where its still was bright. Leaving the page or
flipping to another one drops the pending animation requests. The inspector
keeps the full-size preview for the selected item.

## One decision per download

Double-click a Discover tile, or choose **Download** in the inspector, once.
With SteamCMD installed and a saved Steam sign-in, nothing else opens: the
download starts and its tile reports it. A dialog appears only for what the
download cannot do alone — installing SteamCMD, the first Steam account name,
consent for shared scene resources, or a password / Steam Guard request that
Steam actually sends — and it closes by itself once Steam is satisfied.
**Not now** closes the dialog without removing the request; that exact request
stays quiet until Steam asks for something else, and the tile's shield or
**Continue setup** in the inspector or Downloads reopens it.

### Download state on the tile

A Discover tile wears its download state as a ring over its thumbnail, the
way Wallpaper Engine's own library does:

| Ring | Meaning | Click |
| --- | --- | --- |
| Percentage inside a filling ring | Transferring; the ring follows the measured bytes | Cancel the download |
| Spinning arc | Signing in, requesting the item, or transferring before any bytes can be measured | Cancel |
| Dimmed download arrow | Waiting for the download ahead of it to finish | Remove from the queue |
| Pulsing shield | Steam or setup needs you | Open the dialog |
| Retry mark | Failed or cancelled | Try again |
| Small check in the corner | Already in your library | — |

Double-clicking a tile that is already in the library applies it, as on the
Installed tab.

### Transfer progress

SteamCMD prints byte counters for `app_update` (shared scene resources) but
nothing while it fetches a Workshop item, so Workshop progress is measured
outside its output and compared with the `file_size` Steam's Workshop listing
gave for the item. While Steam reports the item as downloading, the app takes
two measures twice a second and shows the smaller: the bytes that have landed
under the private staging's `steamapps/workshop` tree (allocated blocks, so a
sparse file does not count), and the bytes the SteamCMD process has received
over the network since the transfer began, read from the same per-process
`nettop` session that supplies the speed. Steam can allocate a file's full
length before its chunks arrive, which the network total cannot overstate;
compressed chunks make the network total run slightly behind, which the tree
cannot overstate. `nettop`'s first row counts everything since the process
launched (the sign-in), so it only anchors the timeline and neither the speed
nor the total includes it. The ring and the inspector show that percentage
together with received/total bytes and the measured network speed; the last
percent is claimed only by Steam's own success line, then validation and
import follow. An item Steam lists without a size keeps the spinning arc and
the speed; if `nettop` is unavailable the tree alone is used.

Downloads never subscribe on Steam and never apply automatically. Use **Show in
library**, then Apply — see [Control panel](control-panel.md).

## SteamCMD setup

SteamCMD is Valve's command-line download tool. Installing it does not sign you
in. A download can guide you through installing it or locating an existing macOS
runtime; setup also remains available in **Settings -> Library & Steam**.
Pending download requests continue once their prerequisites are met.

Signature, dependency and Rosetta checks remain required. Because official
signed SteamCMD is a command-line tool, one-click **Install SteamCMD** does not
wait for an extra Allow step once Valve's signature checks pass. Copies that
Gatekeeper actually rejects stay at the same path across restarts and retries;
you can follow Apple's guidance, or explicitly confirm **Allow This SteamCMD**.
In that case the app removes quarantine only from that verified copy and records
its content fingerprint. Global Gatekeeper stays enabled, changed files require
another approval, and the app never re-signs SteamCMD or silently grants an
exception. A retained download that is not yet usable can be revealed in Finder
or discarded from Settings.

If the installed Valve SteamCMD package produces a damaged Breakpad framework
warning, the in-app setup flow handles it: it detects the incomplete runtime and
prepares a private complete runtime by running Valve's own updater inside
private staging. Valve's updater installs a `Breakpad.framework` whose sealed
resources no longer match its own `CodeResources`, so validation checks the code
seal dyld actually enforces — once per architecture slice, for every Mach-O
image in the runtime including that framework — instead of a bundle-wide
resource verification. The framework is checked before it is ever launched. No
signature is changed and no system security setting is disabled. Downloads then
run the prepared runtime with its bootstrap updater inhibited, so a prepared
complete runtime never self-updates mid-download: update the official runtime
and repeat setup when a newer version is needed. This is implemented in
`App/Services/Steam/SteamCMDRuntime.swift` and
`App/Services/Steam/SteamCMDSetupStore.swift`.

## The download queue

Every download also appears in a compact popover from the bottom activity bar,
and from the top-bar downloads button that is shown while there is download
activity. Each transfer uses a private SteamCMD session and an account that
owns Wallpaper Engine.

- Up to three downloads run at once (`WorkshopDownloadManager`, default
  `maximumConcurrentDownloads`), each in its own private SteamCMD session and
  staging directory with its own copy of the saved sign-in; clicking several
  tiles queues them and they fill the free slots in order without another
  click. With a saved sign-in for the account on disk every job restores it
  itself, so a batch starts together without waiting for the first job to get
  through Steam's login. Without one, the batch signs in once through the job
  at the front of the queue: the rest wait while that sign-in is in progress
  (and whenever a password or Steam Guard prompt is on screen, so prompts
  never pile up), and the worker saves the session the moment Steam accepts
  it — not only at the end of the transfer — so the waiting jobs start
  silently from it while the first transfer is still running. Every queued job
  shows why it is waiting (a free slot, the current sign-in, or the previous
  download). The app log records each start and hold reason, and for every
  session the runtime preparation, whether a saved sign-in was restored, each
  status change, the sign-in handoff and SteamCMD's exit status, so a stalled
  batch can be diagnosed from **Show download logs**.
- Sessions that cannot share a sign-in run one after another: with **Keep me
  signed in** off each job prompts on its own, and if Steam ends a session
  because the same account signed in from another of the app's sessions
  ("logged in elsewhere"), the ended job goes back in line once behind the
  running one and the queue stays serial for the rest of the app's run
  (`sessionConflictDetected`). A session Steam ends while no sibling is running
  is reported as an ordinary failure with a retry.
- The activity bar carries the running job's status, percentage and speed, or
  the batch's count, mean percentage and summed speed while several run. The
  queue footer states the slot rule.
- Passwords and Steam Guard codes belong to that exact job; the dialog seeds the
  account per request, so switching requests cannot submit another one's
  sign-in. A submitted secret is cleared from the field immediately and is not
  retained by the panel. **Change account** cancels that job and hands the same
  intent back at the sign-in step.
- The account stage is just the **Steam account name** field, the keep-signed-in
  checkbox and a note that the password and Steam Guard come next; there is no
  guide card, because the field label already says what to type. A password
  prompt is the same: identity, labelled field, actions and the footer note.
  Steam Guard stages are guide cards: a glyph, a one-line title and numbered
  steps for whichever method Steam asked for — mobile approval, authenticator
  code or emailed code. The mobile-approval steps say to answer **Steam Client**
  when the Steam app asks "Where are you trying to sign in?", because SteamCMD
  signs in as the client. Steam may still require another approval.
- When Steam accepts the sign-in the dialog does not vanish: it switches to a
  "Signed in" card with the running job's status and progress (or notes that
  shared resources download first), offers **Done** and **Show downloads**, and
  closes by itself a few seconds later. The transfer is already running on the
  tile and in the activity bar throughout.
- Closing the popover or the sign-in dialog does not cancel work. Removing a
  waiting request prevents it from starting. Cancelling a running transfer
  lets the next queued job start after session cleanup. Quitting stops active
  and queued work.
- Failed and cancelled jobs stay visible with their recovery action; completed
  jobs collapse behind **Show completed** and can be cleared.

## Shared scene resources

Scene wallpapers need shared shaders and materials from a purchased Wallpaper
Engine installation; video wallpapers do not. Scene downloads request explicit
consent before downloading missing shared resources, and one resource job is
shared by all waiting scenes. The consent stage of the download dialog
("Shared resources needed") is a choice between two full-width buttons, each
carrying its title and the one fact that decides it: **Download from Steam**
(needs a Steam account that owns Wallpaper Engine and several gigabytes free
while downloading) and **Use an existing installation** (choose its folder,
nothing downloads), with **Not now** beneath. Steam downloads the full Windows
build into temporary storage — hence the space — and only the shared resources
are kept afterwards. No Windows program is ever run; the Settings page still
says so. A resource failure does not discard an already downloaded wallpaper;
scene playback stays unavailable until its resources are installed.

Scene support is experimental; [web wallpapers](web-wallpapers.md) run in a
built-in web view; Windows application wallpapers are labeled unsupported.

**Download from Steam…** in **Settings → Library & Steam**, or **Get shared
resources** in a scene's details, starts the installation; **Locate an
installation…** (**Use an existing installation** in the dialog) instead points
at an existing purchased installation. Installation reuses the private
SteamCMD login and cancellation flow and requests the Windows application with
`app_update 431960 validate`. Only the validated `assets` tree is retained, at
`~/Library/Application Support/WallpaperMachine/SceneAssets`; the Windows
executables are removed together with the temporary installation. Steam must
confirm that the installation completed before assets are published. An empty or
incomplete directory is rejected without replacing existing assets, and the
basic shader and material checks are not a compatibility guarantee for any given
scene. Once setup finishes, an already-downloaded wallpaper applies without
restarting the app and without downloading that wallpaper again.

## Steam sign-in

The requirement itself — a Steam account that owns Wallpaper Engine — is stated
once, with registration and store links, on the panel's
[first-run guide](control-panel.md#first-run); the download dialog only asks
for what the current download still needs.

The guide can also sign in ahead of any download. `WorkshopStore.requestSignIn`
retains a `WorkshopDownloadRequest` with id `WorkshopStore.signInRequestID`
(`steam-sign-in`) that climbs the same ladder as a download — SteamCMD setup,
then the account — and never the shared-resources stage, then runs
`WorkshopDownloader.signIn`: a private SteamCMD session with `+login <account>
+quit` and no download command (`isSigningInOnly`). Steam's password and Steam
Guard prompts arrive on the job exactly as for a download and are answered
through `downloadInput`; with **Keep me signed in** the accepted session is
saved the same way, so the next download starts silently. The job takes a
queue slot like any other (`WorkshopDownloadManager.signIn`, at most one at a
time), succeeds only once Steam confirms the sign-in before quitting, and
reports "Steam sign-in" as its title; the page hides it from the downloads
list once it has finished.

**Keep me signed in on this Mac** is enabled by default for Workshop downloads
and for scene-asset installation. After a successful authentication the app
preserves the Steam-issued cached credentials and machine-authentication files
of the last account at
`~/Library/Application Support/WallpaperMachine/SteamSession`. The next
download, including after an app restart, restores only that account's cache and
pre-fills its login name. Cache directories are restricted to `0700` and files
to `0600`. Submitted passwords and Steam Guard codes are sent only to the
private terminal and are never saved. Downloaded content, runtime programs and
logs are not retained in the sign-in cache. Settings → **Library & Steam** shows
the account as **Steam account · Signed in as <name>**; **Log out…** (confirmed
natively, unavailable while downloads run) or turning the option off removes the
local cache without signing other Steam devices out. Steam still controls
expiry, renewal, revocation and any additional security checks, so indefinite
authentication is not guaranteed.

Authentication state is preserved even when an already-authenticated download
fails or is cancelled, and a failed authentication does not replace a previously
saved account. SteamCMD's invalid-cache warning can fall back to a password
prompt; a terminal cached-credential rejection clears the stale cache before an
explicit retry. Every download still uses private temporary staging, and the
child process is stopped before that staging is removed.

The sign-in dialog, and the welcome guide's Steam page, show step-by-step
Steam Guard help for whichever method Steam asked for, in every shipped
language. For mobile approval, open the Steam
mobile app's shield tab for the same account and approve only the sign-in you
initiated; if Steam asks where the sign-in comes from, choose **Steam Client**.
For an authenticator or emailed code, enter the current code in the
app's code field and submit it. Keep the download open; it continues after
verification. Never disable Steam Guard, and never share passwords,
verification codes or recovery codes. Valve's
[mobile-authenticator instructions](https://help.steampowered.com/en/faqs/view/6891-E071-C9D9-0134)
describe the supported sign-in methods, and
[email-code help](https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode)
covers delivery delays.

## Prompt and retry handling

Password and Steam Guard prompts are read without waiting for a full terminal
buffer, including prompts split across reads or arriving without a trailing
newline. Login failures are processed before credential prompts, and output is
drained before process exit is handled. The five-minute inactivity timeout is a
safety limit, not a substitute for receiving a login prompt.

After authentication is rejected or times out, **Try again** (or the failed
tile's retry) starts a new private SteamCMD session for the selected wallpaper or asset installation
and for the account name still in the form. The prior process is stopped and its
private staging removed first. Supply a password or a fresh code when Steam
asks: rejected requests are never reused, approval is never bypassed, and
retries are never automatic. If Steam reports rate limiting, wait before
retrying. Workshop content-access errors are a separate failure and offer no
authentication retry.

## Completion and recovery

Completed Workshop downloads are validated and moved atomically into the library
without copying their payload again. Fresh downloads do not request SteamCMD's
optional extra validation pass. These choices reduce local disk work; network
throughput still depends on Steam and your connection. Manual file imports
remain non-destructive copies.

A download interrupted by a crash leaves staging behind. The app reclaims only
staging directories it can prove nothing is writing to.

## Verification

See [Testing](../testing/README.md) for how download and Workshop behavior is
exercised, and the [verification log](../testing/verification-log.md) for
recorded runs.

Back to the [project README](../../README.md).
