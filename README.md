# MacWallpaperEngine

A native macOS Wallpaper Engine client with scene rendering and independently implemented Steam Workshop browsing and downloads.

## Initial source snapshot

This repository currently contains a **partial source snapshot**, not a buildable release. Files involved in concurrent wallpaper synchronization and renderer work were deliberately left out of the initial commit, along with other recently modified files. Local working copies were not changed. Generated build products, local wallpaper assets, and app binaries are not published.

See `LICENSING.md` for implementation provenance, local build requirements, and unresolved distribution considerations, and `upstream/provenance.json` for upstream revisions. Upstream source retains its license and copyright notices. Publishing this source snapshot does not mean that bundled binaries or third-party wallpaper assets are cleared for distribution.

Renderer and scene-engine sources are included directly in this snapshot, rather than as Git submodules. Build instructions in the existing documentation require the omitted work-in-progress files and resources and are not yet reproducible from this snapshot alone.
