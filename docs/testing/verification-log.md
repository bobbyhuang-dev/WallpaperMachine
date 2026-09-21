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

## 2026-09-21 — A trait default swallowed the sink that kept the shortcut channel open

The instrumented build logged 'Stopped waiting for wallpaper shortcuts' at startup, before any press, which placed the fault in the bridge rather than anywhere downstream.

- EngineFacade::set_user_shortcut_callback carried a default no-op body. ArcEngineFacade, which BridgeBuilder::build wraps every facade in, never overrode it, so the callback was dropped on the floor
- That callback owned the only sender for the shortcut channel. Dropping it closed the channel immediately, so the very first next_user_shortcut returned "the engine stopped reporting user shortcuts" and the loop gave up before the user touched anything
- The default body is removed; the method is now required, and the compiler found ArcEngineFacade plus three test fakes. FakeEngineFacade keeps the callback and gained report_user_shortcut so a test can report a press the way the engine does
- New a_reported_press_comes_back_out_of_the_bridge: fails with the forwarder removed ("the bridge never installed its sink"), passes with it
- Two robustness fixes alongside: a failed consent lookup no longer kills the loop permanently, and the Swift loop retries five times with backoff and logs the actual error instead of discarding it
- scripts/test.py 535 passed / 0 failed / 11 skipped of 546; wallpaper-bridge 322 passed
- Release rebuilt

## 2026-09-21 — Nothing was waiting at the end of the shortcut chain

Presses still did nothing after the value fix. Instrumenting each hop and reading the user's log settled it in one press instead of another round of reasoning.

- Log evidence: `openUserShortcut nextsongbutton -> "media:next"` and `user shortcut reported: request=1 callback=1 value="media:next"` both appear, so the value fix works and the request crosses the main looper
- Neither the consent-drop line nor the carried-out line appears, which places the break after the engine and before anything acts
- Cause: SceneMediaCoordinator, which owned the nextUserShortcut long poll, was never constructed. It appeared only in two stop() calls. The class was dead code, so the whole Swift half of the chain never ran
- The wait now belongs to SceneMediaSink, the object that already holds the one live DesktopMediaSession and is actually constructed; DesktopMediaSession gained send(_:). The dead coordinator is deleted rather than started, which would have double-subscribed the provider
- Verified the last link directly against the machine before changing anything: the bundled adapter toggled Spotify False -> True -> False, so send was never the problem
- New testAPressReachesThePlayer: three presses in, two commands out, and a binding this host cannot carry out never reaches the player
- scripts/test.py 535 passed / 0 failed / 11 skipped of 546; SceneMediaSinkTests 7 passed
- Release rebuilt

## 2026-09-21 — The bound shortcut never reached the scene engine

The button pressed and released correctly after the capture fix, but the player still did not skip. The default bound in the last change only existed on the panel side.

- The scene engine parses project.json itself, where all three usershortcut values are empty. The bridge sent only explicit property_overrides, and the user has none, so openUserShortcut resolved to an empty value and the press was correctly dropped
- ProjectProperty now records default_is_host_supplied, set exactly where an unbound usershortcut is given the action its name states. Scene activation sends those defaults with the overrides, user overrides applied on top
- New an_unbound_transport_shortcut_reaches_the_scene_engine asserts the scene receives {"nextsongbutton":"media:next","playpausebutton":"media:playpause"} with no user overrides, that an unguessable name stays out of it, and that choosing no action still sends the empty string
- scripts/test.py 534 passed / 0 failed / 11 skipped of 545; wallpaper-bridge 321 passed
- Release rebuilt

## 2026-09-21 — The stuck transport button: a press made it too small to catch its own release

Reported with a screenshot: the next button sits flattened to a dash and the player never skips. Rendering the wallpaper offscreen showed all three buttons drawing correctly, so the cause was runtime state, not content.

- The scene sets this button scale scripts hoScale to 0.1, so a held button shrinks to a tenth. It only restores itself from cursorUp
- SceneRuntimeContext::DispatchCursorFrameEvents decided who hears a release by hit-testing at release time. The press shrank the button out from under the cursor, the hit test failed, cursorUp was skipped, and hover stayed latched -- the button can never come back
- Fixed by capturing the press: a release now goes to whichever scripted values and scene scripts took that button down, wherever the cursor has since gone. Anything that did not take the press keeps the old rule
- New AButtonThatShrinksWhileHeldStillGetsItsRelease reproduces it end to end through the parser and cursor dispatch: fails without the fix (button stuck at 0.1), passes with it
- Also added APressedTransportButtonComesBackWhenItIsReleased, driving the wallpaper own scale script with the scene real hoScale of 0.1 and speed of 25
- Offscreen render of the wallpaper with media events confirms all three transport buttons draw correctly, so nothing was wrong with the asset, model, material or scripts
- scripts/test.py 534 passed / 0 failed / 11 skipped of 545; scene_schema_tests 80 passed with the two pre-existing pointer-commit timeouts; check_renderer.py 10 cases pixels_equal=True
- Release rebuilt after the fix

