#!/usr/bin/env python3
"""Unit tests for the generated-scene pixel criteria in scripts/check_renderer.py."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("check_renderer", SCRIPTS / "check_renderer.py")
check_renderer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(check_renderer)

WIDTH, HEIGHT = 384, 256
MARGIN = bytes((26, 51, 77))
PAGE = bytes((255, 255, 255))
# The paused parent timeline holds the third corner on its first key; leaving it
# on the constant value is the defect the fixture has to make visible.
AUTHORED = [(0.25, 0.5), (0.75, 0.375), (0.875, 0.875), (0.375, 1.0)]
STATIC_CORNER = [(0.25, 0.5), (0.75, 0.375), (0.375, 0.875), (0.375, 1.0)]


def ppm(shade):
    """Render a 384x256 P6 frame the way the probe writes one."""
    body = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            body += shade((x + 0.5) / WIDTH, (y + 0.5) / HEIGHT)
    return b"P6\n%d %d\n255\n" % (WIDTH, HEIGHT) + bytes(body)


def quad_mask(corners):
    """The square-to-quad homography the fixture shader inverts per fragment."""
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = corners
    sx, sy = x0 - x1 + x2 - x3, y0 - y1 + y2 - y3
    dx1, dy1 = x1 - x2, y1 - y2
    dx2, dy2 = x3 - x2, y3 - y2
    basis = dx1 * dy2 - dx2 * dy1
    g = (sx * dy2 - dx2 * sy) / basis
    h = (dx1 * sy - sx * dy1) / basis
    a, b, c = x1 - x0 + g * x1, x3 - x0 + h * x3, x0
    d, e, f = y1 - y0 + g * y1, y3 - y0 + h * y3, y0
    det = a * (e - f * h) - b * (d - f * g) + c * (d * h - e * g)
    rows = [[value / det for value in row] for row in
            [[e - f * h, c * h - b, b * f - c * e],
             [f * g - d, a - c * g, c * d - a * f],
             [d * h - e * g, b * g - a * h, a * e - b * d]]]

    def shade(u, v):
        point = (u, v, 1.0)
        w = sum(factor * value for factor, value in zip(rows[2], point))
        if w <= 0.0:
            return MARGIN
        square = [sum(factor * value for factor, value in zip(row, point)) / w for row in rows[:2]]
        return PAGE if all(0.0 <= value <= 1.0 for value in square) else MARGIN

    return shade


class PerspectiveCornerPixelTests(unittest.TestCase):
    def test_accepts_the_page_drawn_from_the_authored_first_key(self):
        self.assertTrue(check_renderer.check_generated_pixels(ppm(quad_mask(AUTHORED)), 9))

    def test_rejects_the_wedge_left_by_the_unanimated_corner(self):
        self.assertFalse(check_renderer.check_generated_pixels(ppm(quad_mask(STATIC_CORNER)), 9))

    def test_rejects_frames_with_no_page_and_frames_that_are_only_page(self):
        for fill in [MARGIN, PAGE]:
            with self.subTest(fill=fill):
                self.assertFalse(
                    check_renderer.check_generated_pixels(ppm(lambda u, v, c=fill: c), 9))

    def test_rejects_the_right_page_over_the_wrong_background(self):
        # A correct page over a cleared-to-black or recoloured target is still a
        # broken frame, so matching the two margins to each other is not enough.
        for wrong in [bytes((0, 0, 0)), bytes((26, 51, 180))]:
            with self.subTest(background=wrong):
                page = quad_mask(AUTHORED)
                shade = lambda u, v: PAGE if page(u, v) == PAGE else wrong
                self.assertFalse(check_renderer.check_generated_pixels(ppm(shade), 9))


if __name__ == "__main__":
    unittest.main()
