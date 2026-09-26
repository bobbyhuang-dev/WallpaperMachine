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

## 2026-09-26 — Release build with wallpaper-window canHide fix

- python3 scripts/build.py --configuration Release: OK (cargo, uniffi-bindgen, xcodegen, xcodebuild; pre-existing warnings only); generated bindings unchanged.
- Built binary 2026-09-26 18:56 contains the setCanHide: selector reference.
- Delivered: build/Build/Products/Release/WallpaperMachine.app. Not launched; two-display apply/hide behavior not checked on the desktop.

## 2026-09-26 — Wallpaper windows survive app hide (canHide=false)

- Bug: after an activation NSApp.hide(nil) (e8aab7b) also hid every wallpaper window (AppKit canHide default YES); occlusion then suspended both displays. Evidence: app log 20260926-180315 shows 'presentation suspended for displays [1, 2]' after each of 5 activations; no [1, 2] suspension in any session before 2026-09-26 14:24.
- Fix: canHide=false on MWEWallpaperDesktopWindow (crates/core window.rs), MWEWebWallpaperDesktopWindow, MWENativeVideoDesktopWindow; provenance note and architecture.md updated.
- python3 scripts/build.py --renderer-only: passed (pre-existing unused-code warnings only).
- cargo test --release -p wallpaper-core --lib window: 12 passed.
- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped.
- Not run: desktop hide/apply check on two displays (needs desktop authorization); no Release build.
- Separate finding, not changed: each scene's text worker reads the 78 MB PingFang fallback font twice per text update under the process-wide g_freetype_mutex (TextLayer.cpp CreateFallbackFace); a sample showed the two scenes' workers waiting on each other (333 mutex-wait samples).

## 2026-09-26 — Top bar/About version display + Release build

- Removed top-bar version and GitHub button; About shows 'beta (unreleased)' and component versions 0.1.0 (display-only); removed bigsaltyfishes renderer row.
- Updated ControlPanelShellTests top-bar tests (repository link removed).
- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped.
- python3 scripts/build.py --swift-only --configuration Release: OK; bundled WebUI identical to WebUI/.
- Not checked: visual rendering of Settings/About on a desktop run.

## 2026-09-26 — Release pipeline follow-ups: reference bytes, real transport, safer rebuild

After review: the .DS_Store and alias writers are held to ds_store 1.3.3 / mac_alias 2.2.3 output, the model call has a 600 s deadline and claim rules, --rebuild-changelog never calls the model and keeps recorded sections, the image copy sheds extended attributes, and DMG inputs are checked in the packaging preflight. Python-only changes after the previous entry's full gate.

