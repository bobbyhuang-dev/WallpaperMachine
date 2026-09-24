#!/usr/bin/env python3
"""Unit tests for the manifest and measurement parsers in scripts/power_benchmark.py."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest import mock

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


GPU_CLIENTS = """\
+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x1000010bd, !registered, !matched, active>
    {
      "AppUsage" = ()
      "IOUserClientCreator" = "pid 443, WindowServer"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x1000010bf, !registered, !matched, active>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=18,"accumulatedGPUTime"=1000},\
{"API"="Metal","lastSubmittedTime"=0,"accumulatedGPUTime"=500})
      "IOUserClientCreator" = "pid 443, WindowServer"
      "CommandQueueCount" = 2
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100001226, !registered, !matched, active>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=20,"accumulatedGPUTime"=7})
      "IOUserClientCreator" = "pid 29493, WallpaperMachine"
    }
"""

POWERMETRICS_SAMPLES = """\
*** Sampled system activity (Wed Sep 23 10:00:00 2026 +0800) (1003.21ms elapsed) ***

**** Processor usage ****

E-Cluster Power: 90 mW
CPU Power: 1000 mW
GPU Power: 400 mW
ANE Power: 0 mW
Combined Power (CPU + GPU + ANE): 1400 mW

**** GPU usage ****

GPU HW active residency:  60.00%
GPU Power: 400 mW

*** Sampled system activity (Wed Sep 23 10:00:01 2026 +0800) (1001.02ms elapsed) ***

**** Processor usage ****

E-Cluster Power: 110 mW
CPU Power: 2000 mW
GPU Power: 600 mW
ANE Power: 10 mW
Combined Power (CPU + GPU + ANE): 2610 mW

**** GPU usage ****

GPU Power: 600 mW
"""


class MeasurementParserTests(unittest.TestCase):
    def test_cpu_time_accepts_unbounded_minutes_hours_and_days(self):
        self.assertAlmostEqual(power_benchmark.parse_cpu_time("419:00.62"), 25140.62)
        self.assertAlmostEqual(power_benchmark.parse_cpu_time("1:02:03.04"), 3723.04)
        self.assertAlmostEqual(power_benchmark.parse_cpu_time("2-01:00:00.00"), 176400.0)

    def test_cpu_time_rejects_anything_else(self):
        for text in ("", "12", "cpu", "1:2:3:4", "-1:00"):
            self.assertIsNone(power_benchmark.parse_cpu_time(text), text)

    def test_gpu_time_is_summed_over_every_client_of_a_process(self):
        self.assertEqual(power_benchmark.parse_gpu_times(GPU_CLIENTS), {443: 1500, 29493: 7})

    def test_package_power_is_the_mean_over_samples(self):
        power = power_benchmark.parse_powermetrics(POWERMETRICS_SAMPLES)
        self.assertTrue(power["measured"])
        self.assertEqual(power["samples"], 2)
        self.assertEqual((power["cpu_mw"], power["gpu_mw"], power["ane_mw"], power["combined_mw"]),
                         (1500.0, 500.0, 5.0, 2005.0))

    def test_output_without_samples_is_not_a_measurement(self):
        power = power_benchmark.parse_powermetrics("powermetrics must be invoked as the superuser")
        self.assertFalse(power["measured"])

    def test_system_power_is_the_mean_of_the_readings_taken_in_the_window(self):
        before = {"AccumulatedSystemLoad": 1_000_000, "SystemLoadAccumulatorCount": 100,
                  "AccumulatedSystemPowerIn": 5_000, "SystemPowerInAccumulatorCount": 7}
        after = {"AccumulatedSystemLoad": 1_000_000 + 3 * 20_000 + 2 * 23_000,
                 "SystemLoadAccumulatorCount": 105,
                 "AccumulatedSystemPowerIn": 5_000, "SystemPowerInAccumulatorCount": 7}
        power = power_benchmark.system_power(before, after)
        self.assertTrue(power["measured"])
        self.assertEqual((power["load_mw"], power["samples"]), (21_200, 5))
        self.assertIsNone(power["power_in_mw"], "an adapter that delivered nothing has no mean")

    def test_system_power_without_new_readings_or_a_battery_is_not_a_measurement(self):
        snapshot = {"AccumulatedSystemLoad": 10, "SystemLoadAccumulatorCount": 1}
        self.assertFalse(power_benchmark.system_power(snapshot, dict(snapshot))["measured"])
        self.assertFalse(power_benchmark.system_power(None, snapshot)["measured"])

    def test_battery_telemetry_is_read_from_the_plist_ioreg_prints(self):
        telemetry = {"SystemLoad": 21_503, "AccumulatedSystemLoad": 6_226_785_686,
                     "SystemLoadAccumulatorCount": 225_876}
        text = plistlib.dumps([{"PowerTelemetryData": telemetry, "Voltage": 12_316}]).decode()
        self.assertEqual(power_benchmark.parse_power_telemetry(text), telemetry)
        self.assertIsNone(power_benchmark.parse_power_telemetry("not a plist"))
        self.assertIsNone(power_benchmark.parse_power_telemetry(plistlib.dumps([]).decode()))


class MeasureWindowTests(unittest.TestCase):
    def test_a_refused_powermetrics_still_measures_the_whole_window(self):
        # sudo rejecting the password returns at once. Taking the second
        # samples then would turn a 60-second measurement into a rate over a
        # fraction of a second.
        clock = SimpleNamespace(now=5_000.0, slept=[])

        def sleep(seconds):
            clock.slept.append(seconds)
            clock.now += seconds

        def refused(seconds, password):
            clock.now += 0.2
            return {"measured": False, "reason": "sudo: 1 incorrect password attempt"}

        cpu = iter([{7: 10.0}, {7: 40.0}])
        with mock.patch.object(power_benchmark, "time",
                               SimpleNamespace(monotonic=lambda: clock.now, sleep=sleep)), \
                mock.patch.object(power_benchmark, "role_pids", lambda: {"app": [7]}), \
                mock.patch.object(power_benchmark, "cpu_seconds", lambda pids: next(cpu)), \
                mock.patch.object(power_benchmark, "gpu_times", lambda: None), \
                mock.patch.object(power_benchmark, "power_telemetry", lambda: None), \
                mock.patch.object(power_benchmark, "package_power", refused):
            measurement = power_benchmark.measure(60, True, "wrong")
        self.assertAlmostEqual(measurement["elapsed_seconds"], 60.0)
        self.assertAlmostEqual(sum(clock.slept), 59.8)
        self.assertEqual(measurement["processes"]["app"]["cpu_percent"], 50.0)
        self.assertFalse(measurement["package_power"]["measured"])
        self.assertIn("incorrect password", measurement["package_power"]["reason"])


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

    def test_measuring_needs_a_condition(self):
        completed = subprocess.run(
            [sys.executable, str(SCRIPTS / "power_benchmark.py"), "--measure", "1"],
            capture_output=True, text=True, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("--condition", completed.stderr)


if __name__ == "__main__":
    unittest.main()
