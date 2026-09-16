#!/usr/bin/env python3
"""Unit tests for scripts/build.py."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("build", SCRIPTS / "build.py")
build = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(build)

IDENTITY = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]


def commit_repository(path, message):
    """Initialise a Git repository at `path` with one commit; return its short commit."""
    path.mkdir(parents=True, exist_ok=True)
    git = ["git", *IDENTITY, "-C", str(path)]
    subprocess.run([*git, "init", "--quiet"], check=True)
    subprocess.run([*git, "commit", "--quiet", "--allow-empty", "-m", message], check=True)
    return subprocess.check_output([*git, "rev-parse", "--short", "HEAD"], text=True).strip()


class RepositoryCommitTests(unittest.TestCase):
    def test_reports_the_repository_not_the_vendored_renderer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            application = commit_repository(root, "application source")
            renderer = commit_repository(root / "upstream/renderer", "pinned upstream revision")
            self.assertNotEqual(application, renderer)
            self.assertEqual(build.repository_commit(root), application)


if __name__ == "__main__":
    unittest.main()
