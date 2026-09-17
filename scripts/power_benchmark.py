#!/usr/bin/env python3
"""Record the configuration a power comparison was taken under; measure nothing.

Two paired runs are comparable only when commit, configuration, hardware, macOS
build, display geometry and power state match. This writes that manifest to
`artifacts/power/` so a later measurement can be attached to it, and reports the
baseline/load matrix still to be covered. It never sets a wallpaper, captures
the screen, records audio or asks for a permission, and it runs no profiler:
`powermetrics` and Instruments need separate authorization. See
docs/testing/power-benchmark.md.
"""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from lib.glyphs import markers
from lib.paths import ARTIFACTS, ROOT

MARK = markers()
POWER_ARTIFACTS = ARTIFACTS / "power"

# Conditions from the improvement plan's baseline table. Each entry stays
# `measured: false` until a run records real numbers against this manifest.
CONDITIONS = {
    "B0": "application quit, system static wallpaper",
    "B1": "application running, no active wallpaper, panel closed",
    "B2": "same content as the load case, static poster only",
    "T1": "single display, static or low-frequency scene",
    "T2": "1080p/4K/ultrawide video at 24/30/60 FPS",
    "T3": "simple, multi-layer post-processed, particle and video-texture scenes",
    "T4": "web wallpaper with and without a cooperating pause listener",
    "T5": "two displays: one visible one occluded, then both occluded",
    "T6": "lock screen, unlock, display sleep, system preview",
    "T7": "rapid wallpaper switching, hot-plug, window and resolution changes",
    "T8": "deliberately broken input, unsupported format, repeated web crashes",
}


def command_output(command):
    """Stdout of a read-only inspection command, or None when unavailable."""
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return completed.stdout.strip() if completed.returncode == 0 else None


def hardware():
    """Chip, memory and model, read from the read-only hardware data type."""
    raw = command_output(["system_profiler", "-json", "SPHardwareDataType"])
    if raw is None:
        return {}
    try:
        entries = json.loads(raw).get("SPHardwareDataType", [])
    except json.JSONDecodeError:
        return {}
    entry = entries[0] if entries else {}
    return {key: entry[key] for key in
            ("machine_model", "chip_type", "physical_memory", "number_processors") if key in entry}


def displays():
    """Per-display pixel geometry, so results from unequal output are not compared."""
    raw = command_output(["system_profiler", "-json", "SPDisplaysDataType"])
    if raw is None:
        return []
    try:
        cards = json.loads(raw).get("SPDisplaysDataType", [])
    except json.JSONDecodeError:
        return []
    found = []
    for card in cards:
        for display in card.get("spdisplays_ndrvs", []):
            found.append({key: display[key] for key in (
                "_name", "_spdisplays_resolution", "_spdisplays_pixels",
                "spdisplays_resolution", "spdisplays_pixelresolution",
                "spdisplays_mirror", "spdisplays_online", "spdisplays_main",
            ) if key in display})
    return found


def power_state():
    """Charging state and low-power mode; both change the comparison baseline."""
    state = {"pmset_ps": command_output(["pmset", "-g", "ps"])}
    raw = command_output(["pmset", "-g", "live"])
    if raw:
        state["lowpowermode"] = next(
            (line.strip() for line in raw.splitlines() if "lowpowermode" in line), None)
    return state


def thermal_state():
    raw = command_output(["pmset", "-g", "therm"])
    return raw.splitlines() if raw else []


def build_identity(configuration):
    project = ROOT / "project.yml"
    version = None
    if project.is_file():
        for line in project.read_text().splitlines():
            if "MARKETING_VERSION" in line:
                version = line.split(":", 1)[1].strip().strip('"')
                break
    return {
        "commit": command_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"]),
        "dirty": bool(command_output(["git", "-C", str(ROOT), "status", "--porcelain"])),
        "marketing_version": version,
        "configuration": configuration,
    }


def system_identity():
    raw = command_output(["sw_vers"])
    parsed = {}
    for line in (raw or "").splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            parsed[key.strip()] = value.strip()
    return parsed


def renderer_libraries():
    """Actual dynamic-library versions the run linked against."""
    versions = {}
    for formula in ("ffmpeg@8", "quickjs-ng", "glslang", "molten-vk", "freetype", "lz4"):
        target = command_output(["readlink", f"/opt/homebrew/opt/{formula}"])
        if target:
            versions[formula] = target.rsplit("/", 1)[-1]
    return versions


def provenance():
    """Pinned revision of every vendored component that ships in the build."""
    path = ROOT / "upstream/provenance.json"
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}
    if not isinstance(data, dict):
        return {}
    # Entries without a revision describe first-party directories recorded for
    # licensing, not pinned third-party code, so they identify nothing here.
    return {entry["directory"]: entry["revision"]
            for entry in data.values()
            if isinstance(entry, dict) and "directory" in entry and entry.get("revision")}


def manifest(args):
    return {
        "recorded_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "note": args.note,
        "build": build_identity(args.configuration),
        "system": system_identity(),
        "hardware": hardware(),
        "displays": displays(),
        "power": power_state(),
        "thermal": thermal_state(),
        "renderer_libraries": renderer_libraries(),
        "upstream_revisions": provenance(),
        "measured": False,
        "measurement_tool": None,
        "conditions": [{"id": key, "description": value, "measured": False}
                       for key, value in CONDITIONS.items()],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", default="Release", help="Build configuration under test.")
    parser.add_argument("--note", default="", help="Free-text label for this manifest.")
    parser.add_argument("--print-only", action="store_true", help="Write nothing; print the manifest.")
    args = parser.parse_args()

    document = manifest(args)
    if args.print_only:
        print(json.dumps(document, indent=2))
        return 0

    POWER_ARTIFACTS.mkdir(parents=True, exist_ok=True)
    path = POWER_ARTIFACTS / (datetime.now().strftime("manifest-%Y%m%d-%H%M%S") + ".json")
    path.write_text(json.dumps(document, indent=2))
    print(f"{MARK.step} Configuration manifest: {path}")
    print(f"{MARK.warn} No power was measured: every condition is recorded as measured=false.")
    unmeasured = ", ".join(entry["id"] for entry in document["conditions"])
    print(f"{MARK.missing} Conditions still unmeasured: {unmeasured}")
    if document["build"]["dirty"]:
        print(f"{MARK.warn} Working tree is dirty; the commit alone does not identify this build.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
