#!/usr/bin/env python3
"""Bundle Homebrew dylibs, configure MoltenVK, and ad-hoc sign the local application."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def output(args):
    return subprocess.check_output(list(map(str, args)), text=True)


def run(args):
    subprocess.run(list(map(str, args)), check=True)


def dependencies(file):
    return [line.strip().split(" (compatibility")[0] for line in output(["otool", "-L", file]).splitlines()[1:] if line.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", default="Debug", choices=["Debug", "Release"])
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()
    app = ROOT / "build/Build/Products" / args.configuration / "MacWallpaperEngine.app"
    binary = app / "Contents/MacOS/MacWallpaperEngine"
    extensions = list((app / "Contents/Extensions").glob("*.appex"))
    extension_binaries = [extension / "Contents/MacOS" / extension.stem for extension in extensions]
    if not binary.is_file():
        raise SystemExit("Build the application first using scripts/build.py")
    frameworks = app / "Contents/Frameworks"
    resources = app / "Contents/Resources"
    frameworks.mkdir(exist_ok=True)
    prefix = Path(output(["brew", "--prefix"]).strip())
    molten = prefix / "opt/molten-vk/lib/libMoltenVK.dylib"
    queue = [binary, *extension_binaries]
    seen = set()

    def add_library(source):
        name = source.name
        destination = frameworks / name
        if name not in seen:
            seen.add(name)
            shutil.copy2(source.resolve(), destination)
            destination.chmod(0o755)
            queue.append(destination)
            run(["install_name_tool", "-id", f"@rpath/{name}", destination])
        return f"@rpath/{name}"

    add_library(molten)
    while queue:
        file = queue.pop(0)
        for dependency in dependencies(file):
            if dependency.startswith(str(prefix)):
                replacement = add_library(Path(dependency))
                run(["install_name_tool", "-change", dependency, replacement, file])
            elif dependency.startswith("@rpath/"):
                name = Path(dependency).name
                if not (frameworks / name).exists():
                    candidate = prefix / "lib" / name
                    if candidate.exists():
                        add_library(candidate)
        # Executable-relative path also resolves transitive dylibs without a Homebrew installation.
        load_commands = output(["otool", "-l", file]).splitlines()
        paths = []
        for index, line in enumerate(load_commands):
            if line.strip() == "cmd LC_RPATH":
                paths.append(load_commands[index + 2].strip().split(" (offset")[0].removeprefix("path "))
        for path in set(paths):
            if path.startswith(str(prefix)) or path.startswith(str(ROOT)):
                run(["install_name_tool", "-delete_rpath", path, file])
        desired = "@executable_path/../../../../Frameworks" if file in extension_binaries else "@executable_path/../Frameworks"
        if desired not in paths:
            run(["install_name_tool", "-add_rpath", desired, file])

    (resources / "MoltenVK_icd.json").write_text(json.dumps({"file_format_version": "1.0.0", "ICD": {"library_path": "../Frameworks/libMoltenVK.dylib", "api_version": "1.3.0", "is_portability_driver": True}}, indent=2))
    for extension in extensions:
        extension_resources = extension / "Contents/Resources"
        extension_resources.mkdir(exist_ok=True)
        (extension_resources / "MoltenVK_icd.json").write_text(json.dumps({"file_format_version": "1.0.0", "ICD": {"library_path": "../../../../Frameworks/libMoltenVK.dylib", "api_version": "1.3.0", "is_portability_driver": True}}, indent=2))
    shutil.copy2(ROOT / "upstream/renderer/LICENSE", resources / "Renderer-LICENSE.txt")
    shutil.copy2(ROOT / "upstream/provenance.json", resources / "provenance.json")
    for file in frameworks.glob("*.dylib"):
        run(["codesign", "--force", "--sign", "-", file])
    for extension in extensions:
        run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements", extension])
    run(["codesign", "--force", "--sign", "-", "--options", "0", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    for file in [binary, *extension_binaries, *frameworks.glob("*.dylib")]:
        for dependency in dependencies(file):
            if dependency.startswith(str(prefix)):
                raise RuntimeError(f"Unbundled dependency: {file}: {dependency}")
            if dependency.startswith("@rpath/") and not (frameworks / Path(dependency).name).exists() and "libswift" not in dependency:
                raise RuntimeError(f"Missing bundled dependency: {dependency}")
    info = app / "Contents/Info.plist"
    version = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", info], text=True).strip()
    archive = app.parent / f"MacWallpaperEngine-{version}-arm64.zip"
    archive.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--keepParent", app, archive])
    if args.install:
        destination = Path.home() / "Applications/MacWallpaperEngine.app"
        destination.parent.mkdir(exist_ok=True)
        if destination.exists():
            raise SystemExit(f"An installation already exists: {destination}. Quit it and explicitly remove/replace it before installation.")
        shutil.copytree(app, destination)
        print(f"Installed {destination}")
    print(f"Verified bundle: {app}")
    print(f"Release archive: {archive}")


if __name__ == "__main__":
    main()
