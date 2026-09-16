# Versioning and releases

Version numbers, the CI pipeline that publishes a build, and how the in-app
updater consumes it. Build mechanics live in [build.md](build.md).

## Source of truth

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
[`project.yml`](../project.yml) are the version of both the app and the
lock-screen extension; the two targets carry identical values.
`scripts/bump_version.py` also rewrites the same two keys in the committed
`mac-wallpaper-engine.xcodeproj/project.pbxproj`, so the generated project stays
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

## Workflows

Three workflows in `.github/workflows/`, all requiring `contents: write`.

### Version (`version.yml`)

Runs on every push to `main`, and on demand from **Actions -> Version -> Run
workflow** with a `spec` input. On an `ubuntu-latest` runner it:

1. checks out with full history;
2. runs `python3 scripts/bump_version.py --ci --apply`;
3. if anything changed, refuses to continue when the target tag already exists on
   `origin`, then commits `project.yml` and
   `mac-wallpaper-engine.xcodeproj/project.pbxproj` as
   `chore: bump version to x.y.z`, tags `vx.y.z`, and pushes branch and tag
   atomically as `github-actions[bot]`;
4. calls the Build workflow directly for the tag it just pushed.

Step 4 is not redundant. **A tag pushed with `GITHUB_TOKEN` never starts another
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
Release for hand-pushed ones. On a `macos-26` runner (120-minute timeout) it:

1. checks out the tag;
2. `brew install --quiet` the XcodeGen/CMake/renderer package set;
3. restores an `actions/cache` entry for `~/.cargo/registry`, `~/.cargo/git` and
   `upstream/renderer/target`, keyed `renderer-${{ hashFiles('upstream/renderer/Cargo.lock') }}`
   with the `renderer-` prefix as a restore key, so an unchanged lock file reuses
   the previous renderer build;
4. runs `python3 scripts/build.py --configuration Release` and
   `python3 scripts/package.py --configuration Release`;
5. checks that `build/Build/Products/Release/MacWallpaperEngine-<tag without
   v>-arm64.zip` exists, creates the GitHub Release if needed
   (`gh release create "$TAG" --generate-notes --verify-tag`), and uploads the
   archive with `--clobber`.

Step 5's filename check is the guard that the bump actually reached the build:
`scripts/package.py` names the archive from the bundle's
`CFBundleShortVersionString`, so a mismatch means the published tag and the
built version disagree and the job fails instead of publishing the wrong binary.

### Release (`release.yml`)

Triggered by pushing a `v*.*.*` tag by hand. It only calls Build with
`github.ref_name`, sharing the `publish-<tag>` concurrency group with Version's
publish job so one tag is never built twice at once.

## What the in-app updater expects

**Settings -> About** is the in-app update surface. It checks the repository's
latest GitHub Release and, after confirmation, downloads the asset and
restart-installs it. **Check for Updates…** in the application menu opens that
section and starts the same check. The contract it relies on:

- the release is not a prerelease, and its tag parses as `vx.y.z` (no
  prerelease suffixes, no `nightly`);
- exactly the asset named `MacWallpaperEngine-<x.y.z>-arm64.zip` — the name
  `scripts/package.py` produces — is selected;
- downloads are restricted to `github.com` and
  `objects.githubusercontent.com` over HTTPS, and a `sha256:` asset digest, when
  GitHub supplies one, is verified;
- the installed copy must live in `/Applications` or `~/Applications`.

With no matching asset the app falls back to opening GitHub Releases for a manual
update. Renaming the archive, publishing a prerelease, or attaching a `.dmg`
instead silently breaks automatic updates; `Tests/Unit/GitHub/AppUpdateTests.swift`
pins this behavior.

## Checklist for a release

1. Land the change on `main` with a `release:` spec line, or run the Version
   workflow with a spec.
2. Confirm the Version run committed `chore: bump version to x.y.z` and pushed
   `vx.y.z`.
3. Confirm the called Build run uploaded `MacWallpaperEngine-x.y.z-arm64.zip`.
4. Run the manual smoke pass in
   [testing/manual-smoke.md](testing/manual-smoke.md) against the packaged build
   and record it in [testing/verification-log.md](testing/verification-log.md).

Distribution of built binaries is still subject to the unresolved questions in
[../LICENSING.md](../LICENSING.md).
