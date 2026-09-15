# Testing

## Routine checks

Run `python3 scripts/test.py`. This generates the Xcode project and runs only
`MacWallpaperEngineTests`, preserving a `build/Tests-*.xcresult` bundle.
The default Xcode scheme also excludes UI tests. The unit-test host skips app
startup: it does not create the control panel, initialize the renderer, or restore
wallpapers.

Existing native tests cover import validation, duplicates, cancellation, downloader
lifecycle, authentication, saved sessions, and scene-asset installation. Workshop
service tests cover search and pagination beneath the UI (two tests use live Steam
responses and therefore require network access). These remain in routine coverage.

Deterministic Workshop tests additionally cover committed-query pagination,
superseded requests, cancellation, and exact failed-request retry through the real
page parser. Editor-state tests cover locale-specific scaling, invalid raw text,
and independent wallpaper/field drafts.

SteamCMD setup tests use isolated preferences/directories, URLProtocol archives,
real system tar, and owned child processes. They cover publication/replacement,
invalid discovery, traversal/link/archive-size boundaries, network failures,
signature-policy blocking, cancellation, and no late writes. Runtime fixtures
exercise canonical macOS path aliases and nested Mach-O executable dependencies.
Fixtures do not prove that Valve's current distribution passes this Mac's policy.
An official no-login installation smoke must use a disposable support root and
the production providers, stop on any Gatekeeper/Rosetta/signature block, and never
approve a prompt, re-sign downloaded code, or remove quarantine automatically.

Approval tests operate only on isolated local fixtures: exact SHA-256 receipts,
signature/policy-failure rejection, stale candidates, changed resources, private
copies, and quarantine scope. Retained-install tests cover same-path retry/relaunch
and explicit discard. The installation-to-downloader regression launches the
published executable through the real PTY downloader and asserts imported manifest
and media bytes; it does not use a separate prebuilt runtime folder.

Control-panel layout tests measure offscreen NSHostingController proposals at
760×560, 960×640, and 1240×800, long display menus, and English/Chinese empty-state
reflow. They create no window, take no screenshot, and do not start the renderer.
They establish layout bounds, not visual or desktop-integration correctness.

Native desktop-poster tests use synthetic renderer pixels and an in-memory
workspace. They cover lossless PNG dimensions/channel order/orientation, malformed
frames, independent display/Space originals, duplicate-frame suppression, bounded
alternating frame files, relaunch recovery, external wallpaper changes, and write
failures. They never initialize the renderer or call the real wallpaper setter.

## Headless renderer regression (Lonely Cat)

The C++ tests now cover persistent shader-cache metadata, cache invalidation after
include edits, corrupt-cache recovery, parent-aware compose-background sampling,
and SceneScript AM/PM sprite-frame selection. These tests do not create a window
or Vulkan device.

`TextObjectRuntime.LonelyCatHeadlessRegression` is an opt-in local-asset diagnostic
in `text_object_runtime_test`. Set `WE_TEST_PROJECT` to Lonely Cat's `project.json`,
`WE_TEST_ASSETS` to the installed `SceneAssets` directory, and `WE_TEST_CACHE` to a
**disposable build-directory cache**, then run the binary with
`--gtest_filter=TextObjectRuntime.LonelyCatHeadlessRegression`. Add
`WE_TEST_EXPECT_WARM=1` for a second run to assert zero shader compilations.
It parses the package, ticks scripts, and constructs the render graph; it does not
initialize playback, capture the desktop, or modify the imported wallpaper.

The renderer test build requires `cargo build -p shader --features ffi --release`
and CMake `BUILD_TESTS=ON`, `RUST_SHADER_FFI=ON`, and `RUST_SHADER_STATICLIB` pointing
to `upstream/renderer/target/release/libshader.a`. Use the Homebrew environment from
`scripts/build.py`. Current binaries/evidence live under
`build/verification/renderer-tests` and `build/verification/lonely-cat-*.log`.

Known pre-existing extended-suite failure:
`ScriptRuntimeCompat.HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors`
references undeclared `scriptProperties`. It also fails with the original
`ScriptEngine.cpp`; it is not a regression from the Lonely Cat fixes. The other
27 script compatibility tests, 45 scene schema tests, 57 text tests, and shader
cache regression pass. Native app tests remain the routine gate above.