## 2026-09-21 — Why the transport buttons did nothing, and what the progress bar actually is

Reported: the transport buttons still have no effect, and the progress bar cannot be dragged. Both were investigated against the installed wallpaper rather than assumed.

- Cause of the dead buttons: `~/Library/.../wallpapers/3280146735.json` has `property_overrides: {}` and all three usershortcut values are empty, so dispatch correctly skipped every press. Defaulting to no action left buttons named play, next and previous doing nothing until their user found the picker
- An unbound usershortcut now starts on the action its own name states; a name that says nothing stays unbound; an authored value is never overwritten. The override still wins and dispatch still carries the value, not the name (`unbound_transport_shortcuts_start_on_the_action_they_are_named_for`)
- The progress bar has no pointer logic at all -- objects 187 and 370 carry no scripts, and 366 only moves its origin from `mediaTimelineChanged`. It was never draggable in any client; the question is whether it advances
- New `TheProgressFillFollowsAPublishedTimeline` drives the wallpaper own origin script: a published timeline does place the fill exactly (-637 + position/duration * 620), keeps tracking, and does not jitter on a repeat
- It also pins an upstream quirk: the author places the fill before recording the duration it divides by, so the first event divides by an unset `dur` and puts the layer at infinity until the next one arrives
- scripts/test.py 534 passed / 0 failed / 11 skipped of 545; wallpaper-bridge 320; scene_schema_tests 78 passed with the two pre-existing pointer-commit timeouts
- Release built and checked: media:playpause / media:previous / next_user_shortcut all present in the delivered binary

## 2026-09-21 — Power regression: two defects the restored dispatch and its guard exposed

- Restoring CMD_SET_RENDER_SCALE dispatch made MetalRender::ApplyRenderScale reachable for the first time, and it had no same-value guard: it set scene.render_scale and called compile() unconditionally, which begins with releaseGraph() - video.release, images.clear, pipelines. apply_effective_render_scale pushes the scale to every open scene on scene creation and on every SetPowerSource/InitialFrameReady while the battery profile is on, and its own comment says it exists so a dragged quality control does not reparse the project or reopen its video. A Metal-preferred user would have taken a full rebuild plus video reopen on each plug and unplug at an unchanged value.
- MetalRender::ApplyRenderScale now clamps to kMinRenderScale..1.0 and returns early when scene.render_scale already equals it, mirroring VulkanRender::Impl::applyRenderScale. Caught by review before the behaviour shipped; the earlier round had recorded this path as Metal-only and unreachable, which stopped being true the moment the dispatch was fixed.
- The -Werror=switch guard's second catch was a live misreport, not a stale warning. crates/core/src/owe/scene_registry.rs:103 feeds owe_scene_wallpaper_video_path into SceneVideoPath::from_raw, which maps 5 to Nv12ConvertedPreparing, but the C enumeration stopped at NV12_MIXED = 4 and the switch fell through to OWE_SCENE_VIDEO_PATH_NONE. A scene that had chosen the converted path and was preparing it reported having no video path at all. Corrected by adding OWE_SCENE_VIDEO_PATH_NV12_CONVERTED_PREPARING = 5 and returning it, rather than the earlier mapping to NONE.
- Gates on these two fixes: scripts/check_renderer.py all binaries 0, pixels equal, 0 diagnostics; scripts/test.py 534 passed / 0 failed / 11 skipped.
- Not run: launch, wallpaper change, screenshots, audio capture, power measurement. No watt or percentage claimed. Metal-preferred rendering and non-default internal quality still need the user's visual acceptance.

## 2026-09-21 — Power regression: render scale was never wired, switch guard made hard, delivery

