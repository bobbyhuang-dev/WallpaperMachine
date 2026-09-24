#!/usr/bin/env python3
"""Record the configuration a power comparison was taken under and, on request, sample it.

Two paired runs are comparable only when commit, configuration, hardware, macOS
build, display geometry and power state match. This writes that manifest to
`artifacts/power/` so a later measurement can be attached to it, and reports the
baseline/load matrix still to be covered. It never sets a wallpaper, captures
the screen, records audio or asks for a permission.

`--measure SECONDS --condition ID` also samples the accumulated CPU time (`ps`)
and GPU time (`ioreg` AGXDeviceUserClient) of the application, WindowServer,
coreaudiod, WebContent and the lock-screen extension across the window; the
whole machine's mean power draw from the battery controller's own accumulators
(`ioreg` AppleSmartBattery PowerTelemetryData), which is what a menu-bar watt
meter shows and which includes memory, display and everything else outside the
CPU and GPU cores; and, with `--powermetrics`, the CPU + GPU + ANE package power
`powermetrics` reports. powermetrics needs root: the script runs it directly as
root, through `sudo -S` with the password read from one stdin line
(`--sudo-password-stdin`), or through `sudo -n`. The password only ever travels
from this process's stdin to sudo's stdin. See docs/testing/power-benchmark.md.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
import plistlib
import re
import subprocess
import sys
import time

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

# Processes a measurement attributes work to, keyed by executable file name.
# WebContent is every WebKit content process of this user, not only this app's;
# coreaudiod runs the system audio tap an audio-reactive wallpaper asks for.
ROLE_EXECUTABLES = {
    "app": "WallpaperMachine",
    "window_server": "WindowServer",
    "core_audio": "coreaudiod",
    "web_content": "com.apple.WebKit.WebContent",
    "extension": "WallpaperMachineExtension",
}
CPU_TIME = re.compile(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)")
GPU_CLIENT = "+-o AGXDeviceUserClient"
GPU_CREATOR = re.compile(r'"IOUserClientCreator" = "pid (\d+), ')
GPU_TIME = re.compile(r'"accumulatedGPUTime"=(\d+)')
POWER_LINES = {
    key: re.compile(rf"^\s*{re.escape(label)}: (\d+(?:\.\d+)?) mW\s*$", re.MULTILINE)
    for key, label in (
        ("cpu_mw", "CPU Power"),
        ("gpu_mw", "GPU Power"),
        ("ane_mw", "ANE Power"),
        ("combined_mw", "Combined Power (CPU + GPU + ANE)"),
    )
}
# Whole-machine power from the battery controller: each is a running sum of mW
# readings and the number of readings in it, so a window's mean is the ratio of
# their deltas. SystemLoad is what the machine consumes whatever powers it;
# SystemPowerIn is what the adapter delivers, charging included, and does not
# advance on battery.
SYSTEM_POWER_ACCUMULATORS = (
    ("load_mw", "AccumulatedSystemLoad", "SystemLoadAccumulatorCount"),
    ("power_in_mw", "AccumulatedSystemPowerIn", "SystemPowerInAccumulatorCount"),
)


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
    for formula in ("mwe-ffmpeg", "quickjs-ng", "glslang", "molten-vk", "freetype", "lz4"):
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


def parse_cpu_time(text: str) -> float | None:
    """Seconds in a `ps -o time=` value `[D-][H:]M:S[.ff]`; minutes are unbounded."""
    match = CPU_TIME.fullmatch(text.strip())
    if match is None:
        return None
    days, hours, minutes, seconds = match.groups()
    return (int(days or 0) * 86400 + int(hours or 0) * 3600 + int(minutes) * 60
            + float(seconds))


def role_pids() -> dict[str, list[int]]:
    """Running processes per measured role, matched by executable file name."""
    found = {role: [] for role in ROLE_EXECUTABLES}
    by_name = {name: role for role, name in ROLE_EXECUTABLES.items()}
    for line in (command_output(["ps", "-axwwo", "pid=,comm="]) or "").splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        role = by_name.get(os.path.basename(fields[1]))
        if role is not None:
            found[role].append(int(fields[0]))
    return found


def cpu_seconds(pids: list[int]) -> dict[int, float]:
    """Accumulated user + system CPU seconds of each pid that is still running."""
    if not pids:
        return {}
    raw = command_output(["ps", "-o", "pid=,time=", "-p", ",".join(map(str, pids))])
    found = {}
    for line in (raw or "").splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0].isdigit():
            seconds = parse_cpu_time(fields[1])
            if seconds is not None:
                found[int(fields[0])] = seconds
    return found


def parse_gpu_times(text: str) -> dict[int, int]:
    """Accumulated GPU nanoseconds per creating pid, summed over its Metal clients."""
    found: dict[int, int] = {}
    for block in text.split(GPU_CLIENT):
        creator = GPU_CREATOR.search(block)
        if creator is None:
            continue
        pid = int(creator.group(1))
        found[pid] = found.get(pid, 0) + sum(int(value) for value in GPU_TIME.findall(block))
    return found


def gpu_times() -> dict[int, int] | None:
    raw = command_output(["ioreg", "-r", "-c", "AGXDeviceUserClient", "-l", "-w", "0"])
    return None if raw is None else parse_gpu_times(raw)


def parse_power_telemetry(text: str) -> dict | None:
    """PowerTelemetryData of the first battery in `ioreg -a` plist output."""
    try:
        entries = plistlib.loads(text.encode())
    except (plistlib.InvalidFileException, ValueError):
        return None
    if not isinstance(entries, list) or not entries or not isinstance(entries[0], dict):
        return None
    telemetry = entries[0].get("PowerTelemetryData")
    return telemetry if isinstance(telemetry, dict) else None


def power_telemetry() -> dict | None:
    raw = command_output(["ioreg", "-r", "-c", "AppleSmartBattery", "-a"])
    return None if raw is None else parse_power_telemetry(raw)


def system_power(before: dict | None, after: dict | None) -> dict:
    """Mean whole-machine power between two telemetry snapshots."""
    if before is None or after is None:
        return {"measured": False, "reason": "no AppleSmartBattery power telemetry on this Mac"}
    result: dict = {"measured": True}
    for key, total, count in SYSTEM_POWER_ACCUMULATORS:
        samples = after.get(count, 0) - before.get(count, 0)
        result[key] = round((after.get(total, 0) - before.get(total, 0)) / samples) \
            if samples > 0 else None
        if key == "load_mw":
            result["samples"] = max(samples, 0)
    if result["load_mw"] is None:
        return {"measured": False, "reason": "the system load accumulator did not advance"}
    return result


def parse_powermetrics(text: str) -> dict:
    """Mean package power over the samples powermetrics printed."""
    values = {key: [float(value) for value in pattern.findall(text)]
              for key, pattern in POWER_LINES.items()}
    samples = len(values["combined_mw"])
    if samples == 0:
        return {"measured": False, "reason": "powermetrics printed no power samples"}
    result = {"measured": True, "samples": samples}
    for key, found in values.items():
        result[key] = round(sum(found) / len(found), 1) if found else None
    return result


def powermetrics_command(seconds: int) -> list[str]:
    return ["/usr/bin/powermetrics", "--samplers", "cpu_power,gpu_power",
            "-i", "1000", "-n", str(seconds)]


def package_power(seconds: int, sudo_password: str | None) -> dict:
    """Run powermetrics for the window; the password goes only to sudo's stdin."""
    command = powermetrics_command(seconds)
    stdin = None
    if os.geteuid() != 0:
        if sudo_password is None:
            command = ["sudo", "-n", *command]
        else:
            command = ["sudo", "-S", "-p", "", *command]
            stdin = sudo_password + "\n"
    try:
        completed = subprocess.run(command, input=stdin, capture_output=True, text=True,
                                   timeout=seconds + 30, check=False)
    except subprocess.TimeoutExpired:
        return {"measured": False, "reason": "powermetrics did not finish in time"}
    except OSError as error:
        return {"measured": False, "reason": f"powermetrics could not start: {error.strerror}"}
    if completed.returncode != 0:
        lines = [line.strip() for line in completed.stderr.splitlines() if line.strip()]
        reason = lines[0] if lines else f"powermetrics exited with status {completed.returncode}"
        return {"measured": False, "reason": reason}
    return parse_powermetrics(completed.stdout)


