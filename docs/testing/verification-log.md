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

## 2026-09-20 — An annotation default was claiming the author bound that texture slot

3280146735's album cover rendered as a circle. WPSceneParser's default-texture stabilisation loop feeds the defaulted list back as the compiler's texture presence, so every sampler with both a combo and a default had that combo forced to 1; rounded_mask then read its radius from a white default instead of u_Radius. The default still binds for sampling — only what the combo reports changed.

- Probe on 3280146735 — the cover goes from an inscribed circle (fill 0.790 ≈ π/4) to the authored rounded square; same crop, same seed
- Same-seed frames for all 10 installed scenes, before and after: 6 byte-identical; 3662790108, 2998757800 and 3665954520 differ only in their wall-clock text (a same-binary back-to-back rerun of 3665954520 changes 5.33% against the 5.39% measured, so that scene is noise)
- The only change outside those clocks is the cover itself: 0.54% of 3280146735
- `LayerTextureReference.AnnotationDefaultBindsItsSlotWithoutClaimingTheAuthorBoundIt` — 11 tests pass; it fails with the change reverted
- `metal_scene_draw_smoke` local gate on 3280146735 — still Native Metal, 120 frames, no `metal translation of … failed`
- `python3 scripts/check_renderer.py` — exit 0, adaptive-20260920-204029: 10 generated cases `pixels_equal=true`, 0 diagnostics
- `python3 scripts/test.py` — exit 0, Tests-20260920-210253-762337.xcresult: 519 passed, 0 failed, 11 skipped of 530

## 2026-09-20 — A scalar uniform array had two different layouts

std140 pads every array element to 16 bytes — what the host packs and the reflection reports — while the MSL backend emits the natural tight stride, so `float g_AudioSpectrum64Left[64]` moved every member after it by 768 bytes on Native Metal only. Narrow array members are now declared `vec4 name[N]` with reads swizzled back; see [renderer.md](renderer.md). `ShaderPipelineRevision` 6 → 8.

- Four read paths: direct, array-parameter specialization, `#define` aliases written inside `main` (this one broke five installed wallpapers before it was covered), and local array aliases
- 3799253558 on Metal, audio vs silence — 929 → 11 428 244 px whole-frame, 0 → 66 995 in the ring annulus; frame 30.0% → 99.8% non-black, its background, flowers and fog back
- Metal gate over all 10 installed scenes, before and after — backend decisions identical, `metal translation of … failed` 11 → 8, exactly the three repaired shaders
- Installed corpus (Vulkan probe) — 4 pre-existing failures in 3292361861 before and after; every other scene 0
- `cargo test -p shader` — 14 binaries, 0 failed; `metal_scene_draw_smoke` — 34 tests, 33 passed, 1 skipped (local gate skips without `WE_TEST_METAL_PROJECTS`)
- Re-run after rebasing onto `d6e9b78`, which reworked the test runner: `python3 scripts/check_renderer.py` — exit 0, `adaptive-20260920-195302`: 10 generated cases `pixels_equal=true`, 0 diagnostics, 8 projects × 2 reload cycles clean
- `python3 scripts/test.py` — exit 0, `Tests-20260920-195139-287781.xcresult`: 519 passed, 0 failed, 11 skipped of 530
- `python3 scripts/build.py --configuration Release` — exit 0; app not launched, no desktop state changed

## 2026-09-20 — The halo was missing because the desktop draws that scene with Metal

`config.toml` sets `scene_renderer = "native_metal_preferred"` and the local-project gate reports 3799253558 as Native Metal, so every `offscreen_scene_probe` measurement of it described a backend it never runs on. The probe is Vulkan-only; check the backend before comparing.

- Same scene, same seed, audio the only difference — Vulkan: 7 668 590 px changed whole-frame, 129 471 in the ring annulus. Native Metal: 929 and 0
- Not a missing uniform: `g_AudioSpectrum64Left` is in that pass's Metal reflection and written every frame at offset 1120, stride 16, with a live band 0
- `metal_scene_draw_smoke`'s local-project gate now reads `WE_TEST_PROPERTIES` and `WE_TEST_AUDIO_HZ`; without them a property-gated, audio-driven layer could not be drawn there at all