- Archaeology settles it: git log -S 'CASE_CMD(SET_RENDER_SCALE)' returns nothing, while the enumerator arrives in 48b8df2 'feat(quality): internal render scale, quality settings, shared video decode'. The case never existed, so internal render scale never worked for scene wallpapers - this is never-wired, not a regression, and therefore cannot explain a power increase. It does explain why lowering internal quality never saved anything.
- The UI said otherwise the whole time: activation.rs:526-528 sets render_scale_supported = true for any applied Scene, and snapshots.rs:729 reports effective_render_scale, so the control was enabled and showed 50%/75% as in force while the GPU kept rasterizing at 100%. The battery profile's quality.battery.render_scale went the same way.
- Guard promoted from warning to build failure, narrowly: -Werror=switch on the wescene-renderer target only, which is the target that owns both looper handler switches. warn_opts does not reach that target, which is why the warning-level version proved nothing. Both handler switches now have fixed-width enums, no default, and an explicit CMD_NO case.
- Verified by deleting the case again: 'error: enumeration value CMD_SET_RENDER_SCALE not handled in switch [-Werror,-Wswitch]', build exit 2.
- That promotion surfaced a second, pre-existing gap the earlier log check had missed because the target was not being recompiled: owe_scene_wallpaper_video_path did not name SceneVideoPath::Nv12ConvertedPreparing and reached OWE_SCENE_VIDEO_PATH_NONE by falling through. NONE is documented as covering a path that has drawn no frame yet, so the case is written out explicitly with the same result - behaviour unchanged, Metal-only in any case.
- Two panel races fixed rather than documented as tolerable, since docs/testing/README.md already forbids that trade: the first-run guide settles with panel.quiet() before its 50 ms measurement window, and the top-bar layout test waits for window.innerWidth to reach the new frame width instead of reading getBoundingClientRect mid-reflow. The README paragraph now teaches both techniques and the revert-to-confirm-ownership check instead of granting an exemption.
- Gates green: scripts/check_renderer.py all binaries 0, pixels equal, 0 diagnostics; scripts/test.py 531 passed / 0 failed / 11 skipped.
- Release built 16:51: build/Build/Products/Release/MacWallpaperEngine.app with Contents/Extensions/MacWallpaperExtension.appex; both binaries carry SetMinInterval, the shared-ownership ImageSlotsRef constructor and handle_SET_RENDER_SCALE. Not run: launch, wallpaper change, screenshots, audio capture, power measurement.

## 2026-09-21 — Power regression: render scale dispatch restored, panel races fixed, gate green

- RenderHandler's command switch had no CASE_CMD(SET_RENDER_SCALE), so every CMD_SET_RENDER_SCALE posted from setPropertyFloat(PROPERTY_RENDER_SCALE) fell into default:break. m_render_scale is written nowhere else, so it stayed 1.0 whatever the user chose, and rebuildRenderGraph seeded scene.render_scale from it. Internal quality 75%/50% and the battery profile's render scale were therefore complete no-ops for scene wallpapers - not a live-update bug, the value never arrived at all. owe_scene_wallpaper_set_render_scale is the only FFI entry, so no other path compensated.
- Fixed as a class, not an instance: the case is restored, CMD gets a fixed int32_t underlying type so the looper's cast back is defined, and default: is replaced by an explicit CMD_NO case. With -Wall -Wextra already on, -Wswitch now names any command added and not dispatched. Verified by deleting the case again: 'enumeration value CMD_SET_RENDER_SCALE not handled in switch [-Wswitch]'.
- Inert for the reporting user's configuration: render_scale is 1.0 and the battery profile is off, and VulkanRender::applyRenderScale early-returns when scene.render_scale already equals the clamped value (VulkanRender.cpp:1470-1472). Users with a non-default internal quality will see it take effect for the first time.
- Why no existing test caught it: render_scale_test sets scene.render_scale directly and exercises ResolveScreenBoundRenderTargetSizes; VulkanRender has its own same-value early return. Both sit below the message dispatch, and no harness drives RenderHandler::onMessageReceived. The compiler check replaces the harness that does not exist.
- Two panel tests were racing on wall clock, not on shared state. testFirstRunGuideCovers... latched a snapshot count, submitted a form and read the count 50ms later, counting any push already in flight; it settles with panel.quiet() first now. testTopBarKeepsTheRepositoryLink... measured getBoundingClientRect immediately after setFrameSize, reading the pre-reflow layout (744 vs 760, one whole reflow); it now waits for window.innerWidth to reach the new width.
- The first of those was wrongly attributed to load at first. A control gate with only the SceneWallpaper dispatch hunk reverted still failed the same assertion, which exonerated the change and identified the test. An 11-failure gate earlier was separately explained by load average 165 and a 174s run versus the usual 30s.
- Gate now green and stable: scripts/test.py 531 passed / 0 failed / 11 skipped, three consecutive runs (39s, 28s, 28s). check_renderer.py green after the C++ change: all binaries 0, pixels equal, 0 diagnostics.
- Release rebuilt 16:26: build/Build/Products/Release/MacWallpaperEngine.app with Contents/Extensions/MacWallpaperExtension.appex; both binaries carry SetMinInterval, the shared-ownership ImageSlotsRef constructor and handle_SET_RENDER_SCALE. Not run: launch, wallpaper change, screenshots, audio capture, power measurement.

