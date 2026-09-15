# Build delivery

- The user runs `build/Build/Products/Release/MacWallpaperEngine.app`. After app changes, update that Release build before reporting completion; a Debug test build alone does not deliver the change to the app they use.
- For Swift-only changes, run `python3 scripts/build.py --swift-only --configuration Release`. If renderer changes are included, run `python3 scripts/build.py --configuration Release` instead.
- Confirm the Release build succeeds and report its path. Remind the user to quit and reopen the app to load the updated build; do not launch or quit it automatically as part of routine verification.

# Available development tools

- Peekaboo is installed at `/opt/homebrew/bin/peekaboo` (last checked: 4.3.0). Agents can invoke its CLI through bash; no additional Computer Use framework or MCP server is required. Check the installed command's `--help` for version-specific usage.
- The selected full Xcode includes Instruments, Accessibility Inspector, and `xctrace`. Use them for CPU/memory/GPU profiling and accessibility diagnosis when the relevant interactive test is explicitly authorized.
- Run `python3 scripts/check-dev-tools.py` for a safe installation check. This checks versions and paths only; it does not capture or control the desktop. Installation does not prove Screen Recording or Accessibility permissions are granted.
- For explicitly requested desktop tests, use Peekaboo for exploratory visual/UI checks and the existing XCUITest suite for repeatable UI regression. Prefer semantic accessibility actions with explicit app/window targets. Do not install redundant automation frameworks by default.
- Read `docs/DEVELOPMENT-TOOLS.md` for the workflow and `docs/wallpaper-corpus.md` for the fixed local asset checklist. The corpus is not yet populated; do not treat it as a passing test suite. Keep private assets, screenshots, and traces out of Git.
- Tool availability is not blanket permission to use the desktop. Follow the verification rules below; do not automatically request permissions, launch apps, capture screenshots, or modify wallpapers.

# Verification

- Routine verification must not control the desktop, capture screenshots, open app windows, or change the user's wallpapers.
- Use `python3 scripts/test.py` for native unit/integration tests and build checks as appropriate.
- Do not run Peekaboo, XCUITest, or other desktop automation unless the user explicitly requests a desktop test run. Approval to implement a feature or run routine tests is not approval for desktop automation.
- The optional `python3 scripts/test.py --ui` command takes over the desktop; it is not a required completion or release gate.
- See `TESTING.md` for coverage and the manual release smoke checklist. Report visual behavior as unverified when it was not checked; do not run desktop automation to fill that gap automatically.
