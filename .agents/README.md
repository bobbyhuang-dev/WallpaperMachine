# Agent tooling

Everything an automated contributor needs that is not a project rule. The rules
themselves live in [`../AGENTS.md`](../AGENTS.md); human contributors start at
[`../CONTRIBUTING.md`](../CONTRIBUTING.md).

| Path | Tracked | Purpose |
| --- | --- | --- |
| `../AGENTS.md` | yes | Authoritative rules: skill routing, verification limits, build delivery |
| `.agents/README.md` | yes | This file: how the agent tooling is wired |
| `.agents/skills/sources.json` | yes | Upstream commit pinned for each vendored skill |
| `.agents/skills/<name>/` | no | Vendored third-party skill text, restored locally |
| `.pi/settings.json` | no | Local harness settings (skill discovery overrides) |
| `.omp/` | no | Local harness scratch state |

`AGENTS.md` stays at the repository root: the vendored skill entry points link to
it as `../../../AGENTS.md`, and that is where agent harnesses look for it. Moving
it breaks both.

## Skills

Skills are task guidance, not authorization. Project rules in `../AGENTS.md`
outrank any skill workflow.

| Task | Skill |
| --- | --- |
| Visual design, layout, UX, HTML/CSS polish in `WebUI/` | `impeccable` |
| SwiftUI/WebKit loading, navigation, JavaScript bridging | `swiftui-webkit` |
| Explicit supplemental WebKit API research | `webkit-integration` |
| Work spanning design and WebKit | Each skill covers its own concern; do not run two end-to-end workflows |

`webkit-integration` sets `disable-model-invocation: true`, so it stays available
by explicit command but is left out of automatic skill discovery. Some harnesses
also ship their own WebKit skills; those are external to this repository and the
project rules still take precedence over all of them.

## Vendored copies

Only `sources.json` and this file are tracked. The skill directories are
Git-ignored so no third-party skill text ships in this repository. To restore a
working checkout, for each entry in `sources.json` check out `sourcePath` from
the pinned `commit` into `.agents/skills/<name>/`, then reapply the local
adaptations below. Preserve the upstream `LICENSE` and `NOTICE` files.

Local adaptations, which must survive every upstream update:

- **All entry points** link to the skill routing and conflict rules in
  `../AGENTS.md`.
- **impeccable** — project authorization outranks its mandatory visual
  workflows, browser question flows and Release rebuilds. Continue permitted
  implementation and non-desktop verification, and disclose omitted visual
  checks instead of blocking or taking over the desktop. Ask questions in chat
  rather than opening a browser-based question UI.
- **swiftui-webkit** — primary WebKit implementation guidance, explicitly
  including macOS. The selected SDK decides whether `WebPage` or a justified
  `WKWebView` is correct; do not migrate to satisfy a skill preference.
- **webkit-integration** — explicit-only supplemental reference. The upstream
  `allowed-tools: [Read, Glob, Grep]` metadata was removed because it reads as
  an implementation-blocking restriction; this does not override real harness
  restrictions or a review-only request.
- **API disagreement** — supplemental navigation examples use `decidePolicyFor`
  with optional preferences or Boolean results. The selected SDK declares
  `WebPage.NavigationDeciding.decidePolicy(for:preferences:)` returning
  `WKNavigationActionPolicy`, with a response overload returning
  `WKNavigationResponsePolicy`. The SDK is authoritative; upstream verification
  dates prove nothing about compatibility.

## Harness settings

`.pi/settings.json` is local and Git-ignored. It disables the globally installed
`impeccable` skill for this project only, so the vendored and adapted copy wins
the name collision while the global copy keeps working elsewhere:

```json
{
  "skills": [
    "~/.pi/agent/skills/impeccable/SKILL.md",
    "!**/.pi/agent/skills/impeccable/SKILL.md"
  ]
}
```

Both entries are required: the plain path registers the inherited resource in
project scope and the glob disables it, because discovery exclusions apply
within their own scope. `~` expands in plain resource paths but not in exclusion
patterns, so a `-~/...` form silently fails to match and the global copy wins.
The glob avoids hard-coding a home directory. Preserve unrelated settings, and
reload the harness after changing this file.

## Updating a skill

1. Record the new upstream commit in `sources.json` and reapply every local
   adaptation above.
2. Check that skill names stay unique, descriptions stay valid, and
   `webkit-integration` remains the only explicit-only skill.
3. Confirm each entry point still links to `../AGENTS.md` and that no read-only
   tool metadata came back.
4. Re-check API disagreements against the selected SDK, not upstream dates.
5. Reload the harness and confirm automatic routing exposes `impeccable` and
   `swiftui-webkit` only.

Skill and documentation maintenance needs no app build, desktop automation or
wallpaper change.
