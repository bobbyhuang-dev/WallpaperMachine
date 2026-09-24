# Performance

**Settings -> Performance** exposes the playback and quality controls that
previously existed only as environment variables. Every control is applied
through the bridge and the page re-renders from the snapshot the engine returns,
so the page never shows a setting the engine did not accept.

Experimental content pacing, shared video decode and direct video plane
sampling are grouped in the **Advanced** disclosure. Renderer feature support
is under **Renderer compatibility**, beside the current scene backend report.

## Repeated-work reduction

These internal optimizations do not change any setting, target frame rate,
render scale, animation speed or audio-response subscription:

- Metal and Compatibility passes borrow their uniform writer only for the
  synchronous update call. Matrices still update every frame, pack column-major
  into owned storage, and preserve the input scalar type until conversion to
  float. Fixed 4×4 values use the existing inline storage; larger values own a
  vector. No camera, bone, script or effect result is cached by this path.
- The audio-analysis FIFO advances a logical read position instead of moving
  its tail after every 200-frame hop. Appends compact only when the consumed
  prefix is at least the retained suffix or the physical queue would exceed
  24,000 frames. Stereo channels advance together, capacity grows geometrically
  within that bound, and every 1,024-frame analysis window is still copied and
  processed at the original cadence.
- Repeated system-media artwork skips redundant input conversion while still
  consuming every media-state message; see [media integration](media-integration.md).

Fewer allocations, queue moves or conversions are workload evidence, not a
measurement of watts. Draw-call CPU timing excludes simulation and is not
displayed FPS; a power claim still requires the matched conditions described in
[power benchmarking](../testing/power-benchmark.md).

## Video backend

| Setting | Values | Default |
| --- | --- | --- |
| Video playback | **Compatibility**, **Native video preferred** | Compatibility |

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

It is on the **Settings -> Performance** page so it can be turned off and on
for an A/B comparison without an environment variable.

Unlike content pacing and shared video decode, which are read back from the
renderer, this row reports the saved preference: the renderer publishes no query
for it. The engine applies a change to running scenes in place, so nothing
restarts and no wallpaper reloads.

Reuse needs a target that is both cacheable and holding a pinned allocation,
because the render-target pool may otherwise hand that image to another key.
Pinning is bounded by a memory budget, so a graph whose targets do not fit at
the current output size ends up with nothing pinned. In that case the per-frame
sampling and signature walk that decide what to reuse are skipped outright:
their only reachable answer is "draw everything", and paying to reach it every
frame was pure overhead. The budget itself is unchanged; a target that cannot
be pinned still redraws.

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
audio-reactive shader, a time uniform, an animated sprite, geometry rebuilt
every frame, a puppet, a feedback pass, a text layer whose content is computed
every tick, a sound layer, a node transform or material constant driven by a
script or an animation, text whose new layout has not reached a frame yet, or
any input the renderer could not account for. That last one is reported as **an
input the renderer could not account for**, and it is the answer when a
wallpaper does not go idle.

The distinction the list turns on is between something that *can* change and
something that *is* changing. A text layer's card is rewritten when the text is
re-laid out and its texture is replaced when the glyphs change, and a layer's
visibility is a binding whether or not anything ever moves it — none of which
means the scene has work to do. A static caption, a static caption over a static
background, a caption the user's own property supplies, an image replaced only
when a resource arrives, and any of those under a supported effect chain all
stop their clocks; the same layer driven by a script does not.

Pointer-reactive scenes do sleep, and pointer movement wakes them. Property
changes, resizes, display reconfiguration, resource updates, poster requests and
visibility changes all wake the scene, as does a text layout finishing on its
own thread; a wallpaper the user paused is never woken by any of them. Writing
a caption the layer already has is not a change and wakes nothing, which is what
keeps a script that returns the same string from defeating the whole feature.

Waking is not a licence to draw. The configured frame rate is a ceiling on
every path into a frame, not only on the periodic one: a request, a one-shot
appointment and an appointment already past all wait until one frame period
after the last frame, so a burst of pointer samples coalesces into one frame
per period instead of one frame each. After a quiet stretch longer than that
period the first event draws immediately, which is the case that matters for
responsiveness. Content pacing can make the *cadence* longer than the ceiling
and an event may cut that wait short — but only as far as the ceiling.

A request is never discarded to enforce any of that. It stays outstanding until
a draw actually consumes it, so a tick dropped because a draw was still in
flight loses the tick and not the update. The end of that draw re-arms the
clock, which is the only moment that can see both facts: the scene decides
whether it still needs the clock *after* the draw ends, so a request the
running clock left outstanding would otherwise have no later tick to notice it.
Nothing polls to find out — there is one wake at that edge, not a retry per
frame period.

Both renderers implement this. The status line below reports what each scene is
actually doing, so a backend that could not idle a particular scene is visible
as such rather than described in general.

