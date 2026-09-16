#!/usr/bin/env python3
"""Run non-interactive native tests; desktop automation requires --ui.

Order: the Python script tests in `scripts/tests/`, then `xcodegen generate`, then
the Swift test bundle. Result bundles land in `artifacts/tests/` and are disposable;
`scripts/clean.py` removes them. See docs/testing/README.md.
"""
import argparse
from datetime import datetime
import subprocess
import sys

from lib.glyphs import markers
from lib.paths import BUILD, ROOT, TEST_ARTIFACTS, XCODEPROJ

MARK = markers()
SCRIPT_TESTS = sorted((ROOT / "scripts/tests").glob("test_*.py"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui", action="store_true", help="Run desktop UI tests instead (takes over the desktop).")
    args = parser.parse_args()
    scheme = "MacWallpaperEngineUI" if args.ui else "MacWallpaperEngine"
    target = "MacWallpaperEngineUITests" if args.ui else "MacWallpaperEngineTests"
    if args.ui:
        print(f"{MARK.warn} Desktop automation explicitly enabled: do not use the mouse or keyboard during this run.", flush=True)
    for module in SCRIPT_TESTS:
        script_tests = subprocess.run([sys.executable, str(module)], cwd=ROOT)
        if script_tests.returncode != 0:
            return script_tests.returncode
    subprocess.run(["xcodegen", "generate"], cwd=ROOT, check=True)
    TEST_ARTIFACTS.mkdir(parents=True, exist_ok=True)
    prefix = "UI-" if args.ui else "Tests-"
    result = TEST_ARTIFACTS / (prefix + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".xcresult")
    command = [
        "xcodebuild", "-project", XCODEPROJ.name,
        "-scheme", scheme, "-configuration", "Debug", "-derivedDataPath", str(BUILD),
        "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(result),
        "-only-testing:" + target,
        "-maximum-test-execution-time-allowance", "90", "-test-timeouts-enabled", "YES", "test",
    ]
    completed = subprocess.run(command, cwd=ROOT)
    if (result / "Info.plist").exists():
        subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], cwd=ROOT)
    print(f"{MARK.step} Test evidence: {result}")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
