# Manual release smoke checklist

**This checklist is manual and is not automated.** Every item below controls the
desktop, opens application windows, changes the user's wallpapers, signs in to
Steam, or grants system permissions, so each run requires an explicit user
decision. It is not part of routine verification (see
[README.md](README.md)) and no agent may perform it without an explicit request.

Perform the checks yourself when preparing a release, using disposable imports
where needed. Note any check skipped for unavailable hardware or assets. Restore
your original wallpaper configuration afterwards.

These visual and OS-integration checks are not proven by passing native tests.
Keep UI wiring, window behavior, and visible rendering explicitly unverified
when no manual or explicitly requested desktop check was performed.

## Launch and window

- [ ] One library window opens, the starter wallpaper is visible, and there are
      no blank floating panels.
- [ ] Switch between the Discover, Installed and Settings tabs and through the
      six Settings categories: General, Appearance, Displays, Library & Steam,
      Storage, About.
- [ ] Command-comma reuses the existing window.
- [ ] Close and reopen the window without quitting or crashing.

## Appearance

- [ ] Choose Light and Dark, then System, and change the macOS appearance.
- [ ] Check the titlebar, menus, controls, dialogs, inspector and download
      popover in each mode.
- [ ] Set an accent and a surface tone; relaunch and confirm both persist.
- [ ] Try white and black accents, then Reset appearance. Wallpapers and
      playback must not change.

## Library and import

- [ ] Open and cancel Import.
- [ ] Search for a nonexistent local title, clear the search, and confirm the
      collection returns.
- [ ] Select a wallpaper and refresh: the selection survives.
- [ ] Selecting must not activate a wallpaper. Apply/Reapply and double-click
      activate it, and double-click must not close the window.
- [ ] Try invalid media and missing scene assets: actionable failures appear
      without blocking videos or losing an already downloaded scene, and a valid
      wallpaper remains usable.

## Layout and accessibility

- [ ] Check Discover and Installed at 1240×800, 960×640 and 760×560 in light and
      dark mode. The inspector stays present; panes resize without losing the
      target or the primary actions.
- [ ] Command-F, grid arrows, Return/Space, text editing and VoiceOver names
      stay correctly scoped.

## Discover, search and filters

- [ ] Search Discover, edit an unsubmitted query, then advance a page:
      pagination must still use the displayed query. Submit to switch queries.
- [ ] Navigate away and back: query, page and selection stay.
- [ ] A failed request's Retry repeats that request.
- [ ] Open and dismiss the Downloads/Import pane.
- [ ] Select tags in the filter sidebar across the resolution,
      ultrawide/portrait, genre, age-rating and category groups: results contain
      only items matching every selected tag, and Clear filters restores the
      unfiltered query.
- [ ] Filter changes never activate wallpapers.

## SteamCMD setup

- [ ] Install or locate SteamCMD in Settings → Library & Steam or the download
      setup dialog, and use the same runtime without restarting.
- [ ] Installation itself must not log in; a retained wallpaper request
      continues once its prerequisites are met.
- [ ] Official signed command-line SteamCMD finishes from Install without an
      extra Allow step.
- [ ] A blocked download remains present across relaunch and retry.
- [ ] Only confirm Allow This SteamCMD after checking the shown path and
      fingerprint and understanding the risk, and only when Gatekeeper actually
      rejects a copy. Global Gatekeeper and signature checks stay enabled;
      updated bytes require another approval.
- [ ] An official no-login installation smoke uses a disposable support root and
      the production providers, stops on any Gatekeeper, Rosetta or signature
      block, and never approves a prompt, re-signs downloaded code, or removes
      quarantine automatically.

## Download queue

- [ ] Double-click a Discover tile with SteamCMD installed and a saved sign-in:
      no dialog opens, the tile's ring fills with a percentage that matches the
      inspector's received/total bytes, and clicking the ring cancels.
- [ ] With a saved sign-in, queue at least four Workshop items: three transfer
      at once (the activity bar reads "3 downloading" with a combined speed),
      the fourth waits for a free slot, and the app log records each start.
- [ ] With no saved sign-in, queue several items: only the first prompts, the
      rest wait for the sign-in, then start silently as soon as Steam accepts
      it and before the first transfer finishes.
- [ ] Cancel an active item and check that the oldest queued item starts after
      cleanup.
- [ ] If Steam ends a session with "logged in elsewhere", the ended item goes
      back in line, the footer reads "Downloads run one at a time", and it
      retries after the running item without a click.
- [ ] Remove queued work and confirm it never starts.
- [ ] Complete one sign-in and check that the next job attempts saved-session
      reuse. Steam may still ask again.
- [ ] With no saved sign-in, the password / Steam Guard dialog opens by itself;
      Not now keeps it closed until Steam asks for something else, and the
      tile's shield reopens it. Close the Downloads popover, change search or
      page, and reopen the active transfer's sign-in dialog.
- [ ] Verify independent retry, completion and scene-resource consent.
- [ ] Saved sign-in settings stay locked until pending transfers finish;
      quitting stops all transfers.
- [ ] With setup missing, click Download, dismiss with Not now, and navigate
      elsewhere: the request remains in Downloads and Continue setup resumes it.
      Removing it prevents later automatic continuation.
