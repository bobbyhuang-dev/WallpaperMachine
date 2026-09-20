#!/usr/bin/env python3
"""Build MacWallpaperEngine's Rust/C++ renderer and SwiftUI application with Homebrew.

Stages, in order: cargo builds the renderer workspace, `uniffi-bindgen` regenerates
the Swift bridge into `App/Bridge/Generated`, `xcodegen` regenerates the Xcode project
from `project.yml`, and `xcodebuild` builds the app. See docs/build.md.

Each stage's full output goes to `artifacts/build/<stage>-<timestamp>.log`; the
terminal only sees errors and the final verdict unless `--verbose` is given.
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import subprocess
import sys

from lib.glyphs import markers
from lib.paths import BUILD, BUILD_ARTIFACTS, GENERATED_BRIDGE, PRODUCTS, RENDERER, ROOT, XCODEPROJ
from lib.xcode import run_quiet

MARK = markers()
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
VERBOSE = False


def run(args, cwd=ROOT, env=None, stage="build"):
    print(MARK.step, " ".join(map(str, args)), flush=True)
    log = BUILD_ARTIFACTS / f"{stage}-{STAMP}.log"
    completed, _ = run_quiet(args, log, cwd=cwd, env=env, verbose=VERBOSE)
    if completed.returncode != 0:
        print(f"{MARK.missing} {stage} failed (exit {completed.returncode}); full log: {log}", flush=True)
        raise subprocess.CalledProcessError(completed.returncode, list(map(str, args)))


def repository_commit(root=ROOT):
    """Short commit of `root`, stamped into the build as the source it came from.

    `upstream/renderer` holds its own Git checkout pinned to the vendored revision in
    `upstream/provenance.json`, so HEAD is resolved against the repository root
    explicitly: resolving it inside the renderer reports that pinned revision forever,
    whatever source the binary was actually built from.
    """
    return subprocess.check_output(["git", "-C", str(root), "rev-parse", "--short", "HEAD"], text=True).strip()


def build_environment():
    result = os.environ.copy()
    prefix = subprocess.check_output(["brew", "--prefix"], text=True).strip()
    packages = ["quickjs-ng", "glslang", "ffmpeg@8", "freetype", "lz4", "vulkan-loader", "vulkan-headers", "molten-vk", "eigen", "nlohmann-json", "argparse", "shaderc", "spirv-tools", "glm"]
    roots = [str(Path(prefix) / "opt" / name) for name in packages]
    result["PATH"] = f"{prefix}/bin:" + result.get("PATH", "")
    result["CMAKE_PREFIX_PATH"] = ";".join(roots + [prefix])
    result["PKG_CONFIG_PATH"] = ":".join(str(Path(p) / "lib/pkgconfig") for p in roots)
    result["OWE_NIX_LIBRARY_PATH"] = ":".join(str(Path(p) / "lib") for p in roots) + f":{prefix}/lib"
    result["LIBCLANG_PATH"] = subprocess.check_output(["xcode-select", "-p"], text=True).strip() + "/Toolchains/XcodeDefault.xctoolchain/usr/lib"
    result["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    result["CC"] = "/usr/bin/clang"
    result["CXX"] = "/usr/bin/clang++"
    result["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
    result["GIT_SHORT_COMMIT"] = repository_commit()
    return result


def cargo_environment():
    """The build environment with the deployment target renamed for cargo.

    Cargo builds proc-macro crates and build scripts for the host and then
    dlopens them in the running compiler. A pinned deployment target applies to
    those host dylibs too, and the ones this toolchain then produces are
    rejected at load with "mis-aligned LINKEDIT" -- which the compiler reports
    as `can't find crate for <macro>`, so every crate behind a derive fails to
    build.

    The pin is not dropped, only moved: the renderer crate's build script reads
    `OWE_MACOSX_DEPLOYMENT_TARGET` and hands it to CMake, so the C++ engine is
    still built for the same minimum as the app that links it. Rust's own
    objects fall back to the compiler default, which is below that minimum and
    therefore links without complaint.
    """
    result = build_environment()
    pinned = result.pop("MACOSX_DEPLOYMENT_TARGET", None)
    if pinned is not None:
        result["OWE_MACOSX_DEPLOYMENT_TARGET"] = pinned
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-only", action="store_true")
    parser.add_argument("--renderer-only", action="store_true")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--verbose", action="store_true", help="Echo every tool line instead of only errors.")
    args = parser.parse_args()
    global VERBOSE
    VERBOSE = args.verbose
    env = build_environment()
    if not args.swift_only:
        run(["cargo", "build", "--workspace", "--release"], RENDERER, cargo_environment(), stage="cargo")
        run([RENDERER / "target/release/uniffi-bindgen", "generate", "--library", RENDERER / "target/release/libwallpaper_bridge.a", "--language", "swift", "--no-format", "--out-dir", GENERATED_BRIDGE], cwd=RENDERER, env=env, stage="bindgen")
    if args.renderer_only:
        return
    # `--use-cache` skips rewriting the project when `project.yml` has not changed,
    # which keeps Xcode's incremental build state (and `scripts/test.py` agrees).
    run(["xcodegen", "generate", "--use-cache", "--quiet"], env=env, stage="xcodegen")
    run(["xcodebuild", "-project", XCODEPROJ.name, "-scheme", "MacWallpaperEngine", "-configuration", args.configuration, "-derivedDataPath", BUILD, "build"], env=env, stage=f"xcodebuild-{args.configuration}")
    print(f"{MARK.ok} Built {PRODUCTS / args.configuration / 'MacWallpaperEngine.app'}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
