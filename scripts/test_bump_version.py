#!/usr/bin/env python3
"""Unit tests for scripts/bump_version.py."""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parent / "bump_version.py"
SPEC = importlib.util.spec_from_file_location("bump_version", SCRIPT)
bump_version = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(bump_version)

SAMPLE_YML = """name: mac-wallpaper-engine
targets:
  MacWallpaperEngine:
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
  MacWallpaperExtension:
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
"""

SAMPLE_PBX = """
				CURRENT_PROJECT_VERSION = 1;
				MARKETING_VERSION = 0.1.0;
				CURRENT_PROJECT_VERSION = 1;
				MARKETING_VERSION = 0.1.0;
"""


class ParseTests(unittest.TestCase):
    def test_subject_patch(self):
        self.assertEqual(bump_version.parse_specs("release: patch\n"), ["patch"])

    def test_case_and_v_prefix(self):
        self.assertEqual(bump_version.parse_specs("Release: V1.2.3\n"), ["1.2.3"])

    def test_body_line_in_merge_commit(self):
        message = "Merge pull request #2 from user/branch\n\nrelease: minor\n"
        self.assertEqual(bump_version.parse_specs(message), ["minor"])

    def test_ignores_ordinary_commits(self):
        self.assertEqual(bump_version.parse_specs("fix: crash on import\n"), [])

    def test_ignores_bump_commit(self):
        self.assertEqual(bump_version.parse_specs("chore: bump version to 0.1.1\n"), [])

    def test_ignores_release_without_spec(self):
        self.assertEqual(bump_version.parse_specs("release the notes\n"), [])

    def test_resolve_highest_bump(self):
        self.assertEqual(bump_version.resolve_specs(["patch", "minor", "patch"]), "minor")

    def test_explicit_version_wins(self):
        self.assertEqual(bump_version.resolve_specs(["major", "1.4.0"]), "1.4.0")

    def test_no_specs(self):
        self.assertIsNone(bump_version.resolve_specs([]))


class BumpTests(unittest.TestCase):
    def test_patch_minor_major(self):
        self.assertEqual(bump_version.bump_marketing("0.1.0", "patch"), "0.1.1")
        self.assertEqual(bump_version.bump_marketing("0.1.9", "minor"), "0.2.0")
        self.assertEqual(bump_version.bump_marketing("0.9.1", "major"), "1.0.0")

    def test_explicit_same_or_higher(self):
        self.assertEqual(bump_version.bump_marketing("0.1.0", "0.1.0"), "0.1.0")
        self.assertEqual(bump_version.bump_marketing("0.1.0", "v2.0.0"), "2.0.0")

    def test_refuses_downgrade(self):
        with self.assertRaises(bump_version.VersionError):
            bump_version.bump_marketing("1.0.0", "0.9.0")

    def test_invalid_semver(self):
        with self.assertRaises(bump_version.VersionError):
            bump_version.bump_marketing("0.1.0", "1.2")

    def test_next_build(self):
        self.assertEqual(bump_version.next_build("1"), "2")
        with self.assertRaises(bump_version.VersionError):
            bump_version.next_build("build")


