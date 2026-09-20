# Agent rules

MacWallpaperEngine: macOS/arm64; AppKit/SwiftUI, WKWebView panel, Rust/C++ renderer,
sandboxed ExtensionKit lock screen. `CLAUDE.md` must stay a relative symlink to `AGENTS.md`.

## Read on demand

Read only task-relevant sections; keep this file to durable rules and routing.

- Placement / runtime: [layout](docs/repository-layout.md), [architecture](docs/architecture.md).
- Code / tests / docs: [conventions](docs/conventions.md), [testing](docs/testing/README.md).
- Build / package / versions: [build](docs/build.md), [release](docs/release.md).
- Product / features: [README](README.md), [docs index](docs/README.md). Humans: [CONTRIBUTING](CONTRIBUTING.md).

## Ownership and invariants

- `App/Services/<Domain>/`: domain logic/stores; `App/ViewModels/`: `BridgeStore`
  renderer facade and editor drafts; `App/Views/ControlPanel/`: host, snapshots, actions.
- `WebUI/`: bundled verbatim; ES modules, no npm/bundler. Preserve CSP, escaping and
  message-origin checks; new files need `WebPanelAssets` allowlisting. Network work stays in Swift.
- `Extension/`: sandboxed extension; `Shared/`: only code compiled by both targets,
  extension-API-safe. Tests: `Tests/Unit/<Domain>/` and opt-in `Tests/UI/`.
- `scripts/`: Python CLI; reuse `scripts/lib/` (paths, glyphs); tests in `scripts/tests/`.
- `project.yml` owns targets/settings/versions: run `xcodegen generate`, never hand-edit
  `mac-wallpaper-engine.xcodeproj`. Regenerate `App/Bridge/Generated/` via
  `scripts/build.py` after bridge changes; never patch generated bindings.
- `upstream/` is vendored renderer code, not app code. Every change requires updating
  `upstream/provenance.json`; preserve notices and [licensing constraints](LICENSING.md).
- Match surrounding conventions; reuse `ClientPaths`, `AppLog`, localization and
  dependency injection. Isolate tests with `MAC_WALLPAPER_ENGINE_HOME`; assert behavior,
  not wording/wiring. Migrate changed APIs completely; preserve others' concurrent edits.
- `artifacts/` = disposable evidence; `build/` = disposable Xcode output. Neither is
  durable evidence or committable; keep secrets/private assets/screenshots/traces out too.
  Coordinate cleanup; preview with `python3 scripts/clean.py --dry-run`, then use
  `python3 scripts/clean.py` (keeps built apps). `--all` deletes the delivered app.

## Skills and permissions

- System/developer instructions, explicit user scope and these rules outrank skills.
  Skills grant neither authorization nor read-only restrictions; respect actual harness
  limits and review-only requests. Continue permitted work when optional steps are
  unavailable; ask questions in chat, not a browser UI.
- `impeccable` → UI/UX; `swiftui-webkit` → primary WebKit; `webkit-integration` →
  explicit-only reference. Use each only for its concern. The selected SDK and
  `project.yml` decide APIs/deployment target, not examples; no skill-driven migration.
  Preserve [local adaptations and source pins](.agents/README.md).
- No desktop control, opening windows, screenshots, wallpaper/appearance changes, audio
  hardware, permission prompts, live Steam login or app install/restart without explicit
  authorization. Feature/test approval is not desktop approval. Peekaboo and
  `python3 scripts/test.py --ui` require a requested desktop run, never a completion/release
  gate. [Tool guidance](docs/development-tools.md) includes `python3 scripts/check_dev_tools.py`
  (safe inspection; installation ≠ permission).

## Verify and deliver

- Routine gate: `python3 scripts/test.py` (Python → XcodeGen → native unit/integration).
  Add `python3 scripts/check_renderer.py` for renderer changes; preserve applicable
  [renderer/download regressions](docs/testing/renderer.md#regression-areas-that-must-stay-covered).
  Report skipped asset checks as skipped; the [local corpus](docs/testing/wallpaper-corpus.md)
  is not a passing suite. Docs/skill-only changes: check links, paths and commands;
  no app build or desktop test.
- Release builds after every new feature (`.omp/rules/release-build-on-feature.md`)
  and for an explicit build/delivery request:
  `python3 scripts/build.py --swift-only --configuration Release` for Swift/WebUI/resources/config
  with current renderer/bindings; `python3 scripts/build.py --configuration Release`
  for renderer/bridge changes or missing outputs.
- Delivered app: `build/Build/Products/Release/MacWallpaperEngine.app`. Claim delivery
  only after a successful Release build containing the changes; report path and remind
  the user to quit/reopen. Never launch/quit automatically. Failed/blocked builds ≠ delivery.
- Update the owning docs; index new/removed documents in [docs/README.md](docs/README.md).
  Record commands, results, skips and gaps newest-first in the
  [verification log](docs/testing/verification-log.md), about ten lines per entry;
  it keeps the ten newest, older ones move to `docs/testing/archive/`. Historical
  results aren't current proof, so promote anything durable (known-failing tests,
  recurring traps) into the owning doc instead of leaving it in the log.
  Report shared-workspace blockers and unchecked visual behavior explicitly.

