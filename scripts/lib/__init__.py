"""Shared helpers for the developer scripts in `scripts/`.

Entry-point scripts live directly in `scripts/`; anything imported by more than
one of them belongs here. Python puts a script's own directory on `sys.path`, so
`scripts/build.py` can `from lib.paths import ROOT` without any path juggling.
"""
