# Agent rules

Authoritative rules for automated contributors to this repository. They outrank
any skill workflow, upstream example or habit. Human contributors start at
[`CONTRIBUTING.md`](CONTRIBUTING.md).

Orientation, in reading order:

| Question | Read |
| --- | --- |
| What is this and how do I run it? | [`README.md`](README.md) |
| Where does code live and where does new code go? | [`docs/repository-layout.md`](docs/repository-layout.md) |
| How do the pieces fit together? | [`docs/architecture.md`](docs/architecture.md) |
| How do I build it? | [`docs/build.md`](docs/build.md) |
| How do I verify a change? | [`docs/testing/README.md`](docs/testing/README.md) |
| What are the code and documentation rules? | [`docs/conventions.md`](docs/conventions.md) |
| Everything else | [`docs/README.md`](docs/README.md) |
| How is the agent tooling wired? | [`.agents/README.md`](.agents/README.md) |

## Repository rules

- `project.yml` is the only source of truth for targets, build settings and
  versions. Edit it and run `xcodegen generate`; never hand-edit
  `mac-wallpaper-engine.xcodeproj`.
- `App/Bridge/Generated` is build output from `scripts/build.py`. Never edit it
  by hand.
- `upstream/` is vendored third-party code. Changing anything there requires a
  matching update to `upstream/provenance.json`, and `LICENSING.md` governs how
  it may be combined and distributed.
- `artifacts/` and `build/` are disposable and Git-ignored. Never commit them,
  never cite a path inside them as durable evidence, and use
  `python3 scripts/clean.py` to clear byproducts instead of leaving logs, result
  bundles or `.app` snapshots lying around.
- Keep private wallpaper assets, screenshots and traces out of Git.

## Skill routing and conflicts

- Skills are task guidance, not independent authorization. Follow system and
  developer instructions, the user's explicit task and authorization, and these
  project rules over conflicting skill workflows. Continue unaffected work; do
  not stop implementation solely because an optional skill step is unavailable
  or disallowed.
- Use `impeccable` for visual design and UX, and `swiftui-webkit` as the primary
  WebKit implementation skill. For work spanning both, apply each to its own
  concern rather than running two competing end-to-end workflows.
- `webkit-integration` is a supplemental, explicitly invoked reference, not a
  second automatic WebKit workflow. Its upstream examples contain API
  differences; the selected Xcode SDK and deployment target are authoritative.
  Never combine conflicting API signatures or raise the deployment target merely
  to satisfy a skill.
- Skills do not impose a read-only mode on implementation requests. Use the
  tools available in this harness within the task's authorization; respect
  actual harness restrictions and explicit review-only requests.
- Skill instructions to launch browsers or apps, capture screenshots, run
  desktop automation or rebuild Release remain subject to the verification and
  delivery rules below. Without the required authorization, use source
  inspection and non-desktop checks, report visual behavior as unverified, and
  continue. Do not open a skill's browser-based question UI automatically; ask
  in chat instead.
- Keep local skill adaptations documented in [`.agents/README.md`](.agents/README.md)
  and preserve them when updating the pinned upstream sources in
  `.agents/skills/sources.json`.

## Verification

- Routine verification must not control the desktop, capture screenshots, open
  app windows, or change the user's wallpapers.
- Use `python3 scripts/test.py` for the Python script tests and the native
  unit/integration suite. Add targeted checks from
  [`docs/testing/README.md`](docs/testing/README.md) when the change warrants
  them.
- Do not run Peekaboo, XCUITest or other desktop automation unless the user
  explicitly requests a desktop test run. Approval to implement a feature or to
  run routine tests is not approval for desktop automation.
  `python3 scripts/test.py --ui` takes over the desktop and is never a required
  completion or release gate.
- Report visual behavior as unverified when it was not checked. Do not run
  desktop automation to fill that gap automatically.
- Record what a change verified in
  [`docs/testing/verification-log.md`](docs/testing/verification-log.md), newest
  entry first, including what was explicitly not verified.
- Coverage that must not silently regress, with details and probe environment
  variables in [`docs/testing/renderer.md`](docs/testing/renderer.md):
  - Scene `general.zoom` may carry an authored scalar animation, not just a
    fixed camera scale — `scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'`.
  - Callback-only property scripts — `*CallbackOnly*` in `scene_schema_tests`
    and `script_runtime_compat_test`.
  - MDLS3 skinning must preserve the authored skeleton; mesh format versions do
    not justify flattening it —
    `MdlSchema.Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions`
    in `mdl_schema_tests`.
  - Download-speed sampling, including the local-socket check of real `nettop`
    streaming over a private PTY with CRLF handling — `DownloaderTests`.
    LF-only fixtures do not verify live sample delivery.
- The fixed local asset corpus in
  [`docs/testing/wallpaper-corpus.md`](docs/testing/wallpaper-corpus.md) is not
  yet populated; do not treat it as a passing test suite.

## Build delivery

- Release builds are an explicit integration step, not a per-session
  requirement. Multiple agents may be editing this workspace concurrently; do
  not build Release automatically after app changes. Build it only when the user
  explicitly requests a build or delivery.
- Perform targeted verification where practical. Report exactly what was
  verified and whether shared-workspace changes blocked verification.
  Distinguish changes implemented and verified from an updated app delivered.
- The user runs `build/Build/Products/Release/MacWallpaperEngine.app`. Never
  claim that this Release app contains your changes unless a successful Release
  build was performed after those changes.
- When a Release build is requested, run
  `python3 scripts/build.py --swift-only --configuration Release` for Swift-only
  changes, or `python3 scripts/build.py --configuration Release` when renderer
  changes are included.
- After a successful Release build, report its path and remind the user to quit
  and reopen the app to load the updated build. If the build fails, report the
  failure without claiming delivery. Do not launch or quit the app
  automatically as part of routine verification.

## Development tools

- Peekaboo is installed at `/opt/homebrew/bin/peekaboo` (last checked: 4.3.0)
  and can be invoked through bash; no extra Computer Use framework or MCP server
  is required. Check `--help` for version-specific usage.
- The selected full Xcode includes Instruments, Accessibility Inspector and
  `xctrace`. Use them for CPU, memory and GPU profiling and accessibility
  diagnosis when the relevant interactive test is explicitly authorized.
- Run `python3 scripts/check_dev_tools.py` for a safe installation check. It
  reports versions and paths only; it neither captures nor controls the desktop,
  and installation does not prove that Screen Recording or Accessibility
  permissions are granted.
- For explicitly requested desktop tests, use Peekaboo for exploratory visual
  checks and the existing XCUITest suite in `Tests/UI` for repeatable UI
  regression. Prefer semantic accessibility actions with explicit app and window
  targets. Do not install redundant automation frameworks.
- Tool availability is not permission to use the desktop. Do not automatically
  request permissions, launch apps, capture screenshots or modify wallpapers.
  [`docs/development-tools.md`](docs/development-tools.md) has the full
  authorization boundary and tool-selection guidance.
