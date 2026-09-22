#!/usr/bin/env python3
"""Attach a built archive to its GitHub Release, draft first, never to a live one.

The in-app updater reads the newest non-draft release, so a release that is public
before its archive is uploaded is a release users cannot download. This creates the
release as a draft, uploads, and clears the draft flag last; a failure anywhere in
between leaves a draft, which `releases/latest` does not return.

Two things the naive `gh` sequence gets wrong, both covered by
`scripts/tests/test_publish_release.py`:

* A release that is *already* published is refused rather than updated.
  `gh release upload --clobber` deletes an existing asset before writing its
  replacement, so re-running against a live release takes the download away and
  only puts it back if the upload succeeds — the window the draft-first order
  exists to close. Republishing different bytes under a tag people already
  downloaded is wrong anyway: cut the next version.
* Latest is claimed only when no greater version is already public. The workflows
  lock per tag, not per repository, so two versions can build at once and finish in
  whatever order their caches allow; promoting unconditionally lets the older build
  finish last, take Latest, and offer users the wrong version.

    python3 scripts/publish_release.py --tag v0.6.0 --notes notes.md app.zip app.zip.sha256
    python3 scripts/publish_release.py --tag v0.6.0 --notes notes.md --dry-run app.zip

Called by .github/workflows/build.yml; `gh` reads GH_TOKEN from the environment.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from lib.glyphs import markers

MARK = markers()
VERSION_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")

CREATE = "create"
RESUME = "resume"
REFUSE = "refuse"


class PublishError(Exception):
    """A condition that stops publishing; the message is the whole report."""


def version_key(tag):
    match = VERSION_TAG.match((tag or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None


def plan(existing):
    """What to do about a release for this tag.

    `existing` is None when no release exists, True for a draft, False for one that
    is already published.
    """
    if existing is None:
        return CREATE
    return RESUME if existing else REFUSE


def promotes_to_latest(tag, published):
    """Whether this tag may claim Latest, given the versions already public."""
    ours = version_key(tag)
    if ours is None:
        raise PublishError(f"Not an x.y.z version tag: {tag!r}")
    return not any(other > ours for other in published)


def commands(tag, action, notes, assets, latest):
    """The `gh` invocations for an action, in the only order that is safe.

    The draft flag is cleared last and in its own command, so an upload that fails
    never reaches it.
    """
    if action == CREATE:
        first = ["gh", "release", "create", tag, "--draft", "--verify-tag", "--title", tag, "--notes-file", notes]
    else:
        first = ["gh", "release", "edit", tag, "--title", tag, "--notes-file", notes]
    return [
        first,
        ["gh", "release", "upload", tag, *assets, "--clobber"],
        ["gh", "release", "edit", tag, "--draft=false", "--latest" if latest else "--latest=false"],
    ]


def runner(command, check=True):
    completed = subprocess.run(command, capture_output=True, text=True)
    if check and completed.returncode != 0:
        raise PublishError(f"{' '.join(command)} failed: {completed.stderr.strip() or completed.stdout.strip()}")
    return completed


def lookup(tag, run):
    """True when a release for the tag exists as a draft, False when published, None when absent."""
    completed = run(["gh", "release", "view", tag, "--json", "isDraft", "--jq", ".isDraft"], check=False)
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    if value not in ("true", "false"):
        raise PublishError(f"gh reported an unreadable draft state for {tag}: {value!r}")
    return value == "true"


def published_versions(run):
    """Versions of every release that is already public; drafts and prereleases are not."""
    completed = run(["gh", "release", "list", "--limit", "200", "--json", "tagName,isDraft,isPrerelease"])
    versions = []
    for entry in json.loads(completed.stdout or "[]"):
        if entry.get("isDraft") or entry.get("isPrerelease"):
            continue
        key = version_key(entry.get("tagName", ""))
        if key is not None:
            versions.append(key)
    return versions


def publish(tag, notes, assets, run=runner, dry_run=False):
    action = plan(lookup(tag, run))
    if action == REFUSE:
        raise PublishError(
            f"{tag} is already published. Uploading over it would remove the live download first, "
            "which is what the draft-first order exists to prevent. Cut the next version, or delete "
            "that release by hand if it was a mistake."
        )
    latest = promotes_to_latest(tag, published_versions(run))
    for command in commands(tag, action, notes, assets, latest):
        if dry_run:
            print(f"{MARK.step} {' '.join(command)}")
            continue
        run(command)
    return action, latest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True, help="Version tag the release belongs to.")
    parser.add_argument("--notes", required=True, help="Markdown file holding the release body.")
    parser.add_argument("--dry-run", action="store_true", help="Print the gh commands and run none of them.")
    parser.add_argument("assets", nargs="+", help="Files to upload, archive first.")
    args = parser.parse_args(argv)
    for path in [args.notes, *args.assets]:
        if not Path(path).is_file():
            raise PublishError(f"Not a file: {path}")
    action, latest = publish(args.tag, args.notes, args.assets, dry_run=args.dry_run)
    verb = "Created and published" if action == CREATE else "Finished the draft for"
    mark = "Latest" if latest else "not Latest: a greater version is already public"
    print(f"{MARK.ok} {verb} {args.tag} ({mark}): {', '.join(Path(asset).name for asset in args.assets)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PublishError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
