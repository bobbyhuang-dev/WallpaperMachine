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

## 2026-09-21 — The button sound reaches the runtime and plays; the Metal brightness predates the blur chain

Two open questions closed by measurement. The sound: parsed through WPSoundParser, the layer registers, starts silent as its author asked, and PlaySoundLayer makes it play -- so nothing between the click handler and the stream is swallowing it. If a user still hears nothing, the remaining suspects are app-side output, which this does not cover.

- `AButtonSoundStartsSilentAndPlaysWhenAsked` pins both halves: quiet at rest, playing after the ask
- Metal: dumping all 64 targets with their bright tail shows every post-processing intermediate -- _downscaled1/2, _full1/_full2, _rt_FullCompoBuffer1, both _rt_QuarterCompoBuffers -- already at p99 255 with mean ~101, so the bright content exists before that chain rather than being made by it
- Two earlier suspects are ruled out: `_coc` reads 255 because its Mask mode writes CAST4(mask) with mask 1.0, and it is an rg88 target an RGBA readback reports oddly; the clouds effect input is a white card on both backends by design
- Still not isolated: which pass first writes the tail. Visibility gating, blend factors and the alpha write mask are identical between backends, and clamping LOD moves the mean onto Vulkan without moving the tail
- `scene_schema_tests` 77 passed plus the two known pointer timeouts

## 2026-09-21 — Release build after the revert and the doc updates

python3 scripts/build.py --configuration Release, following the full gate.

- Confirmed in the delivered binary: the bound transport value and the shortcut option label are present, and the reverted video-picker title is gone
- Owning docs updated: media-integration.md no longer says transport is unimplemented, build.md records why the deployment pin is kept out of cargo, renderer.md lists the three new probe knobs. Link check clean apart from two pre-existing breaks in docs/archive/implementation-progress.md (f94ab32, not this work)
- Delivered: `build/Build/Products/Release/MacWallpaperEngine.app` — quit and reopen the app to pick it up

## 2026-09-21 — Corrected: two sound claims were wrong, and the video picker promised what cannot work

Three things in the entries below do not survive checking. The sound volume was never dropped -- _GetJsonValue reads a node's `value` when it is an object (WPJson.cpp:47-50), so 0.3 parsed fine; what was actually wrong is narrower, and the volume now follows the user's live property instead of the number scene.json shipped with. The negative check cited was a compile failure on the old header, which only shows a field exists.

- Replaced with `ASoundFollowsTheSliderValueTheUserActuallyHas`, which parses through WPSoundParser and reads the registered stream: reverting only the resolution in Parse (header kept) fails it with "the sound kept the number scene.json shipped with instead of the user\s slider"
- The video-picker change is reverted. This scene binds `"usertextures": ["backgroundimage"]` — a plain property name — and ApplySystemUserTextures substitutes only `$mediaThumbnail`/`$mediaPreviousThumbnail`, so a chosen path never reaches the material. There is also no VFS mount for user-chosen files, so an absolute path could not load even if it did
- Widening the file filter alone ships a picker that accepts a video and changes nothing, which is a promise the app cannot keep. The real work is property-named texture substitution plus a user-asset mount with the path and permission rules that boundary needs, and video into a texture slot
- `scripts/test.py` 526 passed; `cargo test --release` core 213 / bridge 317; `scene_schema_tests` 76 passed plus the two known pointer timeouts

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
