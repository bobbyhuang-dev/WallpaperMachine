# Taste

## Communication
- User communicates in Simplified Chinese; reply in Chinese by default. Confidence: 0.75

## Engineering & debugging workflow
- For bug fixes (e.g., wallpaper rendering), require a general, root-cause solution — explicitly reject one-off fixes hard-coded to a single asset/wallpaper. Confidence: 0.9
- Don't assume the currently active/selected resource is the broken one; verify and identify the actual affected file (e.g., match by name/title) before fixing. Confidence: 0.8
- User is impatient with long, multi-step debugging sessions ("太慢了") — keep investigations tight and decisive, surface interim findings early, and don't spiral into repeated exploratory probes. Confidence: 0.7
- On revert/cleanup requests: remove every file the agent itself generated (keep diagnostics in git-ignored scratch dirs like `artifacts/` so removal is trivial), but never touch pre-existing working-tree changes the agent didn't author — verify ownership via `git status` before deleting anything. Confidence: 0.9
