# Documentation

Product behavior is documented per feature under `features/`; how the code is
organized and how it runs is in the two reference documents; how to build, test,
release and contribute is in the process documents; test strategy and evidence
live under `testing/`.

## Getting started

| Document | Purpose |
|---|---|
| [../README.md](../README.md) | What the app is, feature summary, quickstart |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Contributor working agreement and day-to-day loop |
| [build.md](build.md) | Toolchain, dependencies, build, package, install, troubleshooting |

## Reference

| Document | Purpose |
|---|---|
| [architecture.md](architecture.md) | Runtime architecture and module boundaries |
| [repository-layout.md](repository-layout.md) | Directory map and where new code goes |

## Process

| Document | Purpose |
|---|---|
| [conventions.md](conventions.md) | Code, test, documentation, commit and pull-request rules |
| [release.md](release.md) | Versioning, release specs, CI pipeline, in-app updater contract |
| [development-tools.md](development-tools.md) | Optional diagnostics and the desktop authorization boundary |
| [../AGENTS.md](../AGENTS.md) / [../CLAUDE.md](../CLAUDE.md) | Agent rules; CLAUDE.md is a symlink, not a separate policy |
| [../LICENSING.md](../LICENSING.md) | License-compatibility record and distribution constraints |

## Testing

| Document | Purpose |
|---|---|
| [testing/README.md](testing/README.md) | Test strategy, how to run each layer, evidence policy |
| [testing/renderer.md](testing/renderer.md) | Headless renderer/GPU checks, probe environment variables, known regressions |
| [testing/manual-smoke.md](testing/manual-smoke.md) | Manual release smoke checklist |
| [testing/verification-log.md](testing/verification-log.md) | Dated verification history |
| [testing/wallpaper-corpus.md](testing/wallpaper-corpus.md) | Local regression corpus checklist |

## Product features

| Document | Purpose |
|---|---|
| [features/control-panel.md](features/control-panel.md) | Window and panel UX, tabs, inspector, interaction reference |
| [features/workshop-downloads.md](features/workshop-downloads.md) | Discover, SteamCMD setup, download queue |
| [features/audio-response.md](features/audio-response.md) | Audio-responsive wallpapers |
| [features/lock-screen.md](features/lock-screen.md) | Experimental animated lock screen |
| [features/appearance.md](features/appearance.md) | Theme and appearance customization |

## Maintaining these docs

- **One topic per file.** When another document owns a topic, link to it in one
  sentence rather than restating it.
- **Naming.** Files under `docs/` are `lowercase-hyphenated.md` with exactly one
  `#` H1. Feature documents go in `docs/features/`, test documents in
  `docs/testing/`.
- **Index.** Every new document must be added to the table above, in the group it
  belongs to; a removed document must be removed from it. A document that is not
  listed here does not exist as far as readers are concerned.
- The remaining rules — grounding claims in the repository, the append-only
  verification log, and not citing disposable artifact paths as evidence — are in
  [conventions.md](conventions.md).
