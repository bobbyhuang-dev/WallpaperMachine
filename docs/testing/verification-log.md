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

## 2026-09-21 — Power regression: advisory round 3 - web delivery, listener identity, pixel-level lifetime proof

- Regression I introduced and reverted: gating WebWallpaperMediaRelay.emit on consumer membership silenced every visible web wallpaper. WebWallpaperHost registers one listener under mediaListenerKey (WebWallpaperHost.swift:105) but counts consumers per page (ObjectIdentifier(page), line 436), so a listener key is never a consumer key. emit is unconditional again; the decision not to work moved into SceneMediaSink, which knows its own effective demand.
- SceneMediaSink now records consuming from each applied reconcile and checks it both before enqueuing a delivery and again inside the task, so an event queued before a pause does no artwork copy, JSON encode or bridge call after it. shutdown clears it with the generation.
- Listener identity fixed in both places: SceneMediaSink.listenerKey and WebWallpaperHost.mediaListenerKey were ObjectIdentifier of a temporary that died immediately, so the address could be reused by another listener in the shared relay. Both hold a strong token and derive the key from it.
- New Swift test testEveryListenerIsFedEvenThoughListenerKeysAreNeverConsumerKeys builds the real WebWallpaperHost on a shared relay and proves a non-consumer listener still receives events; it fails with the consumer filter restored (verified) and passes without it.
- Cover lifetime test strengthened per review: CollectCompletedUploads is nonblocking, so it now drains with WaitForPendingUploads first and then reads actual RGBA back off the GPU through TextureCache::ReadbackImageSample for both slots, across three covers and both refresh orders.
- That readback is a real use-after-free detector, no sanitizer needed: with ImageSlotsRef reverted to borrowing (image_owner not bound to the cached ImageSlots) the test process dies during readback; with shared ownership it passes with exact pixels in both orders.
- Corrected an earlier claim in that test: whether the outgoing image object survives is order-dependent and is no longer asserted. When the current slot refreshes first, nothing references the old image and it is correctly released while the previous slot takes an equivalent upload. What holds in both orders is what the two slots show.
- Found, reported, NOT changed: RenderHandler::onMessageReceived has no CASE_CMD(SET_RENDER_SCALE) (SceneWallpaper.cpp:488-506), so CMD_SET_RENDER_SCALE posted at line 1877 never reaches handle_SET_RENDER_SCALE and m_render_scale keeps its 1.0 default. Pre-existing (git diff touches no CASE_CMD line). This corrects the earlier report: P1 item 5 is not 'already a no-op in Vulkan' but unreachable in the scene path. Enabling it changes rendering for anyone with a non-default internal quality and needs visual acceptance, so it is left for the user's call.
- Gates: scripts/test.py 529 passed / 0 failed / 11 skipped; scripts/check_renderer.py all binaries 0, pixels equal, 0 diagnostics; cargo test -p wallpaper-bridge 319 passed.
- Release rebuilt 14:17: build/Build/Products/Release/MacWallpaperEngine.app plus Contents/Extensions/MacWallpaperExtension.appex; both binaries carry SetMinInterval and the shared-ownership ImageSlotsRef constructor, the app exports system_media_consent_handles. Not run: launch, wallpaper change, screenshots, audio capture, power measurement.

## 2026-09-21 — Power regression follow-up: texture lifetime, request handover, media gating completeness

- Blocker fixed before delivery: with the cover no longer rebuilding the graph, TextureCache::ReplaceTex could free an image a second binding was still sampling. A cover change aliases $mediaPreviousThumbnail onto the outgoing Image, so both names share one Image::key; whichever binding refreshed second retired that key, and the first never refreshed again because its own key was unchanged. m_tex_map and m_retired_runtime_textures now hold shared_ptr<ImageSlots> and ImageSlotsRef carries image_owner, so retiring drops the name and the image goes with its last holder.
- New device-backed test PlaybackGPU.AnAliasedCoverOutlivesTheNameItSharesBeingReplaced drives three successive covers in both binding-refresh orders and asserts the outgoing image is not released while the previous slot holds it, that the two slots stay distinct and non-null, and that the image dies with its last holder. Contract test, not a sanitiser repro: it does not compile against the old borrow-only model.
- Trailing-request fix corrected: the earlier retry-when-idle still lost an update across Continuous to Idle, because the tick was suppressed while the clock was still running and the scene only idled after that draw ended. FrameTimer now keeps m_frame_requested until a draw consumes it and re-arms from FrameEnd; the retry poll is gone.
- Two new timer tests drive the real asynchronous draw path (a worker thread holding FrameBegin/FrameEnd), not m_frame_busy_count: AnEventThatArrivesDuringADrawIsStillDrawn at 20 FPS and ARequestSuppressedByAContinuousDrawSurvivesGoingIdle at 30 FPS. Both fail with the re-arm disabled and pass with it; timer_tests now 27/27.
- Media gating completed: GetSceneMediaWallpapers and UpdateSceneMedia answer from the same effective-consumer predicate as the fan-out instead of playback_paused alone. New bridge test one_suspended_display_stops_only_its_own_scene_on_every_entry_point proves a two-display setup keeps feeding display 8 while display 7 is suspended, on handles, legacy list, events and artwork.
- SceneMediaSink.reconcile is generation-bound so a slow earlier answer cannot re-open the provider a later one closed, and WebWallpaperMediaRelay.emit delivers only to current consumers so a paused scene does no artwork copy, JSON encode or bridge call while a visible Web wallpaper keeps the shared provider alive. Both new Swift tests fail with the guards removed (verified with scripts/test.py --only SceneMediaSinkTests) and pass with them.
- Identical cover is now a true no-op: SYSTEM_MEDIA_ARTWORK is excluded from the blanket per-command requestFrame, and its handler requests a frame only when PublishSystemMediaArtwork reports the pixels moved.
- upstream/provenance.json updated for this round (recorded 2026-09-21); renderer and sceneEngine notes prepended, revisions, licences and prior notes preserved.
- Gates after all fixes: scripts/test.py 528 passed / 0 failed / 11 skipped; scripts/check_renderer.py all binaries 0, 10 pixel cases equal, 0 diagnostics, timer_tests 27/27, playback_gpu_test including the new lifetime test; cargo test -p wallpaper-bridge 319 passed.
- Release rebuilt: build/Build/Products/Release/MacWallpaperEngine.app with Contents/Extensions/MacWallpaperExtension.appex (13:54). Both binaries contain SetMinInterval and the shared-ownership ImageSlotsRef constructor; the app exports system_media_consent_handles. Not run: launch, wallpaper change, screenshots, audio capture, power measurement.

