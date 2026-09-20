# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. When it grows past that,
move the oldest entries verbatim into
[archive/verification-log-2026-09.md](archive/verification-log-2026-09.md)
(or a new dated archive file) first, and promote anything durable before it
goes. Trimming is allowed; editing an entry's recorded result is not.

## 2026-09-21 — Release build carrying the transport, sound and video-picker fixes

python3 scripts/build.py --configuration Release, after the full gate.

- Confirmed in the delivered binary: the bound transport value, the picker title for a video-accepting project, and the shortcut option label are all present, and the bundled WebUI matches WebUI/ file for file
- Delivered: `build/Build/Products/Release/MacWallpaperEngine.app` — quit and reopen the app to pick it up

## 2026-09-21 — The missing background video was a picker that only ever offered images

This wallpaper's Custom Background is a scenetexture property, and its manifest declares general.supportsvideo -- Wallpaper Engine's way of saying a video is as acceptable there as an image. Nothing in the app read that flag, and the picker set allowedContentTypes to .image, so the video the official example uses could not be selected at all. The scene has no missing video layer; the file simply never got in.

- supportsvideo now reaches the texture property metadata and the bridge descriptor, and the picker offers video and retitles itself only for a project that declares it
- `a_manifest_that_supports_video_says_so_on_its_texture_pickers` — a declaring manifest marks its scenetexture accordingly, and the existing scenetexture test pins the default false
- `scripts/test.py` — 526 passed, 0 failed, 11 skipped of 537; `cargo test --release -p wallpaper-bridge --lib` 318 passed
- Unverified: no desktop run, so whether the renderer then plays a selected video through that slot was not observed here

## 2026-09-21 — The button-click handler does not throw; its volume slider was the thing that did nothing

The reported throw from thisScene.getLayer('button_press').play() does not reproduce: registered as a layer script and driven with a cursor-down, the handler runs with zero script errors. play() on a layer that is not a sound layer sets a local flag rather than raising, so nothing there can throw.

- What is really broken on this wallpaper: both of its sound layers bind volume to the `buttonsvolume` slider as {"user": …, "value": …}, and the parser read only numbers -- so the binding was dropped, the sounds kept the author default, and moving that slider changed nothing
- `ASoundVolumeBoundToASliderFollowsTheUsersChoice` and `APlainSoundVolumeIsStillANumber` — the bound form keeps both the value and the property it follows, the plain form still parses as a number
- `PressingAButtonWhoseSoundExistsPlaysIt` — the wallpaper\s own handler, run for real, reports no script error
- `scene_schema_tests` 76 passed plus the two known pointer timeouts; `scenescript_media_event_smoke` 20 passed

## 2026-09-21 — Release build carrying the whole shortcut chain

python3 scripts/build.py --configuration Release, the first full renderer release build since the deployment-target fix -- which is what made it possible at all.

- Confirmed the delivered app carries the change: the binary contains the bound-action value and the bridge call, the bundled WebUI matches WebUI/ file for file, and the bundled zh-Hans catalogue has the new option
- Delivered: `build/Build/Products/Release/MacWallpaperEngine.app` — quit and reopen the app to pick it up

## 2026-09-21 — A bound wallpaper button now reaches a real media player

The Swift side takes presses off the bridge's long poll and carries them out through whichever provider is currently answering. The three combos default to no action, so the buttons stay inert until the user binds them in the wallpaper's own properties -- which is what Wallpaper Engine has them do, and what keeps a wallpaper from choosing on their behalf.

- Transport is a capability of the provider seam: the adapter stream runs one short-lived `perl … send N` off the main actor, the AppleScript runner tells the player it is currently reading, and a provider that cannot control playback answers false rather than pretending
- `SystemMediaTransportTests` (3) — the three actions reach the adapter as MRCommand 2, 4 and 5 from its own header; a refusing player is reported rather than assumed; the command follows the provider that is answering rather than a fixed one
- Combo labels now go through `t()` in the panel, with the four actions in the zh-Hans catalogue. "No action" rather than "None" — that key already means deselect-all
- `scripts/test.py` — 526 passed, 0 failed, 11 skipped of 537; `cargo test --release -p wallpaper-bridge --lib` 317 passed
- Unverified: no desktop run. Whether a press moves a real player was not observed here, only that the command is handed to the adapter the state comes from

## 2026-09-21 — A wallpaper's shortcut press now reaches the host, gated on the user's media consent

The engine pushes each request to an installed observer instead of holding it, because a request no host has taken is a press the user already stopped waiting for. WallpaperBridge::next_user_shortcut long-polls a bounded channel outside the actor, so waiting for a rare press stalls no other request and costs no idle wakeup, and it drops requests from wallpapers missing from system_media_scene_handles.

