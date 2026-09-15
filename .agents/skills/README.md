# Project skill integration

These skills are vendored from the commits recorded in `sources.json`. Those commits identify the upstream baseline, not byte-for-byte copies: the entry points have local adaptations. Preserve the licenses and these adaptations during updates.

Only this file and `sources.json` are tracked in Git. The skill directories themselves stay local and are ignored, so no third-party skill text ships in this repository. Restore them by checking out each `sourcePath` from the pinned commit in `sources.json`, then reapplying the local adaptations listed below.

## Routing

| Task | Guidance |
| --- | --- |
| Visual design, layout, UX, HTML/CSS polish | `impeccable` |
| SwiftUI/WebKit loading, navigation, JavaScript/native integration | `swiftui-webkit` |
| Work involving both | Each skill covers its own concern; do not duplicate workflows |
| Explicit supplemental WebKit API research | `webkit-integration`, checked against the selected SDK |

`webkit-integration` has `disable-model-invocation: true`, so pi retains `/skill:webkit-integration` but omits it from automatic skill discovery in the model prompt. Its description and entry-point warning also explain the supplemental role for other harnesses. Run `/reload` in existing pi sessions to refresh skill metadata and project context.

## Pi skill discovery

The local, Git-ignored `.pi/settings.json` disables the global `~/.pi/agent/skills/impeccable/SKILL.md` only for this project, leaving the vendored, customized `impeccable` active and the global copy available in other projects:

```json
{
  "skills": [
    "~/.pi/agent/skills/impeccable/SKILL.md",
    "!**/.pi/agent/skills/impeccable/SKILL.md"
  ]
}
```

The plain path registers the inherited resource in project scope; the matching exclusion glob disables it. Both entries are needed because Pi applies discovery exclusions within their own scope. Pi expands `~` in plain resource paths but not in exclusion patterns, so `-~/.pi/agent/skills/impeccable/SKILL.md` does not match and causes the global copy to win the collision. The glob avoids hard-coding a home directory. Preserve other settings when applying this configuration in a fresh checkout. No skill files are deleted or renamed. Run `/reload` after changing this configuration.

## Local adaptations

- **All three entry points:** link to the skill routing and conflict rules in the root `AGENTS.md`.
- **Impeccable:** project authorization takes precedence over mandatory visual workflows, browser question flows, and Release rebuilds. Continue permitted implementation and non-desktop verification; disclose omitted visual checks rather than blocking or taking over the desktop. No design launcher needs to run when merely maintaining these skill files.
- **SwiftUI WebKit:** primary implementation guidance, explicitly including macOS. SDK availability and required bridge features determine whether `WebPage` or a justified `WKWebView` is appropriate.
- **WebKit Integration:** explicit-only supplemental reference; removed upstream `allowed-tools: [Read, Glob, Grep]` metadata, which could be interpreted as an implementation-blocking restriction. This does not override actual harness tool restrictions or a review-only request.
- **API disagreement:** supplemental navigation examples use `decidePolicyFor` with optional preferences/Boolean results. The selected SDK instead declares `WebPage.NavigationDeciding.decidePolicy(for:preferences:)` returning `WKNavigationActionPolicy`, and a response overload returning `WKNavigationResponsePolicy`. The supplemental entry point flags this; its upstream reference files are retained, not certified as compiling examples. The SDK remains authoritative over either skill.

## Update checks

1. Record the new upstream commits in `sources.json` and preserve/reapply the local adaptations above.
2. Check that skill names remain unique, descriptions are valid, and only `webkit-integration` is explicit-only.
3. Confirm entry-point links resolve to the root `AGENTS.md` and no read-only tool metadata has been reintroduced.
4. Check API disagreements against the selected SDK, not upstream verification dates.
5. Reload pi and confirm automatic routing exposes `impeccable` and `swiftui-webkit`, with `webkit-integration` still available by explicit command.

Skill/documentation maintenance does not require an app build, desktop automation, or wallpaper changes.