def role_usage(pids, cpu_before, cpu_after, gpu_before, gpu_after, elapsed) -> dict:
    """CPU and GPU busy percentages of one role over the window."""
    measured = [pid for pid in pids if pid in cpu_before and pid in cpu_after]
    usage = {
        "pids": measured,
        "exited": [pid for pid in pids if pid not in cpu_after],
        "cpu_percent": None,
        "gpu_percent": None,
    }
    if not measured:
        return usage
    cpu = sum(cpu_after[pid] - cpu_before[pid] for pid in measured)
    usage["cpu_percent"] = round(cpu / elapsed * 100, 1)
    if gpu_before is not None and gpu_after is not None:
        deltas = [gpu_after.get(pid, 0) - gpu_before.get(pid, 0) for pid in measured]
        if min(deltas) < 0:
            usage["gpu_note"] = "a GPU client closed during the window"
        else:
            usage["gpu_percent"] = round(sum(deltas) / 1e9 / elapsed * 100, 1)
    return usage


def measure(seconds: int, use_powermetrics: bool, sudo_password: str | None) -> dict:
    """Sample every role and the machine before and after the window, package power across it."""
    roles = role_pids()
    pids = sorted({pid for group in roles.values() for pid in group})
    started = time.monotonic()
    cpu_before = cpu_seconds(pids)
    gpu_before = gpu_times()
    telemetry_before = power_telemetry()
    if use_powermetrics:
        power = package_power(seconds, sudo_password)
    else:
        power = {"measured": False, "reason": "--powermetrics was not requested"}
    # A refused or failed powermetrics returns at once. The window is still as
    # long as asked, or every rate below would describe a fraction of a second.
    remaining = seconds - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(remaining)
    elapsed = time.monotonic() - started
    cpu_after = cpu_seconds(pids)
    gpu_after = gpu_times()
    system = system_power(telemetry_before, power_telemetry())
    tools = ["ps accumulated CPU time"]
    if gpu_before is not None and gpu_after is not None:
        tools.append("ioreg AGXDeviceUserClient accumulatedGPUTime")
    if system["measured"]:
        tools.append("ioreg AppleSmartBattery PowerTelemetryData accumulators")
    if power["measured"]:
        tools.append("powermetrics cpu_power,gpu_power")
    return {
        "tools": tools,
        "elapsed_seconds": round(elapsed, 2),
        "processes": {
            role: {"executable": ROLE_EXECUTABLES[role],
                   **role_usage(group, cpu_before, cpu_after, gpu_before, gpu_after, elapsed)}
            for role, group in roles.items()
        },
        "system_power": system,
        "package_power": power,
    }


