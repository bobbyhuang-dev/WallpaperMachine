# MacWallpaperEngine

A native macOS Wallpaper Engine client with scene rendering and independently implemented Steam Workshop browsing and downloads.

## Source snapshot

This repository includes the current application and renderer sources, tests, project configuration, and bundled resources. The files omitted from the initial partial snapshot are now included. Build outputs, caches, local credentials, and app binaries are not published.

This is a source snapshot, not a verified binary release. No build or desktop tests were run as part of publishing it.

See `LICENSING.md` for implementation provenance, local build requirements, and unresolved distribution considerations, and `upstream/provenance.json` for upstream revisions. Upstream source retains its license and copyright notices. Publishing this source snapshot does not mean that bundled binaries or third-party wallpaper assets are cleared for distribution.

Renderer and scene-engine sources are included directly in this snapshot, rather than as Git submodules. See `LICENSING.md` for local build instructions and `TESTING.md` for verification guidance.

## Local app workflow

- Library: choose an enabled independent display in the inspector, then click an
  installed wallpaper to apply it there. Double-clicking does not close the window.
  The context menu offers inspect-only selection, favorites, Finder, and Trash.
  The sidebar includes All Wallpapers, Favorites, active-on-target, and type categories.
- Properties: audio, scaling mode, and FPS take effect immediately. Apply Changes
  saves pending properties and scaling factors; Revert discards pending changes.
  Unsubmitted text stays with its wallpaper when navigating between pages.
- Workshop: browsing needs no Steam login. Install SteamCMD in Settings or download
  setup, or locate a complete existing macOS runtime. Installation is a separate,
  no-login operation. Signature, dependency, and Rosetta checks remain required.
  Policy-blocked downloads stay at the same path across restarts and retries.
  You can follow Apple's guidance or explicitly confirm **Allow This SteamCMD**:
  the app then removes quarantine only from that verified copy and records its
  content fingerprint. Global Gatekeeper stays enabled; changed files require
  another approval. The app never re-signs SteamCMD or silently grants an exception.
- Downloads run one at a time using an account that owns Wallpaper Engine. You can
  keep browsing and reopen Download Details from the activity bar for password or
  Steam Guard prompts. Closing details does not cancel the task. Downloads do not
  subscribe on Steam or apply automatically; use Show in Library or explicit Apply.
  Scene wallpapers additionally need shared scene assets; videos do not.

The app used for local delivery is
`build/Build/Products/Release/MacWallpaperEngine.app`. Quit and reopen it after a
successful Release build. See `TESTING.md` for non-desktop verification and the
manual UI/display checklist.
