# Local wallpaper regression corpus

Status: **partial offscreen corpus; desktop behavior unverified.** The corpus is
not yet populated and **must not be treated as a passing test suite.** A
generated renderer matrix and a handful of locally installed scene packages have
been exercised with `python3 scripts/check_renderer.py`; every case below that
is not marked as passed offscreen is still outstanding.

Private assets stay outside Git. Local paths, SHA-256 hashes and diagnostics
belong in the run report that `scripts/check_renderer.py` writes to
`artifacts/renderer/<run>/report.json`, which is Git-ignored and disposable.
Private before/after GPU frames and crops from individual investigations are
disposable in the same way. The generated matrix contains no workshop-specific
rendering rules.

See [renderer.md](renderer.md) for the exact checks, probe environment variables
and known shader limitations, and [verification-log.md](verification-log.md) for
what has actually been run.

Select additional assets you own or have permission to use. Record local paths
and hashes in a local inventory under the Git-ignored `artifacts/` tree, not in
this public document. Do not reuse real imports for destructive or
invalid-input tests; use copies.

## Pointing the tests at your local corpus

Corpus-dependent tests resolve their roots from the environment and **skip with
a printed reason** when the assets are absent, so a clean checkout runs green on
any machine. Never hardcode a home directory in a test.

| Variable | Default | Used by |
| --- | --- | --- |
| `WALLPAPER_MACHINE_ASSETS_ROOT` | `~/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets` | Wallpaper Engine's shipped `assets/shaders` (`crates/shader/tests/pipeline.rs`, and the bridge at runtime) |
| `WALLPAPER_MACHINE_UNPACK_ROOT` | `upstream/renderer/unpack` | shaders unpacked from workshop packages |

A skipped case is **not** a passing case. Run
`cargo test -p shader --test pipeline -- --nocapture` and read the `skipping …`
lines to see exactly which files are missing before claiming shader coverage.

## Cases

| Case | Asset to select | Expected checks | Status |
| --- | --- | --- | --- |
| video-basic | Short ordinary video, known dimensions and colors | Playback, fill/match/stretch, orientation, pause/resume | Needs asset |
| scene-basic | Acheron Black Hole | Pooled/isolated allocation pixel equality | Passed offscreen; desktop/animation unverified |
| scene-effects | Sparkle multi-character scene | Pooled/isolated equality; paused effect timeline; blink geometry | Passed offscreen; sampled blink cycle inspected; desktop unverified |
| scene-text-script | Lonely Cat | Fonts, clock/date, pooled/isolated allocation pixel equality | Passed offscreen; live audio/desktop unverified |
| generated-composites | Eight original synthetic scenes | Transparent input, nested children, hidden parents, transforms, order, pixel assertions | Passed offscreen; no private assets needed |
| scene-audio | Audio-responsive scene | Response to authorized test audio, quiet-input behavior | Needs asset |
| invalid-input | Disposable malformed package and missing-resource copy | Useful error, no crash, subsequent valid apply succeeds | Needs fixture |

## What to record per asset

- Stable case ID, source URL or provenance, usage/license restrictions.
- Package hash (or a file-hash inventory for directory assets) and asset version.
- Local project path and required scene assets; never account credentials.
- Expected appearance, playback behavior, known unsupported features.
- Reference evidence source: a previous build is a baseline, not proof of
  correctness.

## What to record per authorized desktop run

Desktop runs require explicit authorization; see [README.md](README.md) for the
boundary and [manual-smoke.md](manual-smoke.md) for the checklist.

- Date, source revision and dirty state, Release app path, macOS and hardware.
- Case IDs, displays and Spaces, scaling, FPS settings, audio and power
  conditions.
- Cold/warm cache state, load time, frame timing, CPU/GPU/memory observations.
- Pass/fail/unverified per check, evidence paths, and the restoration outcome.

Cross-cutting checks, when hardware and authorization permit: multiple displays,
multiple Spaces and Mission Control posters, sleep/wake, quit and relaunch
restoration, external wallpaper changes, invalid→valid recovery. A still
screenshot does not prove animation smoothness or immediate first-frame
delivery.
