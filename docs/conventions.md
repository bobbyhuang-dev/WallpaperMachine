# Conventions

The rules this repository actually follows. Most of them are descriptions of
existing code: when a rule and the surrounding file disagree, match the file and
raise the conflict rather than reformatting someone else's code in passing.

## Repository structure

- Application code goes in `App/`, grouped by role (`Services/<Domain>/`,
  `ViewModels/`, `Views/ControlPanel/`, `Bridge/`, `Logging/`). Lock-screen
  extension code goes in `Extension/`, and only types both targets compile go in
  `Shared/`.
- The web control panel lives in `WebUI/` and is bundled verbatim as the app
  resource folder `WebUI`.
- Third-party renderer sources stay under `upstream/renderer/`. Do not add
  first-party app code there, and do not change vendored sources without
  recording the revision in `upstream/provenance.json`.
- Tests go in `Tests/Unit/<Domain>/` (non-interactive) or `Tests/UI/`
  (XCUITest, takes over the desktop).
- Developer commands go in `scripts/`; their shared helpers in `scripts/lib/`;
  their own tests in `scripts/tests/`.
- Everything a run produces is disposable: `artifacts/` for evidence, `build/`
  for Xcode output. Both are Git-ignored.

Adding a new target, source directory, resource or build setting means editing
`project.yml` and regenerating the project. See
[repository-layout.md](repository-layout.md) for the full map.

## Swift

- **One primary type per file, named after it.** `AppLog.swift` declares
  `enum AppLog`, `WorkshopStore.swift` declares `WorkshopStore`. Small supporting
  types (`Report`, `ImportError`, a private helper class) stay nested in or
  beside the type that owns them.
- **Imports first, alphabetically**, one per line: `import AppKit` / `import
  Darwin` / `import Foundation`. Test files open with `import XCTest` followed by
  `@testable import MacWallpaperEngine`.
- **Indentation follows the file.** Four spaces dominate `App/Services/` and
  `Tests/`; the control-panel views, `Extension/` and `Shared/` use two. Braces
  are K&R (opening brace on the declaration line). Never reindent a file you are
  only partly changing.
- **Dependency injection through default initializer arguments**, so production
  call sites stay argument-free and tests substitute fakes:
  `init(session: URLSession = .shared)`,
  `init(defaults: UserDefaults = .standard)`,
  `init(processRunner: any SteamCMDProcessRunning = SteamCMDProcessRunner())`,
  `init(currentAppURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default)`.
  Where the seam needs more than one implementation, declare a `Sendable`
  protocol (`AppUpdateClient`, `SteamCMDProcessRunning`) and inject `any` of it.
  Reaching for a singleton or `Bundle.main` in the middle of a method is what
  makes a type untestable; put it in the initializer default instead.
- **Filesystem and process work belongs in an `actor`** (`WallpaperImportService`,
  `WorkshopDownloader`); observable UI state belongs in a `@MainActor` store
  (`BridgeStore`, `WorkshopStore`, `AppUpdateStore`). Long operations honour
  cancellation with `try Task.checkCancellation()` and clean up staging in
  `defer`.
- **Stateless namespaces are `enum` with `static` members**, not empty structs or
  classes (`AppLog`, `ClientPaths`).
- **Errors are typed values, not strings**: a small struct conforming to
  `LocalizedError`, or a coded issue such as `AppUpdateIssue(code:detail:)`.
  Report failures; never swallow them into a silent no-op.
- **User-facing text is localized**: native strings use `String(localized:)` and
  `App/Resources/Localizable.xcstrings` / `InfoPlist.xcstrings`. WebUI strings use
  `t(source, params)` and the Simplified Chinese catalog in `WebUI/i18n.js`;
  static HTML uses `data-i18n` / `data-i18n-label`. Translate labels, never action
  identifiers, option values, paths or third-party content. Escape translated
  text and interpolated values at the HTML boundary; use named placeholders
  instead of assembling sentences from English fragments. Missing keys fall
  back to their English source. No hardcoded English in new UI strings.
