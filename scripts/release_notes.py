#!/usr/bin/env python3
"""Release notes and CHANGELOG.md sections, read from the commits between two version tags.

`gh release create --generate-notes` writes a bare compare link when the history has
no pull requests, which is all the thirteen releases through v0.5.0 ever said. This
reads the commits instead and groups them by the `type(scope): subject` convention
the repository already follows, so the GitHub Release body, `CHANGELOG.md` and the
in-app "What's New" all come from one source.

    python3 scripts/release_notes.py                            # notes for project.yml's version
    python3 scripts/release_notes.py --tag v0.6.0 --to HEAD     # before the tag exists
    python3 scripts/release_notes.py --tag v0.6.0 --release-body --output notes.md
    python3 scripts/release_notes.py --changelog --apply
    python3 scripts/release_notes.py --rebuild-changelog --apply

Documentation, test and tooling commits are counted in a single line instead of
listed; a commit the convention does not recognise is listed under "Other changes",
so no commit disappears silently. `--release-body` appends the install, checksum
and requirement footer the release page needs. `CHANGELOG.md` is only written with
`--apply`; `--output` writes the file it is given.
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple

from lib.glyphs import markers
from lib.paths import PROJECT_YML, ROOT

MARK = markers()
CHANGELOG = ROOT / "CHANGELOG.md"
APPLICATION = "WallpaperMachine"

# `type(scope)!: subject`, the convention docs/conventions.md describes.
CONVENTIONAL = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?:[ \t]*(?P<subject>.+)$")
VERSION_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
# The Version workflow's own commit; it describes the release, it is not part of it.
BUMP_COMMIT = re.compile(r"^chore: bump version to \d+\.\d+\.\d+$")
BREAKING_BODY = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)
CHANGELOG_HEADING = re.compile(r"^## (\d+\.\d+\.\d+)\b")
MARKETING_VERSION = re.compile(r'MARKETING_VERSION:\s*"([^"]+)"')
REMOTE_SLUG = re.compile(r"(?:https://github\.com/|git@github\.com:)(?P<slug>[^/]+/[^/\s]+?)(?:\.git)?/?$")
DEPLOYMENT_TARGET = re.compile(r"MACOSX_DEPLOYMENT_TARGET:\s*\"?([\d.]+)")

# One bullet, one line: past this a subject is cut at a word boundary and the linked
# commit carries the rest.
SUBJECT_LIMIT = 140

# Boundary between the notes the in-app updater shows and the download instructions
# that belong only to the release page. App/Services/GitHub reads the same marker.
NOTES_END = "<!-- release-notes-end -->"

FIELD = "\x1f"
RECORD = "\x1e"

# Where a commit type is reported. A type that is absent is user-visible by
# default: an unrecognised commit is listed under "Other changes", never hidden.
GROUPS = {
    "feat": "features",
    "fix": "fixes",
    "perf": "performance",
    "docs": "internal",
    "test": "internal",
    "tests": "internal",
    "chore": "internal",
    "ci": "internal",
    "build": "internal",
    "style": "internal",
}
SECTIONS = (
    ("breaking", "Breaking changes"),
    ("features", "New"),
    ("fixes", "Fixed"),
    ("performance", "Performance"),
    ("other", "Other changes"),
)

CHANGELOG_PREAMBLE = """\
# Changelog

Every published version, newest first. Sections are written by
[`scripts/release_notes.py`](scripts/release_notes.py) from the commits between two
version tags, so this file and the GitHub Release body always say the same thing.
Documentation, test and tooling commits are counted rather than listed. See
[docs/release.md](docs/release.md) for how a version is cut.