class FileUpdateTests(unittest.TestCase):
    def test_replaces_every_yml_entry(self):
        updated = bump_version.replace_project_yml(SAMPLE_YML, "0.2.0", "3")
        self.assertEqual(updated.count('MARKETING_VERSION: "0.2.0"'), 2)
        self.assertEqual(updated.count('CURRENT_PROJECT_VERSION: "3"'), 2)
        self.assertNotIn("0.1.0", updated)

    def test_replaces_every_pbx_entry(self):
        updated = bump_version.replace_pbxproj(SAMPLE_PBX, "0.2.0", "3")
        self.assertEqual(updated.count("MARKETING_VERSION = 0.2.0;"), 2)
        self.assertEqual(updated.count("CURRENT_PROJECT_VERSION = 3;"), 2)

    def test_plan_and_apply(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "mac-wallpaper-engine.xcodeproj").mkdir()
            (root / "project.yml").write_text(SAMPLE_YML)
            (root / "mac-wallpaper-engine.xcodeproj/project.pbxproj").write_text(SAMPLE_PBX)
            plan = bump_version.plan_bump(root, "minor")
            self.assertEqual(plan["new_marketing"], "0.2.0")
            self.assertEqual(plan["new_build"], "2")
            self.assertTrue(plan["changed"])
            self.assertEqual(plan["tag"], "v0.2.0")
            bump_version.apply_bump(root, "0.2.0", "2")
            yml = (root / "project.yml").read_text()
            self.assertIn('MARKETING_VERSION: "0.2.0"', yml)
            self.assertIn('CURRENT_PROJECT_VERSION: "2"', yml)
            self.assertIn("MARKETING_VERSION = 0.2.0;", (root / "mac-wallpaper-engine.xcodeproj/project.pbxproj").read_text())

    def test_plan_skips_unchanged_explicit_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "project.yml").write_text(SAMPLE_YML)
            plan = bump_version.plan_bump(root, "0.1.0")
            self.assertFalse(plan["changed"])
            self.assertEqual(plan["new_build"], "1")

    def test_github_event_messages(self):
        event = {
            "head_commit": {"message": "Merge pull request #2 from user/branch\n"},
            "commits": [
                {"message": "Merge pull request #2 from user/branch\n"},
                {"message": "release: patch\n\nqueue downloads\n"},
            ],
        }
        messages = bump_version.collect_event_messages(event)
        self.assertEqual(bump_version.spec_from_messages(messages), "patch")

    def test_github_output_format(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "output"
            bump_version.write_github_output(path, {"changed": True, "new_marketing": "0.2.0", "tag": "v0.2.0"})
            text = path.read_text()
            self.assertIn("changed=true\n", text)
            self.assertIn("new_marketing=0.2.0\n", text)
            self.assertIn("tag=v0.2.0\n", text)


class RepoFileTests(unittest.TestCase):
    def test_checked_in_project_yml_is_valid(self):
        root = Path(__file__).resolve().parents[1]
        marketing, build = bump_version.read_yml_versions((root / "project.yml").read_text())
        bump_version.parse_semver(marketing)
        self.assertGreaterEqual(int(build), 1)
        pbx = (root / "mac-wallpaper-engine.xcodeproj/project.pbxproj").read_text()
        self.assertGreaterEqual(len(bump_version.PBX_MARKETING.findall(pbx)), 2)
        self.assertGreaterEqual(len(bump_version.PBX_BUILD.findall(pbx)), 2)


class CLITests(unittest.TestCase):
    def test_ci_uses_release_spec_env(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "mac-wallpaper-engine.xcodeproj").mkdir()
            (root / "project.yml").write_text(SAMPLE_YML)
            (root / "mac-wallpaper-engine.xcodeproj/project.pbxproj").write_text(SAMPLE_PBX)
            output = root / "github-output"
            env = {"RELEASE_SPEC": "patch", "GITHUB_OUTPUT": str(output)}
            with patch.dict(os.environ, env, clear=False), patch.object(
                bump_version.sys, "argv", ["bump_version.py", "--ci", "--apply", "--root", str(root)]
            ):
                self.assertEqual(bump_version.main(), 0)
            self.assertIn("0.1.1", (root / "project.yml").read_text())
            self.assertIn("changed=true", output.read_text())

    def test_ci_reads_event_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "mac-wallpaper-engine.xcodeproj").mkdir()
            (root / "project.yml").write_text(SAMPLE_YML)
            (root / "mac-wallpaper-engine.xcodeproj/project.pbxproj").write_text(SAMPLE_PBX)
            event = root / "event.json"
            event.write_text(json.dumps({"head_commit": {"message": "release: major\n"}}))
            output = root / "github-output"
            env = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output), "RELEASE_SPEC": ""}
            with patch.dict(os.environ, env, clear=False), patch.object(
                bump_version.sys, "argv", ["bump_version.py", "--ci", "--root", str(root)]
            ):
                self.assertEqual(bump_version.main(), 0)
            self.assertIn("new_marketing=1.0.0", output.read_text())
            self.assertIn('MARKETING_VERSION: "0.1.0"', (root / "project.yml").read_text())

    def test_no_spec_is_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "github-output"
            with patch.object(
                bump_version.sys,
                "argv",
                ["bump_version.py", "--message", "fix: nits", "--output", str(output), "--root", str(root)],
            ):
                self.assertEqual(bump_version.main(), 0)
            self.assertIn("changed=false", output.read_text())


if __name__ == "__main__":
    unittest.main()
