# Workshop browsing and downloads

Workshop browsing and downloading are implemented independently of the Steam
client. Browsing needs no Steam login; downloading does, because Steam enforces
that the account owns Wallpaper Engine.

The bundled Aurora Drift wallpaper can be applied immediately from Library
without any download. Public browsing also needs no Steam Web API key.
Credentials for a download are entered only in the app's own local prompts.

## Discover

The **Discover** tab searches the Workshop and pages through results. A left
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

## One decision per download

Choose **Download** once. If SteamCMD, a Steam sign-in, or shared scene
resources are still needed, a focused dialog guides the next step and keeps the
wallpaper request. **Not now** closes the dialog without removing the request;
resume it from Downloads with **Continue setup**.

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

Downloads appear in a compact popover from the toolbar or the bottom activity
bar. Each transfer uses a private SteamCMD session and an account that owns
Wallpaper Engine.

- Transfers are serialized: only one job authenticates or downloads at a time,
  so a queued job can reuse the sign-in the previous one saved. Additional
  requests wait in order.
- Passwords and Steam Guard codes belong to that exact job; the dialog seeds the
  account per request, so switching requests cannot submit another one's
  sign-in. A submitted secret is cleared from the field immediately and is not
  retained by the panel. **Change account** cancels that job and hands the same
  intent back at the sign-in step.
- Steam Guard prompts explain the method Steam asked for — mobile approval,
  authenticator code or emailed code. Steam may still require another approval.
- Closing the popover or the sign-in dialog does not cancel work. Removing a
  waiting request prevents it from starting. Cancelling the active transfer
  releases the next queued item after session cleanup. Quitting stops active and
  queued work.
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