## Optional desktop automation

The existing `UITests/MacWallpaperEngineUITests.swift` suite is retained only as an
opt-in diagnostic tool: `python3 scripts/test.py --ui`, or the
`MacWallpaperEngineUI` Xcode scheme. It controls the desktop and is neither part of
routine verification nor a required release gate. Agents must not run it without
an explicit user request. No Peekaboo scripts or requirement were found in this
project when this policy was introduced.

## Manual release smoke checklist

Perform these checks yourself when preparing a release, using disposable imports
where needed. Note any checks skipped for unavailable hardware or assets.

- Launch: one library window, starter wallpaper visible, no blank floating panels.
- Navigate Library, Workshop, Display, and Settings. Command-comma should reuse
  the existing window. Close and reopen the window without quitting or crashing.
- Open and cancel Import. Search for a nonexistent local title, clear the search,
  and confirm the collection returns. Single-click a wallpaper and refresh:
  selection should survive. Double-click must not close the window.
- Check Library/Workshop at 1240×800, 960×640, and 760×560 in light/dark mode. Inspectors stay
  present; panes resize without losing the target or primary actions. Command-F,
  grid arrows, Return/Space, text editing, and VoiceOver names remain scoped correctly.
- Search Workshop, edit an unsubmitted query, then advance a page: pagination must
  still use the displayed query. Submit to switch queries. Navigate away and back;
  query/page/selection should stay. A failed request's Retry repeats that request.
- Select a target display and apply; other displays keep their assignments.
  Disconnected, disabled, or mirror targets are not silently redirected to primary.
  Pause/resume and relaunch; expected wallpaper/playback state should return.
- Leave invalid scaling text, refresh or change routes, then return: preserve text
  and disable Apply Changes. Return stages only that field, not unrelated properties.
  Check immediate audio/FPS/scaling-mode semantics versus pending Apply/Revert.
- Install or locate SteamCMD in Settings and use the same runtime in Workshop
  without restarting. Installation itself must not log in or start a download.
  A blocked download remains present across relaunch/retry. Only explicitly confirm
  Allow This SteamCMD after checking the shown path/fingerprint and understanding
  the risk. Global Gatekeeper/signature checks remain enabled; updated bytes need
  another approval. Verify category-sidebar filters never activate wallpapers.
- Start a disposable download, close details and navigate elsewhere. The activity
  bar restores its prompts; cancellation stops it without changing the old library.
  Downloads do not auto-apply. Show in Library can reveal an item excluded by filters
  and return to the original results; deleting it removes Workshop's installed badge.
- Try invalid media and missing scene assets: show actionable failures without
  blocking videos or losing an already downloaded scene. A valid wallpaper remains usable.
- When relevant, check each connected display and sleep/wake behavior. Restore
  your original wallpaper configuration afterward.
- Native desktop posters: apply both a video and a scene, visit each Desktop once,
  then open Mission Control. Check that the thumbnails use the rendered wallpaper
  (not its Workshop cover), including Fill/Match/Stretch, scaling and flipping.
  Check different and mirrored wallpapers on connected displays, switch wallpaper,
  pause/resume, and visit a newly created Desktop. Eject a wallpaper and check that
  each visited Desktop recovers its previous native image/scaling. Quit and reopen
  to check restoration journaling. Also change a native wallpaper outside the app
  and verify quitting does not overwrite it.

Mission Control posters are sampled still frames, not live animation. The public
NSWorkspace API updates only the active Space: other Spaces update when visited.
Quitting restores the current Space; inactive Spaces keep their poster until they
can be restored while the app is running without a wallpaper on that display.
The app preserves their original settings and poster files under
`~/Library/Application Support/mac-wallpaper-engine/DesktopPosters`. It does not
switch Spaces, restart Dock/WallpaperAgent, or modify Apple's private settings.
GPU readback and Mission Control rendering need a manual desktop check; the native
pixel/ledger tests and Release build do not prove this visual integration.

These visual and OS-integration checks are not proven by passing native tests.
Keep UI wiring, window behavior, and visible rendering explicitly unverified if
no manual or explicitly requested desktop check was performed.