def positive_seconds(text: str) -> int:
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be a positive number of seconds")
    return value


def describe_role(role: str, usage: dict) -> str:
    if not usage["pids"]:
        return f"{role}: not running"
    gpu = "unavailable" if usage["gpu_percent"] is None else f"{usage['gpu_percent']} %"
    return f"{role}: CPU {usage['cpu_percent']} %, GPU {gpu}"


def attach_measurement(document: dict, condition: str, seconds: int, measurement: dict) -> None:
    document["measured"] = True
    document["measurement_tool"] = "; ".join(measurement["tools"])
    for entry in document["conditions"]:
        if entry["id"] == condition:
            entry["measured"] = True
    document["measurement"] = {
        "condition": condition,
        "seconds": seconds,
        "elapsed_seconds": measurement["elapsed_seconds"],
        "processes": measurement["processes"],
        "system_power": measurement["system_power"],
        "package_power": measurement["package_power"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", default="Release", help="Build configuration under test.")
    parser.add_argument("--note", default="", help="Free-text label for this manifest.")
    parser.add_argument("--print-only", action="store_true", help="Write nothing; print the manifest.")
    parser.add_argument("--measure", type=positive_seconds, metavar="SECONDS",
                        help="Sample CPU and GPU time of the measured processes over this window.")
    parser.add_argument("--condition", choices=list(CONDITIONS),
                        help="Condition the measured window represents (required with --measure).")
    parser.add_argument("--powermetrics", action="store_true",
                        help="Also record package power with powermetrics (needs root or sudo).")
    parser.add_argument("--sudo-password-stdin", action="store_true",
                        help="Read the sudo password for powermetrics from one line of stdin.")
    args = parser.parse_args()
    if args.measure is None:
        if args.condition or args.powermetrics or args.sudo_password_stdin:
            parser.error("--condition, --powermetrics and --sudo-password-stdin need --measure")
    elif args.condition is None:
        parser.error("--measure needs --condition")
    if args.sudo_password_stdin and not args.powermetrics:
        parser.error("--sudo-password-stdin needs --powermetrics")

    password = sys.stdin.readline().rstrip("\r\n") if args.sudo_password_stdin else None
    document = manifest(args)
    if args.measure is not None:
        measurement = measure(args.measure, args.powermetrics, password)
        attach_measurement(document, args.condition, args.measure, measurement)
    if args.print_only:
        print(json.dumps(document, indent=2))
        return 0

    POWER_ARTIFACTS.mkdir(parents=True, exist_ok=True)
    stem = "measure" if args.measure is not None else "manifest"
    path = POWER_ARTIFACTS / (datetime.now().strftime(f"{stem}-%Y%m%d-%H%M%S") + ".json")
    path.write_text(json.dumps(document, indent=2))
    if args.measure is None:
        print(f"{MARK.step} Configuration manifest: {path}")
        print(f"{MARK.warn} No power was measured: every condition is recorded as measured=false.")
        unmeasured = ", ".join(entry["id"] for entry in document["conditions"])
        print(f"{MARK.missing} Conditions still unmeasured: {unmeasured}")
    else:
        report = document["measurement"]
        print(f"{MARK.step} Measurement ({args.condition}, {report['elapsed_seconds']} s): {path}")
        for role, usage in report["processes"].items():
            print(f"{MARK.step} {describe_role(role, usage)}")
        power = report["package_power"]
        system = report["system_power"]
        if system["measured"]:
            power_in = "n/a" if system["power_in_mw"] is None else f"{system['power_in_mw']} mW"
            print(f"{MARK.step} system: load {system['load_mw']} mW (adapter in {power_in}) "
                  f"over {system['samples']} readings")
        else:
            print(f"{MARK.warn} System power not measured: {system['reason']}")
        if power["measured"]:
            print(f"{MARK.step} package: combined {power['combined_mw']} mW (CPU {power['cpu_mw']}, "
                  f"GPU {power['gpu_mw']}, ANE {power['ane_mw']}) over {power['samples']} samples")
        else:
            print(f"{MARK.warn} Package power not measured: {power['reason']}")
    if document["build"]["dirty"]:
        print(f"{MARK.warn} Working tree is dirty; the commit alone does not identify this build.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