## 2026-09-20 — Three author effects were rejected by the shader frontend

3280146735 failed to load Bokeh blur, Cutout Vignette and Refract on every launch, so it rendered with no depth-of-field, vignette or refraction. Four permissive-path idioms now absorbed; see [renderer.md](renderer.md).

- `effects/refract` — a texture annotation `"default":""` means the slot has no default, not an invalid request
- `workshop/2798319181/effects/gaussian` — `(depth < limit) * 6.0` converts with `float(...)`; a comparison that stays a condition is untouched
- `workshop/2138904733/effects/cutout_vignette` — mixed-width operands inside a call argument truncate to the narrowest; `CAST2`/`CAST3`/`CAST4` now classify as constructors
- Probe on 3280146735 — 3 `failed to load` and 3 `Rust shader compile failed` before, 0 and 0 after; 399 executed passes before, 432 after
- Installed corpus (10 scenes, Vulkan probe) — only 3292361861 still fails (4× `clipping_mask`, logical-not on a float, not addressed); no scene gained a failure
- 4 tests in `legalize_type_coercion.rs`, two per rule, each pinning the rewrite and its refusal; the rewriting two also compile through `NagaCompiler`

## 2026-09-20 — Download ring names the SteamCMD step before bytes move

- Change: WorkshopDownloader.phase (preparing/connecting/updating/signingIn/requesting/transferring/finishing) set alongside status; DownloadJob.phase; snapshot field phase.
- WebUI: busy tile ring shows the phase word (ring-phase) instead of an empty sweep; transfer without percent keeps speed; progress 1 + finishing reads Finishing not 100%.
- zh-Hans catalog: Preparing/Connecting/Signing in/Requesting/Finishing (Updating already present).
- python3 scripts/test.py --only DownloaderLifecycleTests: 20 passed (new testPhaseFollowsEachSteamCMDStepBeforeAndAfterTheTransfer).
- python3 scripts/test.py --only ControlPanelDiscoverTests: 6 passed (ring test extended with phased/finishing).
- python3 scripts/test.py: 519 passed, 0 failed, 11 skipped (opt-in/asset checks).
- impeccable detect on WebUI/panel.css, panel.js: no findings.
- Gap: no desktop run; ring word fit at 60/72px and Chinese rendering not visually checked. Release app not rebuilt.

## 2026-09-20 — Quiet script output, doc archive and rg ignore, log helper, section index, test-file split

Agent-cost pass. `scripts/lib/xcode.py` streams xcodebuild/cargo output to `artifacts/` and echoes only errors, failing tests and a verdict (`--verbose` restores the stream; `xcodegen --quiet`); the two 250 KB plan/progress documents moved to `docs/archive/` and a repository `.ignore` keeps `rg` out of archives, generated bindings and `upstream/`; `scripts/log_verification.py` prepends log entries and archives overflow; `docs/testing/renderer.md` gained a section index; `DownloaderTests` and `ControlPanelLayoutTests` split into five suites each over shared base classes (same 88 test methods, none rewritten).

- `python3 scripts/test.py` — exit 0; 529 native tests: 518 passed, 11 skipped (asset/opt-in), 0 failed, 33 s; 99 Python script tests OK including new `test_xcode.py` (8) and `test_log_verification.py` (8).
- `python3 scripts/test.py --only ControlPanelSyncTests --only SteamCMDRuntimeValidationTests` — 14 passed; `--only AppThemeTests` after the runner change — 3 passed, three lines of output.
- Filter replayed over nine archived xcodebuild logs: green runs echo 0 lines, the two failing ones echo 7–8 (assertion, failed case, suite verdict).
- Not verified: Release build (no app code changed); desktop behaviour untouched.

## 2026-09-20 — Parallel native tests, opt-in live Steam cases, doc split, build-on-request

Follow-up to the tiered gate. Test classes now run in parallel worker processes
(`-parallel-testing-enabled YES`, `--serial` to diagnose interference); the two
`testLive…` Workshop cases became opt-in behind
`MAC_WALLPAPER_ENGINE_NETWORK_TESTS=1`; `scripts/test.py` keeps the five newest
result bundles; `scripts/build.py` also uses `xcodegen --use-cache`. Coverage
inventory moved to `docs/testing/coverage.md`, `docs/architecture.md` gained a
section index, and the Release build is now on request
(`.omp/rules/release-build-on-request.md`) rather than after every feature.

