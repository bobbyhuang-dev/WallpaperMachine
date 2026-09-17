#!/usr/bin/env python3
"""Unit tests for the configuration manifest in scripts/power_benchmark.py."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("power_benchmark", SCRIPTS / "power_benchmark.py")
power_benchmark = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(power_benchmark)


class CommandOutputTests(unittest.TestCase):
    def test_a_failing_inspection_reports_nothing_rather_than_an_empty_string(self):
        self.assertIsNone(power_benchmark.command_output([sys.executable, "-c", "raise SystemExit(3)"]))

    def test_a_missing_tool_does_not_raise(self):
        self.assertIsNone(power_benchmark.command_output(["mwe-tool-that-does-not-exist"]))

    def test_output_is_stripped(self):
        self.assertEqual(
            power_benchmark.command_output([sys.executable, "-c", "print('  value  ')"]),
            "value")


class ParserTests(unittest.TestCase):
    def test_malformed_hardware_json_yields_an_empty_section(self):
        original = power_benchmark.command_output
        power_benchmark.command_output = lambda command: "{not json"
        try:
            self.assertEqual(power_benchmark.hardware(), {})
            self.assertEqual(power_benchmark.displays(), [])
        finally:
            power_benchmark.command_output = original

    def test_displays_are_flattened_across_graphics_cards(self):
        payload = json.dumps({"SPDisplaysDataType": [
            {"spdisplays_ndrvs": [
                {"_name": "Built-in", "_spdisplays_pixels": "3456 x 2234", "ignored": "x"},
                {"_name": "External", "_spdisplays_pixels": "6880 x 2880"},
            ]},
            {"spdisplays_ndrvs": [{"_name": "Third", "_spdisplays_pixels": "1920 x 1080"}]},
        ]})
        original = power_benchmark.command_output
        power_benchmark.command_output = lambda command: payload
        try:
            found = power_benchmark.displays()
        finally:
            power_benchmark.command_output = original
        self.assertEqual([entry["_name"] for entry in found], ["Built-in", "External", "Third"])
        self.assertNotIn("ignored", found[0], "only geometry fields are recorded")

    def test_vendored_revisions_are_keyed_by_the_directory_they_ship_from(self):
        revisions = power_benchmark.provenance()
        self.assertIn("upstream/renderer", revisions)
        self.assertIn("upstream/renderer/external/open-wallpaper-engine", revisions)
        self.assertTrue(all(revisions.values()), "a recorded entry must carry its pinned revision")
        self.assertNotIn("App", revisions, "first-party directories pin no upstream revision")

    def test_a_card_without_displays_contributes_nothing(self):
        original = power_benchmark.command_output
        power_benchmark.command_output = lambda command: json.dumps(
            {"SPDisplaysDataType": [{"_name": "Headless"}]})
        try:
            self.assertEqual(power_benchmark.displays(), [])
        finally:
            power_benchmark.command_output = original


class ManifestTests(unittest.TestCase):
    def manifest(self):
        return power_benchmark.manifest(
            argparse.Namespace(configuration="Release", note="test"))

    def test_every_condition_starts_unmeasured(self):
        document = self.manifest()
        self.assertFalse(document["measured"])
        self.assertIsNone(document["measurement_tool"])
        self.assertTrue(document["conditions"])
        self.assertTrue(all(not entry["measured"] for entry in document["conditions"]))

    def test_the_baseline_and_load_matrix_is_complete(self):
        ids = [entry["id"] for entry in self.manifest()["conditions"]]
        self.assertEqual(ids, ["B0", "B1", "B2", "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8"])

    def test_the_manifest_is_json_serializable(self):
        json.loads(json.dumps(self.manifest()))


class InvocationTests(unittest.TestCase):
    def test_print_only_writes_no_artifact_and_emits_the_manifest(self):
        before = set(power_benchmark.POWER_ARTIFACTS.glob("*.json")) \
            if power_benchmark.POWER_ARTIFACTS.is_dir() else set()
        completed = subprocess.run(
            [sys.executable, str(SCRIPTS / "power_benchmark.py"), "--print-only"],
            capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = json.loads(completed.stdout)
        self.assertFalse(document["measured"])
        after = set(power_benchmark.POWER_ARTIFACTS.glob("*.json")) \
            if power_benchmark.POWER_ARTIFACTS.is_dir() else set()
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