## 2026-09-21 — Power regression: frame ceiling, media consumers, cover updates

- HEAD 06ac2ca3 + dirty tree (13 tracked files); runtime read from config.toml and Logs/20260921-113428: scene wallpaper 3799253558, VulkanRender (scene_renderer=compatibility), render_scale 1.0, output 4112x2658, scene_optimization on, scene_on_demand off, content_pacing on, media_integration on.
- P0 ThreadTimer: the FPS ceiling now bounds every wake path (request, appointment, expired appointment), not just the cadence; FrameTimer publishes it via SetMinInterval and re-arms a tick dropped by an in-flight draw.
- Reproduced pre-fix by temporarily restoring the old idle branch: 102 frames from ~150 requests in 300ms at a 10 FPS ceiling, and a trailing update lost behind an in-flight draw. Post-fix both bounded/delivered.
- P0 media: bridge media_scene_handles() now subtracts global pause, power suspend, presentation suspend and per-display suspend; consent moved to a separate media_consent_handles()/GetSystemMediaConsentHandles so a wallpaper button press is judged on permission, not presentation. AppDelegate reconciles the sink when a suspend commits (those paths publish no snapshot).
- P0 artwork: applySystemMediaArtworkPayload publishes pixels and requests a frame instead of rebuildRenderGraph(); PublishSystemMediaArtwork returns false for a byte-identical cover. SET_SCENE now always builds its own graph.
- P1 (actual backend) VulkanRender::planStaticSkips: dropped the per-frame std::vector allocation (writes into m_static_skip) and skips the sampling/signature walk when no target is pinned, since Plan can then only answer 'execute every pass'.
- Excluded by source/runtime, not changed: MetalRender encoder merging and its 192MiB pin budget (scene_renderer=compatibility, Metal not running); VulkanRender::applyRenderScale already no-ops on an unchanged scale (VulkanRender.cpp:1472), so the ApplyRenderScale rebuild is Metal-only.
- Counter wiring checked: Vulkan records OWE_RC_RENDER_SUBMISSIONS and OWE_RC_GPU_COMPLETIONS (VulkanRender.cpp:859/879/934/940); Metal records only OWE_RC_PRESENT_REQUESTS (MetalRender.mm:4226), so those two read 0 on Metal because they are unwired, not because the GPU is idle. Not added: no claim this round depends on them.
- Tests: check_renderer.py all green (timer_tests 26/26 incl. 2 new, static_subgraph_cache_test, render_scale_test, playback_gpu_test, 10 pixel cases equal, 0 diagnostics); cargo test -p wallpaper-bridge 318 passed incl. new paused/suspended consumer test; media_thumbnail_texture_smoke 15 passed incl. new identical-cover test; scripts/test.py 526 passed / 0 failed / 11 skipped (first run hit a known-flaky ControlPanelShellTests power-probe timing assert, passed alone and on rerun).
- Offscreen probe on the user's own wallpaper 3799253558: 249 passes (247 executed + 2 reused), 7 cacheable targets, 1 pinned - so the no-pin early-out does not fire for this scene, while the removed per-cover rebuild was re-preparing all 249 passes.
- Release build OK: build/Build/Products/Release/MacWallpaperEngine.app with Contents/Extensions/MacWallpaperExtension.appex; both binaries contain SetMinInterval and the app exports system_media_consent_handles. Not run: app launch, wallpaper change, screenshots, audio capture, power measurement - no watt or percentage claim.

## 2026-09-21 — Installed page filters with Discover's sidebar boxes

- Change: LibraryMetricsService reads Workshop-style tags from project.json (genre tags, contentrating, Approved, Audio responsive, Customizable); snapshot wallpapers carry them as tags.
- Change: WebUI Installed sidebar now renders Discover's groups (Show only + Favorites/Active, Type, Age rating, Tags; Resolution and Wallpaper/Preset are Discover-only) and filters the library in the page with the same required/excluded rules; every box starts ticked.
- Removed: Installed type menu, 'Favorites only' / 'Active on target display' checkboxes; unused zh-Hans keys dropped.
- python3 scripts/test.py --only LibraryMetricsTests --only ControlPanelLibraryTests: 10 passed (new testReadsWorkshopStyleTagsFromTheManifest, testInstalledFiltersTheLibraryWithDiscoverBoxesWithoutWindow).
- python3 scripts/test.py (full gate, before rebase onto origin/main): 525 passed, 0 failed, 11 skipped (opt-in media/network layers).
- Docs: control-panel.md Filtering + layout table, workshop-downloads.md cross-reference.
- Not done: no Release build; sidebar not viewed on the desktop (offscreen WebKit tests only).
