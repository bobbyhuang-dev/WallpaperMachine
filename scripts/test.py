#!/usr/bin/env python3
"""Run non-interactive native tests; desktop automation requires --ui.

Order: the Python script tests in `scripts/tests/`, then `xcodegen generate`, then
the Swift test bundle. Result bundles land in `artifacts/tests/` and are disposable;
`scripts/clean.py` removes them. See docs/testing/README.md.

`--only` narrows the native run to test classes or methods
(`--only LibraryStoreTests --only WorkshopSearchTests/testPagination`) for quick
iteration on a small change; the full gate is still the default and the final word.

Opt-in layers are off by default and are requested through the environment:
`MAC_WALLPAPER_ENGINE_MEDIA_TESTS=1` (real video decoding) and
`MAC_WALLPAPER_ENGINE_NETWORK_TESTS=1` (live Steam pages).
"""
import argparse
from datetime import datetime
import os
import shutil
import subprocess
import sys

from lib.glyphs import markers
from lib.paths import BUILD, ROOT, TEST_ARTIFACTS, XCODEPROJ

MARK = markers()
SCRIPT_TESTS = sorted((ROOT / "scripts/tests").glob("test_*.py"))
NATIVE_TARGET = "MacWallpaperEngineTests"
UI_TARGET = "MacWallpaperEngineUITests"

# Opt-in test layers. xcodebuild does not hand its own environment to the hosted test
# process; `TEST_RUNNER_`-prefixed variables are forwarded with the prefix stripped,
# which is what makes these reach the tests that gate themselves on them.
OPT_IN_VARIABLES = ("MAC_WALLPAPER_ENGINE_MEDIA_TESTS", "MAC_WALLPAPER_ENGINE_NETWORK_TESTS")

# Result bundles are tens of megabytes each and only the newest ones are ever read.
KEPT_RESULT_BUNDLES = 5


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


def xcodebuild_command(scheme, target, result, only=None, parallel=True):
    command = [
        "xcodebuild", "-project", XCODEPROJ.name,
        "-scheme", scheme, "-configuration", "Debug", "-derivedDataPath", str(BUILD),
        "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(result),
    ]
    command += ["-only-testing:" + identifier for identifier in test_identifiers(target, only)]
    # Test classes run in parallel worker processes. Every suite already isolates its
    # state through `MAC_WALLPAPER_ENGINE_HOME`, temporary directories and per-test
    # `UserDefaults` suites, so workers do not share a home, a preferences domain or a
    # staging tree. Most of the wall clock is spent waiting on debounce intervals and
    # child-process reaping, which overlaps well.
    command += ["-parallel-testing-enabled", "YES" if parallel else "NO"]
    command += ["-maximum-test-execution-time-allowance", "90", "-test-timeouts-enabled", "YES", "test"]
    return command


def prune_result_bundles(keep=KEPT_RESULT_BUNDLES, directory=TEST_ARTIFACTS):
    """Delete all but the `keep` newest result bundles, newest by name."""
    bundles = sorted((entry for entry in directory.glob("*.xcresult") if entry.is_dir()), reverse=True)
    for stale in bundles[keep:]:
        shutil.rmtree(stale, ignore_errors=True)
    return bundles[keep:]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ui", action="store_true", help="Run desktop UI tests instead (takes over the desktop).")
    parser.add_argument(
        "--only", action="append", metavar="CLASS[/METHOD]",
        help="Run only this native test class or method (repeatable). Skips the Python script tests.",
    )
    parser.add_argument(
        "--serial", action="store_true",
        help="Run test classes one at a time instead of in parallel (for diagnosing interference).",
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
    # UI tests drive one desktop and cannot share it with a second worker.
    command = xcodebuild_command(scheme, target, result, args.only, parallel=not (args.serial or args.ui))
    env = dict(os.environ)
    for name in OPT_IN_VARIABLES:
        if name in env:
            env["TEST_RUNNER_" + name] = env[name]
    completed = subprocess.run(command, cwd=ROOT, env=env)
    if (result / "Info.plist").exists():
        subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], cwd=ROOT)
    print(f"{MARK.step} Test evidence: {result}")
    prune_result_bundles()
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
