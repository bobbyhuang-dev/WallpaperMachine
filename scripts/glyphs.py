#!/usr/bin/env python3
"""Status markers for script output: Nerd Font glyphs where the terminal can draw them.

Nerd Font icons live in the Unicode Private Use Area, so they appear only when
the terminal has a patched font to draw them from; otherwise the terminal shows
tofu. Warp resolves those code points through its own font fallback once any
Nerd Font is installed, so `markers()` upgrades the plain ASCII markers to
glyphs for an interactive Warp session with such a font present, and keeps ASCII
everywhere else: pipes, redirects, CI logs, and terminals without the fallback.

Set `MWE_GLYPHS=nerd` to force glyphs (any terminal configured with a Nerd
Font) or `MWE_GLYPHS=ascii` to force the plain markers.
"""
from __future__ import annotations

from functools import lru_cache
import os
from pathlib import Path
import sys
from typing import NamedTuple


class Markers(NamedTuple):
    """Line prefixes for status output."""

    ok: str
    warn: str
    missing: str
    step: str


ASCII = Markers(ok="OK", warn="WARN", missing="MISSING", step="+")
# Font Awesome block of the Nerd Font private use area, unchanged between Nerd
# Font v2 and v3: check, triangle-exclamation, xmark, chevron-right.
NERD = Markers(ok="\uf00c", warn="\uf071", missing="\uf00d", step="\uf054")

# Terminals that substitute an installed Nerd Font for private use code points.
NERD_FONT_TERMINALS = frozenset({"WarpTerminal"})
FONT_DIRECTORIES = (Path.home() / "Library/Fonts", Path("/Library/Fonts"))
ENABLE = frozenset({"nerd", "1", "true", "on", "yes"})
DISABLE = frozenset({"ascii", "0", "false", "off", "no", "none"})


@lru_cache(maxsize=4)
def nerd_font_installed(directories):
    """True when a Nerd Font file is installed for the terminal to fall back to."""
    for directory in directories:
        try:
            with os.scandir(directory) as entries:
                if any("nerd" in entry.name.lower() for entry in entries):
                    return True
        except OSError:
            continue
    return False


def supports_nerd_font(stream=None, environ=None):
    """Whether glyph markers will render as icons rather than tofu."""
    environ = os.environ if environ is None else environ
    override = environ.get("MWE_GLYPHS", "").strip().lower()
    if override in ENABLE:
        return True
    if override in DISABLE:
        return False
    stream = sys.stdout if stream is None else stream
    if not callable(getattr(stream, "isatty", None)) or not stream.isatty():
        return False
    if environ.get("TERM", "") in ("", "dumb"):
        return False
    if environ.get("TERM_PROGRAM") not in NERD_FONT_TERMINALS:
        return False
    return nerd_font_installed(FONT_DIRECTORIES)


def markers(stream=None, environ=None):
    """ASCII markers, upgraded to Nerd Font glyphs when the terminal can show them."""
    return NERD if supports_nerd_font(stream, environ) else ASCII


if __name__ == "__main__":
    mark = markers()
    style = "nerd" if mark is NERD else "ascii"
    print(f"{mark.step} glyph style: {style}")
    print(f"{mark.ok} ok")
    print(f"{mark.warn} warn")
    print(f"{mark.missing} missing")
