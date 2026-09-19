#!/usr/bin/env python3
"""Unit tests for scripts/clean.py."""
from __future__ import annotations

import contextlib
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("clean", SCRIPTS / "clean.py")
clean = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(clean)

# `clean.ROOT`, `clean.ARTIFACTS` and `clean.BUILD` are bound to the real checkout at
# import time, and `clean.main` deletes what they name. Every test that calls into
# `clean.main` has to redirect all three, and prove it did.
REAL_ROOT = clean.ROOT
REAL_ARTIFACTS = clean.ARTIFACTS
REAL_BUILD = clean.BUILD


def project(root, name, staged=("a.png",)):
    directory = root / name
    directory.mkdir(parents=True)
    (directory / "project.json").write_text("{}")
    if staged is None:
        return directory
    staging = directory / clean.USER_ASSETS_DIR
    staging.mkdir()
    for entry in staged:
        (staging / entry).write_bytes(b"staged")
    return directory


class UserAssetDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        os.environ["MAC_WALLPAPER_ENGINE_HOME"] = str(self.home / "support")
        self.library = self.home / "support/Library"

    def tearDown(self):
        os.environ.pop("MAC_WALLPAPER_ENGINE_HOME", None)

    def found(self):
        with mock.patch.object(clean.Path, "home", staticmethod(lambda: self.home)):
            return sorted(clean.user_assets())

    def test_staging_directories_are_found_in_the_imported_library(self):
        project(self.library, "starter-aurora")
        self.assertEqual(self.found(), [self.library / "starter-aurora" / clean.USER_ASSETS_DIR])

    def test_steam_workshop_projects_are_included(self):
        workshop = self.home / clean.STEAM_WORKSHOP
        project(workshop, "123456")
        self.assertEqual(self.found(), [workshop / "123456" / clean.USER_ASSETS_DIR])

    def test_wallpapers_without_staged_assets_are_left_alone(self):
        project(self.library, "plain", staged=None)
        self.assertEqual(self.found(), [])

    def test_missing_roots_are_not_an_error(self):
        self.assertEqual(self.found(), [])

    def test_only_the_staging_directory_is_listed_not_the_wallpaper(self):
        directory = project(self.library, "starter-aurora")
        found = self.found()
        self.assertNotIn(directory, found)
        self.assertTrue((directory / "project.json").exists())

    def test_default_pass_never_includes_staged_assets(self):
        project(self.library, "starter-aurora")
        with mock.patch.object(clean.Path, "home", staticmethod(lambda: self.home)):
            self.assertEqual([path for path in clean.evidence() if clean.USER_ASSETS_DIR in path.parts], [])


