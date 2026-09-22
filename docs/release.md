# Versioning and releases

Version numbers, the pipeline that publishes a build, the notes it writes, and how
the in-app updater consumes it. Build mechanics live in [build.md](build.md).

## Source of truth

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
[`project.yml`](../project.yml) are the version of both the app and the
lock-screen extension; the two targets carry identical values.
`scripts/bump_version.py` also rewrites the same two keys in the committed
`WallpaperMachine.xcodeproj/project.pbxproj`, so the generated project stays
in sync without anyone running `xcodegen`. Change the version through the script
or the Version workflow, never by editing one of the two files alone.

`MARKETING_VERSION` is a strict `x.y.z` semantic version.
`CURRENT_PROJECT_VERSION` is an integer build number, incremented by one on every
bump.

## Release specs in commit messages

Push to `main` with a line of exactly this form — as the subject, a body line, or
a squash-merge title — to trigger a bump:

| Spec | Effect on `0.1.0` |
|---|---|
| `release: patch` | `0.1.1` |
| `release: minor` | `0.2.0` |
| `release: major` | `1.0.0` |
| `release: 1.2.3` or `release: v1.2.3` | sets `1.2.3` exactly |

Matching is case-insensitive and anchored to a whole line. An explicit `x.y.z`
must not move the version backwards.

If a single push contains several `release:` lines, an explicit `x.y.z` wins;
otherwise the highest of `major` > `minor` > `patch` is used. A push with no
`release:` line prints `No release: spec in commit message; skipping.` and does
nothing.

Bump the same way locally:

```sh
python3 scripts/bump_version.py --spec patch            # dry run, prints old -> new
python3 scripts/bump_version.py --spec patch --apply    # writes both files
```

`--message` / `--message-file` scan a commit message instead of taking a spec
directly; `--ci` reads `RELEASE_SPEC` or the GitHub event payload. With `--apply`
omitted nothing is written, which makes it safe to inspect a planned bump.
`scripts/bump_version.py` is covered by `scripts/tests/test_bump_version.py`,
which runs as part of `python3 scripts/test.py`.

## Release notes and the changelog

[`scripts/release_notes.py`](../scripts/release_notes.py) writes the release body
and the [`CHANGELOG.md`](../CHANGELOG.md) section from the commits between two
version tags, so the release page, the changelog and the in-app **What's new**
card cannot disagree. `gh release --generate-notes` is not used: with no pull
requests in the history it produces a bare compare link, which is all the thirteen
releases through `v0.5.0` ever said before they were deleted.

Commits are read through the `type(scope): subject` convention in
[conventions.md](conventions.md):

| Commit type | Section |
|---|---|
| `feat` | **New** |
| `fix` | **Fixed** |
| `perf` | **Performance** |
| `!` suffix or a `BREAKING CHANGE:` trailer | **Breaking changes** |
| `docs`, `test`, `chore`, `ci`, `build`, `style` | counted in one closing line |
| anything else, including non-conventional subjects | **Other changes** |

Nothing is dropped silently: a subject the convention does not recognise is
listed rather than hidden, and the only commit removed outright is CI's own
`chore: bump version to x.y.z`. A subject longer than 140 characters is cut at a
word boundary; the linked commit still carries every word.

```sh
python3 scripts/release_notes.py                          # notes for project.yml's version
python3 scripts/release_notes.py --tag v0.6.0 --to HEAD   # before the tag exists
python3 scripts/release_notes.py --tag v0.6.0 --release-body --output notes.md
python3 scripts/release_notes.py --changelog --apply      # insert one section
python3 scripts/release_notes.py --rebuild-changelog --apply
```

`--previous` overrides the tag the range starts after; by default it is the
newest released version below the target that the range's end descends from, so a
gap in the numbering resolves correctly. `--release-body` appends the install,
checksum and requirement footer that belongs to the release page, separated from
the notes by `<!-- release-notes-end -->`. That marker is a contract: the app
shows everything above it and nothing below.

Inserting a section is idempotent — rerunning replaces the section for that
version instead of duplicating it — and `CHANGELOG.md` is only written with
`--apply`. `scripts/tests/test_release_notes.py` covers classification,
rendering, changelog ordering and range resolution against a real throwaway
repository.

## Workflows

Three workflows in `.github/workflows/`. All grant `contents: write`; Build also
needs `id-token: write` and `attestations: write` for its provenance attestation,
and both callers pass those through.

### Version (`version.yml`)