- **Log through `AppLog`** (`trace`/`debug`/`info`/`warn`/`error`), which routes
  into the in-app log view. Do not add `print` to app code.
- **Paths come from `ClientPaths`.** Never hardcode `~/Library/Application
  Support/...`; the `MAC_WALLPAPER_ENGINE_HOME` override is what keeps tests off
  the real library.
- **`App/Bridge/Generated/` is build output.** It is written by `uniffi-bindgen`
  during [the build](build.md); hand edits are lost on the next build. Change the
  bridge crate under `upstream/renderer/` and regenerate.
- Comments explain a decision that is not visible from the code (why a staging
  directory is a sibling of the library, why an rpath is deleted). `///` doc
  comments state a type's responsibility in one line. No commentary that restates
  the next statement.

## Web control panel (`WebUI/`)

- Plain ES modules, no bundler, no npm dependency, no build step: the files ship
  exactly as written. Two-space indentation, single-quoted JavaScript strings.
- The panel is served from the custom `mwe-ui:` scheme out of the bundled
  resource folder, under a strict `Content-Security-Policy`
  (`default-src 'none'; script-src 'self'; style-src 'self'`). That means no
  inline `<script>`, no remote fonts or CDNs, and no network access from the
  page. Fetching belongs in Swift.
- Every value interpolated into markup goes through the module's `escapeHTML`
  helper. Building HTML from unescaped model data is a defect, not a style
  preference.
- The page never calls native APIs directly: controls carry `data-action`
  attributes, actions are dispatched to Swift over the reply-based script message
  handler, and the panel re-renders from the snapshot it gets back. Swift
  validates the message origin.
- Colors, radii and surfaces come from the CSS custom properties defined in
  `:root`; `theme.js` sets `data-theme`, `data-theme-mode` and `data-tone` on
  `<html>` and injects contrast-fitted accent tokens. Never hardcode a hex value
  in a component rule.
- Icons are Lucide glyphs vendored in `WebUI/icons.js` (ISC, version noted in the
  file header) and rendered through `panel.js`'s `icon(name)` helper. To add one, copy
  its node list from the Lucide package under the panel's name; never hand-draw SVG
  paths or load an icon font.
- Keep the accessibility scaffolding: `aria-label` on landmarks, `role="alert"`
  and `aria-live` on status regions, real `<button>`/`<dialog>` elements.

## Python scripts

- File names are `snake_case.py`; each starts with `#!/usr/bin/env python3` and a
  one-line module docstring describing what it does.
- Standard library only. No third-party packages, no virtualenv.
- Arguments via `argparse`, usually with `description=__doc__`. Flags are
  `--kebab-case`.
- Define `main()` and end with `raise SystemExit(main())`; `main()` returns an
  exit code (`0`/`1`) rather than calling `sys.exit` from nested helpers. Scripts
  that only orchestrate subprocesses may instead translate
  `subprocess.CalledProcessError` into that process's return code.
- Shared logic goes in `scripts/lib/` — repository paths in `scripts/lib/paths.py`,
  status markers in `scripts/lib/glyphs.py`. Do not recompute the repository root
  or re-derive shared paths in a new script.
- Status output uses `markers()` from `scripts/lib/glyphs.py`
  (`OK`/`WARN`/`MISSING`/`+`, upgraded to Nerd Font glyphs only where they
  render). Do not invent per-script symbols or emoji. See
  [development-tools.md](development-tools.md).
- Every script gets a test in `scripts/tests/` when it contains real logic
  (parsing, version arithmetic, detection rules) rather than only shelling out.
  `python3 scripts/test.py` runs them.

## Tests

Full strategy, commands and evidence policy: [testing/README.md](testing/README.md).
The rules that bind every change:

- Pick the cheapest layer that can observe the behavior: a Swift unit test in
  `Tests/Unit/<Domain>/`, a Python test in `scripts/tests/`, a headless renderer
  check ([testing/renderer.md](testing/renderer.md)), and only then `Tests/UI/`.
