#!/usr/bin/env python3
"""Unit tests for scripts/clean.py."""
from __future__ import annotations

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
