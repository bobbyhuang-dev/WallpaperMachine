#!/usr/bin/env python3
"""Unit tests for scripts/publish_release.py."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("publish_release", SCRIPTS / "publish_release.py")
publish_release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(publish_release)

ASSETS = ["WallpaperMachine-0.6.0-arm64.dmg", "WallpaperMachine-0.6.0-arm64.dmg.sha256"]


def completed(stdout="", returncode=0):
    return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr="")


class FakeGitHub:
    def __init__(self, draft=None, published=(), prereleases=(), drafted=(), fail_on=None):
        self.draft = draft
        self.published = list(published)
        self.prereleases = list(prereleases)
        self.drafted = list(drafted)
        self.fail_on = fail_on
        self.calls: list[list[str]] = []

    def __call__(self, command, check=True):
        self.calls.append(command)
        verb = command[2] if len(command) > 2 else ""
        if verb == "view":
            if self.draft is None:
                return completed(returncode=1)
            return completed("true\n" if self.draft else "false\n")
        if verb == "list":
            entries = [{"tagName": tag, "isDraft": False, "isPrerelease": False} for tag in self.published]
            entries += [{"tagName": tag, "isDraft": False, "isPrerelease": True} for tag in self.prereleases]
            entries += [{"tagName": tag, "isDraft": True, "isPrerelease": False} for tag in self.drafted]
            return completed(json.dumps(entries))
        if self.fail_on and self.fail_on in command:
            raise publish_release.PublishError(f"{verb} failed")
        return completed()

    @property
    def mutations(self):
        return [command for command in self.calls if command[2] not in ("view", "list")]


class PlanTests(unittest.TestCase):
    def test_no_release_is_created(self):
        self.assertEqual(publish_release.plan(None), publish_release.CREATE)

    def test_a_draft_is_resumed(self):
        self.assertEqual(publish_release.plan(True), publish_release.RESUME)

    def test_a_published_release_is_refused(self):
        self.assertEqual(publish_release.plan(False), publish_release.REFUSE)


class PublishTests(unittest.TestCase):
    def publish(self, github, tag="v0.6.0"):
        return publish_release.publish(tag, "notes.md", ASSETS, run=github)

    def test_a_new_tag_is_drafted_uploaded_then_published(self):
        github = FakeGitHub(draft=None)
        action, latest = self.publish(github)
        self.assertEqual(action, publish_release.CREATE)
        self.assertTrue(latest)
        self.assertEqual([command[1:4] for command in github.mutations],
                         [["release", "create", "v0.6.0"],
                          ["release", "upload", "v0.6.0"],
                          ["release", "edit", "v0.6.0"]])
        self.assertIn("--draft", github.mutations[0])
        self.assertIn("--draft=false", github.mutations[2])

    def test_an_interrupted_run_finishes_its_own_draft(self):
        github = FakeGitHub(draft=True)
        action, _ = self.publish(github)
        self.assertEqual(action, publish_release.RESUME)
        self.assertEqual(github.mutations[0][1:3], ["release", "edit"])
        self.assertNotIn("--draft", github.mutations[0])

    def test_a_published_release_is_never_touched(self):
        github = FakeGitHub(draft=False, published=["v0.6.0"])
        with self.assertRaises(publish_release.PublishError):
            self.publish(github)
        self.assertEqual(github.mutations, [], "A live release must not be edited, cleared or clobbered")

    def test_a_failed_upload_leaves_the_release_a_draft(self):
        github = FakeGitHub(draft=None, fail_on="upload")
        with self.assertRaises(publish_release.PublishError):
            self.publish(github)
        cleared = [command for command in github.mutations if "--draft=false" in command]
        self.assertEqual(cleared, [], "Nothing may publish a release whose upload failed")


class LatestTests(unittest.TestCase):
    def test_the_first_release_claims_latest(self):
        self.assertTrue(publish_release.promotes_to_latest("v0.6.0", []))

    def test_a_newer_version_claims_latest(self):
        self.assertTrue(publish_release.promotes_to_latest("v0.6.0", [(0, 5, 0), (0, 4, 0)]))

    def test_an_older_build_finishing_last_does_not_steal_latest(self):
        # v0.7.0 built faster and published first; v0.6.0 must not demote it.
        github = FakeGitHub(draft=None, published=["v0.7.0"])
        _, latest = publish_release.publish("v0.6.0", "notes.md", ASSETS, run=github)
        self.assertFalse(latest)
        self.assertIn("--latest=false", github.mutations[-1])

    def test_the_newer_build_finishing_last_does_claim_latest(self):
        github = FakeGitHub(draft=None, published=["v0.6.0"])
        _, latest = publish_release.publish("v0.7.0", "notes.md", ASSETS, run=github)
        self.assertTrue(latest)
        self.assertIn("--latest", github.mutations[-1])

    def test_a_greater_prerelease_or_draft_does_not_block_latest(self):
        github = FakeGitHub(draft=None, published=["v0.5.0"], prereleases=["v0.9.0"], drafted=["v0.8.0"])
        _, latest = publish_release.publish("v0.6.0", "notes.md", ASSETS, run=github)
        self.assertTrue(latest, "Only a public, non-prerelease version is what the updater reads")
        self.assertIn("--latest", github.mutations[-1])

    def test_a_tag_that_is_not_a_version_is_refused(self):
        with self.assertRaises(publish_release.PublishError):
            publish_release.promotes_to_latest("nightly", [])


if __name__ == "__main__":
    unittest.main()
