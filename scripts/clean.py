#!/usr/bin/env python3
"""Remove testing and build byproducts.

Default pass deletes only regenerable evidence: `artifacts/`, stray result bundles
and logs left in `build/`, `__pycache__` directories, and `.DS_Store` files. Xcode's
derived data and the built app survive unless `--derived` or `--all` is requested,
because `build/Build/Products/Release/MacWallpaperEngine.app` is the locally
delivered app. See docs/testing/README.md for the evidence policy.
`--user-assets` is separate from all of that: it deletes the regenerable bridge each
wallpaper keeps inside its own folder, which is live wallpaper state rather than a
byproduct, and so is never touched by the default pass or by `--all`. The bridge is
rebuilt from managed storage the next time the wallpaper loads, so nothing is lost.

`--managed-user-assets` is the destructive one: it deletes the app's own copies of the
files the user imported for `file` and `directory` wallpaper properties. Those copies
are the system of record and nothing regenerates them, so no other flag — not
`--all`, not `--derived`, not `--user-assets` — ever reaches them.
"""
import argparse
import os
from pathlib import Path
import shutil

from lib.glyphs import markers
from lib.paths import ARTIFACTS, BUILD, ROOT

MARK = markers()

# Xcode owns these entries under build/. Anything else there is a stray byproduct:
# an ad-hoc derived-data tree, a saved .app snapshot, a result bundle, or a log.
PRODUCTS_DIR = "Build"
DERIVED_CACHES = (
    "ModuleCache.noindex",
    "Index.noindex",
    "CompilationCache.noindex",
    "ExplicitPrecompiledModules",
    "SDKExplicitPrecompiledModules",
    "SDKStatCaches.noindex",
    "SourcePackages",
    "XCBuildData",
    "Symbols",
    "TextIndex",
    "Logs",
    "TestResults",
    "info.plist",
    "LogStoreManifest.plist",
)

# Round 6 staged user picks here and nowhere else. Round 7 made this a derived bridge
# onto MANAGED_USER_ASSETS_DIR, kept inside the project only because WebKit grants a
# page read access below its project directory and nowhere else.
USER_ASSETS_DIR = ".mwe-user-assets"
# The app's own copies, mirroring ClientPaths.userAssetsURL. Deliberately not under
# any directory named Cache: nothing regenerates these.
MANAGED_USER_ASSETS_DIR = "UserAssets"
STEAM_WORKSHOP = "Library/Application Support/Steam/steamapps/workshop/content/431960"


def evidence():
    """Regenerable evidence, wherever a script or an older layout left it."""
    if ARTIFACTS.exists():
        yield ARTIFACTS
    if BUILD.is_dir():
        for child in sorted(BUILD.iterdir()):
            if child.name not in DERIVED_CACHES and child.name != PRODUCTS_DIR:
                yield child
    for pattern in ("**/__pycache__", "**/.DS_Store"):
        for path in sorted(ROOT.glob(pattern)):
            if BUILD not in path.parents:
                yield path


def derived():
    for name in DERIVED_CACHES:
        path = BUILD / name
        if path.exists():
            yield path


def support_root():
    """The app's data directory, mirroring ClientPaths.supportURL."""
    override = os.environ.get("MAC_WALLPAPER_ENGINE_HOME")
    if override:
        return Path(override)
    return Path.home() / "Library/Application Support/mac-wallpaper-engine"


def user_assets():
    """The regenerable bridge each wallpaper keeps in its own folder.

    Live wallpaper state, not a byproduct, so no other pass touches it. Since round 7
    this is derived: every entry is a link onto the app's own copy under
    `MANAGED_USER_ASSETS_DIR`, and the next load of the wallpaper rebuilds whatever
    this removes. The user's originals were never at risk and still are not.
    """
    for root in (support_root() / "Library", Path.home() / STEAM_WORKSHOP):
        if not root.is_dir():
            continue
        for project in sorted(root.iterdir()):
            staging = project / USER_ASSETS_DIR
            if staging.is_dir():
                yield staging


def managed_user_assets():
    """The app's own copies of the files the user imported.

    Nothing regenerates these: once the user's original has moved or gone, this is the
    only copy the wallpaper has. Reached only by the flag that says so in as many words.
    """
    managed = support_root() / MANAGED_USER_ASSETS_DIR
    if managed.is_dir():
        yield managed


def label(path):
    """Repository-relative where possible, `~`-relative for the user's own library."""
    for base, prefix in ((ROOT, Path()), (Path.home(), Path("~"))):
        try:
            return prefix / path.relative_to(base)
        except ValueError:
            continue
    return path


def reclaimable(path):
    """Bytes an unlink actually frees. A file with other hard links onto it frees none,
    which is how every staged user asset on the same volume as its source is held."""
    status = path.stat()
    return status.st_size if status.st_nlink == 1 else 0


def remove(paths, dry_run):
    total = 0
    for path in paths:
        size = sum(reclaimable(file) for file in path.rglob("*") if file.is_file()) if path.is_dir() else reclaimable(path)
        total += size
        print(f"{MARK.step} {'would remove' if dry_run else 'removing'} {label(path)} ({size / 1e9:.2f} GB)")
        if not dry_run:
            shutil.rmtree(path) if path.is_dir() else path.unlink()
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived", action="store_true", help="Also clear Xcode's derived-data caches under build/.")
    parser.add_argument("--all", action="store_true", help="Remove build/ entirely, including the built app.")
    parser.add_argument("--dry-run", action="store_true", help="List what would be removed and exit.")
    parser.add_argument("--user-assets", action="store_true",
                        help="Also remove the regenerable in-project bridge for file/directory "
                             "wallpaper properties. The app rebuilds it from managed storage on "
                             "the next load, so nothing the user imported is lost.")
    parser.add_argument("--managed-user-assets", action="store_true",
                        help="DESTRUCTIVE: also delete the app's own copies of the files the user "
                             "imported for file/directory wallpaper properties. Nothing "
                             "regenerates these; an import whose original has since moved or been "
                             "deleted is gone for good. No other flag reaches them.")
    args = parser.parse_args()
    targets = list(evidence())
    if args.all:
        targets = [path for path in targets if BUILD not in path.parents and path != BUILD]
        if BUILD.exists():
            targets.append(BUILD)
    elif args.derived:
        targets += list(derived())
    if args.user_assets:
        targets += list(user_assets())
    if args.managed_user_assets:
        targets += list(managed_user_assets())
    if not targets:
        print(f"{MARK.ok} Nothing to remove.")
        return 0
    total = remove(targets, args.dry_run)
    verb = "Would reclaim" if args.dry_run else "Reclaimed"
    print(f"{MARK.ok} {verb} {total / 1e9:.2f} GB")
    if args.all and not args.dry_run:
        print(f"{MARK.warn} build/ is gone: rebuild with `python3 scripts/build.py --configuration Release` before running the app.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
