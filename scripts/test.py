#!/usr/bin/env python3
"""Run non-interactive native tests; desktop automation requires --ui.

Order: the Python script tests in `scripts/tests/`, then `xcodegen generate`, then
the Swift test bundle. Result bundles land in `artifacts/tests/` and are disposable;
`scripts/clean.py` removes them. See docs/testing/README.md.

`--only` narrows the native run to test classes or methods
(`--only LibraryStoreTests --only WorkshopSearchTests/testPagination`) for quick
iteration on a small change; the full gate is still the default and the final word.
"""
import argparse
from datetime import datetime
import os
import subprocess
import sys

from lib.glyphs import markers
from lib.paths import BUILD, ROOT, TEST_ARTIFACTS, XCODEPROJ

MARK = markers()
SCRIPT_TESTS = sorted((ROOT / "scripts/tests").glob("test_*.py"))
NATIVE_TARGET = "MacWallpaperEngineTests"
UI_TARGET = "MacWallpaperEngineUITests"


def test_identifiers(target, only):
    """`-only-testing:` identifiers for a target, given `Class` or `Class/method` names."""
    identifiers = []
    for entry in only or ():
        name = entry.strip().strip("/")
        if not name:
            continue
        if name.startswith(target + "/"):
            name = name[len(target) + 1:]
        identifiers.append(f"{target}/{name}")
    return identifiers or [target]


def xcodebuild_command(scheme, target, result, only=None):
    command = [
        "xcodebuild", "-project", XCODEPROJ.name,
        "-scheme", scheme, "-configuration", "Debug", "-derivedDataPath", str(BUILD),
        "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(result),
    ]
    command += ["-only-testing:" + identifier for identifier in test_identifiers(target, only)]
    command += ["-maximum-test-execution-time-allowance", "90", "-test-timeouts-enabled", "YES", "test"]
    return command


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ui", action="store_true", help="Run desktop UI tests instead (takes over the desktop).")
    parser.add_argument(
        "--only", action="append", metavar="CLASS[/METHOD]",
        help="Run only this native test class or method (repeatable). Skips the Python script tests.",
    )
    args = parser.parse_args()
    scheme = "MacWallpaperEngineUI" if args.ui else "MacWallpaperEngine"
    target = UI_TARGET if args.ui else NATIVE_TARGET
    if args.ui:
        print(f"{MARK.warn} Desktop automation explicitly enabled: do not use the mouse or keyboard during this run.", flush=True)
    if args.only:
        print(f"{MARK.warn} Targeted run ({', '.join(args.only)}): not a substitute for the full gate.", flush=True)
    else:
        for module in SCRIPT_TESTS:
            script_tests = subprocess.run([sys.executable, str(module)], cwd=ROOT)
            if script_tests.returncode != 0:
                return script_tests.returncode
    # `--use-cache` leaves the project untouched when project.yml has not changed,
    # so Xcode's incremental build state survives between runs.
    subprocess.run(["xcodegen", "generate", "--use-cache"], cwd=ROOT, check=True)
    TEST_ARTIFACTS.mkdir(parents=True, exist_ok=True)
    prefix = "UI-" if args.ui else "Tests-"
    result = TEST_ARTIFACTS / (prefix + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".xcresult")
    command = xcodebuild_command(scheme, target, result, args.only)
    env = dict(os.environ)
    # xcodebuild does not hand its own environment to the hosted test process.
    # `TEST_RUNNER_`-prefixed variables are forwarded with the prefix stripped,
    # which is what makes the documented opt-in
    # `MAC_WALLPAPER_ENGINE_MEDIA_TESTS=1 python3 scripts/test.py` reach the
    # tests that gate themselves on it.
    for name in ("MAC_WALLPAPER_ENGINE_MEDIA_TESTS",):
        if name in env:
            env["TEST_RUNNER_" + name] = env[name]
    completed = subprocess.run(command, cwd=ROOT, env=env)
    if (result / "Info.plist").exists():
        subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], cwd=ROOT)
    print(f"{MARK.step} Test evidence: {result}")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
