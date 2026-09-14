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
  and confirm the collection returns. Select a wallpaper and refresh: selection
  should survive.
- Search Workshop, advance a page, navigate away and back: query/page should stay.
  Open and dismiss download setup.
- Apply a wallpaper and visually confirm it renders, switch to another, then
  pause/resume. Relaunch and verify the expected wallpaper/playback state returns.
- Try invalid media: confirm a useful failure and that a valid wallpaper still
  applies afterward.
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
