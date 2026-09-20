#!/usr/bin/env python3
"""Unit tests for scripts/log_verification.py."""
from __future__ import annotations

from datetime import date
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("log_verification", SCRIPTS / "log_verification.py")
logv = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(logv)

PREAMBLE = "# Verification log\n\nIntro paragraph that must survive.\n\n"


def entry(index, links=""):
    return f"## 2026-09-{index:02d} — Entry {index}\n\nContext {index}.{links}\n\n- `cmd` — exit 0\n\n"


class FormatEntry(unittest.TestCase):
    def test_context_and_lines(self):
        text = logv.format_entry("Quiet output", date(2026, 9, 21), "Some   context\nwrapped.", ["`a` — ok", " ", "`b` — skipped"])
        self.assertEqual(text, "## 2026-09-21 — Quiet output\n\nSome context wrapped.\n\n- `a` — ok\n- `b` — skipped\n\n")

    def test_body_wins(self):
        text = logv.format_entry("T", date(2026, 9, 21), body="\nraw *markdown*\n\n")
        self.assertEqual(text, "## 2026-09-21 — T\n\nraw *markdown*\n\n")

    def test_empty_entry_is_rejected(self):
        with self.assertRaises(ValueError):
            logv.format_entry("T", date(2026, 9, 21))


class Relink(unittest.TestCase):
    def test_relative_links_gain_one_level_and_others_stay(self):
        text = "[a](renderer.md) [b](../build.md) [c](https://x.y/z.md) [d](#anchor) [e](/abs.md)"
        self.assertEqual(
            logv.relink_for_archive(text),
            "[a](../renderer.md) [b](../../build.md) [c](https://x.y/z.md) [d](#anchor) [e](/abs.md)",
        )


class AddEntry(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.log = self.directory / "verification-log.md"
        self.archive_dir = self.directory / "archive"

    def write_log(self, count):
        self.log.write_text(PREAMBLE + "".join(entry(index) for index in range(count, 0, -1)))

    def headings(self, path):
        return [line for line in path.read_text().splitlines() if line.startswith("## ")]

    def test_prepends_without_touching_the_preamble(self):
        self.write_log(3)
        new = logv.format_entry("New", date(2026, 9, 21), lines=["`x` — exit 0"])
        archive, retired, created = logv.add_entry(new, self.log, self.archive_dir, keep=10)
        self.assertIsNone(archive)
        self.assertEqual(retired, [])
        self.assertFalse(created)
        text = self.log.read_text()
        self.assertTrue(text.startswith(PREAMBLE + "## 2026-09-21 — New\n"))
        self.assertEqual(self.headings(self.log), ["## 2026-09-21 — New", "## 2026-09-03 — Entry 3", "## 2026-09-02 — Entry 2", "## 2026-09-01 — Entry 1"])
        self.assertIn("Context 1.", text)
        self.assertTrue(text.endswith("- `cmd` — exit 0\n"))

    def test_overflow_moves_oldest_verbatim_into_a_new_archive(self):
        self.log.write_text(PREAMBLE + entry(3) + entry(2, " See [renderer.md](renderer.md).") + entry(1))
        new = logv.format_entry("New", date(2026, 9, 21), lines=["`x` — exit 0"])
        archive, retired, created = logv.add_entry(new, self.log, self.archive_dir, keep=2)
        self.assertTrue(created)
        self.assertEqual(archive, self.archive_dir / "verification-log-2026-09.md")
        self.assertEqual([item.splitlines()[0] for item in retired], ["## 2026-09-02 — Entry 2", "## 2026-09-01 — Entry 1"])
        self.assertEqual(self.headings(self.log), ["## 2026-09-21 — New", "## 2026-09-03 — Entry 3"])
        archived = archive.read_text()
        self.assertTrue(archived.startswith("# Verification log archive — 2026-09 and earlier"))
        self.assertEqual(self.headings(archive), ["## 2026-09-02 — Entry 2", "## 2026-09-01 — Entry 1"])
        self.assertIn("See [renderer.md](../renderer.md).", archived)

    def test_overflow_goes_on_top_of_an_existing_archive(self):
        self.write_log(2)
        self.archive_dir.mkdir()
        archive = self.archive_dir / "verification-log-2026-09.md"
        archive.write_text("# Archive\n\nKeep this preamble.\n\n" + entry(0))
        new = logv.format_entry("New", date(2026, 9, 21), lines=["`x` — exit 0"])
        path, retired, created = logv.add_entry(new, self.log, self.archive_dir, keep=2)
        self.assertEqual(path, archive)
        self.assertFalse(created)
        self.assertEqual(len(retired), 1)
        text = archive.read_text()
        self.assertTrue(text.startswith("# Archive\n\nKeep this preamble.\n\n## 2026-09-01 — Entry 1\n"))
        self.assertEqual(self.headings(archive), ["## 2026-09-01 — Entry 1", "## 2026-09-00 — Entry 0"])

    def test_dry_run_writes_nothing(self):
        self.write_log(2)
        before = self.log.read_text()
        new = logv.format_entry("New", date(2026, 9, 21), lines=["`x` — exit 0"])
        archive, retired, _ = logv.add_entry(new, self.log, self.archive_dir, keep=1, write=False)
        self.assertEqual(self.log.read_text(), before)
        self.assertFalse(self.archive_dir.exists())
        self.assertEqual(len(retired), 2)
        self.assertIsNotNone(archive)


if __name__ == "__main__":
    unittest.main()