## 2026-09-21 — Power regression: advisory round 5 closeout

- Only actionable item this round: SceneMediaSink.shutdown told the relay to stop consuming twice, once through setConsuming(false) and once directly. The second call relied on the relay's remove-guard to be harmless; dropped.
- Re-verified as already converged in earlier rounds, not changed again: the cover test compares raw Read() bytes with no NormalizeColorBytes (Pass/Target outputs are always RGBA8); deliveryEpoch is separate from generation and advances only when consuming flips, so an unrelated reconcile cannot retire wanted deliveries; the captured epoch is re-checked after the applyArtwork await; the over-specified combined test was already split into one chain-ordering test and one pause-retirement test; docs/features/media-integration.md already carries both durable contracts.
- Stability: SceneMediaSinkTests run six consecutive times, 6 passed each time. Neither new test contains a pause-then-resume sequence, so the replay nondeterminism that made the earlier combined test flaky does not arise.
- Renderer sources unchanged since the round-four gate, so check_renderer.py was not re-run; that run remains current evidence (all binaries 0, pixels equal, 0 diagnostics).
- Gate: scripts/test.py 531 passed / 0 failed / 11 skipped.
- Release rebuilt 15:33: build/Build/Products/Release/MacWallpaperEngine.app with Contents/Extensions/MacWallpaperExtension.appex; both binaries carry SetMinInterval and the shared-ownership ImageSlotsRef constructor, the app exports system_media_consent_handles. Not run: launch, wallpaper change, screenshots, audio capture, power measurement.

## 2026-09-21 — Power regression: advisory round 4 - legal readback, ordered deliveries, delivery epoch

- Cover lifetime test made legal Vulkan: cached images carry TRANSFER_DST|SAMPLED only (TextureCache.cpp:857-862), so ReadbackImageSample's transition to TRANSFER_SRC was invalid usage MoltenVK happened to tolerate. The test now binds each slot into an ordinary PlaybackGPU pass, draws, and reads the render target, which is readback-capable.
- That path is a cleaner detector than the previous one: with ImageSlotsRef reverted to borrowing, the test no longer crashes but fails with the previous slot drawing {0,0,0,0} instead of its cover, at previous_first=true, covers 1 and 2. With shared ownership both refresh orders draw the exact published bytes across three covers.
- SceneMediaSink deliveries are now chained and epoch-bound. Chaining fixes ordering: a slow cover must not be overtaken by the one that replaced it, because the engine shows whatever arrives last. The epoch moves only on effective-demand transitions and is checked at task entry and again after the artwork await, so a delivery retired by a pause stops there; a boolean could not, since a resume sets it true again.
- Two Swift tests replace the earlier over-specified one, after the real behaviour showed [1,1,1,2] (the extra 1s are legitimate resume replays, not a defect): testASlowCoverIsNotOvertakenByTheOneThatReplacedIt and testADeliveryRetiredByAPauseDoesNotReportItselfWhenItReturns. Removing the chain fails the first ('a later cover overtook the one still being applied: [2]'); removing the post-await epoch check fails the second ('a delivery retired by a pause still reported itself').
- Test helper poll() now takes a label, so a timeout names the condition instead of reporting an anonymous 2s failure.
- Gates: scripts/test.py 531 passed / 0 failed / 11 skipped; scripts/check_renderer.py all binaries 0, pixels equal, 0 diagnostics, including the reworked PlaybackGPU cover test.
- Release rebuilt 14:45: build/Build/Products/Release/MacWallpaperEngine.app with Contents/Extensions/MacWallpaperExtension.appex; both binaries carry SetMinInterval and the shared-ownership ImageSlotsRef constructor. Not run: launch, wallpaper change, screenshots, audio capture, power measurement.
