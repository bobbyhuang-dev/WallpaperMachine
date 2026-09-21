"""Canonical repository paths, so no script re-derives them from `__file__`.

Two rules the layout depends on:

* `build/` holds Xcode derived data and built products, nothing else.
* `artifacts/` holds every piece of test or verification evidence. It is
  Git-ignored and disposable; `scripts/clean.py` removes it.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

APP = ROOT / "App"
EXTENSION = ROOT / "Extension"
SHARED = ROOT / "Shared"
WEB_UI = ROOT / "WebUI"
TESTS = ROOT / "Tests"

# Swift bindings written by `uniffi-bindgen` during `scripts/build.py`.
GENERATED_BRIDGE = APP / "Bridge/Generated"

# Vendored third-party renderer; see upstream/provenance.json.
RENDERER = ROOT / "upstream/renderer"

PROJECT_YML = ROOT / "project.yml"
XCODEPROJ = ROOT / "WallpaperMachine.xcodeproj"

BUILD = ROOT / "build"
PRODUCTS = BUILD / "Build/Products"

ARTIFACTS = ROOT / "artifacts"
TEST_ARTIFACTS = ARTIFACTS / "tests"
# Full tool logs from scripts/build.py; the terminal only shows their failures.
BUILD_ARTIFACTS = ARTIFACTS / "build"
RENDERER_ARTIFACTS = ARTIFACTS / "renderer"


def app_bundle(configuration="Debug"):
    """Path of the built application for a build configuration."""
    return PRODUCTS / configuration / "WallpaperMachine.app"