The status line reports what each running scene is doing right now — updating
continuously and why, waiting for events, paused by you, suspended by the
system, or that the state could not be read. A scene that is running but cannot
be read says so; it is never shown as updating normally.

### Scene renderer

Which renderer scene wallpapers prefer. **Compatibility** is the existing
Vulkan-through-MoltenVK path and the default. **Native Metal preferred** asks
for the native Metal backend; the menu states that unsupported scenes use
Compatibility, while **Renderer compatibility** holds the full feature list.
A scene the native backend cannot draw runs on Compatibility and the status
line says why. Lock-screen playback always uses Compatibility.
Native Metal draws image layers, text layers, sprite-sheet animation,
two-dimensional puppets, two-dimensional sprite, sprite-trail, rope and
rope-trail particles, perspective cameras for those layer types, ordinary
effect chains and scene post-processing, layers that read an image another
layer produced earlier in the same frame, images the runtime replaces while
the scene plays, and BGRA or 8-bit NV12 video textures — the latter either
converted once per frame or, with **Direct video plane sampling** on, sampled
by the layer's own shader. Lit particles, 3D models, dynamic lighting,
history-feedback effects, HDR or 10-bit video, plain video wallpapers and
shaders that do not translate fall back as a whole scene; an effect is never
dropped to keep a scene native.

Compatibility (Vulkan) instantiates leaf `.mdl` model objects, activates the
scene's perspective camera when `orthogonalprojection` is null or `isOrtho` is
false, and a visible camera object named `default` replaces the editor preview
pose as `activeCamera`. It writes live `g_EyePosition` / view-basis uniforms, honours material
`depthtest` / `depthwrite` / `cullmode` on a depth attachment for `_rt_default`,
keeps authored `scene.lights`, and still builds the LDR bloom chain when the
author set `hdr: true` so a sun glow is not skipped entirely. Native Metal
continues to refuse those scenes as a whole until that backend grows the same
depth, perspective and lighting path. `input.cursorWorldPosition` remains 2D
(`z = 0`), so scripted orbit drag may not match Wallpaper Engine.

A puppet is deformed by its author's own skinning shader on both renderers. The
pose comes from the one animation system the scene already has — animation
layers, their play, pause, stop, rate, blend and visibility, and any script or
user property driving them — and the renderer only uploads the resulting bone
matrices, so choosing a renderer does not change how a puppet moves. Rope and
rope-trail geometry is generated once by the shared particle simulation and
consumed by whichever renderer is active. Not implemented on either renderer:
the rope renderers' *UV scale*. A puppet model whose animation block the model
parser cannot read — seen locally with one format-version-23 model — is drawn
in its bind pose on both renderers, and the log says so when it loads.

A text layer is an ordinary layer here: it takes its place in the layer order
and carries its transform, opacity, blend, effect chain, camera and the final
composition, and it appears in desktop posters. Its typography is the engine's
existing text system's — the same fonts, layout and rasterisation the
compatibility backend uses — and choosing a renderer neither adds nor removes a
typographic feature. Text whose content has not changed is not laid out,
rasterised or uploaded again; a script that produces it still runs on its own
schedule every frame.
Effect and video output has not yet been compared against real wallpapers.

No GPU backend is created until the scene has been parsed and a backend chosen,
so the row reports one of three states per scene: **preparing** (no backend
yet), the backend actually in use, or Compatibility with the reason native was
not used. It never shows the preference in place of the outcome. The
lock-screen extension always uses the compatibility backend.

Desktop posters work on both backends and need no setting: the native backend
re-draws its final composition — fit, zoom and flip included — into a texture
of its own only when a poster is requested, including while the scene is idle
or paused. **Scene optimisation** applies to both renderers, and a change to it
now reaches a running scene on that scene's next frame in either direction: the
copy plan, the targets it governs and the reuse table are rebuilt over the graph
that is already compiled, without reparsing the project, reopening a video or
resetting a timeline. The row beneath the switch reports what each running scene
is actually under, so a preference that has not reached a scene yet is visible
as such rather than looking applied.

Compiled work is reused across launches where it can be. A scene's translated
Metal shaders, their reflection and their binding plans are stored in that
scene's shader cache and read back instead of being translated again — including
the optional direct-plane program, which is prepared in the background and now
survives a restart the same way. Alongside them, the render pipelines Metal
built are kept in a binary archive in that same directory and handed back to
Metal the next time the same pipeline is created, so each wallpaper has its own
store even when two displays are showing different ones.

Every one of those is a separate saving and none of them removes the others: a
stored shader means no translation ran, a stored pipeline means Metal did not
have to produce that pipeline's compiled form again, and the first use of a
program in a process still costs some compilation whatever is cached. An archive
that cannot be read, is from another machine, or is simply missing is not a
failure — the pipeline is compiled exactly as it was before, and the wallpaper
loads. All of it is regenerable and all of it is removed by **Clear shader
cache** in Storage; nothing you imported is stored there.

