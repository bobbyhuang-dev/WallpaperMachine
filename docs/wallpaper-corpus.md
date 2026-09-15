# Local wallpaper regression corpus

Status: **partial offscreen corpus; desktop behavior unverified**. The generated
renderer matrix and three locally installed scene packages were tested with
`python3 scripts/test-renderer.py`. Local paths, SHA-256 hashes and diagnostics
are in `build/verification/adaptive-20260915-021127/report.json`; private assets
remain outside Git. The matrix contains no workshop-specific rendering rules.
See [../TESTING.md](../TESTING.md) for the exact checks and known shader limitations.
The animation repair was additionally verified against Sparkle and the generated
matrix in `build/verification/adaptive-20260915-215052/report.json`, with no shader
diagnostics. Private seven-second before/after animation evidence is under
`build/verification/render-animation-fix/`; desktop presentation remains unverified.
The translucent-coverage fix (source-over alpha accumulation) was verified against
the generated matrix, its new synthetic coverage scene, Sparkle and four other
locally installed scenes in
`build/verification/adaptive-20260915-235447/report.json`, with no new diagnostics.
Private before/after crops are under `build/verification/eye-outline/`.

Select additional assets you own or have permission to use. Record local paths
and hashes in a local inventory under `build/verification/`, not this public
document. Do not reuse real imports for destructive/invalid-input tests; use copies.

| Case | Asset to select | Expected checks | Status |
| --- | --- | --- | --- |
| video-basic | Short ordinary video, known dimensions and colors | Playback, fill/match/stretch, orientation, pause/resume | Needs asset |
| scene-basic | Acheron Black Hole | Pooled/isolated allocation pixel equality | Passed offscreen; desktop/animation unverified |
| scene-effects | Sparkle multi-character scene | Pooled/isolated equality; paused effect timeline; blink geometry | Passed offscreen; sampled blink cycle inspected; desktop unverified |
| scene-text-script | Lonely Cat | Fonts, clock/date, pooled/isolated allocation pixel equality | Passed offscreen; live audio/desktop unverified |
| generated-composites | Eight original synthetic scenes | Transparent input, nested children, hidden parents, transforms, order, pixel assertions | Passed offscreen; no private assets needed |
| scene-audio | Audio-responsive scene | Response to authorized test audio, quiet-input behavior | Needs asset |
| invalid-input | Disposable malformed package and missing-resource copy | Useful error, no crash, subsequent valid apply succeeds | Needs fixture |

For every selected asset, record:

- Stable case ID, source URL or provenance, usage/license restrictions.
- Package hash (or a file-hash inventory for directory assets) and asset version.
- Local project path and required scene assets; never account credentials.
- Expected appearance, playback behavior, known unsupported features.
- Reference evidence source: a previous build is a baseline, not proof of correctness.

For each explicitly authorized desktop run, record:

- Date, source revision/dirty state, Release app path, macOS and hardware.
- Case IDs, displays/Spaces, scaling, FPS settings, audio and power conditions.
- Cold/warm cache state, load time, frame timing, CPU/GPU/memory observations.
- Pass/fail/unverified per check, evidence paths, and restoration outcome.

Cross-cutting checks (when hardware and authorization permit): multiple displays,
multiple Spaces/Mission Control posters, sleep/wake, quit/relaunch restoration,
external wallpaper changes, invalid→valid recovery. Use the detailed checklist
in [../TESTING.md](../TESTING.md). A still screenshot does not prove animation
smoothness or immediate first-frame delivery.