Runs on every push to `main`, and on demand from **Actions -> Version -> Run
workflow** with a `spec` input. On an `ubuntu-latest` runner it:

1. checks out with full history;
2. runs `python3 scripts/bump_version.py --ci --apply`;
3. writes the new version's section into `CHANGELOG.md` with
   `scripts/release_notes.py --to HEAD` — the tag does not exist yet, so the
   range ends at `HEAD`;
4. if anything changed, refuses to continue when the target tag already exists on
   `origin`, then commits `project.yml`,
   `WallpaperMachine.xcodeproj/project.pbxproj` and `CHANGELOG.md` as
   `chore: bump version to x.y.z`, tags `vx.y.z`, and pushes branch and tag
   atomically as `github-actions[bot]`;
5. calls the Build workflow directly for the tag it just pushed.

Step 5 is not redundant. **A tag pushed with `GITHUB_TOKEN` never starts another
workflow**, so the tag-triggered Release workflow would never fire for a
CI-produced tag; without the direct call, a bumped version would be tagged but
never published.

The bump job holds a `version-<ref>` concurrency group only while the bump commit
is produced. A workflow-wide group would keep the lock through the macOS build,
and because GitHub retains only the newest pending run, a queued `release:` push
could be replaced by a later ordinary push and silently lost.

The workflow needs permission to push to `main`: `contents: write`, and branch
protection must allow GitHub Actions.

### Build (`build.yml`)

`workflow_call` only, with a required `tag` input. It is the single place a
publishable artifact is produced, called by Version for CI-produced tags and by
Release for hand-pushed ones.

**Its first step currently fails unconditionally** with an `::error::` citing
[../LICENSING.md](../LICENSING.md): distribution of any binary is blocked by the
Apache-2.0 components in the link closure, and no input or secret bypasses the
step. The steps below are kept so the pipeline is ready once that step is
deleted, which happens only after LICENSING.md records the blockers as
resolved. Until then a `release:` push bumps the version, writes the changelog
section and tags it, and the Build run fails before checkout. On a `macos-26`
runner (150-minute timeout) the remaining steps:

1. checks out the tag with full history, which the notes need;
2. `brew install --quiet` the XcodeGen/CMake/renderer package set and
   `python3 scripts/install_ffmpeg.py` for the project's LGPL FFmpeg build;
3. restores an `actions/cache` entry for `~/.cargo/registry`, `~/.cargo/git` and
   `upstream/renderer/target`, keyed `renderer-${{ hashFiles('upstream/renderer/Cargo.lock') }}`
   with the `renderer-` prefix as a restore key, so an unchanged lock file reuses
   the previous renderer build;
4. runs `python3 scripts/build.py --configuration Release`, then
   `python3 scripts/test.py`, then `python3 scripts/package.py --configuration Release`.
   The test gate runs against the renderer and generated bridge the build step
   already produced, so it adds the test target rather than a second renderer
   build; a published binary has passed the same gate a change has to pass;
5. verifies the archive: the file must be named
   `WallpaperMachine-<tag without v>-arm64.zip`, it is unpacked with `ditto`, the
   unpacked bundle's `CFBundleShortVersionString` must equal the tag, and
   `codesign --verify --deep --strict` must pass. A `.sha256` sidecar is written
   beside it and echoed into the job summary;
6. writes the release body with `scripts/release_notes.py --release-body
   --built-from "$(git rev-parse HEAD)"`;
7. attests build provenance for the archive with
   `actions/attest-build-provenance`;
8. publishes with `scripts/publish_release.py`.

Step 5's name check is the guard that the bump actually reached the build:
`scripts/package.py` names the archive from the bundle's
`CFBundleShortVersionString`, so a mismatch means the published tag and the
built version disagree and the job fails instead of publishing the wrong binary.