"""


class NotesError(Exception):
    """A condition that stops note generation; the message is the whole report."""


class Change(NamedTuple):
    """One commit, already classified for the section it belongs to."""

    group: str
    scope: str
    subject: str
    sha: str


def git(*args, cwd=ROOT):
    result = subprocess.run(["git", *map(str, args)], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise NotesError(f"git {' '.join(map(str, args))} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def version_key(value):
    match = VERSION_TAG.match(value.strip())
    if not match:
        raise NotesError(f"Not an x.y.z version: {value!r}")
    return tuple(int(part) for part in match.groups())


def display_version(value):
    return ".".join(str(part) for part in version_key(value))


def repository(cwd=ROOT):
    """`owner/repo` from the GitHub origin remote, or None when there is no usable one."""
    try:
        url = git("config", "--get", "remote.origin.url", cwd=cwd).strip()
    except NotesError:
        return None
    match = REMOTE_SLUG.search(url)
    return match.group("slug") if match else None


def current_version(project=PROJECT_YML):
    match = MARKETING_VERSION.search(Path(project).read_text(encoding="utf-8"))
    if not match:
        raise NotesError(f"No MARKETING_VERSION in {project}")
    return match.group(1)


def deployment_target(project=PROJECT_YML):
    match = DEPLOYMENT_TARGET.search(Path(project).read_text(encoding="utf-8"))
    return match.group(1) if match else None


def version_tags(cwd=ROOT):
    """Every `vx.y.z` tag, oldest version first."""
    tags = [tag for tag in git("tag", "--list", "v*", cwd=cwd).split() if VERSION_TAG.match(tag)]
    return sorted(tags, key=version_key)


def is_ancestor(candidate, revision, cwd=ROOT):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", candidate, revision], cwd=cwd, capture_output=True, text=True)
    return result.returncode == 0


def previous_tag(version, revision, cwd=ROOT, tags=None):
    """The newest released version below `version` that `revision` descends from."""
    target = version_key(version)
    for tag in reversed(tags if tags is not None else version_tags(cwd)):
        if version_key(tag) >= target:
            continue
        if is_ancestor(tag, revision, cwd):
            return tag
    return None


def commits(previous, revision, cwd=ROOT):
    """`(sha, subject, body)` for every non-merge commit in the range, newest first."""
    span = f"{previous}..{revision}" if previous else revision
    raw = git("log", "--no-merges", f"--format=%h{FIELD}%s{FIELD}%b{RECORD}", span, cwd=cwd)
    for record in raw.split(RECORD):
        record = record.strip("\n")
        if not record:
            continue
        sha, subject, body = record.split(FIELD, 2)
        yield sha, subject, body


def sentence(text):
    """A bullet reads as a sentence: no trailing period, leading capital, one line long.

    A commit message that ran to a paragraph would otherwise widen the whole section;
    the linked commit still carries every word.
    """
    text = " ".join(text.split()).rstrip(".").strip()
    if len(text) > SUBJECT_LIMIT:
        head = text[:SUBJECT_LIMIT].rsplit(" ", 1)[0].rstrip(",;:—-")
        text = f"{head}…"
    return text[:1].upper() + text[1:] if text else text


def classify(sha, subject, body=""):
    """The change a commit contributes, or None when it only records the release itself."""
    if BUMP_COMMIT.match(subject.strip()):
        return None
    match = CONVENTIONAL.match(subject.strip())
    if not match:
        return Change("other", "", sentence(subject), sha)
    breaking = bool(match.group("breaking")) or bool(BREAKING_BODY.search(body or ""))
    group = "breaking" if breaking else GROUPS.get(match.group("type"), "other")
    return Change(group, (match.group("scope") or "").strip(), sentence(match.group("subject")), sha)


def changes(previous, revision, cwd=ROOT):
    collected = []
    for sha, subject, body in commits(previous, revision, cwd):
        change = classify(sha, subject, body)
        if change is not None:
            collected.append(change)
    return collected


def group_changes(collected):
    """Section key -> its changes, newest first, with repeated wording collapsed."""
    grouped = {}
    seen = set()
    for change in collected:
        key = (change.group, change.scope, change.subject.lower())
        if key in seen:
            continue
        seen.add(key)
        grouped.setdefault(change.group, []).append(change)
    return grouped


def bullet(change, repo=None):
    scope = f"**{change.scope}** — " if change.scope else ""
    link = f"[`{change.sha}`](https://github.com/{repo}/commit/{change.sha})" if repo else f"`{change.sha}`"
    return f"- {scope}{change.subject} ({link})"


def compare_link(previous, tag, repo):
    if not repo:
        return None
    if previous:
        return f"**Full changelog**: https://github.com/{repo}/compare/{previous}...{tag}"
    return f"**Full changelog**: https://github.com/{repo}/commits/{tag}"


def archive_name(version):
    """The asset name `scripts/package.py` produces and the in-app updater selects."""
    return f"{APPLICATION}-{display_version(version)}-arm64.zip"


def install_footer(version, target=None, built_from=None):
    """The part of the release body that belongs to the web page, not to the app.

    The marker is the contract with the in-app updater: everything after it is
    download instructions the app already knows, so its "What's new" card stops there.

    `built_from` names the revision the archive was built from. The build provenance
    attestation cannot: its SLSA predicate records the revision that triggered the
    workflow run, which for a CI-produced tag is the push that asked for the bump,
    not the bump commit the tag points at. This line is checkable —
    `git rev-parse <tag>^{commit}` must equal it.
    """
    archive = archive_name(version)
    tag = f"v{display_version(version)}"
    requirement = f"Apple silicon (arm64), macOS {target} or later." if target else "Apple silicon (arm64)."
    lines = [
        NOTES_END,
        "",
        "### Install",
        "",
        f"1. Download `{archive}` and unzip it.",
        f"2. Move `{APPLICATION}.app` into `/Applications` or `~/Applications`. In-app updates replace a copy",
        "   in one of those two locations and nowhere else.",
        "3. The build is ad-hoc signed and not notarized, so the first launch needs Control-click -> Open.",
        "",
        "### Verify the download",
        "",
        "```sh",
        f"shasum -a 256 -c {archive}.sha256",
        "```",
        "",
        requirement,
    ]
    if built_from:
        lines += ["", f"Built from `{tag}` at `{built_from}` (`git rev-parse {tag}^{{commit}}` must match)."]
    return "\n".join(lines)


def render(version, collected, previous=None, repo=None, internal_label=True):
    """The notes body for one version: sections, an internal-work count, a compare link."""
    tag = f"v{display_version(version)}"
    grouped = group_changes(collected)
    parts = []
    for key, heading in SECTIONS:
        entries = grouped.get(key)
        if not entries:
            continue
        parts.append(f"### {heading}\n\n" + "\n".join(bullet(change, repo) for change in entries))
    internal = len(grouped.get("internal", ()))
    if not parts:
        span = f"since `{previous}`" if previous else "in this history"
        parts.append(f"No user-visible changes {span}.")
    elif internal and internal_label:
        noun = "commit" if internal == 1 else "commits"
        parts.append(f"Plus {internal} documentation, test and tooling {noun}.")
    link = compare_link(previous, tag, repo)
    if link:
        parts.append(link)
    return "\n\n".join(parts).strip() + "\n"


def tag_date(tag, cwd=ROOT):
    """The commit date of a tag, or today when the tag does not exist yet."""
    try:
        return git("log", "-1", "--format=%cs", tag, cwd=cwd).strip() or date.today().isoformat()
    except NotesError:
        return date.today().isoformat()


def section(version, day, body):
    return f"## {display_version(version)} — {day}\n\n{body.strip()}\n\n"


def split_sections(text):
    """`(preamble, [section, ...])`; each section starts at a `## ` heading."""
    positions = [match.start() for match in re.finditer(r"^## ", text, re.MULTILINE)]
    if not positions:
        return text, []
    bounds = positions + [len(text)]
    return text[: positions[0]], [text[bounds[index] : bounds[index + 1]] for index in range(len(positions))]


def section_version(text):
    match = CHANGELOG_HEADING.match(text)
    return version_key(match.group(1)) if match else None


def insert_section(text, version, entry):
    """`entry` replaces any section for the same version and lands in descending order."""
    preamble, sections = split_sections(text or CHANGELOG_PREAMBLE)
    target = version_key(version)
    kept = [item for item in sections if section_version(item) != target]
    index = next((position for position, item in enumerate(kept) if (section_version(item) or (0, 0, 0)) < target), len(kept))
    kept.insert(index, entry)
    return preamble.rstrip("\n") + "\n\n" + "".join(kept).rstrip("\n") + "\n"


def rebuild_changelog(repo=None, cwd=ROOT):
    """A whole changelog built from every version tag in the repository."""
    tags = version_tags(cwd)
    if not tags:
        raise NotesError("No vx.y.z tags to build a changelog from.")
    body = CHANGELOG_PREAMBLE
    for position in range(len(tags) - 1, -1, -1):
        tag = tags[position]
        earlier = tags[position - 1] if position else None
        notes = render(tag, changes(earlier, tag, cwd), earlier, repo)
        body += section(tag, tag_date(tag, cwd), notes)
    return body.rstrip("\n") + "\n"


def resolve(args):
    """Version, range and repository for this invocation."""
    version = display_version(args.tag or current_version())
    revision = args.to or f"v{version}"
    repo = args.repository or repository()
    if args.previous is not None:
        earlier = args.previous or None
    else:
        earlier = previous_tag(version, revision)
    return version, revision, earlier, repo


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", help="Version being released; defaults to MARKETING_VERSION in project.yml.")
    parser.add_argument("--to", help="Revision the range ends at; defaults to the version's tag.")
    parser.add_argument("--previous", help="Tag the range starts after; empty string means the whole history.")
    parser.add_argument("--repository", help="owner/repo for commit and compare links; defaults to the origin remote.")
    parser.add_argument("--release-body", action="store_true", help="Append the install, checksum and requirement footer.")
    parser.add_argument("--built-from", help="Revision the archive was built from; recorded in the footer.")
    parser.add_argument("--output", help="Write the notes here instead of stdout.")
    parser.add_argument("--changelog", action="store_true", help="Insert this version's section into CHANGELOG.md.")
    parser.add_argument("--rebuild-changelog", action="store_true", help="Regenerate CHANGELOG.md from every version tag.")
    parser.add_argument("--apply", action="store_true", help="Write CHANGELOG.md; without it the planned section is only described.")
    args = parser.parse_args(argv)

    if args.rebuild_changelog:
        body = rebuild_changelog(args.repository or repository())
        if args.apply:
            CHANGELOG.write_text(body, encoding="utf-8")
            print(f"{MARK.ok} Rebuilt {CHANGELOG.relative_to(ROOT)} from {len(version_tags())} tags")
        else:
            print(f"{MARK.step} Would rebuild {CHANGELOG.relative_to(ROOT)} from {len(version_tags())} tags; --apply writes it")
        return 0

    version, revision, earlier, repo = resolve(args)
    notes = render(version, changes(earlier, revision), earlier, repo)
    footer = install_footer(version, deployment_target(), args.built_from)
    body = notes if not args.release_body else notes.rstrip("\n") + "\n\n" + footer + "\n"

    if args.changelog:
        day = tag_date(f"v{version}") if args.to is None else date.today().isoformat()
        existing = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else CHANGELOG_PREAMBLE
        updated = insert_section(existing, version, section(version, day, notes))
        if args.apply:
            CHANGELOG.write_text(updated, encoding="utf-8")
            print(f"{MARK.ok} {CHANGELOG.relative_to(ROOT)}: {version} — {day}")
        else:
            print(f"{MARK.step} Would write {CHANGELOG.relative_to(ROOT)}: {version} — {day}; --apply writes it")

    if args.output:
        destination = Path(args.output)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(body, encoding="utf-8")
        print(f"{MARK.ok} Notes for {version} ({earlier or 'first release'}..{revision}): {destination}")
    elif not args.changelog:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except NotesError as error:
        print(f"{markers().missing} {error}", file=sys.stderr)
        raise SystemExit(1)
