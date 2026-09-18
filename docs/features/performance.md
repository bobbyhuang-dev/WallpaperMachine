# Performance

**Settings -> Performance** exposes the playback and quality controls that
previously existed only as environment variables. Every control is applied
through the bridge and the page re-renders from the snapshot the engine returns,
so the page never shows a setting the engine did not accept.

## Video backend

| Setting | Values | Default |
| --- | --- | --- |
| Video playback | **Compatibility**, **Native video preferred (falls back automatically)** | Compatibility |

Native is a preference, not a guarantee: the engine selects a backend per
running wallpaper and keeps anything that does not qualify on Compatibility.
**In use now** lists the backend each running video wallpaper actually got, and
names the fallback reason when the user asked for native and did not get it. It
reads `No video wallpaper is running.` when nothing is playing video.

An unrecognised backend name is refused rather than silently mapped to
Compatibility, so a stale page cannot report a choice that was never applied.

## Render quality

| Setting | Values | Default |
| --- | --- | --- |
| Internal render scale | **100% (native)**, **75%**, **50%** | 100% |

This is the internal rasterization size only. Output size, placement and
composition are unchanged; a lower scale rasterizes fewer pixels and draws the
result into the same area, so detail softens as the scale drops. It is a quality
tier and is not part of any same-quality backend comparison.

When no running wallpaper can honour a render scale the control is disabled and
reads `Not applicable to the wallpapers currently running`. Values arriving from
a stale page are clamped to `0.25...1.0`.

The engine clamps a render scale to `0.25...1.0` but does not quantize it to
these tiers, so a hand-edited `config.toml` can hold a value between them. The
control then carries that value as an extra leading option labelled
`60% (from configuration)` and keeps it selected, rather than displaying a
neighbouring tier the user never chose. Picking a tier replaces it.

## Battery profile

Off unless the user turns it on. While enabled and on battery power, the profile
render scale and frame rate replace the saved quality. This is a quality tradeoff
the user chooses. No power saving is measured or promised.

Whenever the effective `renderScale` differs from the saved
`preferredRenderScale`, the render-quality group shows an **Effective now** row
with the scale the engine published. It names the battery profile as the cause
only while that profile is actually in force; otherwise it reports the
divergence without attributing a cause. Turning the profile off restores the
saved scale on that same snapshot, so the row disappears with it.

| Setting | Values | Default |
| --- | --- | --- |
| Use a reduced quality profile on battery | Off / On | Off |
| Render scale on battery | **100%**, **75%**, **50%** | 75% |
| Frame rate on battery | 1-240 fps | 30 fps |

The scale and frame-rate controls are shown only while the profile is enabled.
The engine owns the profile as one value, so changing one control resends the
other two exactly as the engine currently reports them.

## Advanced

Both switches are experimental and off by default.

| Setting | Notes |
| --- | --- |
| Content pacing | Drives presentation from the content's own frame cadence instead of the display refresh |
| Shared video decode | Lets equivalent display surfaces showing the same video share one decode session |

When shared decode is actually merging work, **Shared decode in use** reports the
live session and surface counts the engine publishes. Sharing is reported only
where it genuinely happens: surfaces still submit and present separately.

## Verification

See [Testing](../testing/README.md) and
`Tests/Unit/Panel/WebPanelPerformanceSettingsTests.swift`, which covers the
clamping, the refusal of an unknown backend name and the snapshot keys the page
reads.
