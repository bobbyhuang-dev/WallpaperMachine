---
description: Every new feature ends with a fresh Release build of MacWallpaperEngine.app
alwaysApply: true
---

# Release build after every new feature

When a task adds a new feature (new user-visible behavior, UI, setting, command or
capability — not a pure refactor, docs-only or test-only change), finish it by
producing a fresh Release build after the routine gate passes:

- Swift / WebUI / resources / config with the current renderer and bindings:
  `python3 scripts/build.py --swift-only --configuration Release`
- Renderer, bridge or missing build outputs:
  `python3 scripts/build.py --configuration Release`

The build is not a substitute for `python3 scripts/test.py`; run the gate first,
and do not build on a failing tree. Confirm the built app actually contains the
change (for WebUI, compare the bundled `Contents/Resources/WebUI/` files with
`WebUI/`). Report the delivered path
`build/Build/Products/Release/MacWallpaperEngine.app`, record the build in
`docs/testing/verification-log.md`, and remind the user to quit and reopen the
app. Never launch or quit it yourself. A failed or blocked build is not delivery;
say so explicitly.
