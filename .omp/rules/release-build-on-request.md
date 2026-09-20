---
description: Release-build MacWallpaperEngine.app when delivery is requested, not after every feature
alwaysApply: true
---

# Release build on request

A Release build takes minutes and only matters when the user is actually going to
run the new binary. Build when there is a reason to:

- the user asks to build, deliver, install, ship, package or "try it",
- the change cannot be verified any other way and the user wants it verified,
- a release, tag or version bump is being prepared.

Otherwise finish at the routine gate and state plainly that the app was **not**
rebuilt, so the running app still has the old behavior. Do not build to feel
thorough; an unrequested Release build is minutes spent on an artifact nobody
opens.

When you do build, after `python3 scripts/test.py` passes and never on a failing
tree:

- Swift / WebUI / resources / config with the current renderer and bindings:
  `python3 scripts/build.py --swift-only --configuration Release`
- Renderer, bridge or missing build outputs:
  `python3 scripts/build.py --configuration Release`

Confirm the built app actually contains the change (for WebUI, compare the
bundled `Contents/Resources/WebUI/` files with `WebUI/`). Report the delivered
path `build/Build/Products/Release/MacWallpaperEngine.app`, record the build in
`docs/testing/verification-log.md`, and remind the user to quit and reopen the
app. Never launch or quit it yourself. A failed or blocked build is not
delivery; say so explicitly.