- Assert what a consumer observes — returned values, resulting filesystem state,
  emitted errors, ordering and precedence. Never assert wiring, defaults,
  forwarding, mock echoes, or the text of a source file.
- Deterministic and isolated: unique temporary directories, a redirected
  `MAC_WALLPAPER_ENGINE_HOME`, injected fakes instead of the network or the real
  SteamCMD, cleanup in `defer`. A test must pass in the full suite and on its
  own, in any order.
- Routine verification never controls the desktop, captures the screen, opens app
  windows, or changes the user's wallpapers. Desktop runs
  (`python3 scripts/test.py --ui`) happen only when explicitly requested.
- A test that only pins wording, an implementation detail or an incidental
  default must be deleted, not re-pinned to the new text — regardless of who
  wrote it.

## Documentation

- One topic per file. If a second document needs the topic, link to the owner in
  one sentence instead of restating it.
- Files under `docs/` are `lowercase-hyphenated.md`, with exactly one `#` H1.
  Product feature docs go in `docs/features/`, test documents in `docs/testing/`.
- Adding or removing a document means updating [README.md](README.md), the index.
- Ground every statement in the repository: real paths, real flags, real test
  names. Delete a claim you cannot confirm instead of softening it.
- [testing/verification-log.md](testing/verification-log.md) is newest-entry
  first and keeps the ten newest entries. An entry is a heading, optional short
  context and a bullet per command with exit status, counts and skips — about
  ten lines. Never edit a recorded result. Trimming is a separate act: move the
  oldest entries verbatim into `testing/archive/` and promote anything still
  true about the current tree into the doc that owns it first. A durable fact
  left only in the log is a fact nobody will find.
- Never cite a path under `artifacts/` or `build/` as durable evidence: both are
  Git-ignored and are deleted by `python3 scripts/clean.py`. Describe what was
  exercised and what the run showed.
- State what was **not** verified. "Visual behavior unverified; headless checks
  only" is a complete and acceptable result.

## Commits and pull requests

- Conventional-Commit style subjects, as in the existing history:
  `feat(appearance): add light theme, system adaptation and customization`,
  `fix(scene): drive the global camera from the general.zoom animation`,
  `test(probe): add property overrides and synthetic clicks to the probe`,
  `docs(agents): record the new regression coverage and probe controls`,
  `chore(xcodeproj): match xcodegen target order`. Imperative mood, lower case
  after the colon, no trailing period.
- A version bump is requested with a standalone `release: patch|minor|major|x.y.z`
  line and performed by CI; `chore: bump version to x.y.z` commits are produced
  by the Version workflow, not by hand. See [release.md](release.md).
- Things that must change together in one commit:
  - `project.yml` and the regenerated `mac-wallpaper-engine.xcodeproj` (run
    `xcodegen generate`, which any `scripts/build.py` or `scripts/test.py` run
    does for you);
  - a bridge-crate interface change and the regenerated `App/Bridge/Generated`;
  - a behavior change and the documentation that describes that behavior;
  - a vendored `upstream/` update and `upstream/provenance.json`.
- Never commit `artifacts/`, `build/`, screenshots, traces, wallpaper payloads,
  Steam session data, credentials, or absolute personal paths.

## Definition of done

- [ ] Behavior implemented end to end — no stubs, placeholders or dead flags.
- [ ] Every call site of a changed API migrated; no compatibility shim or unused
      old path left behind.
- [ ] `python3 scripts/test.py` passes, plus any targeted check the change needs
      (`scripts/check_renderer.py` for renderer work).
- [ ] New or changed behavior is covered by a test that would fail without the
      change; tests that no longer defend a contract are deleted.
- [ ] `project.yml` and the generated project agree; generated bindings
      regenerated if the bridge changed.
- [ ] Documentation updated in the file that owns the topic, and
      [README.md](README.md) updated if a document was added.
- [ ] Verification recorded honestly, including what was not verified.
- [ ] No byproducts left in the tree (`python3 scripts/clean.py`).
