# Contributing

MacWallpaperEngine is a native macOS app (SwiftUI/AppKit plus a WKWebView control
panel), a sandboxed lock-screen ExtensionKit extension, and a vendored Rust/C++
renderer. This page gets you running and points at the document that owns each
topic; it does not repeat them.

## Setup

Apple Silicon, macOS 26 or later, and a full Xcode selected with
`xcode-select`. Then:

```sh
brew install rust cmake ninja pkg-config xcodegen
brew install quickjs-ng glslang ffmpeg@8 freetype lz4 vulkan-loader \
  vulkan-headers molten-vk eigen nlohmann-json argparse shaderc spirv-tools glm
python3 scripts/build.py
python3 scripts/test.py
python3 scripts/check_dev_tools.py   # optional diagnostics only
```

The first build compiles the renderer, generates the Swift bridge bindings,
generates the Xcode project and builds the app. Details, flags and failure modes:
[docs/build.md](docs/build.md).

## Day-to-day loop

1. Edit sources. Swift/`WebUI`/resource changes rebuild with
   `python3 scripts/build.py --swift-only`; renderer changes need a full
   `python3 scripts/build.py`.
2. Run `python3 scripts/test.py` — Python script tests, project generation, then
   `MacWallpaperEngineTests`. This never touches the desktop. Only failures and
   a verdict reach the terminal; the full log sits next to the result bundle in
   `artifacts/tests/` (`--verbose` streams it).
3. Run the targeted check your change needs:
   `python3 scripts/check_renderer.py` for renderer or scene work,
   `python3 scripts/test.py --ui` only when a desktop run is explicitly wanted.
4. Update the document that owns the behavior you changed, record the run with
   `python3 scripts/log_verification.py --title "…" --line "…"` when the
   change warrants an entry, then `python3 scripts/clean.py` before you commit.

## Where to read next

| I want to | Read |
|---|---|
| Understand how the pieces fit together | [docs/architecture.md](docs/architecture.md) |
| Find out where a file or new code belongs | [docs/repository-layout.md](docs/repository-layout.md) |
| Build, package, or install locally | [docs/build.md](docs/build.md) |
| Know the code, test and doc rules | [docs/conventions.md](docs/conventions.md) |
| Write or run tests, or record evidence | [docs/testing/README.md](docs/testing/README.md) |
| Debug the renderer or GPU output | [docs/testing/renderer.md](docs/testing/renderer.md) |
| Ship a version | [docs/release.md](docs/release.md) |
| Profile, inspect, or diagnose the desktop | [docs/development-tools.md](docs/development-tools.md) |
| Work on panel UX, downloads, audio, lock screen, theming | [docs/README.md](docs/README.md) product feature section |
| Check licensing constraints | [LICENSING.md](LICENSING.md) |

## Hard rules

- **Never hand-edit generated files.** `mac-wallpaper-engine.xcodeproj` comes from
  `project.yml`; `App/Bridge/Generated` comes from `uniffi-bindgen`. Change the
  source, regenerate, commit both.
- **Never change `upstream/` without updating `upstream/provenance.json`.** That
  file is the record of which third-party revision is vendored.
- **Never commit `artifacts/` or `build/`.** Both are Git-ignored, disposable, and
  removed by `python3 scripts/clean.py` (`--derived` also clears Xcode caches,
  `--all` removes `build/` entirely, `--dry-run` lists only). Screenshots,
  traces, wallpaper payloads, Steam session data and personal paths stay out of
  Git too.
- **Routine verification never takes over the desktop.** No screen capture, no
  synthetic input, no opening app windows, no changing the user's wallpapers
  unless a desktop run was explicitly requested. `scripts/test.py --ui` is that
  explicit case and is not a merge gate.
- **Report what you did not verify.** Headless-only coverage is a fine result;
  claiming visual correctness you never observed is not.

## Pull requests

- [ ] One coherent change, with a Conventional-Commit subject
      (`fix(scene): …`, `feat(downloads): …`).
- [ ] `python3 scripts/build.py --swift-only` (or a full build for renderer
      changes) succeeds.
- [ ] `python3 scripts/test.py` passes; targeted checks for the area you touched
      were run.
- [ ] Tests added for behavior a plausible bug would break; tests that only pinned
      wording or internals removed.
- [ ] `project.yml` and the regenerated project committed together if either
      changed.
- [ ] Docs updated in the owning file; [docs/README.md](docs/README.md) updated if
      you added a document.
- [ ] No byproducts, secrets or absolute personal paths in the diff.
- [ ] Description states what was verified and what was not.

The full checklist, including the definition of done, is in
[docs/conventions.md](docs/conventions.md).

## Automated contributors

Agents working in this repository must follow [AGENTS.md](AGENTS.md) in addition
to everything above; it is the authoritative rule file for skill routing, build
delivery and verification boundaries.