class ManagedUserAssetTests(unittest.TestCase):
    """The app's own copies of what the user imported. Nothing regenerates them, so
    every pass that is not the one flag naming them has to leave them alone."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.support = self.home / "support"
        os.environ["MAC_WALLPAPER_ENGINE_HOME"] = str(self.support)
        self.managed = self.support / clean.MANAGED_USER_ASSETS_DIR / "2001" / "cover" / "abc"
        self.managed.mkdir(parents=True)
        self.asset = self.managed / "clouds.png"
        self.asset.write_bytes(b"imported")
        # A stand-in repository. `clean.main` deletes what `evidence()` finds, and
        # `evidence()` reads the module-level ROOT / ARTIFACTS / BUILD, which are bound
        # to the real checkout at import. Redirecting `Path.home()` alone is not enough:
        # without all four, running this file deletes the developer's own `artifacts/`
        # and `build/`.
        self.repository = self.home / "repository"
        (self.repository / "artifacts").mkdir(parents=True)
        (self.repository / "artifacts" / "log.txt").write_text("evidence")
        (self.repository / "build" / "Build").mkdir(parents=True)
        (self.repository / "build" / "stray.log").write_text("stray")
        self.real = self.setUpReal()

    def setUpReal(self):
        return {path: path.exists() for path in (REAL_ARTIFACTS, REAL_BUILD)}

    def tearDown(self):
        os.environ.pop("MAC_WALLPAPER_ENGINE_HOME", None)
        # The check that would have caught cleaning the wrong tree: the real
        # `artifacts/` and `build/` are exactly as they were before this test ran.
        for path, existed in self.real.items():
            self.assertEqual(
                existed, path.exists(),
                f"these tests must never reach the real {path}")

    def isolated(self, *flags):
        return (
            mock.patch.object(clean.Path, "home", staticmethod(lambda: self.home)),
            mock.patch.object(clean, "ROOT", self.repository),
            mock.patch.object(clean, "ARTIFACTS", self.repository / "artifacts"),
            mock.patch.object(clean, "BUILD", self.repository / "build"),
            mock.patch.object(sys, "argv", ["clean.py", *flags]),
        )

    def run_clean(self, *flags):
        with contextlib.ExitStack() as stack:
            for patch in self.isolated(*flags):
                stack.enter_context(patch)
            # Structural, not merely careful: a redirection that silently stopped
            # working would otherwise be invisible on a machine with no build output.
            for redirected in (clean.ROOT, clean.ARTIFACTS, clean.BUILD):
                self.assertTrue(
                    self.home in redirected.parents,
                    f"{redirected} is outside the test's own directory")
            self.assertEqual(clean.main(), 0)

    def test_the_default_pass_leaves_the_managed_store_alone(self):
        self.run_clean()
        self.assertTrue(self.asset.exists())

    def test_all_leaves_the_managed_store_alone(self):
        self.run_clean("--all")
        self.assertTrue(self.asset.exists())

    def test_derived_leaves_the_managed_store_alone(self):
        self.run_clean("--derived")
        self.assertTrue(self.asset.exists())

    def test_clearing_the_regenerable_bridge_leaves_the_managed_store_alone(self):
        library = self.support / "Library"
        project(library, "2001")
        bridge = library / "2001" / clean.USER_ASSETS_DIR
        self.run_clean("--user-assets")
        self.assertFalse(bridge.exists(), "the bridge is what --user-assets removes")
        self.assertTrue(
            self.asset.exists(),
            "the bridge is derived from the store; removing it must not remove the store")

    def test_only_the_flag_that_says_so_deletes_the_managed_store(self):
        self.run_clean("--managed-user-assets")
        self.assertFalse(self.asset.exists())
        self.assertFalse((self.support / clean.MANAGED_USER_ASSETS_DIR).exists())

    def test_a_dry_run_of_the_destructive_flag_deletes_nothing(self):
        self.run_clean("--managed-user-assets", "--dry-run")
        self.assertTrue(self.asset.exists())

    def test_the_managed_store_is_never_reported_as_evidence(self):
        with contextlib.ExitStack() as stack:
            for patch in self.isolated():
                stack.enter_context(patch)
            self.assertEqual(
                [path for path in clean.evidence()
                 if clean.MANAGED_USER_ASSETS_DIR in path.parts],
                [])

    def test_the_stand_in_repository_is_what_the_default_pass_actually_cleans(self):
        """Proves the redirection is real rather than merely careful: with ROOT,
        ARTIFACTS and BUILD left unpatched this pass would be deleting the checkout."""
        self.run_clean()
        self.assertFalse((self.repository / "artifacts").exists())
        self.assertTrue(
            (self.repository / "build" / "Build").exists(),
            "the default pass keeps the built app; only strays under build/ go")
        self.assertFalse((self.repository / "build" / "stray.log").exists())


class ReclaimableTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def test_a_hard_link_reports_no_reclaimable_space(self):
        source = self.root / "source.png"
        source.write_bytes(b"0" * 4096)
        link = self.root / "staged.png"
        os.link(source, link)
        self.assertEqual(clean.reclaimable(link), 0)

    def test_a_sole_copy_reports_its_size(self):
        copied = self.root / "copy.png"
        copied.write_bytes(b"0" * 4096)
        self.assertEqual(clean.reclaimable(copied), 4096)


class LabelTests(unittest.TestCase):
    def test_repository_paths_stay_relative(self):
        self.assertEqual(str(clean.label(clean.ROOT / "artifacts")), "artifacts")

    def test_paths_in_the_user_library_are_reported_without_the_home_directory(self):
        self.assertEqual(str(clean.label(Path.home() / "Library/x")), "~/Library/x")


if __name__ == "__main__":
    unittest.main()