- `usershortcut` parses as Combo carrying the actions this host can carry out -- none, play/pause, next, previous -- rather than a new property kind, so the panel needs no new control and validation and effective-value come from the paths that already exist
- `user_shortcut_offers_the_actions_this_host_can_carry_out` — asserts the kind and the four option values; deleting just the usershortcut arm in the manifest parser fails it with "a shortcut the user cannot bind is a button that does nothing"
- Also corrected: `cargo_environment()` derives the pin from the popped value instead of repeating the literal
- Measured across the release archives: the C++ engine is `minos 26.0` on all 39 objects, and nothing anywhere exceeds the app minimum
- `cargo test --release -p wallpaper-core --lib` 213 passed; `-p wallpaper-bridge --lib` 317 passed

## 2026-09-21 — Corrected: the deployment target had to move, not disappear

The fix below dropped MACOSX_DEPLOYMENT_TARGET from cargo's environment outright. That variable is also what cmake-rs turns into CMAKE_OSX_DEPLOYMENT_TARGET for the C++ engine, so dropping it silently rebuilt the engine against the SDK default instead of the app's minimum. The 55 s build that looked like a success had reused C++ objects from an earlier run built with the pin.

- Measured on a clean build of the renderer crate: with the variable the engine archive reports `minos 26.0`, without it `minos 27.0`
- The pin is renamed rather than removed -- `cargo_environment()` exports `OWE_MACOSX_DEPLOYMENT_TARGET`, and the crate build script passes it as CMAKE_OSX_DEPLOYMENT_TARGET with rerun-if-env-changed, so the host proc-macro dylibs stay loadable and the engine keeps the app\s minimum
- `cargo clean --release` then `cargo build --release --workspace` — clean build passes, archive at minos 26.0
- `scripts/check_renderer.py` clean — 10 generated cases pixels_equal=True; `scripts/tests` 99 passed

## 2026-09-21 — A pinned deployment target was breaking every release renderer build

scripts/build.py handed cargo a MACOSX_DEPLOYMENT_TARGET. Cargo builds proc-macro crates and build scripts for the host and then dlopens them in the running compiler, and the pinned host dylibs this toolchain produces are rejected at load with "mis-aligned LINKEDIT" -- which rustc reports as `can't find crate for <macro>`, so arc-swap, tokio, zerocopy, miette, futures-util and uniffi_meta all failed to compile. Any renderer release build was dead; --swift-only hid it by skipping cargo.

- Isolated by rebuilding one proc-macro under the environment minus each variable in turn and dlopening the result: without SDKROOT it still fails, without MACOSX_DEPLOYMENT_TARGET it loads
- Cargo steps in `build.py` and `check_renderer.py` now use `cargo_environment()`; Xcode still sets its own deployment target for the app, and the crates ship a staticlib the app links
- `cargo test --release -p wallpaper-core --lib` 213 passed, `-p wallpaper-bridge --lib` 316 passed — the bridge compiles core, so this also covers the open_scene arity change
- `scripts/check_renderer.py` clean — 10 generated cases, pixels_equal=True, 0 diagnostics, 8 reload cycles

## 2026-09-21 — The shortcut request reaches the FFI boundary; the host chain above it does not exist yet

SceneWallpaper drains the runtime's requests after the tick that produced them and reports each on the native main looper, and owe_scene_wallpaper_set_user_shortcut_callback follows the pointer-callback contract exactly. OweScene::set_user_shortcut_callback installs the Rust sink. The buttons are still dead: nothing above the FFI consumes these yet, the three properties hold empty values, and no send path to a media player exists.

- Remaining, in order: a bounded channel per scene in core (the pointer relay uses a watch, which coalesces -- wrong for presses, where play/pause followed by next must not lose one), an actor message tagged with the SceneHandle, a PropertyKind::UserShortcut carrying Combo metadata so the user picks the action, and a Swift consumer that sends it to whichever provider is currently answering
- Enabling that send changes the bundled adapter from read-only to control, which the mediaremote-adapter provenance note currently states is not done -- that note has to change with it
- `scripts/test.py` — 523 passed, 0 failed, 11 skipped of 534
- First run failed on CodeSign with "resource fork, Finder information, or similar detritus not allowed" on the Debug app; `xattr -cr` on the product cleared it, unrelated to any change here

## 2026-09-21 — engine.openUserShortcut existed nowhere, so every transport button threw

This wallpaper's play/pause, next and previous buttons each have a cursorDown handler whose only statement is engine.openUserShortcut("<property>"). That member was not registered on the engine object at all, so the call threw TypeError, the handler aborted, and the press did nothing -- which is the whole of the reported 切歌无效, not a missing media permission.

- The binding resolves the named property against the wallpaper\s own declared properties and queues the request with that property\s VALUE; the three properties here are usershortcut-typed with empty values, so acting on the name would be the host deciding for the user
- `OpenUserShortcutCarriesTheValueTheUserChose` — two presses arrive in order with their configured values, an unbound one still reports with nothing to run, and taking twice does not replay
- `OpenUserShortcutRefusesAPropertyTheWallpaperDoesNotDeclare` — naming a property the wallpaper does not declare raises a script error instead of passing silently
- `UndrainedShortcutRequestsKeepTheNewestPresses` — 40 requests with no drain keep at most 16, and the newest survives
- `scenescript_media_event_smoke` 19 passed; `scene_schema_tests` 74 passed plus the two known 5 s pointer timeouts
