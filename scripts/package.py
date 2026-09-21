#!/usr/bin/env python3
"""Bundle Homebrew dylibs, configure MoltenVK, collect license notices, and ad-hoc sign the local application.

Nothing in the bundle is touched until the preflight passes: the FFmpeg libraries
the binaries actually link must be an LGPL build (Formula/mwe-ffmpeg.rb), never a
`--enable-gpl` / `--enable-version3` / `--enable-nonfree` one, and every bundled
Homebrew keg must carry license files to ship. The archive this produces is for
local use; LICENSING.md records why it is not cleared for distribution.

`--check` runs the preflight against the built bundle and exits without changing it.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

from lib.glyphs import markers
from lib.paths import RENDERER, ROOT, app_bundle

MARK = markers()
FFMPEG_LIBRARY = re.compile(r"^lib(avutil|avcodec|avformat|avfilter|avdevice|swscale|swresample|postproc)\.")
# Written by FFmpeg's configure from exactly the gpl/version3/nonfree switches (`avutil_license()`).
FFMPEG_LICENSE = re.compile(rb"lib[a-z]+ license: ([^\x00]+)")
FFMPEG_FORBIDDEN = re.compile(rb"--enable-(?:gpl|version3|nonfree)\b")
FFMPEG_ACCEPTED_LICENSE = "LGPL version 2.1 or later"
# Homebrew keeps the upstream tarball's license and notice files at the keg root.
KEG_LICENSE_FILE = re.compile(r"^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE)", re.IGNORECASE)
# Statically linked into the renderer; their notices travel with the app binary.
RENDERER_THIRD_PARTY = RENDERER / "external/open-wallpaper-engine/third_party"
# Packaging is one-way: it rewrites load commands and fills Contents/Frameworks, and
# does not record where those dylibs came from. Repackaging therefore needs fresh
# build output rather than an incremental rebuild, which leaves Frameworks as it was.
FRESH_BUILD = "Packaging requires fresh, unrelocated build output; incremental builds retain bundled dylibs. See docs/build.md before cleaning any delivered app"


class PackagingError(Exception):
    """A condition that stops packaging; the message is the whole report."""


def output(args):
    return subprocess.check_output(list(map(str, args)), text=True)


def run(args):
    subprocess.run(list(map(str, args)), check=True)


def dependencies(file):
    return [line.strip().split(" (compatibility")[0] for line in output(["otool", "-L", file]).splitlines()[1:] if line.strip()]


def resolve_libraries(roots, seeds, prefix):
    """Every Homebrew dylib the roots load, directly or transitively, keyed by file name.

    Read-only: the walk runs over the Homebrew files themselves, so the bundle is
    known before anything is copied into it. An `@rpath` dependency that is not a
    Swift runtime library means the input was already relocated by an earlier run,
    whose provenance this script does not track, so it is refused rather than
    resolved against whatever the host has installed.
    """
    libraries = {}
    relocated = []
    queue = list(roots)

    def add(source):
        if source.name not in libraries:
            libraries[source.name] = source.resolve()
            queue.append(source)

    for seed in seeds:
        add(seed)
    while queue:
        file = queue.pop(0)
        for dependency in dependencies(file):
            if dependency.startswith(str(prefix)):
                add(Path(dependency))
            elif dependency.startswith("@rpath/") and Path(dependency).name not in libraries and "libswift" not in dependency:
                relocated.append(f"{file}: {dependency}")
    if relocated:
        raise PackagingError(f"{FRESH_BUILD}\n  " + "\n  ".join(relocated))
    return libraries


def ffmpeg_configuration(data):
    """The NUL-terminated configure command line embedded in an FFmpeg library, or b""."""
    index = data.find(b"--prefix=")
    if index < 0:
        return b""
    return data[data.rfind(b"\x00", 0, index) + 1:data.find(b"\x00", index)]


def ffmpeg_finding(name, source):
    """Why a linked FFmpeg library may not be bundled, or None when it is an LGPL build."""
    data = source.read_bytes()
    license_match = FFMPEG_LICENSE.search(data)
    if license_match is None:
        return f"{name} ({source}): no embedded license string; cannot verify its configuration"
    license = license_match.group(1).decode(errors="replace")
    forbidden = sorted(set(FFMPEG_FORBIDDEN.findall(ffmpeg_configuration(data))))
    if license == FFMPEG_ACCEPTED_LICENSE and not forbidden:
        return None
    detail = f"configured {' '.join(flag.decode() for flag in forbidden)}" if forbidden else "configuration string not found"
    return f"{name} ({source}): {license}; {detail}"


def keg_of(source):
    """The Homebrew keg (`Cellar/<formula>/<version>`) a resolved library belongs to."""
    parts = source.parts
    if "Cellar" in parts and len(parts) > parts.index("Cellar") + 3:
        return Path(*parts[: parts.index("Cellar") + 3])
    return None


def keg_licenses(libraries):
    """Keg -> its license files, for every keg that contributes a bundled library."""
    result = {}
    problems = []
    for name, source in sorted(libraries.items()):
        keg = keg_of(source)
        if keg is None:
            problems.append(f"{name} ({source}) is not installed from a Homebrew keg")
            continue
        if keg not in result:
            result[keg] = sorted(file for file in keg.iterdir() if file.is_file() and KEG_LICENSE_FILE.match(file.name))
            if not result[keg]:
                problems.append(f"{keg} ships no license file")
    if problems:
        raise PackagingError("Missing license payload:\n  " + "\n  ".join(problems))
    return result


def preflight(notices, libraries):
    """Fail before mutation when the bundle links a GPL FFmpeg or could not carry every notice.

    `notices` maps each license file Xcode already placed in the build to the
    repository file it must match.
    """
    findings = [finding for name, source in sorted(libraries.items()) if FFMPEG_LIBRARY.match(name) and (finding := ffmpeg_finding(name, source))]
    if findings:
        raise PackagingError("Refusing to bundle FFmpeg libraries that are not an LGPL build (install the project's with python3 scripts/install_ffmpeg.py; see LICENSING.md):\n  " + "\n  ".join(findings))
    licenses = keg_licenses(libraries)
    sources = [ROOT / "LICENSE", ROOT / "LICENSING.md", RENDERER / "LICENSE", ROOT / "upstream/provenance.json", *notices.values()]
    missing = [f"{file} is missing from the repository" for file in sources if not file.is_file()]
    missing += [f"{file} is missing from the build or differs from {original}" for file, original in notices.items() if original.is_file() and (not file.is_file() or file.read_bytes() != original.read_bytes())]
    if missing:
        raise PackagingError("Missing license payload:\n  " + "\n  ".join(missing))
    return licenses


def write_licenses(resources, licenses):
    """Copy the notices for everything packaged into Resources/Licenses; the directory is rebuilt every run."""
    directory = resources / "Licenses"
    shutil.rmtree(directory, ignore_errors=True)
    for keg, files in licenses.items():
        target = directory / f"{keg.parent.name}-{keg.name}"
        target.mkdir(parents=True)
        for file in files:
            shutil.copy2(file, target / file.name)
    for file in sorted(RENDERER_THIRD_PARTY.glob("*/LICENSE*")):
        target = directory / "renderer-third-party" / file.parent.name
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target / file.name)
    shutil.copy2(ROOT / "LICENSE", resources / "WallpaperMachine-LICENSE.txt")
    shutil.copy2(ROOT / "LICENSING.md", resources / "LICENSING.md")
    shutil.copy2(RENDERER / "LICENSE", resources / "Renderer-LICENSE.txt")
    shutil.copy2(ROOT / "upstream/provenance.json", resources / "provenance.json")


def icd(depth):
    return json.dumps({"file_format_version": "1.0.0", "ICD": {"library_path": f"{depth}/Frameworks/libMoltenVK.dylib", "api_version": "1.3.0", "is_portability_driver": True}}, indent=2)


def relocate(file, prefix, rpath):
    for dependency in dependencies(file):
        if dependency.startswith(str(prefix)):
            run(["install_name_tool", "-change", dependency, f"@rpath/{Path(dependency).name}", file])
    # Executable-relative path also resolves transitive dylibs without a Homebrew installation.
    load_commands = output(["otool", "-l", file]).splitlines()
    paths = []
    for index, line in enumerate(load_commands):
        if line.strip() == "cmd LC_RPATH":
            paths.append(load_commands[index + 2].strip().split(" (offset")[0].removeprefix("path "))
    for path in set(paths):
        if path.startswith(str(prefix)) or path.startswith(str(ROOT)):
            run(["install_name_tool", "-delete_rpath", path, file])
    if rpath not in paths:
        run(["install_name_tool", "-add_rpath", rpath, file])


def package(args):
    app = app_bundle(args.configuration)
    binary = app / "Contents/MacOS/WallpaperMachine"
    extensions = list((app / "Contents/Extensions").glob("*.appex"))
    extension_binaries = [extension / "Contents/MacOS" / extension.stem for extension in extensions]
    if not binary.is_file():
        raise PackagingError("Build the application first using scripts/build.py")
    frameworks = app / "Contents/Frameworks"
    resources = app / "Contents/Resources"
    prefix = Path(output(["brew", "--prefix"]).strip())
    molten = prefix / "opt/molten-vk/lib/libMoltenVK.dylib"
    bundled = sorted(frameworks.glob("*.dylib"))
    if bundled:
        findings = [finding for file in bundled if FFMPEG_LIBRARY.match(file.name) and (finding := ffmpeg_finding(file.name, file))]
        gpl = "\nIt also carries FFmpeg libraries that are not an LGPL build (see LICENSING.md):\n  " + "\n  ".join(findings) if findings else ""
        raise PackagingError(f"{FRESH_BUILD}; Contents/Frameworks already holds: {', '.join(file.name for file in bundled)}{gpl}")
    libraries = resolve_libraries([binary, *extension_binaries], [molten], prefix)
    # Notices Xcode already bundles from project.yml; packaging never rewrites them.
    notices = {resources / "LICENSE": ROOT / "upstream/mediaremote-adapter/LICENSE"}
    for extension in extensions:
        notices[extension / "Contents/Resources/Phosphene-LICENSE.txt"] = ROOT / "Extension/Phosphene-LICENSE.txt"
    licenses = preflight(notices, libraries)
    for keg in licenses:
        print(f"{MARK.ok} {keg.parent.name} {keg.name}: {', '.join(name for name, source in sorted(libraries.items()) if keg_of(source) == keg)}")
    if args.check:
        print(f"{MARK.ok} Preflight passed; bundle left unchanged: {app}")
        return

    frameworks.mkdir(exist_ok=True)
    for name, source in libraries.items():
        destination = frameworks / name
        shutil.copy2(source, destination)
        destination.chmod(0o755)
        run(["install_name_tool", "-id", f"@rpath/{name}", destination])
    for file in [binary, *(frameworks / name for name in libraries)]:
        relocate(file, prefix, "@executable_path/../Frameworks")
    for file in extension_binaries:
        relocate(file, prefix, "@executable_path/../../../../Frameworks")

    (resources / "MoltenVK_icd.json").write_text(icd(".."))
    for extension in extensions:
        extension_resources = extension / "Contents/Resources"
        extension_resources.mkdir(exist_ok=True)
        (extension_resources / "MoltenVK_icd.json").write_text(icd("../../../.."))
    write_licenses(resources, licenses)
    for file in frameworks.glob("*.dylib"):
        run(["codesign", "--force", "--sign", "-", file])
    for extension in extensions:
        run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements", extension])
    run(["codesign", "--force", "--sign", "-", "--options", "0", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    for file in [binary, *extension_binaries, *frameworks.glob("*.dylib")]:
        for dependency in dependencies(file):
            if dependency.startswith(str(prefix)):
                raise PackagingError(f"Unbundled dependency: {file}: {dependency}")
            if dependency.startswith("@rpath/") and not (frameworks / Path(dependency).name).exists() and "libswift" not in dependency:
                raise PackagingError(f"Missing bundled dependency: {dependency}")
    info = app / "Contents/Info.plist"
    version = output(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", info]).strip()
    archive = app.parent / f"WallpaperMachine-{version}-arm64.zip"
    archive.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--keepParent", app, archive])
    if args.install:
        destination = Path.home() / "Applications/WallpaperMachine.app"
        destination.parent.mkdir(exist_ok=True)
        if destination.exists():
            raise PackagingError(f"An installation already exists: {destination}. Quit it and explicitly remove/replace it before installation.")
        shutil.copytree(app, destination)
        print(f"{MARK.ok} Installed {destination}")
    print(f"{MARK.ok} Verified bundle: {app}")
    print(f"{MARK.ok} Local archive (not cleared for distribution, see LICENSING.md): {archive}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--configuration", default="Debug", choices=["Debug", "Release"])
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--check", action="store_true", help="Run the license preflight against the built bundle and change nothing.")
    args = parser.parse_args()
    try:
        package(args)
    except PackagingError as error:
        print(f"{MARK.missing} {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