- `python3 scripts/tests/test_test.py` — 10 tests OK (identifiers, parallel flag,
  bundle pruning, opt-in variable list).
- `python3 scripts/test.py` — Python script tests OK; native 529 tests, 518 passed,
  11 skipped, 0 failures, 1m12 wall clock (was 2m41 serial). Three parallel runs,
  no interference; skips are 9 asset/media + the 2 live Steam cases.
- `MAC_WALLPAPER_ENGINE_NETWORK_TESTS=1 python3 scripts/test.py --only WorkshopTests`
  — 7 passed, 0 skipped; without the variable, 5 passed, 2 skipped.
- No Release build: tooling and docs only, no delivery requested.

## 2026-09-20 — Tiered verification: `scripts/test.py --only`, xcodegen cache, small-fix gate

Small bug fixes were paying the full gate twice plus a Release build (~20 min).
`AGENTS.md` now scales the gate to the change (`docs/testing/README.md`
"Verification tiers"); `scripts/test.py --only <Class[/method]>` narrows the
native run and `xcodegen generate --use-cache` keeps incremental builds alive.

- `python3 scripts/tests/test_test.py` — 5 tests OK (identifier and command shape).
- `python3 scripts/test.py --only AppLanguageTests` — 5 passed, 0 failures, ~2 s wall clock.
- `python3 scripts/test.py` — Python script tests OK; native 529 tests, 520 passed,
  9 skipped, 0 failures, test phase 157 s. No Release build (tooling/docs change).

## 2026-09-20 — Discover search button wrapped vertically in Chinese; panel tests pinned to English

`.search-form` let its submit button shrink, and a CJK label breaks between any
two characters, so 搜索 rendered one glyph per line and taller than the input.
`WebUI/panel.css` now gives `.search-form button` `flex: none; white-space:
nowrap`. The first gate run also exposed that panel tests reading English labels
used `AppLanguageStore.shared`, which follows the developer's in-app language
choice; they now pass `AppLanguageStore.english()` (`Tests/Unit/Support/`).

- `python3 scripts/test.py` before the test fix, with the app set to 简体中文 —
  native 516 passed, 9 skipped, 4 failures, all Chinese labels or a JS lookup
  by English title in `ControlPanelLayoutTests`; none related to the CSS change.
- `python3 scripts/test.py` after — 73 Python tests OK; native 520 passed,
  9 skipped, 0 failures.
- `python3 scripts/build.py --swift-only --configuration Release` — exit 0,
  `** BUILD SUCCEEDED **`; bundled `Contents/Resources/WebUI/` matches `WebUI/`.
  Delivered `build/Build/Products/Release/MacWallpaperEngine.app`; not launched.
  The rendered Chinese button was not screenshotted (no desktop run).

## 2026-09-20 — In-app language picker, per-language panel catalogs, registry checks

Simplified Chinese was already translated but only reachable through macOS's
language settings. Settings → General now has **Language** (System (Auto),
English, 简体中文); the choice switches the panel in place and mirrors into the
app-domain `AppleLanguages` so native strings follow on the next launch. The
WebUI catalog moved to `WebUI/locales/zh-Hans.js` behind a registry in
`i18n.js`; `AppLanguage.supported` drives the picker and the served-file allow
list. Adding a language is documented in `docs/localization.md`.

- `python3 scripts/test.py` — 73 Python tests OK (catalog check now verifies
  Swift/i18n/locales/xcstrings registries agree, native keys all translated, key
  parity across catalogs); native 529 tests, 9 skipped, 0 failures. New:
  `AppLanguageTests` (5), `testLanguageSettingSwitchesThePanelInPlaceAndOffersEveryShippedLanguage`.
- `python3 scripts/build.py --swift-only --configuration Release` — succeeded;
  bundled `WebUI/` byte-identical to source, `locales/zh-Hans.js` and
  `zh-Hans.lproj` present. No renderer change, no desktop run; the picker's
  visual layout is unchecked on screen.
