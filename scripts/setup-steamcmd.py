#!/usr/bin/env python3
"""Prepare a private complete SteamCMD runtime without changing system security policy.

Run SteamCMD's official updater first if steamconsole.dylib is missing. This command
copies only runtime files, repairs the known broken Breakpad resource seal locally,
and records the runtime location for MacWallpaperEngine. No login is performed.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, help="Complete directory containing steamcmd and steamconsole.dylib")
args = parser.parse_args()
if args.source:
    source = args.source.expanduser().resolve()
else:
    cask = Path(subprocess.check_output(["brew", "--prefix"], text=True).strip()) / "Caskroom/steamcmd"
    candidates = sorted(cask.glob("*/MacOS/steamconsole.dylib"))
    if not candidates:
        raise SystemExit("Install SteamCMD with Homebrew and let its official updater finish, then rerun this command. No complete runtime was found.")
    source = candidates[-1].parent
if not (source / "steamcmd").is_file() or not (source / "steamconsole.dylib").is_file():
    raise SystemExit("The source must contain a complete updated SteamCMD runtime.")
support = Path.home() / "Library/Application Support/mac-wallpaper-engine"
destination = support / "SteamCMD"
staging = support / (".steamcmd-setup-" + str(uuid.uuid4()))
staging.mkdir(parents=True)
try:
    for name in ["steamcmd", "steamcmd.sh", "Frameworks", "crashhandler.dylib", "steamconsole.dylib", "steamclient.dylib", "libtier0_s.dylib", "libvstdlib_s.dylib", "libaudio.dylib", "libsteaminput.dylib", "public", "package"]:
        path = source / name
        if path.is_dir():
            shutil.copytree(path, staging / name, symlinks=True)
        elif path.is_file():
            shutil.copy2(path, staging / name)
    framework = staging / "Frameworks/Breakpad.framework"
    check = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(framework)], capture_output=True)
    if check.returncode:
        print("Repairing the copied Valve Breakpad resource seal with a local ad-hoc signature. No system security settings are changed.")
        subprocess.run(["codesign", "--force", "--sign", "-", str(framework)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(framework)], check=True)
    if destination.exists():
        raise SystemExit(f"Runtime already exists: {destination}. Choose a new destination or explicitly remove the prior runtime before replacing it.")
    staging.rename(destination)
    subprocess.run(["defaults", "write", "app.mac-wallpaper-engine", "MacWallpaperEngineSteamCMDPath", "-string", str(destination / "steamcmd")], check=True)
    print(f"Configured {destination / 'steamcmd'}")
    print("Restart MacWallpaperEngine to pick up the selected runtime. Runtime updates are explicit; rerun setup from a newer official installation when needed.")
finally:
    if staging.exists():
        shutil.rmtree(staging)