**What the attestation does and does not say.** Its SLSA predicate is built from
the run's OIDC claims: `resolvedDependencies[0]` is `git+<repo>@<claims.ref>` with
`digest.gitCommit = claims.sha`
([`actions/toolkit`](https://github.com/actions/toolkit/blob/main/packages/attest/src/provenance.ts)).
For a Version-produced tag those claims describe the push to `main` that carried
the `release:` line — the revision *before* the bump commit the tag points at,
because Build runs as a `workflow_call` inside that same run. So the attestation
binds the archive's digest to this repository, this workflow, this builder and
this run; it does **not** identify the revision the archive was built from. That
revision is recorded separately in the release body as
``Built from `vx.y.z` at `<sha>` ``, and anyone can check it with
`git rev-parse vx.y.z^{commit}`. A hand-pushed tag going through Release does not
have the discrepancy, because there the triggering ref is the tag itself.

**How `scripts/publish_release.py` publishes.** It is a separate script rather
than inline shell because its two rules are the ones a release pipeline gets
wrong, and `scripts/tests/test_publish_release.py` exercises both, including a
failed upload and reversed completion order:

- **Drafts first, live releases refused.** No release for the tag: create a draft,
  upload, then clear the draft flag. A draft already there (an earlier attempt
  that died): finish it. A release already *published*: refuse and fail the job.
  `gh release upload --clobber` deletes an existing asset before writing its
  replacement, so re-running against a live release would take the download away
  and only restore it if the upload succeeded — reopening the exact window the
  draft-first order closes. A failure anywhere before the last command leaves a
  draft, which the GitHub API's `releases/latest` does not return.
- **Latest cannot go backwards.** Both callers hold a `publish-<tag>` concurrency
  group, which locks per tag, not per repository, so `v0.6.0` and `v0.7.0` can
  build at the same time and finish in whatever order their caches allow. The
  script therefore passes `--latest` only when no greater public, non-prerelease
  version exists, and `--latest=false` otherwise; an older build finishing last
  cannot take Latest and start offering users the wrong version. The residue is
  the interval between reading the published versions and writing the flag — two
  consecutive API calls, rather than a whole macOS build.

### Release (`release.yml`)

Triggered by pushing a `v*.*.*` tag by hand. It only calls Build with
`github.ref_name`, sharing the `publish-<tag>` concurrency group with Version's
publish job so one tag is never built twice at once.

## What the in-app updater expects

**Settings -> About** is the in-app update surface. It checks the repository's
latest GitHub Release and, after confirmation, downloads the asset and
restart-installs it. **Check for Updates…** in the application menu opens that
section and starts the same check. The contract it relies on:

- the release is not a draft or prerelease, and its tag parses as `vx.y.z` (no
  prerelease suffixes, no `nightly`);
- the asset named exactly `WallpaperMachine-<x.y.z>-arm64.zip` — what
  `AppUpdateConfiguration.assetName(for:)` returns and what `scripts/package.py`
  produces — is preferred, with any other arm64 zip, zip, then disk image as
  fallbacks. The `.sha256` sidecar is neither, so it is never downloaded;
- downloads are restricted to `github.com` and
  `objects.githubusercontent.com` over HTTPS, and a `sha256:` asset digest, when
  GitHub supplies one, is verified;
- the installed copy must live in `/Applications` or `~/Applications`;
- the release body is shown as **What's new** in the About card. Headings become
  section titles, bullets become lines, Markdown emphasis, code fences and commit
  links are reduced to their text, the compare link is dropped, and everything
  from `<!-- release-notes-end -->` onwards is ignored. A body with nothing to
  say produces no card rather than an empty one.

With no matching asset the app falls back to opening GitHub Releases for a manual
update. Renaming the archive, publishing a prerelease, or attaching a `.dmg`
instead silently breaks automatic updates; `Tests/Unit/GitHub/AppUpdateTests.swift`
pins this behavior, including the exact published archive name.

## Checklist for a release

1. Land the change on `main` with a `release:` spec line, or run the Version
   workflow with a spec.
2. Confirm the Version run committed `chore: bump version to x.y.z` with the new
   `CHANGELOG.md` section and pushed `vx.y.z`.
3. Confirm the called Build run passed the test gate, verified the unpacked
   bundle, and published `WallpaperMachine-x.y.z-arm64.zip` with its `.sha256`
   sidecar and a provenance attestation.
4. Read the release body on the page: it should be the generated sections, not a
   bare compare link, and the `Built from` line must match
   `git rev-parse vx.y.z^{commit}`.
5. Confirm Latest points at the highest published version. Re-running Build for a
   tag that is already published fails by design; if a published release is
   genuinely wrong, delete it deliberately rather than re-running.
6. Run the manual smoke pass in
   [testing/manual-smoke.md](testing/manual-smoke.md) against the packaged build
   and record it in [testing/verification-log.md](testing/verification-log.md).

Distribution of built binaries is blocked by the unresolved questions in
[../LICENSING.md](../LICENSING.md), which also records the intended sales
model (a paid official Developer ID signed and notarized build plus priority
support, under the GPL with corresponding source alongside). Neither Developer
ID signing nor notarization exists in this pipeline yet; `scripts/package.py`
signs ad hoc, a provenance attestation records who built an artifact rather than
who vouches for it, and neither is license clearance.
