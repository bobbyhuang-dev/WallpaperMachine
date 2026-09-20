#!/usr/bin/env python3
"""Unit tests for scripts/test.py's command construction."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("test_runner", SCRIPTS / "test.py")
runner = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(runner)


class TestIdentifiers(unittest.TestCase):
    def test_default_is_the_whole_target(self):
        self.assertEqual(runner.test_identifiers("T", None), ["T"])
        self.assertEqual(runner.test_identifiers("T", []), ["T"])
        self.assertEqual(runner.test_identifiers("T", ["", "  "]), ["T"])

    def test_classes_and_methods_are_prefixed_once(self):
        self.assertEqual(
            runner.test_identifiers("T", ["A", "B/testX", "T/C", "/D/"]),
            ["T/A", "T/B/testX", "T/C", "T/D"],
        )


class TestXcodebuildCommand(unittest.TestCase):
    def only_testing(self, only):
        command = runner.xcodebuild_command("S", "T", Path("/tmp/r.xcresult"), only)
        return [part for part in command if part.startswith("-only-testing:")]

    def test_full_run_targets_the_bundle(self):
        self.assertEqual(self.only_testing(None), ["-only-testing:T"])

    def test_targeted_run_lists_each_entry(self):
        self.assertEqual(self.only_testing(["A", "B/testX"]), ["-only-testing:T/A", "-only-testing:T/B/testX"])

    def test_action_stays_last(self):
        self.assertEqual(runner.xcodebuild_command("S", "T", Path("/tmp/r.xcresult"), ["A"])[-1], "test")


if __name__ == "__main__":
    unittest.main()
