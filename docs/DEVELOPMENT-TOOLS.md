# Development diagnostics

## Safe setup check

Run `python3 scripts/check-dev-tools.py`. It checks CLI versions and Xcode tool
paths only. It does not run Peekaboo desktop commands, request permissions,
launch apps, or start background services. These optional tools are not a build
or routine-test dependency.

The initial setup found Peekaboo 4.3.0 already installed, along with Instruments,
Accessibility Inspector, and xctrace in the selected Xcode. No additional desktop
automation framework or MCP server is needed: the agent can invoke the CLI.
An installed CLI is not proof that screen capture or input permissions work.

If Peekaboo is missing, follow the current installation instructions at
https://github.com/openclaw/Peekaboo. The upstream README currently recommends
`brew install openclaw/tap/peekaboo`; the documentation site still lists the older
tap. Do not reinstall or upgrade a working installation just to run this check.
Instruments and Accessibility Inspector come with full Xcode.

## Status markers

`scripts/check-dev-tools.py` and `scripts/build.py` print their `OK` / `WARN` /
`MISSING` / `+` markers through `scripts/glyphs.py`. In an interactive Warp
session with a Nerd Font installed under `~/Library/Fonts` or `/Library/Fonts`,
those markers become Nerd Font glyphs; Warp resolves them through its font
fallback, so the terminal's configured font does not have to be the patched one.
Everywhere else, including pipes, redirects, and CI logs, the output stays the
same ASCII text, because the glyphs are private use code points that render as
tofu without a patched font.

Set `MWE_GLYPHS=nerd` to force glyphs (another terminal already configured with
a Nerd Font) or `MWE_GLYPHS=ascii` to force plain markers. `python3
scripts/glyphs.py` prints the detected style and one line per marker;
`python3 scripts/test_glyphs.py` covers the detection rules and runs as part of
`python3 scripts/test.py`.

## Authorization boundary

Installing tools is not permission to test the desktop. Only run screenshots,
UI inspection, input, app launches, profiling of playback, or wallpaper changes
when the user explicitly requests the relevant desktop test. Never automatically
open System Settings to request permissions. Screen Recording and Accessibility
permissions should be granted by the user to the actual execution host when
needed. Do not collect unrelated windows, login credentials, or clipboard data.

After desktop testing is authorized, `peekaboo permissions status` can diagnose
permissions; use the installed CLI's `--help` for version-specific commands.
Prefer semantic accessibility actions and an explicit app/window target over
coordinates. Avoid autonomous open-ended agent runs. Keep screenshots and traces
local under `build/verification/`, and do not commit them.

## Which tool to use

- Routine correctness: `python3 scripts/test.py`, plus relevant headless renderer
  tests described in [../TESTING.md](../TESTING.md).
- Exploratory visual/UI diagnosis: Peekaboo, only in an authorized desktop run.
- Repeatable UI regression: existing `python3 scripts/test.py --ui`, separately
  authorized. Do not build a second framework for the same flows.
- UI labels and accessibility structure: Xcode > Open Developer Tool >
  Accessibility Inspector, during an authorized interactive session.
- CPU hot spots and memory growth: Instruments Time Profiler and Allocations.
- GPU/CPU scheduling and final Metal execution: Instruments Metal System Trace
  and Xcode Metal debugger. Correlate findings with renderer logs; Metal capture
  does not directly explain all upstream Vulkan/shader translation behavior.

For a performance comparison, use the same asset, display resolution, playback
settings, power state, and observation duration. Separate cold load from warm
shader-cache runs. Record CPU/GPU activity, memory growth, frame timing, and pause
behavior. Do not claim energy savings from a single short sample.

## Fixed asset corpus

Use [wallpaper-corpus.md](wallpaper-corpus.md) to register a small set of local,
legally usable assets. This is initially a selection checklist, not a populated
or passing test suite. Do not download arbitrary Workshop items or commit asset
packages, account/session data, or personal filesystem paths.

Follow the manual release smoke checklist in `TESTING.md`. For each run record
build revision, macOS/hardware, selected corpus cases, expected vs observed
behavior, evidence paths, and skipped checks. Explicitly mark visual behavior
unverified when only headless tests ran.

## References

- Peekaboo: https://github.com/openclaw/Peekaboo
- Apple Metal tools: https://developer.apple.com/metal/tools/
- Accessibility Inspector: https://developer.apple.com/documentation/accessibility/accessibility-inspector
