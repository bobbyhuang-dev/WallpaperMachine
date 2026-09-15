#!/usr/bin/env python3
"""Unit tests for scripts/glyphs.py."""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "glyphs.py"
SPEC = importlib.util.spec_from_file_location("glyphs", SCRIPT)
glyphs = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(glyphs)

WARP_TTY = {"TERM": "xterm-256color", "TERM_PROGRAM": "WarpTerminal"}


class FakeStream:
    def __init__(self, tty):
        self._tty = tty

    def isatty(self):
        return self._tty


def fonts(*names):
    directory = Path(tempfile.mkdtemp())
    for name in names:
        (directory / name).touch()
    return (directory,)


class DetectionTests(unittest.TestCase):
    def markers(self, tty=True, environ=None, installed=("JetBrainsMonoNerdFont-Regular.ttf",)):
        original = glyphs.FONT_DIRECTORIES
        glyphs.FONT_DIRECTORIES = fonts(*installed)
        try:
            glyphs.nerd_font_installed.cache_clear()
            return glyphs.markers(FakeStream(tty), dict(environ or {}))
        finally:
            glyphs.FONT_DIRECTORIES = original
            glyphs.nerd_font_installed.cache_clear()

    def test_warp_tty_with_nerd_font_installed_uses_glyphs(self):
        self.assertEqual(self.markers(environ=WARP_TTY), glyphs.NERD)

    def test_warp_without_nerd_font_installed_stays_ascii(self):
        self.assertEqual(self.markers(environ=WARP_TTY, installed=("Hack-Regular.ttf",)), glyphs.ASCII)

    def test_redirected_output_stays_ascii(self):
        self.assertEqual(self.markers(tty=False, environ=WARP_TTY), glyphs.ASCII)

    def test_other_terminal_stays_ascii(self):
        self.assertEqual(self.markers(environ={"TERM": "xterm-256color", "TERM_PROGRAM": "Apple_Terminal"}), glyphs.ASCII)

    def test_dumb_terminal_stays_ascii(self):
        self.assertEqual(self.markers(environ={"TERM": "dumb", "TERM_PROGRAM": "WarpTerminal"}), glyphs.ASCII)

    def test_override_forces_glyphs_without_any_terminal_hint(self):
        self.assertEqual(self.markers(tty=False, environ={"MWE_GLYPHS": "nerd"}, installed=()), glyphs.NERD)

    def test_override_forces_ascii_inside_warp(self):
        self.assertEqual(self.markers(environ={**WARP_TTY, "MWE_GLYPHS": "ascii"}), glyphs.ASCII)

    def test_unknown_override_falls_back_to_detection(self):
        self.assertEqual(self.markers(environ={**WARP_TTY, "MWE_GLYPHS": "maybe"}), glyphs.NERD)


class MarkerTests(unittest.TestCase):
    def test_glyph_markers_are_single_private_use_code_points(self):
        for marker in glyphs.NERD:
            self.assertEqual(len(marker), 1)
            self.assertTrue(0xE000 <= ord(marker) <= 0xF8FF, marker)

    def test_ascii_markers_stay_ascii(self):
        for marker in glyphs.ASCII:
            self.assertTrue(marker.isascii(), marker)


if __name__ == "__main__":
    unittest.main()