Measured so far on one scene only — Workshop 3620484312, a 3840×2160 canvas on
the built-in 3456×2234 display, with other applications running (numbers in the
verification log). Native Metal used to start a render pass for every pass of
the frame, about 180 here, most of them for hidden layers. Consecutive passes
into one image now share a render pass and a hidden layer starts none (47 here),
and a copy a layer makes only to read the image it draws into — 21 full-frame
copies a frame here, one per clipping-mask layer — is replaced by trading the two
images' textures. The picture is byte-identical, and offscreen CPU per frame
fell from 1.8 ms to about 1 ms. In one desktop pair, the two diagnostics windows
reported approximately 51.3 draws/s; app GPU busy time was 38.6 % versus 33.0 %,
and CPU + GPU + ANE combined power was 2.5 W versus 2.3 W. The power and counter
windows started independently, so this is not proof of matched throughput over
the power window. Neither these numbers nor the earlier render-pass comparison
establish a same-quality whole-machine power saving.

Battery runs on the built-in display recorded 10–25 W of system load with the
app quit, and 21–29 W with this wallpaper at a configured 60 fps ceiling.
Diagnostics observed 45–52 draws/s; the cause of that shortfall was not
established. A 30 fps ceiling recorded 17.5–18.9 W, and a 1 fps run recorded
17.6 W. Those ceilings are quality tradeoffs, not same-quality optimizations.
Background load and independently timed windows prevent subtracting these
ranges into a reliable wallpaper-only watt figure or attributing the difference
to memory or display hardware. CPU + GPU + ANE combined power is not whole-Mac
power. The audio-reactive runs also recorded coreaudiod at 13–17 % CPU, including
at 1 fps. No isolated energy saving has been established for the caches above.

## Advanced

All three switches are experimental and off by default.

| Setting | Notes |
| --- | --- |
| Content pacing | Drives presentation from the content's own frame cadence instead of the display refresh |
| Shared video decode | Lets equivalent display surfaces showing the same video share one decode session |
| Direct video plane sampling | Lets a Native Metal scene's own shader read the decoder's two video planes instead of a colour image converted for it each frame |

When shared decode is actually merging work, **Shared decode in use** reports the
live session and surface counts the engine publishes. Sharing is reported only
where it genuinely happens: surfaces still submit and present separately.

### Direct video plane sampling

An 8-bit NV12 frame is two planes — full-resolution luma and half-resolution
chroma — and turning it into one colour image is a full-frame pass the GPU runs
before any layer samples it. Where a layer's own shader can do that conversion
while it samples, the pass is not needed at all.

The renderer does not rewrite anything at run time to achieve this. While the
scene is parsed, a material with exactly one video texture records everything a
second translation of the same author source would need. Nothing is compiled
then: the wallpaper loads and draws with its ordinary program first. Only if the
switch is on is the second program produced, on a background worker, and its
Metal pipeline built off the frame thread; the scene adopts it between frames
when it is ready. With the switch off nothing is prepared at all, and no shader
is ever compiled inside a frame either way.

What each running scene actually did is reported per scene in **Drawn by**:
sampled directly, converted once per frame, both for a scene whose materials
differ, or converted while the direct program is still being prepared — which
means the wallpaper is playing normally and a second program is still on its
way. A material whose shader the translation cannot reproduce — an explicit
level-of-detail sample, a size query, a texel fetch, two video slots in one
material — keeps converting and says nothing; so does any frame that is not
8-bit NV12, which is what a software decoder produces for the same file. Nothing
here changes which renderer draws a scene.

**Where the two differ.** At a one-to-one mapping between video texels and
output pixels the two paths produce the same picture, to within the single code
value the converted intermediate's own 8-bit quantisation can introduce. Where
the layer is resampled they are not identical, and the reason is structural: the
converting path clamps each texel to the range the stream declares and quantises
it before the layer's sampler filters, while the direct path filters first and
clamps the result. The transform between those two clamps is affine, so the two
orders agree exactly wherever the clamp does nothing — which is every sample a
conforming stream carries. Where a stream carries codes outside the range it
declares, they can differ by up to the excursion that clamp removes, which for
8-bit limited range is at most 24 code values; a deliberately out-of-range
synthetic probe measured 19. This is a real difference, not floating-point
noise, and it is why the setting is opt-in.

No power measurement of any kind has been taken. What is claimed is that a
conversion is not encoded and its destination is not allocated when nothing asks
for one — not that this saves a measurable amount of anything.

## Verification

See [Testing](../testing/README.md) and
`Tests/Unit/Panel/WebPanelPerformanceSettingsTests.swift`, which covers the
clamping, the refusal of an unknown backend name, the scene optimisation default
and round trip, and the snapshot keys the page reads.