- [ ] Completing setup, account and resource consent continues without another
      Start download button. Downloads do not auto-apply.
- [ ] Show in library reveals an item excluded by filters and returns to the
      original results; deleting it removes Discover's installed badge.

Synthetic-process tests do not prove Steam CDN throughput, live-account session
reuse, or visual behavior, which is why these items are manual.

## Displays and properties

- [ ] Select a target display and apply: other displays keep their assignments.
- [ ] Disconnected, disabled or mirrored targets are not silently redirected to
      primary.
- [ ] Pause/resume and relaunch: the expected wallpaper and playback state
      return.
- [ ] Leave invalid scaling text, refresh or change routes, then return: the
      text is preserved and Apply changes is disabled. Return stages only that
      field, not unrelated properties.
- [ ] Check immediate audio/FPS/scaling-mode semantics versus pending
      Apply/Revert.
- [ ] Check the Language, Clock Location and Bar Style property menus, and that
      language-row changes survive reopening the app.
- [ ] When relevant, check each connected display and sleep/wake behavior.

## Native desktop posters and Mission Control

- [ ] Create multiple Desktops, apply a video, and immediately open Mission
      Control **without** switching Desktops.
- [ ] Apply a different scene and repeat, including rapid A→B→C changes. All
      desktop thumbnails update from the new renderer's first frame, with no
      400 ms debounce or two-second sampling cooldown.
- [ ] Check the actual rendered image, not its Workshop cover, including
      Fill/Match/Stretch, scaling and flipping.
- [ ] Check different and mirrored wallpapers on connected displays,
      pause/resume, and a newly created Desktop.
- [ ] Eject a wallpaper: all Desktops recover their previous native image and
      scaling.
- [ ] Quit and reopen to check restoration journaling.
- [ ] Change a native wallpaper outside the app and verify that quitting does
      not overwrite it.

Mission Control posters are sampled still frames, not live animation. Updates
begin as soon as a rendered frame is available, but rendering, PNG encoding and
the system's thumbnail compositor still take time; zero-millisecond visual
latency cannot be guaranteed. The app uses dynamically resolved
`CGSCopyManagedDisplaySpaces` and `DesktopPictureSetDisplayForSpace` to target
all normal desktop Spaces directly, including inactive ones. It restores them on
eject and quit, preserves full native options and the old journal format, and
restores an inherited (pathless) Space, or one left on an unjournaled poster, to
its display's real wallpaper rather than leaving a poster behind. It
never switches Spaces, restarts Dock or WallpaperAgent, or edits Apple's
wallpaper plist. These are non-public APIs: if they are unavailable on a future
macOS the app logs the limitation and falls back to `NSWorkspace`'s
current-Space behavior. Originals and posters live under
`~/Library/Application Support/WallpaperMachine/DesktopPosters`. A Space change
or wake re-applies the poster that already exists and captures a new frame only
for a surface that has none. Posters no desktop shows are deleted once every
Space of their display could be read; on a display with an unreadable Space,
on the current-Space fallback and for a disconnected display, the four newest
are kept.

## Animated lock screen (experimental, opt-in)

- [ ] Enable Animate Lock Screen, then apply wallpaper A and wallpaper B without
      visiting other Spaces, and inspect every desktop thumbnail.
- [ ] Disable the feature: journaled Desktop/Idle entries are restored and PNG
      poster synchronization resumes.
- [ ] Quit with the feature enabled: the native provider is restored before
      poster restoration is attempted.
- [ ] Lock and unlock the screen and confirm the provider becomes active with
      playback unpaused.
- [ ] Do not run this alongside a competing global wallpaper manager; a conflict
      is reported and ownership-aware restoration runs instead.

macOS refuses screenshots while locked, so the final lock-screen appearance and
smoothness cannot be captured. Multi-display hardware, long-duration power use,
sleep/wake and the final settings UI have not received full visual release
verification.

## Audio responsiveness

- [ ] Use an authored audio-reactive scene, leave Audio Response enabled, and
      grant system audio recording access.
- [ ] Play and pause music in another app and check shader, script and particle
      response.
- [ ] Verify that mute affects wallpaper playback only.
- [ ] Verify that the final disabled or removed scene stops capture.
- [ ] Verify that denied permission surfaces an error.

## App update

- [ ] Settings → About shows **Check for Updates**. The application menu item
      **Check for Updates…** opens that same section.
- [ ] A live GitHub release check, the published disk image mounting and the
      replacement of the app in Applications. Update tests use fixture JSON, a
      fake client and locally made images, so this path is manual only.
- [ ] Opening the disk image shows one window without toolbar or sidebar: the
      app and Applications at their places over the background, labels readable,
      the volume icon. Dragging installs; the first launch is refused and opens
      from System Settings → Privacy & Security → **Open Anyway**.

## Cross-cutting

- [ ] Multiple displays, multiple Spaces and Mission Control posters,
      sleep/wake, quit and relaunch restoration, external wallpaper changes, and
      invalid→valid recovery.

Record each authorized desktop run as described in
[wallpaper-corpus.md](wallpaper-corpus.md), and add the outcome to
[verification-log.md](verification-log.md).
