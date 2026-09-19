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

## Scene wallpapers

| Setting | Values | Default |
| --- | --- | --- |
| Scene render optimisation | Off / On | **On** |
| Update only when the scene changes | Off / On | Off |
| Scene renderer | Compatibility / Native Metal preferred | Compatibility |

The only control here that ships on. It reuses the result of scene subgraphs
whose inputs have not changed and removes render passes proven redundant, inside
the scene renderer's own render graph. It is not a quality tier: the same pixels
are produced, and resolution, frame rate and animation speed are untouched. It
reaches legacy scene wallpapers only — video, native video and web wallpapers do
not go through that graph.

It is two clicks from the window (**Settings -> Performance**) so the setting can
be turned off and on for an A/B comparison without an environment variable.

Unlike content pacing and shared video decode, which are read back from the
renderer, this row reports the saved preference: the renderer publishes no query
for it. The engine applies a change to running scenes in place, so nothing
restarts and no wallpaper reloads.

### Update only when the scene changes

Off by default, because stopping a wallpaper's clock changes what the user sees
happen. When a scene can be shown to have nothing that advances on its own, its
frame clock stops entirely instead of ticking at the configured rate: the last
frame stays on screen and events restart it.

This is not a frame-rate setting and it lowers no quality. It is also not the
same question as scene render optimisation. That one asks whether a render
target's pixels can be reused; this one asks whether the whole runtime can
sleep. A scene whose image happens to be still may still be running scripts,
sound and timelines, so both analyses must agree before anything stops.

A scene keeps its clock if any of these is present: a script or scripted
property, an animation, a particle emitter, a playing video texture, an
audio-reactive shader, a time uniform, an animated sprite, a dynamic mesh, a
puppet, a feedback pass, a bound text layer, a sound layer, a node transform or
material constant bound to a dynamic value, or any input the renderer could not
account for. That last one is reported as **an input the renderer could not
account for**, and it is the answer when a wallpaper does not go idle.

Pointer-reactive scenes do sleep, and pointer movement wakes them. Property
changes, resizes, display reconfiguration, resource updates and visibility
changes all wake the scene; a wallpaper the user paused is never woken by any
of them.

The status line reports what each running scene is doing right now — updating
continuously and why, waiting for events, paused by you, suspended by the
system, or that the state could not be read. A scene that is running but cannot
be read says so; it is never shown as updating normally.

### Scene renderer

Which renderer scene wallpapers prefer. **Compatibility** is the existing
Vulkan-through-MoltenVK path and the default. **Native Metal preferred** asks
for the native Metal backend, which covers a subset of scene features; a scene
it cannot draw runs on the compatibility backend and the status line says why.

Native Metal draws image layers, ordinary effect chains and scene
post-processing, layers that read an image another layer produced earlier in
the same frame, and BGRA or 8-bit NV12 video textures. Particles, puppets,
perspective 3D, dynamic lighting, sprite sheets, history-feedback effects,
HDR or 10-bit video, plain video wallpapers and shaders that do not translate
fall back as a whole scene; an effect is never dropped to keep a scene native.
Effect and video output has not yet been compared against real wallpapers.

No GPU backend is created until the scene has been parsed and a backend chosen,
so the row reports one of three states per scene: **preparing** (no backend
yet), the backend actually in use, or Compatibility with the reason native was
not used. It never shows the preference in place of the outcome. The
lock-screen extension always uses the compatibility backend.

Desktop posters work on both backends and need no setting: the native backend
re-draws its final composition — fit, zoom and flip included — into a texture
of its own only when a poster is requested, including while the scene is idle
or paused. **Scene optimisation** applies to the compatibility renderer only;
the row says so while a scene is running natively.

No power comparison has been measured between the two. Choosing native Metal is
not a documented saving.

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
clamping, the refusal of an unknown backend name, the scene optimisation default
and round trip, and the snapshot keys the page reads.
