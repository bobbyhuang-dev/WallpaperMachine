#!/usr/bin/env python3
"""Build MacWallpaperEngine's Rust/C++ renderer and SwiftUI application with Homebrew."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RENDERER = ROOT / "upstream/renderer"


def run(args, cwd=ROOT, env=None):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


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
    result["GIT_SHORT_COMMIT"] = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=RENDERER, text=True).strip()
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-only", action="store_true")
    parser.add_argument("--renderer-only", action="store_true")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    args = parser.parse_args()
    env = build_environment()
    if not args.swift_only:
        run(["cargo", "build", "--workspace", "--release"], RENDERER, env)
        run([RENDERER / "target/release/uniffi-bindgen", "generate", "--library", RENDERER / "target/release/libwallpaper_bridge.a", "--language", "swift", "--no-format", "--out-dir", RENDERER / "app/WallpaperEngine/Bridge/Generated"], cwd=RENDERER, env=env)
    if args.renderer_only:
        return
    run(["xcodegen", "generate"], env=env)
    run(["xcodebuild", "-project", "mac-wallpaper-engine.xcodeproj", "-scheme", "MacWallpaperEngine", "-configuration", args.configuration, "-derivedDataPath", ROOT / "build", "build"], env=env)
    print(f"Built {ROOT}/build/Build/Products/{args.configuration}/MacWallpaperEngine.app")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
