#!/usr/bin/env python3
"""Run non-interactive native tests; desktop automation requires --ui."""
import argparse
from datetime import datetime
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui", action="store_true", help="Run desktop UI tests instead (takes over the desktop).")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    scheme = "MacWallpaperEngineUI" if args.ui else "MacWallpaperEngine"
    target = "MacWallpaperEngineUITests" if args.ui else "MacWallpaperEngineTests"
    if args.ui:
        print("Desktop automation explicitly enabled: do not use the mouse or keyboard during this run.", flush=True)
    for module in ["test_bump_version.py", "test_glyphs.py"]:
        script_tests = subprocess.run([sys.executable, str(root / "scripts" / module)], cwd=root)
        if script_tests.returncode != 0:
            return script_tests.returncode
    subprocess.run(["xcodegen", "generate"], cwd=root, check=True)
    prefix = "UI-" if args.ui else "Tests-"
    result = root / "build" / (prefix + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".xcresult")
    command = [
        "xcodebuild", "-project", "mac-wallpaper-engine.xcodeproj",
        "-scheme", scheme, "-configuration", "Debug", "-derivedDataPath", "build",
        "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(result),
        "-only-testing:" + target,
        "-maximum-test-execution-time-allowance", "90", "-test-timeouts-enabled", "YES", "test",
    ]
    completed = subprocess.run(command, cwd=root)
    if (result / "Info.plist").exists():
        subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], cwd=root)
    print(f"Test evidence: {result}")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
