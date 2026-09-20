#!/usr/bin/env python3
"""Prepend an entry to docs/testing/verification-log.md and archive what falls off.

The log keeps its ten newest entries, newest first; older ones move verbatim into
`docs/testing/archive/verification-log-<YYYY>-<MM>.md` with relative links adjusted
for the extra directory level. Doing that by hand means reading the whole log to
insert one entry; this script does it without anyone reading anything.

    python3 scripts/log_verification.py --title "Quiet test output" \\
        --context "Optional one-paragraph context." \\
        --line "\\`python3 scripts/test.py\\` — exit 0; 500 tests: 491 passed, 9 skipped" \\
        --line "\\`python3 scripts/check_renderer.py\\` — skipped: no corpus"

`--body` (or `--body-file`, `-` for stdin) supplies the whole entry body as Markdown
instead of `--context`/`--line`. `--dry-run` prints the entry and what would be
archived without touching any file. See docs/testing/README.md.
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path
import re
import sys

from lib.glyphs import markers
from lib.paths import ROOT

MARK = markers()
LOG = ROOT / "docs/testing/verification-log.md"
ARCHIVE_DIR = ROOT / "docs/testing/archive"
KEEP = 10

ENTRY = re.compile(r"^## ", re.MULTILINE)
HEADING_DATE = re.compile(r"^## (\d{4})-(\d{2})-\d{2}")
# `](target)` where target is relative: not a scheme, not an anchor, not absolute.
RELATIVE_LINK = re.compile(r"\]\((?![a-z][a-z0-9+.-]*:|#|/)([^)\s]+)\)")

ARCHIVE_PREAMBLE = """\
# Verification log archive — {month} and earlier

Retired entries from [../verification-log.md](../verification-log.md), moved
here when that log was capped at its ten newest entries. No recorded result was
rewritten: each entry is reproduced verbatim, and the only edit is that
relative Markdown links gained one `../` for this file's extra directory
level.

These are historical results about the trees they were taken on. They are not
evidence about the current tree and must never be cited as such.

"""


def split_entries(text):
    """`(preamble, [entry, ...])` for a log; each entry starts with `## ` and ends with a newline."""
    matches = list(ENTRY.finditer(text))
    if not matches:
        return text, []
    preamble = text[: matches[0].start()]
    entries = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        entries.append(text[match.start():end])
    return preamble, entries


def normalise(entry):
    """Exactly one blank line after an entry, so joins stay tidy."""
    return entry.rstrip("\n") + "\n\n"


def format_entry(title, day, context=None, lines=(), body=None):
    heading = f"## {day.isoformat()} — {title.strip()}\n\n"
    if body is not None:
        return normalise(heading + body.strip("\n"))
    parts = []
    if context:
        parts.append(" ".join(context.split()) + "\n")
    if lines:
        parts.append("".join(f"- {line.strip()}\n" for line in lines if line.strip()))
    if not parts:
        raise ValueError("an entry needs --context, --line or --body")
    return normalise(heading + "\n".join(parts))


def relink_for_archive(entry):
    """Relative links gain one `../` because the archive sits one directory deeper."""
    return RELATIVE_LINK.sub(lambda match: f"](../{match.group(1)})", entry)


def archive_name(entries):
    """`verification-log-YYYY-MM.md` after the newest entry being retired."""
    for entry in entries:
        match = HEADING_DATE.match(entry)
        if match:
            return f"verification-log-{match.group(1)}-{match.group(2)}.md"
    return f"verification-log-{date.today():%Y-%m}.md"


def add_entry(entry, log=LOG, archive_dir=ARCHIVE_DIR, keep=KEEP, write=True):
    """Prepend `entry`, trim to `keep`, archive the rest.

    Returns `(archive_path, retired_entries, archive_is_new)`.
    """
    preamble, entries = split_entries(log.read_text(encoding="utf-8"))
    entries = [normalise(existing) for existing in entries]
    kept, retired = ([entry] + entries)[:keep], ([entry] + entries)[keep:]
    archive, created = None, False
    if retired:
        archive = archive_dir / archive_name(retired)
        created = not archive.exists()
        if write:
            archive_dir.mkdir(parents=True, exist_ok=True)
            moved = "".join(relink_for_archive(item) for item in retired)
            if archive.exists():
                head, old = split_entries(archive.read_text(encoding="utf-8"))
                archive.write_text(head + moved + "".join(normalise(item) for item in old), encoding="utf-8")
            else:
                month = HEADING_DATE.match(retired[0])
                label = f"{month.group(1)}-{month.group(2)}" if month else f"{date.today():%Y-%m}"
                archive.write_text(ARCHIVE_PREAMBLE.format(month=label) + moved, encoding="utf-8")
    if write:
        log.write_text(preamble + "".join(kept).rstrip("\n") + "\n", encoding="utf-8")
    return archive, retired, created


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--title", required=True, help="Heading text after the date.")
    parser.add_argument("--date", type=date.fromisoformat, default=date.today(), help="YYYY-MM-DD; default today.")
    parser.add_argument("--context", help="One short paragraph of context, only when the result needs it.")
    parser.add_argument("--line", action="append", default=[], metavar="TEXT", help="One bullet: command, exit status, counts, skips (repeatable).")
    parser.add_argument("--body", help="Whole entry body as Markdown instead of --context/--line.")
    parser.add_argument("--body-file", help="Read --body from this file, or '-' for stdin.")
    parser.add_argument("--keep", type=int, default=KEEP, help=f"Entries kept in the log (default {KEEP}).")
    parser.add_argument("--dry-run", action="store_true", help="Print the entry and what would be archived; write nothing.")
    args = parser.parse_args(argv)
    body = args.body
    if args.body_file:
        body = sys.stdin.read() if args.body_file == "-" else Path(args.body_file).read_text(encoding="utf-8")
    try:
        entry = format_entry(args.title, args.date, args.context, args.line, body)
    except ValueError as error:
        parser.error(str(error))
    archive, retired, created = add_entry(entry, keep=args.keep, write=not args.dry_run)
    if args.dry_run:
        print(entry, end="")
    action = "Would add" if args.dry_run else "Added"
    print(f"{MARK.ok} {action} entry to {LOG.relative_to(ROOT)}")
    if retired:
        titles = ", ".join(item.splitlines()[0][3:] for item in retired)
        print(f"{MARK.step} {'Would move' if args.dry_run else 'Moved'} {len(retired)} older entr{'y' if len(retired) == 1 else 'ies'} to {archive.relative_to(ROOT)}: {titles}")
        if created:
            print(f"{MARK.warn} New archive file: add it to docs/README.md and promote anything durable before committing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
