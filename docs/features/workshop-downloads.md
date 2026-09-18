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
holds exactly as many tiles as the grid shows without scrolling: the panel
measures its columns and rows and reports that size (`workshopPageSize`),
and the store cuts each page from Steam's fixed pages of 30, fetching as many as
the page spans and caching them per query, so paging back or resizing the window
rarely touches the network. Square tiles sized by the grid's width rarely divide
its height evenly, so Discover tiles may stretch or squash by up to 15% for the
rows to fill the grid exactly (a 1px shortfall would otherwise leave a whole row
blank); past that they stay square and the remainder stays empty. The width is
measured outside any scrollbar so a briefly overflowing page cannot flip the fit
back and forth. Resizing keeps the first visible tile in view by
remapping the page number. Steam's public browse page clamps every query to
1,000 pages of 30 items, so at most 30,000 results are reachable per query
(the snapshot's `reachable` count); when the result count is larger the
pagination row says so and suggests narrowing the search or filters. A left
filter sidebar groups multi-select tags:

| Group | Values |
| --- | --- |
| Resolution | 1280 x 720, 1366 x 768, 1920 x 1080, 2560 x 1440, 3840 x 2160, Dynamic resolution, Other resolution |
| Ultrawide & portrait | Ultrawide 2560 x 1080, Ultrawide 3440 x 1440, Portrait 1080 x 1920, Portrait 1440 x 2560, Portrait 2160 x 3840 |
| Genre | Abstract, Anime, Fantasy, Landscape, Nature, Pixel art, Sci-Fi |
| Age rating | Everyone, Questionable, Mature |
| Category | Wallpaper, Preset, Asset |

Selected tags are sent to Steam as `requiredtags[]`, so Steam returns only items
matching *every* selected tag. Tags that are selected but not in the known
groups are kept in an **Other selected tags** group. **Clear filters** removes
them. Results can be sorted by Trending this week, Most subscribed, Newest or
Relevance, and a type menu narrows to Scene, Video, Web or Application.

### Tile thumbnails

Steam's `preview_url` is the full-size preview, and most trending previews are
animated GIFs of roughly a megabyte each, so a page of 30 tiles weighed 20 MB
or more and stayed blank for a minute on slow links. Tiles therefore load
`mwe-ui://thumbnail/<id>` instead: the panel's scheme handler asks
`WorkshopThumbnailCache` for the item, which downloads the preview once (asking
Steam's image CDN for a 512px version, falling back to the original if the CDN
refuses the scaling query), decodes only the first frame with ImageIO, and
stores it as a JPEG under `Cache/WorkshopThumbnails` in the app-support folder.
At most four previews download at once, concurrent requests for the same tile
share one download, cache hits cost no network at all and survive relaunches,
and the folder is trimmed to 128 MB oldest-first. Only ids announced in the
current snapshot (results, queued downloads and pending requests) resolve; a
tile pulses its placeholder until its image arrives and hides a failed image.
Animation is on demand: the tile under the mouse pointer (after a short dwell,
so sweeping across the grid downloads nothing) or under keyboard focus streams
Steam's full preview over its still and fades it in once loaded, so only one
animated preview downloads at a time on any connection. The inspector keeps the
full-size preview for the selected item.

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
- Steam Guard prompts explain the method Steam asked for — mobile approval,
  authenticator code or emailed code. Steam may still require another approval.
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
shared by all waiting scenes. Steam downloads the full Windows build into
temporary storage — keep several gigabytes free — and only the shared resources
are kept afterwards. No Windows program is ever run. A resource failure does not
discard an already downloaded wallpaper; scene playback stays unavailable until
its resources are installed. The resources can also be located on disk instead
of downloaded.

Scene support is experimental; [web wallpapers](web-wallpapers.md) run in a
built-in web view; Windows application wallpapers are labeled unsupported.

**Install scene assets…** in Settings, or the same action in an installed
scene's Workshop details, starts the installation; **Locate assets…** instead
points at an existing purchased installation. Installation reuses the private
SteamCMD login and cancellation flow and requests the Windows application with
`app_update 431960 validate`. Only the validated `assets` tree is retained, at
`~/Library/Application Support/mac-wallpaper-engine/SceneAssets`; the Windows
executables are removed together with the temporary installation. Steam must
confirm that the installation completed before assets are published. An empty or
incomplete directory is rejected without replacing existing assets, and the
basic shader and material checks are not a compatibility guarantee for any given
scene. Once setup finishes, an already-downloaded wallpaper applies without
restarting the app and without downloading that wallpaper again.

## Steam sign-in

**Keep me signed in on this Mac** is enabled by default for Workshop downloads
and for scene-asset installation. After a successful authentication the app
preserves the Steam-issued cached credentials and machine-authentication files
of the last account at
`~/Library/Application Support/mac-wallpaper-engine/SteamSession`. The next
download, including after an app restart, restores only that account's cache and
pre-fills its login name. Cache directories are restricted to `0700` and files
to `0600`. Submitted passwords and Steam Guard codes are sent only to the
private terminal and are never saved. Downloaded content, runtime programs and
logs are not retained in the sign-in cache. **Forget saved Steam sign-in**, or
turning the option off, removes the local cache without signing other Steam
devices out. Steam still controls expiry, renewal, revocation and any additional
security checks, so indefinite authentication is not guaranteed.

Authentication state is preserved even when an already-authenticated download
fails or is cancelled, and a failed authentication does not replace a previously
saved account. SteamCMD's invalid-cache warning can fall back to a password
prompt; a terminal cached-credential rejection clears the stale cache before an
explicit retry. Every download still uses private temporary staging, and the
child process is stopped before that staging is removed.

**Steam Guard sign-in help** in the download form — also translated into
Simplified Chinese — covers both methods. For mobile approval, open the Steam
mobile app's shield tab for the same account and approve only the sign-in you
initiated. For an authenticator or emailed code, enter the current code in the
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

After authentication is rejected or times out, **Retry Steam sign-in** starts a
new private SteamCMD session for the selected wallpaper or asset installation
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
