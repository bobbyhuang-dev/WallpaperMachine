#!/usr/bin/env python3
"""Unit tests for scripts/release_notes.py."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("release_notes", SCRIPTS / "release_notes.py")
release_notes = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(release_notes)

REPOSITORY = "owner/repo"


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def commit(cwd, message, name="file.txt"):
    (Path(cwd) / name).write_text(message, encoding="utf-8")
    git("add", "-A", cwd=cwd)
    git("commit", "-m", message, cwd=cwd)


class ClassifyTests(unittest.TestCase):
    def test_feature_carries_its_scope(self):
        change = release_notes.classify("abc1234", "feat(panel): add a filter rail")
        self.assertEqual(change.group, "features")
        self.assertEqual(change.scope, "panel")
        self.assertEqual(change.subject, "Add a filter rail")

    def test_fix_and_performance_reach_their_sections(self):
        self.assertEqual(release_notes.classify("a", "fix(scene): stop a crash").group, "fixes")
        self.assertEqual(release_notes.classify("b", "perf(renderer): skip a pass").group, "performance")

    def test_documentation_and_tooling_are_internal(self):
        for subject in ("docs: record a run", "test(panel): settle first", "chore(xcode): regenerate", "ci: cache cargo"):
            self.assertEqual(release_notes.classify("a", subject).group, "internal", subject)

    def test_unconventional_subject_is_listed_not_dropped(self):
        change = release_notes.classify("abc1234", "Revert the album-cover rejection")
        self.assertEqual(change.group, "other")
        self.assertEqual(change.scope, "")
        self.assertEqual(change.subject, "Revert the album-cover rejection")

    def test_bang_marks_a_breaking_change(self):
        self.assertEqual(release_notes.classify("a", "feat(bridge)!: drop the old call").group, "breaking")

    def test_breaking_change_trailer_outranks_the_type(self):
        change = release_notes.classify("a", "fix(bridge): rename a field", "BREAKING CHANGE: callers must update")
        self.assertEqual(change.group, "breaking")

    def test_the_bump_commit_is_not_part_of_the_release(self):
        self.assertIsNone(release_notes.classify("a", "chore: bump version to 1.2.3"))

    def test_a_paragraph_subject_is_cut_at_a_word_boundary(self):
        subject = "fix(media): " + "word " * 60
        change = release_notes.classify("a", subject)
        self.assertLessEqual(len(change.subject), release_notes.SUBJECT_LIMIT + 1)
        self.assertTrue(change.subject.endswith("…"))
        self.assertNotIn("  ", change.subject)


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.changes = [
            release_notes.Change("features", "panel", "Add a filter rail", "aaa1111"),
            release_notes.Change("fixes", "scene", "Stop a crash", "bbb2222"),
            release_notes.Change("internal", "", "Record a run", "ccc3333"),
            release_notes.Change("internal", "", "Record another run", "ddd4444"),
        ]

    def test_sections_are_ordered_and_linked(self):
        body = release_notes.render("0.6.0", self.changes, "v0.5.0", REPOSITORY)
        self.assertLess(body.index("### New"), body.index("### Fixed"))
        self.assertIn("- **panel** — Add a filter rail ([`aaa1111`](https://github.com/owner/repo/commit/aaa1111))", body)
        self.assertIn("https://github.com/owner/repo/compare/v0.5.0...v0.6.0", body)

    def test_internal_work_is_counted_not_listed(self):
        body = release_notes.render("0.6.0", self.changes, "v0.5.0", REPOSITORY)
        self.assertIn("Plus 2 documentation, test and tooling commits.", body)
        self.assertNotIn("Record a run", body)

    def test_repeated_wording_collapses(self):
        twice = self.changes + [release_notes.Change("fixes", "scene", "stop a crash", "eee5555")]
        self.assertEqual(release_notes.render("0.6.0", twice, "v0.5.0", REPOSITORY).count("Stop a crash"), 1)

    def test_a_release_with_only_internal_work_says_so(self):
        body = release_notes.render("0.6.0", self.changes[2:], "v0.5.0", REPOSITORY)
        self.assertIn("No user-visible changes since `v0.5.0`.", body)

    def test_a_first_release_links_the_commit_list(self):
        body = release_notes.render("0.1.0", self.changes, None, REPOSITORY)
        self.assertIn("https://github.com/owner/repo/commits/v0.1.0", body)

    def test_the_install_footer_names_the_asset_the_updater_selects(self):
        footer = release_notes.install_footer("0.6.0", "26.0")
        self.assertIn(release_notes.archive_name("0.6.0"), footer)
        self.assertIn("shasum -a 256 -c WallpaperMachine-0.6.0-arm64.zip.sha256", footer)
        self.assertIn("macOS 26.0 or later", footer)


class ChangelogTests(unittest.TestCase):
    def section(self, version, body="### Fixed\n\n- Something\n"):
        return release_notes.section(version, "2026-01-01", body)

    def test_newest_version_lands_first(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.5.0", self.section("0.5.0"))
        text = release_notes.insert_section(text, "0.6.0", self.section("0.6.0"))
        self.assertLess(text.index("## 0.6.0"), text.index("## 0.5.0"))

    def test_an_older_version_lands_below_a_newer_one(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        text = release_notes.insert_section(text, "0.5.0", self.section("0.5.0"))
        self.assertLess(text.index("## 0.6.0"), text.index("## 0.5.0"))

    def test_rerunning_replaces_rather_than_duplicates(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        text = release_notes.insert_section(text, "0.6.0", self.section("0.6.0", "### New\n\n- Rewritten\n"))
        self.assertEqual(text.count("## 0.6.0"), 1)
        self.assertIn("Rewritten", text)
        self.assertNotIn("Something", text)

    def test_the_preamble_survives(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        self.assertTrue(text.startswith("# Changelog"))


class RepositoryRangeTests(unittest.TestCase):
    """The parts that only a real history can answer."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        git("init", "-q", "-b", "main", cwd=self.root)
        git("config", "user.email", "test@example.com", cwd=self.root)
        git("config", "user.name", "Test", cwd=self.root)
        git("config", "commit.gpgsign", "false", cwd=self.root)
        commit(self.root, "feat(panel): first feature")
        git("tag", "v0.1.0", cwd=self.root)
        commit(self.root, "fix(scene): second fix")
        git("tag", "v0.2.0", cwd=self.root)
        commit(self.root, "feat(media): third feature")

    def test_tags_sort_by_version_not_by_string(self):
        git("tag", "v0.10.0", cwd=self.root)
        self.assertEqual(release_notes.version_tags(self.root)[-1], "v0.10.0")

    def test_previous_tag_is_the_newest_version_below_the_target(self):
        self.assertEqual(release_notes.previous_tag("0.3.0", "HEAD", self.root), "v0.2.0")

    def test_previous_tag_skips_a_gap_in_the_numbering(self):
        self.assertEqual(release_notes.previous_tag("0.9.0", "HEAD", self.root), "v0.2.0")

    def test_the_first_release_has_no_previous_tag(self):
        self.assertIsNone(release_notes.previous_tag("0.1.0", "v0.1.0", self.root))

    def test_a_range_carries_only_its_own_commits(self):
        collected = release_notes.changes("v0.1.0", "v0.2.0", self.root)
        self.assertEqual([change.subject for change in collected], ["Second fix"])

    def test_the_bump_commit_leaves_the_range_empty(self):
        commit(self.root, "chore: bump version to 0.3.0")
        collected = release_notes.changes("v0.2.0", "HEAD", self.root)
        self.assertEqual([change.subject for change in collected], ["Third feature"])

    def test_a_rebuilt_changelog_covers_every_tag_newest_first(self):
        text = release_notes.rebuild_changelog(REPOSITORY, self.root)
        self.assertLess(text.index("## 0.2.0"), text.index("## 0.1.0"))
        self.assertIn("First feature", text)
        self.assertIn("Second fix", text)


if __name__ == "__main__":
    unittest.main()
