#!/usr/bin/env python3
"""Check optional macOS diagnostics without opening apps or accessing the desktop."""
from pathlib import Path
import shutil
import subprocess


def output(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)
    return result.returncode, (result.stdout + result.stderr).strip()


def main():
    missing = []
    peekaboo = shutil.which("peekaboo")
    if peekaboo:
        code, version = output([peekaboo, "--version"])
        print(f"{'OK' if code == 0 else 'WARN'} Peekaboo: {peekaboo}\n  {version}")
        if code != 0:
            missing.append("working Peekaboo CLI")
    else:
        print("MISSING Peekaboo: see docs/DEVELOPMENT-TOOLS.md")
        missing.append("Peekaboo")

    code, developer = output(["xcode-select", "-p"])
    if code == 0:
        developer_path = Path(developer)
        for name, path in [
            ("Instruments", developer_path.parent / "Applications/Instruments.app"),
            ("Accessibility Inspector", developer_path.parent / "Applications/Accessibility Inspector.app"),
        ]:
            present = path.is_dir()
            print(f"{'OK' if present else 'MISSING'} {name}: {path}")
            if not present:
                missing.append(name)
    else:
        print(f"MISSING selected Xcode: {developer}")
        missing.append("Xcode")

    code, trace = output(["xcrun", "--find", "xctrace"])
    print(f"{'OK' if code == 0 else 'MISSING'} xctrace: {trace}")
    if code != 0:
        missing.append("xctrace")

    print("\nNo apps opened, screenshots taken, permissions requested, or desktop actions performed.")
    print("Permissions, live capture, GPU profiling, and visual correctness remain unverified.")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
