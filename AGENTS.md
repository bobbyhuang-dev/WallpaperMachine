# Build delivery

- The user runs `build/Build/Products/Release/MacWallpaperEngine.app`. After app changes, update that Release build before reporting completion; a Debug test build alone does not deliver the change to the app they use.
- For Swift-only changes, run `python3 scripts/build.py --swift-only --configuration Release`. If renderer changes are included, run `python3 scripts/build.py --configuration Release` instead.
- Confirm the Release build succeeds and report its path. Remind the user to quit and reopen the app to load the updated build; do not launch or quit it automatically as part of routine verification.

# Verification

- Routine verification must not control the desktop, capture screenshots, open app windows, or change the user's wallpapers.
- Use `python3 scripts/test.py` for native unit/integration tests and build checks as appropriate.
- Do not run Peekaboo, XCUITest, or other desktop automation unless the user explicitly requests a desktop test run. Approval to implement a feature or run routine tests is not approval for desktop automation.
- The optional `python3 scripts/test.py --ui` command takes over the desktop; it is not a required completion or release gate.
- See `TESTING.md` for coverage and the manual release smoke checklist. Report visual behavior as unverified when it was not checked; do not run desktop automation to fill that gap automatically.