- `python3 scripts/tests/test_release_notes.py` — exit 0; 45 tests, including the real HTTP request against a local server (headers, the gateway's 401 message, the deadline)
- `python3 scripts/tests/test_dmg.py` — exit 0; 11 tests: writers byte-identical to the reference goldens; a bundle carrying Finder info round-trips and verifies
- `test_brand.py` 6 and `test_publish_release.py` 13 — exit 0
- `python3 scripts/package.py --configuration Release --check` — exit 0; preflight including the DMG inputs, bundle unchanged
- `release_notes.py --ai --tag v0.6.0 --to HEAD` through the real request — 37 s; opt-in features read optional and off by default, no power claims
- Native suite not rerun: no Swift change since the previous entry's full gate

## 2026-09-26 — Release pipeline: drag-to-install disk image and model-written release notes

The distributable is now WallpaperMachine-<version>-arm64.dmg (scripts/lib/dmg.py, standard library only) and the in-app updater installs from it; release notes are written by claude-opus-5-5 through the sub2api gateway and recorded once in CHANGELOG.md. The Release app in build/ was running and was neither rebuilt nor packaged.

- `python3 scripts/test.py` — exit 0; 14 script test modules OK (test_dmg 7, test_release_notes 41, test_brand 6, test_publish_release 13); native 579 passed, 0 failed, 11 skipped of 590
- `python3 scripts/test.py --only AppUpdateTests --only ControlPanelShellTests` — exit 0; 48 passed, including installs from real hdiutil images that end detached
- scripts/lib/dmg.py against dmgbuild 1.6.7 in a throwaway venv (not a dependency) — .DS_Store (16388 bytes) and background alias (394 bytes) byte-identical for the same inputs; a built image's records equal dmgbuild's
- scripts/package.py run on a copy of the Release app outside build/ — preflight, 19 relocated dylibs, ad-hoc signing, 33 MB ULFO image, mounted verification, `shasum -a 256 -c` OK; nothing left attached
- `release_notes.py --ai --tag v0.6.0 --to HEAD` against the gateway — 93 commits, summary plus 14 New / 8 Improved / 20 Fixed, streamed in 44 s
- Finder window of that image — checked and confirmed by the user on macOS 27.2 beta; not checked on macOS 26.x
- Not run: the CI workflows (Build stays behind the LICENSING.md gate; the RELEASE_NOTES_API_KEY repository secret is not set yet)

## 2026-09-26 — Hide app after wallpaper activation

- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped
- python3 scripts/build.py --swift-only --configuration Release: OK
- Manual check of hide-on-activate pending (user verifying)

## 2026-09-26 — Release build after syncing origin/main (6106f50)

- python3 scripts/test.py: 574 passed, 0 failed, 11 skipped
- python3 scripts/build.py --configuration Release: OK (renderer changes pulled, full build)
- Not launched; check_renderer.py not run

## 2026-09-25 — Release build at 6106f50 (Lucy renderer fix on origin/main)

- `python3 scripts/build.py --configuration Release` — exit 0 at 6106f50, which carries the Lucy renderer fix and the first-seen displays and Discover commits; delivered `build/Build/Products/Release/WallpaperMachine.app`
- Bundle check: app and extension binaries linked 14:37, after the newest tracked source; both contain `ExportKeywordAt`, `ApplyCameraShots` and the camera-aware `FrameVaryingUniforms`; the app also contains the bridge's `for_connected_display`; bundled `WebUI/` identical to the tree; regenerated bindings unchanged
- Gate for this code: the integrated-tree entry below (574 passed, 0 failed, 11 skipped); the only commit since is a provenance note
- Not done: the app was not launched or restarted; no desktop, visual or power check

## 2026-09-25 — Lucy renderer fix moved onto origin/main (first-seen displays, Discover animations) before push

- `git merge --ff-only origin/main` (aaed861 to e44b960), then the change set reapplied: conflicts only in `upstream/provenance.json`, where both sides prepended to the renderer note (both kept, newest first), and the two logs (entries kept in recording order, trimmed to ten by `scripts/log_verification.py`'s rule); the other 33 changed files matched their pre-move checksums
- `python3 scripts/build.py --renderer-only` — exit 0; regenerated `App/Bridge/Generated` unchanged
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not rerun on this tree: `scripts/check_renderer.py` and the C++ suites, since the two remote commits change no scene engine or shader code; the Release app built before the move lacks those two commits

## 2026-09-25 — Lucy renderer fix: parallax report restored per pass camera, playing-only demand; Release build

Revisits two items of the narrowing entry below, decided from the code. Without the kParallax report, frame reuse (on by default) left an otherwise still parallax wallpaper not following the cursor, and on-demand rendering never woke for it; the report is back, judged for the camera each pass draws through, so layer-local composites stay reusable. Stopped playbacks no longer count as demand, since only script commands restart one. Vulkan's upload order stays as at HEAD (Known limitations).

- `script_runtime_compat_test` 78 passed, 1 documented failure; `scene_schema_tests` 86 passed, 2 documented timeouts; `layer_texture_reference_test` 16/16; `static_subgraph_cache_test` 26/26
- Mutations fail their tests: no parallax report; layer-local camera ignored (updater and graph tests); the Vulkan call site dropping `camera_override` (graph test); stopped playbacks counted (camera intro test)
- `python3 scripts/build.py --renderer-only` then `python3 scripts/check_renderer.py` with 3521337568, 3292361861, 3605722997, 3632513108, 2887099508 — exit 1: 23 binaries exit 0, 10 generated cases pixel-equal with expected pixels, reload cycles 0; 3521337568, 3605722997 and 3632513108 pixel-equal with no diagnostics; 3292361861 differs only in its clock-text band (rows 346-394), and 2887099508 logs the same 8 script errors as the previous run
- `metal_scene_draw_smoke`, 3521337568: Native Metal, 120 frames drawn, zero translation failures, 53.0 render passes/frame with and without the report
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- `python3 scripts/build.py --configuration Release` — exit 0; delivered `build/Build/Products/Release/WallpaperMachine.app`; app and extension binaries linked 08:21, after the last renderer edit, and both contain the new `FrameVaryingUniforms` signature and `ExportKeywordAt`
- Not done: the app was not launched or restarted; no desktop run, no parallax under a real cursor, on-demand parallax easing still stops partway (known limitation), no power measurement of the lost reuse, no corpus visual check of the Compatibility upload order

## 2026-09-25 — Lucy renderer fix narrowed to its own regressions (upload order and parallax report withdrawn)

Narrows the follow-up entry below. Withdrawn and recorded under renderer.md Known limitations instead: Vulkan's constants-before-live-values upload order (with the generated-texel-size case) and the kParallax report; also recorded there: finished non-camera timelines still count as demand. Kept, narrowed: finished-playback demand covers camera-layer clocks only; ExportKeywordAt holds the one statement-boundary rule; QuickJS-compiled tests use U+00A0 only.

- `python3 scripts/build.py --renderer-only` then `python3 scripts/check_renderer.py` with 3521337568, 3292361861, 3605722997, 3632513108, 2887099508 — exit 1: 23 binaries exit 0, 10 generated cases pixel-equal with expected pixels, reload cycles 0; 3521337568, 3605722997 and 3632513108 pixel-equal with no diagnostics
- The exit 1 is the known pair: 3292361861 differs only in its clock text (at most 618 px in rows 346-393; `text-8` changes width) with the 7 diagnostics HEAD also logs; 2887099508 logs the same 8 script errors as the previous run
- 3632513108 in the check's environment: 0 of 10 renders (5 pooled, 5 isolated) show the alternate frame; an unmodified HEAD produced it in 1 of 2 pooled runs, so renderer.md records it as predating this work, allocation reuse not ruled out
- `script_runtime_compat_test` 77 passed, 1 documented failure; `scene_schema_tests` 86 passed, 2 documented timeouts; `layer_texture_reference_test` 16/16
- Mutations fail their tests: a stale non-zero link size folded at parse time (caught only under the constants-last order), no statement boundary in `ExportKeywordAt` (`reexport`, `module.export`), camera clocks counted while merely registered
- 3521337568: Vulkan past the intro at 3840x2160 has no non-cache errors and its centre registers with preview frame 40 (NCC 0.95; bands 0.93/0.97/0.99 at one shared offset); `metal_scene_draw_smoke` reports Native Metal, 120 frames drawn, zero translation failures
- `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not done: Release build, desktop run, live parallax under a real cursor, corpus-wide visual check of the Compatibility upload order (a known limitation, unchanged)

## 2026-09-25 — Lucy renderer fix: review follow-ups (upload order, parallax reuse, idle intros, export matcher)

Follow-ups to the Workshop 3521337568 entry below. Vulkan uploads parse-time constants before the value updater's live values (Metal's order), parallax is limited to 2D scenes and reported as cursor-varying, a finished single-play timeline stops asking for frames, script-bound shot origins wait for the first tick, the fullscreen canvas camera is 2D-only, compose cameras stay out of layer-local framing, the camera fold is one helper both backends call, and one ECMAScript-whitespace matcher serves the export rewrite and both update detections (the rewrite now erases only the keyword).

- `python3 scripts/check_renderer.py` with 3521337568, 3292361861, 3605722997, 3632513108, 2887099508 — exit 1: all 23 binaries exit 0, all 11 generated cases (new generated-texel-size included) pixel-equal with expected pixels, reload cycles 0; 3521337568 and 3605722997 pixel-equal with no diagnostics
- The exit 1 is pre-existing only: 3292361861 differs by its live clock text and its 7 diagnostics also occur on HEAD; 3632513108's frame flips between two images on an unmodified HEAD build as well (now in renderer.md Known limitations); 2887099508's 8 script errors match HEAD's except stack-trace columns, shifted because a line-start `export ` keeps its space
- `scene_schema_tests` 86 passed, 2 documented timeouts; `script_runtime_compat_test` 78 passed, 1 documented failure; `layer_texture_reference_test` 16/16; `mouse_input_test` 12/12; `static_subgraph_cache_test` 26/26; `cargo test -p shader` 14 suites, 503 passed
- Mutation checks: each new or changed test fails with its fix reverted (keyword-only erase, Unicode update detection, composelayer order, kParallax report, finished-playback demand, pending bound origin, zero link resolution, compose not layer-local, puppet slot depth); generated-texel-size draws (51, 60, 0) with Vulkan's old upload order
- Metal, 3521337568 at 3840x2160 with its shot hidden: zero `metal translation … failed` lines, mean abs 0.58 against Vulkan at matched scene time; Vulkan after the 5 s intro registers with the preview
- `python3 scripts/build.py --renderer-only` then `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not done: Release build, desktop run, live parallax under a real cursor, the intro's opening framing (no reference), any 3D scene (none installed)

## 2026-09-25 — Workshop 3521337568 (Lucy) renders its intro, planet and effects on both backends

Renderer-only fix: 2D camera layers frame the canvas (zoom plus origin as an offset from the canvas centre, one timeline clock, last visible shot wins), parallax follows the cursor and depth only, layer composites draw through a layer-local camera, fullscreen layers through a canvas camera, static samples fold cameras, link-texture sizes are not folded as zero, cloudmotion's whole-vector assignment narrows, and `export` followed by U+00A0 is stripped. Offset semantics checked against 3605722997 (close-up and default shots, lens sliders) and 3292361861 (scripted lens, identical to HEAD at default settings).

- `python3 scripts/check_renderer.py` with local 3521337568, 3292361861, 3605722997, 3632513108 — exit 1: all 23 binaries exit 0, 10 generated cases pixel-equal with no diagnostics, reload cycles 0; 3292361861 pooled/isolated differ only in its live clock text (5,249 px) and reports 7 diagnostics, all also present on an unmodified HEAD build (clipping_mask, init TypeError)
- `scene_schema_tests` 85 passed, 2 failed (the documented pointer-capability timeouts); `script_runtime_compat_test` 75 passed, 1 failed (documented HostVectorUpdates…); `layer_texture_reference_test` 15/15; `mouse_input_test` 12/12; `static_subgraph_cache_test` 26/26
- `cargo test -p shader` — 14 suites, 503 passed
- Each new test fails with its fix reverted (composite camera, zero link resolution, fullscreen camera, static-sample camera, shot timeline, shot visibility, perspective framing, parallax formula, Unicode export, whole-vector narrowing)
- Offscreen: settled 3521337568 frame registers with every preview frame (background, planet, character); Metal and Vulkan agree at rest (mean abs 1.45 at 480x270) and at a zoom-1.5 shot once the puppet clock is matched (1.02); the intro ends on the rest frame on both backends
- `python3 scripts/build.py --renderer-only` then `python3 scripts/test.py` — exit 0; 574 passed, 0 failed, 11 skipped
- Not done: Release build, desktop run, visual check of the live wallpaper, parallax under a real cursor; the running app still has the old renderer
