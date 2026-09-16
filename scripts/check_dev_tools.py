#!/usr/bin/env python3
"""Check optional macOS diagnostics without opening apps or accessing the desktop."""
from pathlib import Path
import shutil
import subprocess

from lib.glyphs import markers


def output(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)
    return result.returncode, (result.stdout + result.stderr).strip()


def main():
    mark = markers()
    missing = []
    peekaboo = shutil.which("peekaboo")
    if peekaboo:
        code, version = output([peekaboo, "--version"])
        print(f"{mark.ok if code == 0 else mark.warn} Peekaboo: {peekaboo}\n  {version}")
        if code != 0:
            missing.append("working Peekaboo CLI")
    else:
        print(f"{mark.missing} Peekaboo: see docs/development-tools.md")
        missing.append("Peekaboo")

    code, developer = output(["xcode-select", "-p"])
    if code == 0:
        developer_path = Path(developer)
        for name, path in [
            ("Instruments", developer_path.parent / "Applications/Instruments.app"),
            ("Accessibility Inspector", developer_path.parent / "Applications/Accessibility Inspector.app"),
        ]:
            present = path.is_dir()
            print(f"{(mark.ok if present else mark.missing)} {name}: {path}")
            if not present:
                missing.append(name)
    else:
        print(f"{mark.missing} selected Xcode: {developer}")
        missing.append("Xcode")

    code, trace = output(["xcrun", "--find", "xctrace"])
    print(f"{mark.ok if code == 0 else mark.missing} xctrace: {trace}")
    if code != 0:
        missing.append("xctrace")

    print("\nNo apps opened, screenshots taken, permissions requested, or desktop actions performed.")
    print("Permissions, live capture, GPU profiling, and visual correctness remain unverified.")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
