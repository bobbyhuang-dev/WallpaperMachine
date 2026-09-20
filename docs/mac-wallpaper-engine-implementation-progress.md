# Improvement plan implementation progress

Implementation record for the work packages in
[mac-wallpaper-engine-improvement-plan.md](mac-wallpaper-engine-improvement-plan.md).
Task IDs are the plan's own. The plan itself is not rewritten; corrections to it
are recorded here.

Four rounds are recorded here, newest first after the shared preamble. Round 1
covered phase A (M00, V01, V02, W01, V03) and phase B (P01, W02, P02 first
version, A01 consumer gating, E01). Round 2 closed out M00's unbuilt half —
renderer-side counters on the production paths — re-examined P02's correctness
argument, and recorded phase C admission per task. Round 3 is the first phase C
batch: P02's remaining scheduling guarantee, counter attribution, R02, I01 and
an opt-in V04. Round 4 adds no task. It audits what round 3 claimed: R02's
memory accounting against the resources it says it covers, and V04's admission,
rejection and player paths against real media. R01, D01, R03, R04, the full
Metal backend, static-scene classification and V05 are deliberately not in it,
P02 stays off by default, and I01's implementation is untouched — only its
evidence wording is corrected. Phases D/E remain out of scope.

## Evidence vocabulary

A task is never marked done as a whole. These five are tracked separately,
because passing one says nothing about the others:

| Field | Meaning |
|---|---|
| implementation | The change exists on the production call path |
| automated verification | A suite that runs in this environment covers it |
| runtime verification | The real production process was exercised and observed |
| visual verification | Real rendered output was compared on a real display |
| power verification | Equal-quality paired power measurement |

Within those, the following sub-evidence is cited where it applies:

| Field | Meaning |
|---|---|
| source-confirmed | The reviewed control flow was found in the current tree |
| counter-example | A test that fails before the change and passes after it exists |
| fixed-in-production | The fix is on the production call path, not a test helper |
| tests-passing | Which suites actually ran green in this environment |

## Environment and authorization

### Round 2 build identity

Round 2 started from `6bfaa1d840f2ca84feb7ff600e7b32e78a6e9610` on `main`, with
a clean working tree: `git status --porcelain` was empty, so round 1's reported
results — 310 `scripts/test.py` cases, the green renderer gate and 233
`wallpaper-bridge` cases — correspond exactly to that commit and include no
uncommitted work. Round 2's changes are uncommitted working-tree edits on top of
it; no history was rewritten and nothing was rebased.

### Round 1 build identity

Round 1's working tree started at `6dc8c327c6f7e2594d84722413f11d7168eb5898`,
which is the plan's fixed baseline, so no problem needed re-confirmation against
a newer main. Its work is the commit named above.

Available: `cargo`, `cmake`, `xcodegen`, `xcodebuild`, Homebrew `ffmpeg@8`,
`quickjs-ng`, `glslang`, `molten-vk`.

One environment trap worth recording: the shell had `CARGO_TARGET_DIR` pointing
at a sandbox cache, so early `cargo build` runs left
`upstream/renderer/target/release/libwallpaper_bridge.a` untouched and the
regenerated bindings did not contain the new API. Every renderer build below was
re-run with that variable unset. GPU tests also fail with
`VK_ERROR_INCOMPATIBLE_DRIVER` inside the command sandbox and must run outside
it; they create only private GPU images.

Not available or not authorized this round, so every item depending on them is
recorded as blocked rather than failed:

- Desktop control, window/occlusion driving, Spaces, lock and unlock.
- Screen capture, screenshots, wallpaper changes, app install or replacement.
- System audio capture and audio hardware.
- `powermetrics`, Instruments and any elevated sampling.
- `python3 scripts/test.py --ui` (takes over the desktop).

**No power number, watt figure or saving percentage is reported anywhere in this
document.** Counters and unit tests bound what is claimed.

## Round 14 — 32-bit particle indices, layer as texture, perspective cameras, rope UV

Feature round, same discipline as rounds 5–13: implement, wire to production,
keep it building, fix what this round broke. Native Metal stays a manual choice
and Compatibility stays the default. Visual output on real wallpapers, desktop
behaviour and power are the user's to accept. **No power measurement of any
kind was taken and no saving is claimed anywhere below.** Agreement between
this application's two renderers is not a comparison with Wallpaper Engine.

| Feature | State | Default |
|---|---|---|
| Rope trail / sprite meshes past 16 384 quads | Implemented; authored renderer kept, 32-bit indices on both backends | Always |
| Payload > 1 GiB or 64-bit size overflow | Particle object skipped with an error; effect type unchanged | Always |
| Layer as texture `_rt_imageLayerComposite_<id>[_a|_b]` | Implemented in the shared front end; both backends consume `_rt_link_<id>` | Always |
| Hidden source still produces; same-frame self-read snapshot | Implemented | Always |
| Missing / duplicate / cycle / previous-frame (`_b`) | Explicit refusal strings on both backends | Always |
| Effect-chain source composite | Implemented; the node ResolveEffect resolves onto, not `_rt_default` | Always |
| Unused perspective cameras in `scene.cameras` | Not a refusal | Always |
| Per-layer / per-pass / active perspective camera for supported layers | Implemented; the runtime's own camera, not a second Metal timeline | Follows **Scene renderer** |
| Perspective projection (FOV, aspect, near/far, homogeneous divide) | Implemented via `SceneCamera` and the existing Metal clip-space fold | Same |
| Depth test/write | Only for passes whose material asks; translucent layers do not write depth | Same |
| Screen-facing particle orientation | `g_Orientation*` follows the camera node's axes | Same |
| Perspective click/hover unprojection onto the layer plane | Implemented for perspective cameras; ortho path unchanged | Same |
| Rope / rope-trail `uvscale` | Geometry-encoded in trail length (no author uniform) | Always |
| Rope / rope-trail `uvscrolling` | V against mesh/history capacity so a growing rope unrolls | Always |
| Rope / rope-trail `uvsmoothing` | smoothstep on trail-position | Always |
| Runtime `SetRopeUv` | Implemented without re-parsing | Always |
| Poster | Unchanged: the same final composition | Same |

`segments` is an implementation default of 10 when the project omits the field.
That default is not observed from Wallpaper Engine; the shipped rope-trail
preview omits it.

Packed 16-bit remains the default index width. Subdivision is not reduced to
fit. Both backends share the 1 GiB vertex+index budget, so switching renderer
is not a fix. Sprite systems above 16 384 particles take the same 32-bit path.
The implicit Rope Trail → Sprite Trail replacement is gone.

Camera selection uses the node's named camera, a per-pass override, or
`activeCamera`. An unused `global_perspective` entry — which every parsed scene
has — is not a refusal. Projection is `SceneCamera::GetViewProjectionMatrix()`
(the engine's `Perspective()`, not an orthographic scale). Metal still folds
clip space through `MetalClipSpaceFold`, which remains the identity. Depth is
allocated per colour target that a pass actually depth-tests, at that target's
size (already `renderScale`). `"the scene uses a perspective 3D camera"` is no
longer a fallback reason.

Upright/Fixed particle orientations are not parsed, so they are not a distinct
fallback; particles that declare `g_Orientation*` receive the camera basis.

`_rt_imageLayerComposite_<id>` is the source layer's composite after its
effects. In installed wallpaper 3226487183 the referenced hidden layer is id
14942; that layer has no effect chain. A source that does have a chain links
from the isolated composite of the node ResolveEffect resolves onto, not from
`_rt_default`. Hidden sources do not dual-draw that composite onto the scene
framebuffer.

### What the tree actually did before this round

- Particle meshes past 16 384 quads could not keep their authored rope-trail
  renderer: the parser reduced subdivision or rewrote the trail as a sprite
  trail, and both GPU backends bound 16-bit packed indices.
- `_rt_imageLayerComposite_<id>` was rewritten to `_rt_link_<id>` by regex
  without missing/duplicate/cycle/history reasons, and a hidden source was
  dropped.
- Any active perspective camera refused the whole scene.
- Rope UV scale/scroll/smooth had no runtime path.

### Tests added

- `scene_mesh_tests`: index-width / overflow / geometry-budget cases.
- `particle_rope_geometry_test`: packed 16-bit boundary, uint32 past the old
  cap, order across instances, ParticleRopeUv scale/scroll/smooth.
- `layer_texture_reference_test`: authored composite syntax, forward ref,
  duplicate name, missing target, cycle, history `_b`, file name vs layer name,
  invisible source kept, producer-before-consumer, effect-chain source not
  linked from `_rt_default`.
- `metal_backend_test`: unused / per-layer / active perspective cameras
  accepted; unsupported depth compare refused; pipeline key distinguishes
  depth; perspective FOV/homogeneous divide; NDC unprojection onto a layer
  plane; camera axes follow the attached node; a colour target with `withDepth`
  is not a graph refusal.
- `metal_scene_draw_smoke.APerspectiveCameraDrawsThroughTheAuthoredShader`: a
  parsed card drawn through `global_perspective`, rotated, must foreshorten.
- `metal_scene_draw_smoke.ARopeTrailPastTheOldSixteenBitIndexLimitStaysARopeTrail`.

### Local wallpapers run through the Metal gate

`WE_TEST_METAL_PROJECTS` with `MetalSceneDraw.LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend`.
Packages were read in place; nothing was copied into the repository. Select
accepted Native Metal. After the empty-key prepare fix, exact printed lines:

- 3226487183: `Native Metal, 120 frames drawn, 14968995 bytes differ between the first and the last`
- 3680252478: `Native Metal, 120 frames drawn, 2552368 bytes differ between the first and the last`
- 3800629364: `Native Metal, 120 frames drawn, 2814309 bytes differ between the first and the last`

The byte counts are first vs last offscreen frame, not a comparison with
Wallpaper Engine. Layer 14942 in 3226487183 has no effect chain.
3680252478's `effects/shimmer` still failed to translate (`Unknown function
'rotateVec2'`, Naga GLSL parse: the `common.h` helper never reached Naga).
That effect is absent from the native draw; the rest of the scene prepared.
HEAD had already failed 3226487183 and 3800629364 at prepare with an empty
texture key, and rejected 3680252478 for perspective.

### Still falls back as a whole scene

Lit particles, 3D models, dynamic lighting, history-feedback effects, HDR or
10-bit video, plain video wallpapers, shaders that do not translate, RGB8
images, block-compressed images on a device without them, sheets that are also
videos, non-triangle primitives, any other per-frame geometry, a skinning
shader whose bone array or inputs do not match its mesh, a rope or trail mesh
that does not have its generator's layout, MSAA targets, sampling a depth
buffer, unsupported depth compare, and scenes loaded before Native Metal was
selected. The lock-screen extension stays on Compatibility. A scene is never
drawn with a layer missing: every one of these is the whole scene. Perspective
cameras for the layer types Native Metal already draws, and same-frame layer
texture references, are no longer on this list.
Installed 3226487183 / 3680252478 / 3800629364 no longer fall back as a
whole scene on this tree; an empty unsampled material slot is not a Metal
prepare failure.

### Interface

No new switches. **Scene renderer**'s description now lists perspective cameras
for the supported layer types and same-frame layer links as drawn natively, and
no longer names perspective cameras as a whole-scene fallback, in both
languages. The per-wallpaper "Drawn by" list still reports the backend each
running wallpaper actually got with the renderer's own reason.

### Not verified

- Nothing was displayed. No wallpaper was shown on a desktop, no output was
  judged by a person against Wallpaper Engine, and no power, energy or thermal
  measurement was taken.
- Visual equivalence with Wallpaper Engine is not claimed.
- Rope UV appearance against the real engine was not compared.
- The three local wallpapers were drawn offscreen only, 120 frames each. No
  frame was judged against the authored result, and `effects/shimmer` is
  absent from 3680252478's native draw.
- `shared_video_session_test.AFrameStaysValidAfterTheDecoderMovesOn` and the two
  pointer `scene_schema_tests` Wait-timeout cases fail on HEAD as well as on
  this tree; their assertions were not modified.

## Round 13 — two-dimensional puppets, sprite trails, ropes and rope trails on Metal

Feature round, same discipline as rounds 5–12: implement, wire to production,
keep it building, fix what this round broke. Native Metal stays a manual choice
and Compatibility stays the default; direct plane sampling and content pacing
keep their defaults, and nothing here changes a saved setting. Visual output on
real wallpapers, desktop behaviour and power are the user's to accept. **No
power measurement of any kind was taken and no saving is claimed anywhere
below.** A puppet or a trail is more work than the fallback it replaces was for
this backend, which drew nothing; the point is that the same content now has a
native option, not that it costs less.

| Feature | State | Default |
|---|---|---|
| Two-dimensional puppets, deformed by the author's skinning shader | Implemented; accepted per mesh and per shader, not per label | Follows **Scene renderer** |
| Puppets under an effect chain | Implemented; judged by the mesh the chain resolves onto its last node | Same |
| Sprite trail particles | Implemented; the existing sprite geometry, accepted by its vertex layout | Same |
| Rope particles | Implemented in the **shared** runtime, so on both renderers; consumed natively | Same |
| Rope trail particles | Implemented in the shared runtime with per-particle path history; consumed natively | Same |
| Block-compressed (BC1/BC2/BC3) images on Metal | Implemented where the device supports them; a real puppet could not load without it | Always |
| A declared but never sampled texture slot | No longer a prepare failure on Metal | Always |

### What the tree actually did before this round

Read from the code rather than from earlier sections of this document:

- **Puppets were never a missing data path.** Deformation is, and always was,
  the author's vertex shader: the model parser compiles `genericimage*` with
  `SKINNING` and `BONECOUNT`, the mesh carries `a_BlendIndices` as four raw
  32-bit integers and `a_BlendWeights` as four floats, and
  `WPShaderValueUpdater` writes `g_Bones` as one 4x4 float matrix per bone
  through whatever uniform writer the backend gives it. Metal already had that
  writer, already placed array members by their reflected stride, already kept
  its uniforms in one buffer per in-flight frame, and already reported a bone
  uniform as a reason a target cannot be reused. What stood in the way was one
  line: any shader with a `g_Bones` member refused the whole scene.
- **Sprite trails were never different geometry.** A `spritetrail` renderer is
  the thick sprite-particle record; the author's `genericparticle` shader
  stretches it from the velocity that record already carries and from
  `g_RenderVar0`. It was refused by its marker alone.
- **Rope geometry did not exist on either renderer.** `GenRopeParticleData` was
  present but its call was commented out when the generator moved from a flat
  particle list to instances, so a rope mesh was filled with sprite-layout
  records and read by a rope shader. The dormant function also left the first
  vertex slot unwritten and reported one quad too few.
- **Rope trails did not exist at all.** The project parser renamed `ropetrail`
  to `spritetrail` on load, and the simulation kept no per-particle history.

So the round split cleanly in two: for puppets and sprite trails, replace a
refusal with a statement about the actual mesh and shader; for ropes and rope
trails, write the geometry once in the shared runtime and let both renderers
consume it.

### Puppets: where the deformation happens and what Metal consumes

On the GPU, in the author's vertex shader, on both renderers. Nothing is skinned
on the CPU and nothing is skinned twice. Metal consumes three things:

- **The mesh as parsed**, uploaded once when the graph is compiled: positions,
  blend indices, blend weights, texture coordinates, 16-bit indices and the
  per-part draw ranges, per submesh and per material slot, including the mask
  submeshes that draw into `_rt_puppet_mask`. Indices stay the four integers the
  model stores and are bound with the integer vertex format the translated
  shader reflects; weights are neither renormalised nor truncated. Nothing
  assumes four influences beyond what the author's shader itself declares, and
  nothing caps the bone count: the array is the size `BONECOUNT` made it.
- **The pose**, which is `WPPuppetLayer::genFrame`'s output for the scene's
  current time — the existing hierarchy, bind and inverse-bind spaces, animation
  layers and their blend, exactly as the compatibility renderer receives it. It
  is copied, 64 bytes per bone, into the pass's own uniform block inside the
  frame's uniform buffer. No transpose and no axis flip were added for Metal;
  the GPU test below is what says that is right rather than an assumption.
- **The author's program**, through the same structured translation every other
  shader takes. Its bone array is a member of the pass's uniform block, so the
  bone data lives in the per-frame `MTLBuffer` and is never passed as inline
  bytes.

One pose per frame, however many passes use it. `genFrame` caches its result
against the exact time it was asked for and every copy of a `WPPuppetLayer`
shares one state, so the layer's own pass, its mask passes, its effect pass and
its attachments all read one evaluation; what repeats per pass is a `memcpy` into
that pass's block, which is unavoidable while the array is a member of each
program's own block. The animation advances once per frame because the scene's
clock advances once per frame, not because a backend counts.

Pose, frame number and bone matrices are not part of any pipeline key. The key
is the program's content, the vertex layout, blend, target format and alpha
write, as before; a puppet adds one pipeline per distinct program, not one per
frame.

### Puppets: animation control and composition

Nothing was added to the Metal backend for any of this, deliberately: play,
pause, stop, rate, blend, visible, `getFrame`/`setFrame`, a single-shot layer
stopping at its end and restarting on `play()`, and the user-property bindings
for layer settings all act on the shared `WPPuppetLayer` state, and the pose the
backend uploads is read from that state after the frame's scripts have run. The
order inside a frame is unchanged — scripts and the runtime tick, then the
uniform pass that evaluates the pose — so an upload cannot see a pose from
before a script's write. There is no second playback state to drift.

A puppet is an ordinary layer for everything else: order, transform, opacity,
blend, the supported effect chain, attachments (updated at `FrameBegin`, which
the backend already called), `renderScale`, fit/fill/crop, the poster, user
pause and policy suspension.

Caching. A pass with a bone uniform was already classed as advancing on its own,
so its target and everything downstream of it is redrawn while an independent
static background keeps being reused. This round did not try to detect "the
skeleton has stopped": a scene with a puppet keeps its frame clock, which is the
conservative behaviour the brief asked for. A paused layer produces identical
frames; it does not let the scene idle.

### Puppets: the capability rule, and what real content taught it

A `g_Bones` shader is accepted when its reflected array has a stride that holds
a 4x4 matrix, it reads `a_BlendIndices` as four unsigned integers and
`a_BlendWeights` as four floats, and the mesh it is drawn with stores exactly
those. Each failure has its own reason. Two backstops sit behind the gate: a
frame whose pose length does not equal the shader's bone array fails with "a
puppet's bone count does not match its shader" instead of spilling into the
neighbouring uniforms, and preparing a skinning shader against a mesh without
bone inputs fails rather than reading indices from whatever is at offset zero.

Running locally installed wallpapers through the gate found three things no
fixture had:

- **A puppet with an effect chain has no geometry when the gate runs.** The
  parser draws the layer's own pass as a plain card, puts the skinning material
  on the chain's last node with an empty mesh, and keeps the puppet mesh as the
  chain's *final mesh* until `ResolveEffect` moves it across while the render
  graph is built — after backend selection. The first version of the rule
  therefore refused every puppet that had an effect. The gate now finds the
  chain's last output node by the same rule `ResolveEffect` uses and judges that
  node by the final mesh; any other effect node is still judged by what it has.
- **Puppet sheets are block-compressed.** The Metal importer refused BC1, BC2
  and BC3 outright, so the first real puppet fell back with "an image a layer
  needs could not be loaded". They are now uploaded as the blocks the file
  already contains, when `supportsBCTextureCompression` says the device takes
  them — the same formats the compatibility renderer hands the same GPU through
  MoltenVK. A level shorter than its own block grid fails the import rather than
  being read past its end. RGB8 is still refused.
- **A shader may declare a texture slot it never samples.** Two workshop effects
  do, and the resource plan refused them because the material lists no texture
  there. A slot that the reflection reports as inactive is now left unbound,
  which is what Metal does with an unused argument; a slot that *is* sampled
  with nothing behind it still fails, and the message now names the slot and the
  shader.

### Sprite trail, rope, rope trail: three renderers, three meanings

**Sprite trail** — each particle's image, oriented along its motion and
stretched by speed. Simulation and geometry are untouched: it is the thick
sprite record, and the author's shader reads `length`, `maxlength` and — new this
round — `minlength` from `g_RenderVar0`. The native backend accepts it when the
mesh really is thick and carries the velocity attribute.

**Rope** — one continuous line through the particles a system has spawned. The
generator joins the live particles of **one instance** in array order, which for
a rope is age order because the emitter keeps ropes sorted old-to-new. A particle
that died during this tick is skipped and its neighbours joined, rather than
cutting the rope at it for a frame; particles of different instances are never
joined, so a child system's ropes stay separate. Fewer than two live particles
draw nothing. `subdivision` is implemented on the CPU: each pair is split into
that many pieces on a Catmull-Rom curve through the neighbouring particles, with
size, colour and alpha interpolated, which is what the engine's geometry shader
does where one exists. Each piece carries control points chosen so the author's
shader derives the same edge direction on both sides of a joint — a mitred,
continuous rope rather than overlapping rectangles. Texture V runs the way the
author's shader defines it, from the trail length and position the generator
writes. Width follows the sprite path's convention: the owner node's scale is
divided out of size, as it already is for sprites.

**Rope trail** — a line along the path **each particle** has travelled. This
needed the one genuinely new piece of state: `ParticleTrailHistory`, a
fixed-capacity list of positions per particle slot, owned by the simulation and
advanced inside `Emitt()` with the same time step the particles move by. It is
geometry history, not a previous frame's pixels — nothing here reads a render
target from an earlier frame, and history-feedback effects remain unsupported. A
slot's history is reset when a particle is spawned into it, so a reused slot can
never join two unrelated paths, and a rope trail's emitter is no longer
age-sorted, because sorting would move particles away from their histories. A
recording period of zero simulated time records nothing, so user pause and
policy suspension stop the trail growing exactly as they stop the particles.
`segments` and `subdivision` multiply into the number of recorded points, and
`length` is the simulated time those points span; subdividing a trail by
sampling its real path more finely, rather than by interpolating, is both more
faithful and the only form the author's texture-coordinate arithmetic can
express. The head of a trail is a partial piece from the particle to its newest
point; when the history is full the oldest piece shrinks by as much as the head
has grown, so the tail does not vanish a whole piece at a time, and the fraction
that drives both is written to `g_RenderVar0.z` every tick, which both renderers
re-read every frame. The whole trail is drawn with the particle's current colour,
alpha and size, and disappears with its particle.

Degenerate input is handled in the generator, not left to the shader: coincident
points emit no piece (and no `NaN` from normalising a zero vector) while the
trail position still advances, so texture coordinates stay where they belong.

Capacity. A rope mesh is sized from the author's numbers — particles ×
subdivision, or particles × segments × subdivision — against the 16-bit index
limit of 16 383 quads. Only `subdivision` is ever reduced to fit, and the
reduction is logged with both counts; particle count, lifetime and segments are
never reduced. With the defaults (10 segments, subdivision 3) that means
subdivision 2 above 546 particles per mesh and subdivision 1 above 819. A rope
trail that does not fit even then — above 1 638 particles at 10 segments — is
**not dropped**: it is loaded as the sprite trail every rope trail was before
this round, with an error in the log naming both numbers. That keeps a layer
that used to draw from vanishing on the default renderer; it is not a rope
trail, and the log is the only place that says so. A plain rope that cannot fit
at subdivision 1 (more than 16 383 particles in one mesh) is skipped with an
error; before this round it drew a rope-layout buffer of sprite records. The
generator refuses to write past the mesh's capacity and says so; by construction
it cannot reach it.

**This changes the compatibility renderer's output for rope scenes**, which is
the intended effect of fixing shared geometry and is stated rather than
discovered: a rope used to be a rope-layout buffer holding sprite records.

### Dynamic resources: what is reused and what is no longer uploaded

Nothing new was built. Rope, rope-trail and sprite-trail meshes go through the
dynamic path round 9 added: one vertex buffer and one index buffer per in-flight
frame, allocated once at the mesh's declared capacity, written only in the slot
the current frame owns (bounded by the existing in-flight semaphore, so the CPU
never writes what the GPU is reading), with the uploaded revision tracked per
slot so an unchanged simulation uploads nothing. The copy covers the vertex
array's written extent rather than its capacity; that extent only grows, so after
a burst it stays at the peak instead of following the live count back down —
round 9's behaviour, unchanged, and the draw itself is always bounded by the
simulation's own count. Stride, attribute list and binding shape are re-checked
on every upload. No buffer is created per frame, no frame waits for completion,
and there is no separate draw timer. Topology is
indexed triangles with 16-bit indices and no culling, as for sprites.

For a puppet, the mesh, indices, weights and textures are uploaded when the graph
is compiled and never again; per frame only the bone matrices change, inside the
uniform buffer that already existed. What is *not* deduplicated: a puppet with
clip masks has one vertex array per mask submesh, each its own copy of the same
vertices, and each is uploaded once. That is the parser's data model and was
left alone.

Instances share what is immutable — parsed images, translated programs, compiled
pipelines and the pipeline archive. Pose, playback state, particle state and
trail history belong to a scene instance and are not shared because two
wallpapers name the same file.

### Still falls back as a whole scene

Perspective cameras and perspective particles, dynamic lighting and lit
particles, non-triangle primitives, any other per-frame geometry, a skinning
shader whose bone array or inputs do not match its mesh, a rope or trail mesh
that does not have its generator's layout, history-feedback effects, depth or
MSAA targets, RGB8 images, block-compressed images on a device without them,
unsupported video formats, sheets that are also videos, plain video wallpapers,
shaders that do not translate, and scenes loaded before Native Metal was
selected. The lock-screen extension stays on Compatibility. A scene is never
drawn with a layer missing: every one of these is the whole scene.

Of the four locally installed wallpapers that contain puppets, two fall back for
a perspective camera, and the other two fall back for reasons that have nothing
to do with puppets — a layer that names another layer as its texture, which this
runtime does not resolve on either renderer. Their puppet layers, taken alone,
draw natively; see below.

### Interface

No new switches. **Scene renderer**'s description now lists two-dimensional
puppets and sprite, sprite-trail, rope and rope-trail particles as drawn
natively, and perspective or lit particles and 3D models as falling back, in
both languages. The per-wallpaper "Drawn by" list still reports the backend each
running wallpaper actually got with the renderer's own reason; the reasons added
this round reach it unchanged, and the three removed ones ("rope particles",
"particle trails", "animates a puppet skeleton") can no longer appear. **Scene
optimisation** and **Update only when the scene changes** are unchanged.

### Tests added

- `particle_rope_geometry_test.cpp` (new, CPU only, registered in the renderer
  gate), 17 cases: rope pieces and their layout, a dead particle skipped and its
  neighbours joined, no piece across instances, zero and one particle,
  subdivision through the middle particle, coincident particles without `NaN`,
  thick format, instance offset, rope trail from the current position along the
  recorded points, the full-history tail shrink, empty history and dead
  particles, trails never joined; and through `ParticleSubSystem::Emitt()` — the
  birth point, growth to capacity then dropping the oldest, the period fraction
  staying in [0, 1), a zero time step recording nothing, a respawn restarting
  the history.
- `metal_backend_test.cpp`, 26 cases: sprite trail, thin rope, thick rope, rope
  trail and a skinned mesh accepted; a sprite trail without velocity, a
  rope-marked sprite layout, a thin rope trail, a puppet shader on a plain card
  and a bone stride of 48 each refused with a distinct reason; a puppet under an
  effect chain accepted through the chain's final mesh, refused when that mesh
  has no weights, and refused when the skinning material is not on the chain's
  last node.
- `metal_scene_draw_smoke.mm` (real Metal device, private textures, offscreen
  layer), 31 cases plus one that needs an environment variable:
  - `APuppetIsSkinnedByItsOwnShaderFromThePoseTheRuntimeProduces` — reflected
    stride 64; the bone-1 quad **translates by two thirds of its own width** at
    two thirds of the slide while keeping its width, and the bone-0 quad does not
    move, which is what rules out a transposed or re-ordered matrix; a moving
    pose is never reused; `pause()` freezes the picture while time passes and
    `play()` moves it again.
  - `TheShippedImageShaderSkinsAPuppetThroughTheNativeBackend` — the author's
    real `genericimage2` with the two puppet combos translates, reflects a
    64-byte bone stride, is accepted and draws two different poses. Skips when
    the shipped shaders are not installed.
  - `ARopeLayoutMeshReachesTheTarget`, `ASpriteTrailMeshReachesTheTarget`.
  - `TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively` —
    the editor's own `spritetrail`, `rope` and `ropetrail` preview projects,
    through the real parser, the real `genericparticle` and
    `genericropeparticle` shaders, the shared simulation and the native draw.
    Skips when the shipped assets are not installed.
  - `ARopeTrailTooLargeForItsIndexBudgetIsStillDrawnAsItWasBefore` — the
    shipped rope-trail preview with 5 000 particles loads as a sprite trail,
    marked as one, and is accepted. Skips when the shipped assets are not
    installed.
  - `LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend` — any
    `project.json` listed in `WE_TEST_METAL_PROJECTS` is parsed as the wallpaper
    loads it; a fallback is printed with its reason, and an accepted scene must
    prepare and draw 120 frames. Skips when the variable is unset.
- `offscreen_scene_probe` and the preview test honour `WE_TEST_RANDOM_SEED`, so
  one seed makes both renderers simulate the same particles.

### What was observed, and how far it goes

Offscreen only, on this machine's GPU, with content that stays outside the
repository; none of it is a suite that runs on a clean checkout.

- Two reduced copies of a locally installed wallpaper, keeping only its puppet
  layers (a format-version-21 model with 30 bones, six animations and five
  animation layers, once plain and once under its four-effect chain), were drawn
  for 120 frames by both renderers. Sampling every fifth pixel of the 3840×2160
  result, **no sampled pixel differed** between Native Metal and Compatibility in
  either case, and frame 0 and frame 119 differed in roughly 40 % of samples, so
  the comparison was of a moving character.
- With one random seed, the 90th simulated frame of the shipped `spritetrail`,
  `rope` and `ropetrail` previews had **no pixel differing by more than 2/255**
  between the two renderers, while the neighbouring frames differed by hundreds
  to thousands of pixels, so the comparison is sensitive to a single step.

That is agreement between this application's two renderers. It is **not** a
comparison with Wallpaper Engine itself, and the rope and rope-trail geometry is
this round's reading of the author's shader, not a port of the engine's.

### Not verified

- Nothing was displayed. No wallpaper was shown on a desktop, no output was
  judged by a person against Wallpaper Engine, and no power, energy or thermal
  measurement was taken.
- Rope and rope-trail *appearance* against the real engine: the joint shape, the
  width convention, the rope-trail default of 10 segments (the shipped preview
  omits the field, so the engine's own default was not observed), and the
  texture-coordinate behaviour of a full trail's last piece.
- `UV scale` on both rope renderers is not implemented on either renderer; the
  author's shaders expose no uniform for it.
- A sprite trail's `minlength` is now passed through; no project using it was
  run.
- A puppet model whose animation block the model parser cannot read — one
  format-version-23 model seen locally — is drawn in its bind pose on **both**
  renderers. That is a parser limit this round did not touch, and such a puppet
  is not an animated puppet on either backend.
- Puppet clip masks, attachments, single-shot layers, scripted `setFrame` and
  user-property layer bindings reach Metal through shared state and were not
  each driven through the native backend; the GPU tests drive play, pause and a
  looping layer.
- Block-compressed upload was exercised by local content only; there is no
  fixture texture for it in the repository.
- No installed wallpaper reached either index-budget limit; the rope-trail
  fallback was exercised only by raising the shipped preview's particle count.
- More than 16 383 *sprite* particles in one system overflow the same 16-bit
  indices; that predates this round and was left alone.

## Round 12 — scenes that genuinely stop, and compile results that survive a restart

Feature round, same discipline as rounds 5–11: implement, wire to production,
keep it building, fix what this round broke. Native Metal stays a manual choice
and Compatibility stays the default; direct plane sampling stays experimental
and off, and nothing here turns either on. Visual output on real wallpapers,
desktop behaviour and power are the user's to accept. **No power measurement of
any kind was taken and no saving is claimed anywhere below.**

| Feature | State | Default |
|---|---|---|
| A static text scene stops its frame clock | Implemented; it reports no reason to keep drawing and idles through the mechanism round 7 built | Follows **Update only when the scene changes** |
| A changed caption wakes it, updates once, and lets it idle again | Implemented, including from the text worker's own thread | Same |
| Scripted text, animation, video, sound and anything unrecognised keep running | Unchanged, and now the only things that do | Same |
| The optional NV12 program's translation survives a restart | Implemented through the existing on-disk program cache | Follows the existing experimental switch |
| Compiled render pipelines are archived and reused | Implemented with `MTLBinaryArchive`, on the real pipeline-creation path | Always on where a cache path exists |

### What was actually stopping every scene

The on-demand mechanism from round 7 was correct and had almost nothing to
idle. Measured on this round's own fixtures, before any change:

| Scene | Renderer's reasons | Runtime's reasons |
|---|---|---|
| One static text layer | `DynamicMesh`, `RuntimeImage` | `NodeBinding` |
| One static image layer | none | `NodeBinding` |

`RuntimeImage` was already dropped on the way to the scene level, correctly:
an image the runtime may swap changes on an event. The other two were not.

**`NodeBinding` was reported by every scene the parser has ever produced.**
`ParseTextObj`, the image-layer path and the particle path all call
`RegisterNodeVisibility` unconditionally, and `ResolveBoolSetting` always
returns a value, so `m_node_visibility` is never empty. `DescribeTimeAdvancingWork`
answered "is this registry non-empty", which is a question about whether a
binding *exists*, not about whether it *moves*. A wallpaper with a single static
image therefore reported that it had work to do, forever. This is a
pre-existing gap the feature shipped with, found by measuring rather than by
reading, and it is the larger half of what this round fixes.

`DynamicMesh` was the text-specific half. `SceneMesh::Dynamic()` was one bit
answering two questions, and it was the same answer for as long as a particle
system was the only thing that rewrote a mesh.

### Telling "can change" apart from "is changing"

Three facts about a text layer are all true and none of them is a reason to
keep drawing:

- its card is a dynamic mesh, because `ResizeCardMesh` may rewrite it;
- its texture is a runtime image, because a relayout may replace the pixels;
- it has a visibility binding, because every layer does.

`SceneMesh` now carries `MeshUpdate` — `Fixed`, `PerFrame` or `OnEvent` —
instead of a bool. `Dynamic()` still answers the upload question and still
returns true for both moving kinds, so nothing about how vertices reach the GPU
changed. The constructor takes the enum, which is deliberate: every place that
cloned a mesh with `SceneMesh(other.Dynamic())` would have silently turned an
event-driven card into a per-frame one, and the compiler found all of them
(`SceneRuntimeContext`, `SceneImageEffectLayer`, `SetFinalMeshDynamic`, and four
test files) rather than leaving it to be noticed later.

The renderer gained `DynamicReason::EventMesh` beside `DynamicMesh`, raised by
both backends — `CustomShaderPass` for Compatibility and the two demand sites in
`MetalRender.mm`. For pixel reuse the two are identical and
`StaticSubgraphCache` treats them as such, because either one means the vertices
may differ from those the cached pixels were drawn from. For idling they are
opposites, and `SceneDemandReasonsFromShaderInputs` carries one and not the
other. Each omission from that mapping is now named in the comment rather than
implied by a missing line.

On the runtime side, a binding contributes a reason only when its value can
move on its own. That is a closed question here: `ScriptedDynamicValue` is the
only subclass of `DynamicValue`, and it re-evaluates every tick. Every other
value moves only when something calls `update()` on it — a user property write,
a script propagating, or an animation sampling — and each of those is either an
event that asks for its own frame or is already represented by `Script` or
`Animation`. A material constant with an attached animation is treated as
moving regardless of its value, because the animation is the thing that writes
it. `m_node_effect_final` was dropped from the condition entirely: it holds no
value, and `SyncEffectFinalNode` mirrors a node rather than driving one.

### Waking, and not waking

The event paths this round needed were almost all already there. Round 7's
render handler asks for a frame after every command except the draw, so a user
property change, a poster request, a render-scale change, a surface
reconfigure, a media thumbnail arriving and a wallpaper switch all wake an idle
scene by construction.

The one that was not is the text worker. It runs on its own thread, and a scene
that has gone quiet has no clock left to notice that a layout finished — the
new image would sit in the queue until something unrelated happened to ask for
a frame, which for a wallpaper that idles correctly is never. `SceneRuntimeContext`
now takes a wake handler, called after a result is pushed and outside the
worker's own lock, and `SceneWallpaper` installs one that asks its frame timer
for a single frame. The handler reaches the timer through a small shared target
whose pointer the render handler clears in its destructor, so a worker thread
inside the call while the handler is torn down finds a null timer rather than a
dangling one.

Two things keep that from becoming a source of spurious frames. `SetNodeText`
still returns early for an unchanged string, so a script returning the same
caption forever queues nothing and wakes nothing. And a new demand reason,
`TextLayoutPending`, covers the window between "the text changed" and "the new
image has been applied", so the frame that made the change does not also
conclude the scene is still — the scene stays awake on its own account until
the work lands, and the wake handler is the belt to those braces.

Nothing about script execution changed. `update()` runs every tick, no script
source is read, no repeated return value is counted, and no `Date` or
`getMinutes` is turned into a schedule.

### What idling does not do

The per-frame texture slots are not pre-warmed before idling, and they do not
need to be: `refreshRuntimeImages` uploads into the slot *this* frame will use,
comparing that slot's version rather than the ring's, so a frame taken minutes
later after an event updates its own slot before drawing. The frame that idles
has already drawn the current picture correctly into the slot it used. Holding
the clock open to fill the other slot would be paying continuously for
something that costs one upload when it is next needed.

No drawable is retained while idle: a frame acquires and presents one, and an
idle scene takes no frames. `userPaused`, `policySuspended` and `contentIdle`
stay independent — `FrameTimer::RequestFrame` still drops the request while the
clock is stopped, so no resource event can resume a wallpaper the user paused.

Both backends get this. The runtime half is shared, and the renderer half was
implemented in `CustomShaderPass` as well as in `MetalRender`, so a static text
scene idles on Compatibility too.

### The optional program's translation, kept

Round 11 prepared the optional NV12 variant in the background and threw the
result away when the process ended. It now goes through the same on-disk program
cache the ordinary translation already uses — `/cache/<scene>/programs01/<key>.json`,
which already stored the Metal source, the reflection and the binding metadata,
not just a string of MSL. No second cache was built.

`CompileMslVariant` mounts that cache, and only that cache: the includes still
come from the snapshot captured during the parse, so the variant compile cannot
read the project, cannot re-expand an include, and does not need a virtual file
system. The cache key is constructed from the request exactly as it is during a
parse, which is why an entry written by one launch is found by the next — and
why the variant's key differs from the base program's, since the plane-sampling
request is a different request.

The cache root travels with the scene on the `SET_SCENE` message rather than
being read across threads later, because the programs a scene holds were
translated against that cache and a later variant of one of them has to be
looked up in the same place.

Program-cache entries are now published atomically: written beside the entry
under a name carrying the writer's pid and moved over it, so a reader sees the
previous complete entry or this one and never half of either. `Fs` gained a
`Rename` that says no by default; `PhysicalFs` implements it and the VFS refuses
a rename that would cross a mount. A file system that cannot do it falls back to
writing in place, which is what happened before, and a torn entry is still
rejected when it is read.

### Compiled pipelines, archived

`MetalProgramCache` now keeps an `MTLBinaryArchive` per device beside the
shader cache and sets `binaryArchives` on the descriptors it passes to
`newRenderPipelineStateWithDescriptor:` — the real production path, for base and
optional pipelines alike, not a file that is written and never used.

The details that make it safe:

- **Two archive objects from one file.** The one attached to descriptors is
  never written; the one written to is loaded from the same file, so
  serialising republishes what earlier launches stored instead of replacing the
  file with only this run's pipelines.
- **Never on the render thread.** Adding to an archive compiles, and writing one
  touches the disk. Both happen on a serial utility queue, scheduled only after
  a pipeline was created and found nothing stored, and the write is debounced so
  a wallpaper with twenty pipelines publishes once rather than twenty times.
- **Published atomically**, temporary file then replace, with the pid in the
  temporary name, so two processes sharing a directory replace the file whole
  rather than interleaving.
- **A miss is remembered, not retried.** The key stays in the collected set even
  when the archive refuses it, so the same failure is not produced again.
  Contributions are capped per device.
- **The file name is not the registry ID.** `MTLDevice.registryID` is assigned
  at boot, and using it would produce a different archive every restart — the
  one thing a cache that exists to survive restarts must not do. The name is
  built from the device's own name and a digest of the shader toolchain's
  identity, so an incompatible store cannot collide with a usable one. Metal
  rejects a file it cannot use in any case.
- **Per renderer, not per process.** The path is set on the surface's own
  `MetalRender` with its scene, and the store is keyed by device *and*
  directory. A Mac with two displays showing two different wallpapers has one
  device and two caches, and a process-wide root would have filed whichever
  loaded second over the first — losing the other surface's contributions at
  every switch. The library and pipeline caches stay shared by device, because a
  compiled program is the same program whichever wallpaper wanted it.
- **No strict option in production.** `MTLPipelineOptionFailOnBinaryArchiveMiss`
  turns a cold cache into a wallpaper that does not load, so the renderer never
  uses it. A miss compiles, exactly as before.

The archive lives inside the scene's own shader-cache directory, so it is
sharded per wallpaper, is purged with that scene's cache when the project
changes, and is removed by the existing **Clear shader cache** entry, which
deletes the whole shader-cache root. Nothing a user imported is stored there.
One session keeps at most eight stores open; the ninth releases the
least-recently-opened, whose file stays on disk and is reopened when that
wallpaper next builds a pipeline.

### What the cache layers are, named separately

| Layer | What a hit means | State after this round |
|---|---|---|
| Translated MSL, reflection and binding plan on disk | No GLSL→MSL translation ran | Base programs since earlier rounds; **optional variants added this round** |
| `MTLLibrary` in memory | No `newLibraryWithSource:` for that source in this process | Round 11 |
| `MTLRenderPipelineState` in memory | No pipeline created for that key in this process | Round 11 |
| `MTLBinaryArchive` on disk | Metal could supply part of the pipeline's compiled form rather than producing it | **Added this round** |

Reading an MSL file is not "no GPU compilation happened": the first time a
program is used in a process, Metal still compiles it. The binary archive is
what addresses that, and it addresses the GPU back end's share of the work — it
does not make the MSL→AIR stage disappear. A file that loads successfully also
does not mean every pipeline hits; per-pipeline hit reporting is only obtainable
with the strict option, which is used in one test and nowhere else, so the
production diagnostic reports what it actually knows: whether an archive was
opened, how many pipelines were offered to it, and how many times it was
written.

### Interface

No new switches. Static-text idling follows the existing **Performance → Scene
wallpapers → Update only when the scene changes**, which is off unless the user
turns it on, and the "Updating now" line is still read back from each running
scene rather than restated from the preference — a scene only says it is waiting
for events when it actually is.

One new reason name, `text_layout_pending`, shown as "text still being laid
out". It is a bounded state, not a fault, and it exists so that a scene busy
producing a new caption is not reported as an input the renderer could not
account for.

The **Clear shader cache** description now says it removes the compiled render
pipelines kept alongside the compiled shaders. Nothing else on that page
changed, and it still never touches imported material.

### Tests added

- `metal_scene_draw_smoke.mm`
  - `AStaticTextSceneRunsOutOfWorkToDo` — a fixed caption reaches zero demand
    reasons, having drawn its glyphs, while the renderer still reports both
    `EventMesh` and `RuntimeImage` so the reuse cache is provably unaffected.
  - `AChangedCaptionWakesTheSceneAndThenLetsItGoQuietAgain` — demand returns on
    the change, the new picture reaches the output, demand goes back to zero,
    and rewriting the same caption does not wake it.
  - `TextProducedByAScriptIsNeverCalledStill` — thirty frames, `Script` set on
    every one.
  - `TextBoundToAUserPropertyIsEventDrivenRatherThanContinuous`.
  - `AStaticTextLayerUnderAnEffectChainAlsoRunsOutOfWork`.
  - `AnOptionalProgramTranslatedOnceIsRestoredFromDiskOnTheNextLaunch` — one
    translation, then a compile from an empty in-memory cache that produces
    identical source, reflection and per-stage bindings without the compiler
    running; then every stored entry truncated, and the variant produced anyway.
  - `PipelinesThisProcessBuildsAreArchivedAndServeTheProductionPath` — the
    archive is collected, published, reopened from disk and asked strictly for
    every descriptor; and a scene with no archive path still draws.
- `static_subgraph_cache_test.cpp` —
  `GeometryRewrittenOnAnEventIsNotAReasonToKeepDrawing`: both halves, the
  mapping and the cacheability.
- `text_object_runtime_test.cpp` —
  `PreparedTextWakesWhoeverOwnsTheFrameClock`: the handler fires when the worker
  produces a result and does not fire for an unchanged caption.
- `scene_demand.rs` —
  `text_still_being_laid_out_is_its_own_reason_not_an_unknown_input`.

### Not verified

- Nothing was displayed. No wallpaper was shown on a desktop, no output was
  looked at by a person, and no visual comparison was made between an idling
  scene and a continuously drawing one.
- No power, energy or thermal measurement was taken. A scene that stops drawing
  does less work; how much less, and whether it is visible on a battery, is not
  something anything here measured.
- The "next launch" claim is shown within one process by clearing the in-memory
  caches and reopening the published files, which is what a new launch does to
  those two caches. No second process was started.
- The archive was exercised on this machine's GPU only. Whether an archive
  written on one Mac is usable on another is Metal's decision, and the failure
  mode either way is a normal compile.
- Complex scripts, unusual fonts and non-Latin text behave exactly as they did
  before; nothing in this round touches layout or the font system.
- Two bounded losses are accepted rather than solved. A pipeline still inside
  its two-second write debounce when its store is released — the ninth distinct
  wallpaper of a session — is not written, costing that wallpaper one recompile
  on a later launch. And a crash between a program cache entry's staged write
  and its rename leaves a `.tmp<pid>` file in `programs01/`, which is never
  read and is removed with the cache.

## Round 11 — text and runtime images on Metal, optional programs off the load path

Feature round, same discipline as rounds 5–10: implement, wire to production,
keep it building, fix what this round broke. Native Metal stays a manual choice
and Compatibility stays the default; direct plane sampling stays experimental
and off. Visual output on real wallpapers, desktop behaviour and power are the
user's to accept. **No power measurement of any kind was taken and no saving is
claimed anywhere below.**

| Feature | State | Default |
|---|---|---|
| Text layers drawn by the native Metal backend | Implemented end to end: parsed text object → translated text program → rasterised glyphs → card drawn into the scene's own target | Follows the backend choice |
| Unchanged text costs no layout, no rasterisation and no upload | Implemented; the scripts still run every frame | Always on |
| Runtime-replaced images consumed and refreshed on Metal | Implemented for every runtime image a material binds, text textures and the media thumbnail alike | Always on |
| The optional NV12 program prepared off the load path | Implemented: translation on a bounded background worker, Metal pipeline on a serial queue, adopted at a frame boundary | Follows the existing experimental switch |
| Nothing prepared at all while that switch is off | Implemented and asserted | Off |
| Metal libraries and pipelines shared across scenes and surfaces | Implemented, keyed by program content and device | Always on |

### Two corrections to what round 10 reported

Both are corrections of wording, not of behaviour, and neither needed new work
to establish:

- "Not compiled in the per-frame hot path" was true and was **not** the same
  claim as "does not affect the first frame". Round 10 compiled the optional
  variant inside the parse, which is on the path to the first frame; it simply
  was not inside a frame. This round is what makes the stronger statement true
  for the optional program. The **base** program's Metal pipeline is still
  created synchronously in `compileRenderGraph`, before the first frame, and
  that is unchanged.
- The round 10 colour and sampling comparison was one synthetic stream with
  neutral chroma, held still, at two scales. It does not support "all conforming
  streams are identical", and that sentence is withdrawn. What it supports is
  what it measured: that stream, at 1:1, agreed to one code value, and scaled it
  stayed inside the clamp excursion the stream's own limited range implies.

### Text layers reach the native backend

A text layer was never refused for being text. It was refused because its card
is a mesh the runtime rewrites — `RejectDynamicMesh` accepted only the particle
generator's vertex contract and refused everything else, text cards included,
with the honest reason that nothing had checked their upload shape. Three things
were missing, and all three are now there:

- **A program.** `BuildTextSceneShader` compiled the text program to SPIR-V only,
  so `SceneShader::metal_program` stayed null and `prepareDraw` had nothing to
  draw with. It now queues the same `PendingMetalTranslation` a material does,
  captured before the SPIR-V compile consumes the units, so the text program is
  translated to Metal exactly like an author's.
- **A shape the gate can name.** `IsDynamicCardMesh` states the geometry
  positively: one submesh, one vertex array of a float3 position and a float2
  texture coordinate, four vertices of fixed capacity, no index array. That is
  what `ResizeCardMesh` writes for a text layer's own card, for an effect
  chain's final card and for the node an effect chain resolves its last pass
  onto. Anything else that rebuilds geometry per frame is still judged by the
  particle rules and still refused.
- **An upload for it.** The dynamic path assumed an index stream. A card has
  none: four corners, drawn as a triangle strip. `prepareDraw`,
  `uploadDynamicMesh` and the encoder now carry the index-less case, and the
  upload re-checks that the mesh still has the shape it was prepared for, so a
  mesh that grew or lost an index stream fails the frame instead of being
  reinterpreted against the wrong storage.

The layer is an ordinary scene layer from there on: layer order, transform,
opacity, blend, the camera, the author's canvas, `renderScale`, the effect
chains its own node carries, the final composition and the poster all apply to
it because it is a node with a mesh and a material like any other. Nothing is
overlaid as an AppKit or SwiftUI view.

One shared behaviour worth stating because it is easy to mistake for a fault in
this round: a text layer under an effect chain draws into a buffer whose size
the parser fixed from the text it was parsed with, and a much longer string is
clipped to it. That is the shared parser and runtime — `ResolveTextEffectCapacity`
and the effect camera — not this backend, and the compatibility renderer does
the same. Nothing here changed it and nothing here should be read as having
fixed it.

Everything the text system already supports comes with it, because none of it
was reimplemented: the text, the font (asset, system or family), point size,
colour, alpha, brightness, background, padding, horizontal and vertical
alignment, the anchor, explicit size, maximum width and rows, wrapping and
clipping are all resolved by `ResolveTextLayerState` and rasterised by
`RasterizeTextLayer` exactly as the compatibility backend gets them. What that
system does not do, this round does not add: there is no new font library, no
new shaper and no new layout engine, and a backend change cannot give a text
system typographic features it never had.

### The same text does not get redrawn into a new texture

This is the round's optimisation, and it is stated as what must not happen: a
clock layer whose script returns the same string must cost no measurement, no
rasterisation, no geometry rebuild and no texture upload, while the script keeps
running exactly as before.

- The runtime already separated a text value changing from a text value being
  produced: `TextLayer::SetText` returns immediately when the string is equal,
  and only a changed string marks the cache dirty and raises the layout
  revision. Nothing in that was weakened, and no script was slowed down, batched
  or given a deadline. `update()` runs on its own schedule and a `Date` in it
  means nothing to any of this.
- The renderer now asks a version, not a picture. `RuntimeImageSource::Version`
  answers "has anything replaced these pixels?" with one integer under the lock
  it already had, and `refreshRuntimeImages` compares it per in-flight frame
  slot. The common case touches no pixels at all: no `Parse`, no decode, no
  `replaceRegion`.
- When content does change, it is written into the storage the next frame owns —
  one texture per in-flight frame, the same pattern the dynamic vertex ring
  uses — so new pixels never land in an image a queued command buffer is still
  reading, and a text that changes every minute does not allocate a texture
  every minute. A size or format change does allocate, and the images it
  replaces stay alive exactly as long as the command buffers that reference
  them, because `[queue commandBuffer]` retains what it encodes.
- The reuse analysis now folds each bound runtime image's version into the pass
  sample. Without it a target whose only moving input is that image would be
  called unchanged and keep showing the previous picture. That was already live
  for the media thumbnail on Metal before text existed, so this is a bug fixed
  rather than a cost introduced.

There is no glyph atlas to keep in step: the text system rasterises one texture
per layer, and a re-layout replaces the texture and the card's corners together,
in the same frame, from the same prepared result.

### Runtime images, not only text

The refresh is written against "an image the runtime replaces", not against
text, so the two production producers of those — a text layer's rasterised
glyphs and the system media thumbnail — take the identical path: collected once
per compiled graph from the keys the materials actually bind, refreshed at each
frame boundary before anything samples one, and re-uploaded only when the
version moved. No file is re-read, no image re-decoded and no texture recreated
for an unchanged image, and nothing here invents a thumbnail when the system has
not published one.

### The optional program is no longer part of loading a wallpaper

Round 10 produced the NV12 variant during the parse and built its pipeline in
`compileRenderGraph`. Both are on the path to a first frame. This round splits
the two preparations:

- **Required**: the ordinary RGB program, its reflection and its pipeline, built
  with the graph as before. A scene is ready when those are.
- **Optional**: the plane-sampling variant. The parser now captures what it
  would be compiled from — the preprocessed units, the combos, the texture info
  and every include the ordinary translation read, with contents — into a
  snapshot that owns itself, and compiles nothing. `WPShaderParser::CompileMslVariant`
  replays that snapshot through the identical compile with no virtual file
  system at all, so it can run an hour later, after the project, the parser and
  its mounts are gone.
- One worker thread, a queue bounded at 32, and the claim held on the program
  itself, so one program is translated once however many times it is asked for
  and a program that failed is never retried. Two surfaces that parsed the same
  wallpaper separately hold separate programs and each translates its own; what
  they do share is the Metal side, below. Switching wallpapers drops what has
  not started; a compile already inside the shader compiler finishes, because
  nothing can interrupt it, and its result goes away with the program it was
  compiled for. That is stated as it is, not as an abort.
- The Metal library and pipeline are built on a serial utility queue and posted
  into a mailbox owned by a shared pointer, so a build that comes back after the
  graph, the renderer or the process's interest in it is gone writes into a box
  nobody reads. The renderer collects at a frame boundary, checks the graph
  generation, and adopts between frames.
- The variant brings its own uniform storage, one buffer per in-flight frame,
  allocated when it is adopted. The shared ring is cut when the graph is
  compiled and the variant is not there yet; re-cutting it later would move
  storage the current frame is already writing into.
- With the switch off, nothing is asked for, nothing is translated and no extra
  pipeline is created. That is asserted, not asserted-about: the test reads the
  program's state and requires it to be untouched.

### Program and pipeline reuse

`MetalPipelineKey::program_id` was the address of the translated program object.
That is unique only while that object lives — two wallpapers loaded one after
another can put different programs at the same address — so it could not be
shared beyond one compiled graph, and a cache keyed on it would eventually hand
the second scene the first one's pipeline. It is now a hash of what the program
contains: each stage's kind, entry point, language version and Metal source.

With that, the library and pipeline caches moved out of the renderer instance
into one process-wide cache scoped by `MTLDevice.registryID`, holding libraries
by source and pipeline states by the full key — vertex layout, blend state,
colour format, sample count and alpha write mask all included, so two programs
that merely share a name can never share an incompatible pipeline. It is bounded
at 256 libraries and 512 pipelines per device; past that nothing new is
remembered and the caller still gets a correctly built object.

What is cached, said precisely, because these are four different things:

| Layer | What it holds | Where |
|---|---|---|
| Translated MSL text | The Rust shader program cache, per scene, on disk and in memory | Unchanged from before this round |
| `MTLLibrary` | Compiled Metal source, per device, keyed by the source itself | New, process-wide |
| `MTLRenderPipelineState` | Per device, keyed by program content plus pipeline state | New, process-wide |
| GPU binary archive | **Not implemented** | — |

There is no `MTLBinaryArchive` in this round. Reading a cached MSL file is not
the same as not compiling: a library restored from cached text still goes
through the Metal shader compiler on first use in a process. The first cold
launch after an install still compiles every program it draws with.

### Interface

No new switch. The two existing ones carry the round:

- **Native Metal renderer** (Advanced) — unchanged; still a manual choice,
  Compatibility still the default. Text layers and runtime images are simply no
  longer a reason for a scene to fall back.
- **Direct video plane sampling** (Advanced, experimental, off) — unchanged as a
  control. What changed is what it costs: off now means nothing is prepared, and
  on now means the wallpaper plays while the optional program is prepared behind
  it.
- **Drawn by** gains one more video path: *converted once per frame, direct
  sampling still being prepared*. It is said only while a translation or a
  pipeline is genuinely in flight. A material whose variant was refused, or
  which never had a candidate, reports the plain converting path, because
  nothing further is coming — and "preparing" never means the wallpaper is not
  playing.

### Tests added

- `metal_scene_draw_smoke.mm`: 4 new cases, 17 total, all green.
  A parsed text project is accepted by the native backend, is translated,
  rasterised and drawn into the scene's own output, and reports itself as a
  reason to keep drawing. A text that does not change costs no measurement and
  no upload over twelve frames while the runtime ticks, then a new string costs
  at most one upload per in-flight frame and reaches the picture, then goes
  quiet again. A text layer with an effect chain — which has three cards the
  relayout rewrites, not one — draws through the chain and follows a new string
  to the chain's own output. The same translated program compiled by a second
  renderer on the same device is not handed to the Metal compiler a second
  time.
- `metal_scene_draw_smoke.mm`, rewritten for the new preparation: the video
  cases now assert that the parse compiled **nothing** optional, ask for the
  variant the way the wallpaper's own loop does, and draw until the path
  settles rather than assuming the first frame. The switch-off case additionally
  asserts the program was never even claimed.
- `crates/core`: every video path the renderer can report has its own name, and
  a value this build does not know is not invented.

### Not verified

- No real wallpaper has been drawn on a display and nothing has been seen by a
  human. The text cases draw a synthetic project whose glyphs come from this
  machine's font resolution; no golden image of text exists and none is claimed.
- Complex script systems — Arabic shaping, Indic reordering, vertical writing —
  are exactly as supported as they were before this round, which is to say
  whatever `RasterizeTextLayer` already does. Nothing here improved or degraded
  them, and no claim is made about them.
- A purely static text layer still keeps the scene drawing, because its card is
  a per-frame mesh and its texture is a runtime image. That is the conservative
  choice the specification permits, not a limitation discovered late: nothing
  here tries to prove a text layer will never change again.
- No power measurement, and no claim that any of this saves a measurable amount
  of anything. What is claimed is that specific work does not happen: no
  re-layout, no re-rasterisation and no re-upload for unchanged content, and no
  optional compile while the switch is off.

## Round 10 — NV12 direct plane sampling, scene optimisation applied at runtime

Feature round, same discipline as rounds 5–9: implement, wire to production,
keep it building, fix what this round broke. Native Metal stays a manual choice
and Compatibility stays the default; direct plane sampling is a new opt-in on
top of it. Visual output on real wallpapers, desktop behaviour and power are the
user's to accept. **No power measurement of any kind was taken and no saving is
claimed anywhere below.**

| Feature | State | Default |
|---|---|---|
| NV12 direct plane sampling in Metal scenes | Implemented end to end: parsed material → second program → bound → drawn | Off; new experimental switch |
| Conversion decided by what consumers need | Implemented; a planes-only frame allocates and writes no BGRA destination | Follows the switch |
| Scene optimisation applied at a frame boundary | Implemented on both backends, both directions | Follows the existing switch, on |
| Per-scene video path and applied-setting read-back | Implemented, reported in the settings panel | Always on, no setting |

### One material, two programs, chosen per frame

The blocker round 9 recorded was an ordering one: the decoded pixel format is
not known when a shader is translated. This round takes the controlled form of
option (a) from that entry — both variants are produced while the parser still
holds the translation inputs, and the choice is made per frame from the format
the decoder actually produced. Option (b), retaining the inputs past parse and
re-translating at the first frame, was not implemented.

`WPSceneParser` already queues one Metal translation per material with the
combos, preprocessed units and texture info the SPIR-V compile settled on. It now
also records that material's texture keys, and after the ordinary translation
succeeds it compiles a second program from **copies** of the same inputs — copies
because `CompileProgramRust` merges combos, default textures and preprocessor
results into whatever it is handed, and the originals have already been consumed
once. A material qualifies when exactly one of its slots is a video the native
video path accepts; two video slots, a sprite-sheet video or a slot with no media
disqualifies it, because a variant per combination is a matrix this round does
not build.

Inside `crates/shader` the second program is a real translation, not an edit of
the first:

- `ShaderTextureInfo` carries `VideoPlaneLayout`, defaulting to `None`. The
  bridge writes `video_planes` into the request JSON only when it is set and the
  cache key gains a term only when it is set, so an ordinary texture's program
  and its cache identity are exactly what they were.
- `ProgramResourceLayout` allocates a chroma texture, its sampler and two `vec4`
  `GlobalUniforms` members per flagged slot — **after** the author's own
  resources, so a binding a shader encodes in a `g_TextureN` name never moves.
  The chroma global is named `_we_VideoChroma<N>`, deliberately not `g_Texture…`:
  that prefix is how both the reflector and the renderer read a material slot out
  of a resource name, and a plane the renderer supplies is not a slot the
  material has. `active_texture_slots` still reports only the material's own.
- The existing `texture_sampling` codegen strategy rewrites that slot's
  implicit-LOD samples into a generated helper that reads both planes and applies
  the colour transform. The author's coordinate expression is left exactly as
  written, so every later coercion still applies to it, and macro bodies are
  rewritten on the same terms as ordinary source.
- Any other reference to the slot — an explicit-LOD sample, a size query, a texel
  fetch, passing the sampler on — **refuses the variant** before a single fixup is
  emitted. A refusal is recorded on the variant and never on the program: the
  material keeps converting, which is what it did before the variant existed.

The pipeline revision went 4 → 5, so every cached program is recompiled once.

### The renderer asks before it converts

The point of the fast path is not that a shader *can* read planes; it is that
nothing converts a frame no consumer asked to have converted. `MetalVideoTextures`
now takes a per-key demand — does anything sample the planes, does anything need
one colour image — **before** anything is imported:

- BGRA frame: imported zero-copy and sampled as one image, as before.
- NV12 with no consumer needing an image: both plane views are vended, no
  destination is acquired, none is allocated, and no conversion is encoded.
- NV12 with a mixed set of consumers: the planes plus exactly one conversion,
  however many passes read it.
- The format is read from every frame, not from the first: the same file is BGRA
  under software decode and NV12 under VideoToolbox, and either can take over
  mid-playback without the scene being reparsed or a timeline reset.
- A demand change — the switch toggled, a variant becoming usable — re-imports the
  generation that is current rather than waiting for the next one, so a consumer
  is never left with nothing to sample.

One lifetime rule changed while doing this, and it is a fix rather than a
consequence: the bundle a frame is sampled from is now retained into **every**
command buffer that reads it, not only the one that imported it. A paused source
keeps one bundle current across many frames, and dropping it while a later
command buffer still held its vended texture was a Core Video wrapper released
under a live read.

### Binding, and where the two programs meet

`MetalRender` builds both programs' binding plans through one
`BuildMetalResourcePlan`, so the two cannot disagree about how a resource name
becomes a slot. The variant's plan must contain a chroma plane for the slot it
was built for and must bind the luma plane, or it is refused and logged. Both
pipelines are created while the graph is compiled — **synchronously, beside the
ordinary one**; this is not an asynchronous compile. Nothing is compiled inside a
frame, and the first frame is not blocked by it because the graph compile
precedes every frame.

Per frame: the uniform ring reserves the larger of the two blocks, the colour
constants are written from the decoded frame's own colorimetry, `g_TextureNResolution`
is read from the frame rather than from a texture that may not exist on the direct
path, the luma plane is bound with the author's own sampler and the chroma plane
with a linear-filtered copy of it. Chroma is filtered linearly whatever the author
asked for on the colour image, because that is what the conversion pass does to it,
and reproducing that is what makes the two paths comparable rather than merely
similar.

### What the two paths actually produce

Measured, not asserted in prose. One decoded frame, held still and proved held,
drawn by both programs and read back off the GPU:

- **At a one-to-one mapping between video texels and output pixels the two paths
  agree to within one code value** — the converted intermediate's own 8-bit
  quantisation, which the direct path does not perform.
- **Under resampling they are not identical.** The converting path clamps each
  texel to the range the stream declares and quantises it before the layer's
  sampler filters; the direct path filters first and clamps the result. The
  transform between those two clamps is affine, so the orders agree exactly
  wherever the clamp does nothing — every sample a conforming stream carries.
  Where a stream carries codes outside its declared range they differ by up to
  the excursion that clamp removes: at most 24 code values for 8-bit limited
  range, and 19 measured on a deliberately out-of-range synthetic probe
  (full-range noise in a stream declaring limited range, ~1 texel in 7 clamping).

This is a real difference with a named mechanism, not floating-point error, and
it is why the switch is opt-in rather than on. It was found by the test, not
reasoned about afterwards: the first version of the comparison failed at 149 code
values, which turned out to be the test comparing two different decoded frames.

### Scene optimisation, applied where it is changed

Round 9 recorded the asymmetry: turning the setting off took effect on the next
frame, turning it back on waited for the graph to be compiled again. Both
backends now apply it at a frame boundary over the graph already compiled.
Nothing is reparsed, no video is reopened and no timeline is reset.

- Metal: `applySceneOptimizationSetting` runs at the top of `drawFrame`, before
  anything is imported or encoded. It re-plans copy elision, reconciles the
  target table — a destination the plan has just folded onto its source gives up
  its image, one the plan no longer folds gets a fresh one — clears the fresh
  ones **into that frame's own command buffer**, and recompiles the reuse table.
  Nothing waits on the GPU.
- Vulkan: `ApplySceneOptimization` is called from `SceneWallpaper`'s frame loop.
  Where the copy plan really changed it destroys prepared pass state and drops
  render targets, which is what `applyRenderScale` does for the same reason — and
  like `applyRenderScale` it now quiesces first. That is a one-time device wait
  paid when the user changes a setting, never per frame. Turning the setting off
  also restores the copies a previous plan removed, which it did not before.
- Two bugs found while doing this: `compileStaticCache` zeroed its pinned-byte
  total without giving it back to the process-wide budget, which double-counted
  on every re-apply; and `compile()` built a present pipeline only for copies the
  plan had kept, so un-eliding one at run time would have compiled a pipeline
  inside a frame. Both fixed.
- The first frame after re-enabling redraws rather than reusing, because a table
  that has recorded nothing cannot call anything unchanged.

### Interface

Two existing rows carry the round, plus one new experimental switch:

- **Scene render optimisation** — now says it takes effect on the next frame in
  both directions, and carries a new **In force now** line read back from each
  running scene. That distinguishes the saved preference from one that has
  actually reached a scene; a scene the renderer could not answer for is counted
  as unknown rather than as applied.
- **Drawn by** — each running scene now also names the path its video textures
  took: sampled directly, converted once per frame, or both. A scene with no
  video says nothing rather than reporting a failure.
- **Direct video plane sampling** (Advanced, experimental, off) — the new switch.
  Off leaves the existing conversion in place; on but not applicable stays on
  Metal's conversion and never falls back to Compatibility; no environment
  variable is needed, and there is no per-matrix or per-plane control.

### Tests added

- `crates/shader/tests/video_planes.rs`: 9 cases. The ordinary variant is
  unchanged by the option existing; the plane variant translates the author's own
  expression rather than replacing it, declares the chroma plane and the colour
  constants, reaches Metal with its own binding plan, keeps the chroma plane out
  of the material's active slots, and gets a different cache key. An explicit-LOD
  sample, a size query and a size query inside a macro each refuse it; a macro
  that plainly samples the slot is translated; a flag for a slot the shader never
  declares changes nothing.
- `metal_video_texture_test.mm`: 6 new cases. Planes-only demand encodes no
  conversion and offers no single image; mixed demand converts exactly once and
  still publishes the planes; the direct path receives the same eight colour
  constants as the kernel; a demand change re-imports the current generation; a
  BGRA frame ignores a plane demand; a format flip mid-stream switches path
  without losing the picture. 14 cases total, all green.
- `metal_scene_draw_smoke.mm`: 5 new cases. An ordinary parsed author material
  over real decoded media takes the direct path and draws; the same material
  keeps converting while the switch is off and takes the direct path on the next
  frame when it is turned on; the two paths agree at one-to-one; the scaled case
  stays inside the clamp excursion its stream implies; a graph compiled with the
  optimisation off starts reusing when it is turned on. 13 cases total, all green.
- `crates/bridge`: the new setting defaults off, reaches the engine through both
  facade halves, reopens nothing, and is pushed back in after a restart.

### Not verified

- No real wallpaper has been drawn on a display and nothing has been seen by a
  human. The end-to-end video case draws synthetic H.264 media the test encodes.
- The synthetic media carries neutral chroma, so the picture comparison above is
  exact over luma and over the conversion arithmetic and does **not** exercise a
  difference that only appears where chroma varies within a chroma texel. What
  bounds that case is the constants check, not a picture.
- No power measurement. What is claimed is that a conversion is not encoded and
  its destination not allocated when nothing asks for one — never that this saves
  a measurable amount of anything.
- `AVideoLayerKeepsConvertingWhileTheSettingIsOff` asserts the off→on transition
  only when the machine's decoder produced NV12. It did here; on a machine
  without VideoToolbox that assertion does not run.
- Multi-video materials, explicit-LOD and mipmapped video sampling, 10-bit and
  HDR formats are all still pre-converted or refused, unchanged.

## Round 9 — scene optimisation on Metal, sprite sheets, 2D sprite particles

Feature round, same discipline as rounds 5–8: implement, wire to production,
keep it building, fix what this round broke. Native Metal stays a manual choice
and Compatibility stays the default; video content pacing stays opt-in. Visual
output on real wallpapers, desktop behaviour and power are the user's to accept.
Nothing below was seen on a display, and **no power saving is claimed anywhere**
— the counters say passes were not run, which is not a watt.

| Feature | State | Default |
|---|---|---|
| Scene optimisation (reuse + copy elision) on Native Metal | Implemented on the production draw path | Follows the existing Scene optimisation switch, on |
| Sprite-sheet animation on Metal | Implemented for sheets the existing parser produces | Follows Scene renderer |
| Standard 2D sprite particles on Metal | Implemented; simulation still the shared runtime's | Follows Scene renderer |
| NV12 dual-plane direct sampling | **Not done** — blocker below | — |

### Scene optimisation: one analysis, now two backends

`vulkan::StaticSubgraphCache` and `PlanCopyElision` are used directly from
`MetalRender.mm`. They were already backend-neutral — strings, spans and hashes,
no GPU handle — so nothing was moved, no second copy was made and the render
graph was not rewritten. The `vulkan::` namespace is now a misnomer and was left
alone rather than churned through `provenance.json`.

What is shared: target-to-writer association, the input graph, dynamic-reason
propagation, cycle handling, the reuse verdict and the equivalent-copy rules.
What is not: every Metal resource, and every Vulkan lifetime assumption. Metal
pins nothing in a pool because it pools nothing — `Impl::targets` holds one
`MTLTexture` per key for the life of the graph — so "pinned" here is only the
budget decision, using the same 192 MiB ceiling and the same four-bytes-per-texel
estimate as the compatibility backend, so one `pinned_bytes` number in the
settings panel keeps meaning one thing. Over budget, the target simply
re-renders; the frame is never blocked and nothing grows unbounded.

Per target, not per pass, as before: all writers of a target are skipped together
or not at all, so a clear cannot be skipped while the draws that composite onto
it still run. A skipped pass creates **no encoder at all** — creating one would
apply its load action, and a `Clear` load action is exactly how the reused pixels
would be lost — and its mip levels are left as they are, because they already
belong to those pixels. Store actions were already `MTLStoreActionStore`
everywhere and nothing is memoryless, so the "results that are read later must
survive" requirement was already met and was not re-engineered.

Ordering inside `drawFrame` is the correctness lever, and it is:
`nextDrawable` → `video.beginFrame` → the uniform loop → **then** sampling and
`Plan()` → encoding. The uniform loop is where the shared value updater advances
sprite clocks and refreshes node transforms, so a sample taken before it would
describe the previous frame. Nothing above the plan is conditional on it: a
reused target still costs its scripts, its sprite step and its uniform write, and
only the drawing is removed. Whether the whole scene may idle is still the
existing demand mechanism's question, untouched.

Invalidation. Reuse requires a per-frame sample to be unchanged, and the sample
folds: the node's model transform, the mesh's dirty generation, the material's
constant values, **the pass camera's and the active camera's view-projection
matrices** (neither is covered by the node transform, and both move on a
fill-mode change, a user zoom or a script), the sprite frame's rectangle, axes
and `imageId` as they will actually be sampled, and the target extent — which is
where output size and `renderScale` enter. Time, audio, pointer, bones, video
frame generation, runtime-swappable images and per-frame meshes are *dynamic
reasons* instead: those targets are never reusable at all, and the reason
propagates along real dependencies, so an independent still subgraph in a scene
that also contains a video is still reused. There is no "this scene has a video,
therefore everything is dynamic" flag. Anything unaccounted for keeps
`UnknownInput` and redraws.

Sprite sheets are deliberately *not* a dynamic reason on this backend. Because
the sample is taken after the sprite clock has advanced and folds the frame
rectangle itself, a sheet resting between frame changes is reused and a sheet
that stepped is redrawn — while the clock keeps running, so the animation still
reaches its next frame. The compatibility backend still treats a sheet as always
dynamic; that difference is a deliberate consequence of the ordering above and is
not a behaviour difference in the pixels.

Failure and lifetime. `Plan()` records this frame's signatures as it runs, so any
frame that fails *after* the plan — the resampling-copy failure, a dynamic-mesh
upload failure — calls `InvalidateAll()` before failing, or the next frame would
reuse a target the GPU never wrote. The same invalidation runs on surface release
and surface reset; graph release, recompile and `ApplyRenderScale` drop the table
entirely. Frames in flight are bounded by the existing `kFramesInFlight`
semaphore, and nothing evicts a texture: the target keeps its `MTLTexture` for the
life of the graph, so cache bookkeeping can never release something the GPU is
still reading.

Poster. `ServicePosterRequest` re-composes from the scene's output target, which
holds the last complete composition whether or not its writers ran this frame —
skipping happens exactly when the pixels would be identical. No blank image and
no stale generation results from a skipped pass.

### Redundant passes and copies on Metal

`PlanCopyElision` now runs over the Metal pass list, before the targets are
allocated, because what it decides changes which images exist. A copy with no
consumer is not encoded. A copy that qualifies as an alias is not encoded and its
destination gets **no texture of its own** — it shares the source's, resolved
through the chain — so the saving is an allocation as well as a blit. Everything
else runs.

Round 8's unequal copies are real resampling passes, and they stay: the rule's
`copy_compatible` requires equal extent and equal mip level count (one colour
format is used for every scene target), and a copy that also builds the
destination's mip chain is kept. A name is never what decides. The composition
draw and the poster, which both read the scene's output, are entered into the
analysis as a reader, so a scene whose last step is a copy into the output is not
mistaken for a copy nobody wants.

Encoder structure is unchanged: no attempt to merge everything into one encoder,
no splitting small passes into their own command buffers, one bounded submission
per frame as before. No shader, pipeline or sampler is built inside a frame;
dynamic values use the existing per-frame uniform ring.

Counting reuses the existing interface — `RecordSceneOptimizationFrame`,
`RecordElidedCopies`, `AdjustSceneOptimizationPinnedBytes` and the one
`owe_scene_optimization_stats` ABI — so Metal's contribution lands in the same
totals. No new polling and no new setting were added.

### Two defects found while porting, fixed in both backends

Both were in the shared analysis, so leaving either in the compatibility path
while relying on it from a second backend was not an option.

1. **An aliased copy destination looked like a name nothing produces.** After an
   alias, the destination has no writer, so a later read of it resolved to no
   target at all and the reader appeared to carry no dependency — while the
   pixels behind that name are the source's, redrawn every frame. A still effect
   sampling a link texture whose source is time-varying would have been declared
   reusable and frozen. `CopyElision` gains `ResolveCopyAliasKey`, and both
   `VulkanRender::applySceneOptimization` and the Metal equivalent resolve inputs
   through it. Covered by three new cases in `static_subgraph_cache_test`,
   including the chain and a cycle that must terminate rather than hang.
2. **Turning the setting off and on again could reuse stale pixels.** With reuse
   off, `Plan()` never runs, so the recorded signatures stay frozen at the moment
   it was switched off while every frame redraws from whatever inputs it has. If a
   later frame's inputs happened to match that frozen signature — a layer moved
   away and back, a script rewriting a value — re-enabling would call the target
   unchanged although its pixels came from a different frame. Both backends now
   drop the cached verdicts while the setting is off, so the first frame after
   re-enabling redraws and re-records. Covered by
   `MetalSceneDraw.TurningTheOptimisationBackOnDoesNotReuseAFrameDrawnWhileItWasOff`,
   which was run against the unfixed code first and fails there on the pixel
   comparison, not only on the counter — the defect was visible, not theoretical.

### Sprite sheets

Sprite animation is entirely uniform-driven in this engine: the sheet is one
uploaded image and the current frame reaches the shader as
`g_Texture{i}Rotation` / `g_Texture{i}Translation`. So no private format parsing
and no second animation clock were added. `prepareDraw` copies the scene's own
`SpriteAnimation` into the pass, exactly as `SceneToRenderGraph`'s
`CheckAndSetSprite` does, which keeps two layers sharing one sheet on independent
playback; the existing shared value updater advances it and writes the uniforms.
Pause, rate, loop, user properties and a `TextureFrame` override all come from
that updater and are not reset to the first frame.

`resolveTexture` now imports **every slot** of an image, not only the first, and
the current frame's `imageId` selects one at bind time. A sheet spread over
several images would otherwise have played its whole animation out of the first
sheet. A sheet whose frames name an image that was not imported fails prepare
with that reason rather than silently falling back to slot zero.

Sampler state, filtering, mip levels and the author's UVs are the ones the
texture and the frame rectangle already specify. Nothing here modifies an
author's UV to hide neighbour-frame bleed.

Inter-frame blending: for image layers this engine hard-switches frames — there
is no blend-weight uniform on that path, so there is none to invalidate on. The
`SPRITESHEETBLEND` combo is set only for particle materials, where the weight is
derived in-shader from per-particle lifetime in a vertex stream that is rewritten
every frame and is therefore never reusable anyway. Stated rather than invented.

The capability gate no longer refuses `isSprite` textures. A texture that is both
a sprite sheet and a video is still refused, with its own reason.

### Standard two-dimensional sprite particles

Simulation and drawing stay separate. Emitters, initializers, operators, random
state, lifetimes and sub-systems are untouched; `ParticleSystem::Emitt()` is
still driven by `SceneWallpaper`'s frame loop, and the Metal backend never emits,
ages or kills a particle. There is no GPU simulation and no second advance: this
backend consumes the CPU simulation's existing dynamic geometry, which is also
why particle birth, death, velocity, colour, size, rotation, the sequence /
random-frame animation mode and user properties are unchanged — the animation
mode is baked into the per-particle lifetime the generator writes, so a random
frame is drawn once per particle and not re-rolled per draw.

Dynamic buffers. `prepareDraw` allocates, per vertex array, one buffer per
in-flight frame at the mesh's **declared capacity** — the particle maximum is
fixed when the scene is parsed, so there is no growth path to get wrong — plus
the same ring for indices. Per frame the pass writes only the live byte range
into the slot that frame owns, which is bounded by the existing
`kFramesInFlight` semaphore, so the CPU never overwrites storage the GPU is
reading. The uploaded mesh revision is tracked per slot, so an unchanged
simulation re-uploads nothing. Stride, attribute list and submesh topology are
re-checked on every upload; a mesh that changed shape after preparation fails the
frame rather than being reinterpreted against the old pipeline. Zero live
particles draws nothing and is not a failure. Nothing was rebuilt into an
instanced data model.

Author semantics kept: layer order, particle order within the batch, blend mode
and opacity, transform and camera, material and texture, combination with this
round's sprite sheets, the supported effect chain, `renderScale` and the final
composition. No reordering by material to reduce draws, and no silent reduction
of particle count, lifetime or update rate.

Capability. The blanket `HasEmitters()` refusal is gone; the decision is per mesh
and rests on a **positive** marker rather than the absence of others. The parser
now records `PRENDER_SPRITE` on the mesh the sprite-particle generator owns and
`PRENDER_TRAIL` on a trail renderer's, next to the existing `PRENDER_ROPE`.
Accepted: one submesh, one vertex stream, one index stream, non-zero capacity,
triangles, carrying `PRENDER_SPRITE`. Refused, whole-scene, each with its own
reason: rope particles, particle trails, and every other per-frame geometry in
the engine — a text layer's card most obviously — because nothing has checked
the shape of its upload. Perspective particles and lit particles were already
refused by the camera and lighting rules.

### Still falls back as a whole scene

Rope particles, particle trails, puppets, perspective 3D, dynamic lighting,
non-triangle primitives, any other per-frame geometry (text layers), history
feedback effects, depth or MSAA targets, unsupported video formats, sheets that
are also videos, plain video wallpapers, shaders that do not translate, and
scenes loaded before Native Metal was selected. The lock-screen extension stays
on Compatibility.

### NV12 dual-plane direct sampling — not done, and why

*Done in round 10, as the controlled form of option (a) below. The rest of this
section is round 9's record of why it was not attempted then.*

The pre-conversion path from round 8 (NV12 → BGRA intermediate → author shader)
is unchanged and remains the only Metal video path.

The blocker is an ordering one, not an appetite one. Direct dual-plane sampling
requires the author's shader to contain two texture reads and the colour
transform, so the shader has to be *translated differently*. The only structural
injection point is the shader pipeline itself — `crates/shader`'s
`texture_sampling` codegen strategy, which already rewrites sampling calls
against the parsed declaration, plus a per-slot flag through
`RustShaderTextureInfo` and a second plane in the reflection. Editing MSL text
afterwards is exactly the fragile substitution this round was told not to do, and
substituting a generic copy for the author's shader is not equivalence.

But the decoded pixel format is not known when translation happens.
`CvPixelFormatForSoftwareFrame` converts software-decoded frames to BGRA while
VideoToolbox hands back NV12, so the same file is one or the other depending on
whether hardware decode succeeded — decided when the decoder opens, long after
`WPSceneParser` has consumed the combos, units and texture info that a
translation needs. Two designs resolve it, and which one is right is a decision
worth making deliberately rather than inside a feature round: **(a)** compile both
variants eagerly at parse for every shader that samples a video, doubling
translation work for those shaders but needing no deferred compile; or **(b)**
retain each such shader's translation inputs past parse and re-translate once the
first frame's format is known, paying a one-time compile at first frame and
needing a variant-aware pipeline cache. Both then need reflection to carry the
second plane, Metal to bind plane views from the existing `CVMetalTexture` /
`FrameLease` objects, and the round-8 SDR colour contract restated for
"filter-then-convert" versus "convert-then-filter", which are not
unconditionally equivalent once clamping, quantisation and differing chroma
resolution are involved.

Nothing was added that has no caller. There is no unused dual-plane shader in the
tree.

### Interface

No new experimental switches. The three existing rows carry it:

- **Scene renderer** — picks the backend; its description now names sprite-sheet
  animation and standard 2D sprite particles as drawn natively, and rope and
  trail particles as falling back.
- **Scene optimisation** — now says it applies to scene wallpapers on **both**
  renderers instead of "Compatibility only", and the note shown while a scene is
  running natively no longer claims the cache does not apply to it. It still
  reports the saved preference, not a reading from the renderer, and the
  explainer says both renderers implement it and neither reports a power saving.

  One asymmetry in when the switch bites, pre-existing and shared by both
  backends, is worth stating rather than discovering: the bridge deliberately
  does not rebuild or reparse a running scene when the setting changes, and the
  reuse table is only built while compiling a graph with the setting on. So
  turning it **off** takes effect on the very next frame, while turning it back
  **on** takes effect when that scene's graph is next compiled — a wallpaper
  change, a render-scale change or a restart. This round did not change that
  behaviour; the Metal implementation matches the compatibility one exactly.
  *Round 10 removed this asymmetry on both backends.*
- **Update only when the scene changes** — unchanged.

The per-wallpaper "Drawn by" list still reports the backend each running
wallpaper actually got, with the renderer's own fallback reason when it supplied
one.

### Tests added

- `metal_backend_test`: rope particles, particle trails and other dynamic meshes
  each refused with their own distinct reason; a video sprite sheet refused; a
  plain sprite sheet accepted; a standard sprite particle layer accepted; a
  particle layer with nothing alive yet accepted; a zero-capacity dynamic mesh
  refused. 20 cases, all green.
- `metal_scene_draw_smoke` (real Metal device, private textures, offscreen
  layer): an unchanged scene's second frame skips passes **and** reads back
  byte-identical pixels; moving the layer re-executes and changes the picture;
  the setting switched off skips nothing; geometry uploaded after the graph was
  compiled reaches the target, with empty frames before it neither failing nor
  drawing, across more frames than there are in-flight slots; a sheet steps on
  its own clock, is reused between steps and redrawn on a step, and is reported
  as advancing on its own.
  Also: re-enabling the setting after frames were drawn with it off redraws
  instead of reusing, and restores the picture its inputs describe. 8 cases, all
  green.
- `static_subgraph_cache_test`: alias chain resolution, cycle termination, and a
  reader of an aliased destination inheriting its source's dynamism. 24 cases,
  all green.

### Not verified

- No real wallpaper with sprite animation or particles has been drawn on a
  display, and nothing has been compared with the compatibility backend on real
  content. The sprite test's fixture shader binds no texture slot, so **no sheet
  was sampled by an author shader on the GPU** — what is proved there is the
  pick-up, the advance, the invalidation and the demand reporting.
- No real particle project ran through the Metal path; the dynamic-buffer test
  drives the upload path with a hand-filled mesh of the same shape.
- No power measurement of any kind. Reduced work is reported as passes not run
  and copies not encoded, never as a saving.
- The aliased-destination defect is fixed and unit-covered, but no scene in the
  local corpus is known to produce that exact shape, so the fix has not been
  observed changing a picture.

## Round 8 — native Metal scene backend, second version

Feature round, same discipline as rounds 5–7: implement, wire to production,
keep it building, fix what this round broke. No audit round, no benchmark work.
Native Metal stays a manual choice and Compatibility stays the default. Visual
output on real wallpapers, desktop behaviour and power are the user's to accept;
nothing below was seen on a display and nothing is a power claim.

| Feature | State | Default |
|---|---|---|
| Desktop poster from the Metal backend | Implemented on the production poster path | Always on, no setting |
| Backend created after the scene is parsed | Implemented; no Vulkan device is built for a scene that goes native | — |
| Effect chains, post-processing, same-frame layer links on Metal | Implemented; synthetic GPU coverage is partial (below) | Follows Scene renderer |
| Video textures inside Metal scenes | BGRA and 8-bit NV12 implemented; dual-plane fast path not implemented | Follows Scene renderer |
| Settings status: preparing / in use / fell back | Implemented | — |

### Poster

`MetalRenderInitInfo` now carries `wants_poster` / `poster_ready`, filled by one
conversion helper in `SceneRendererHandle`, so the Metal backend sits on the
same `DesktopWallpaperSync` request/delivery path as Vulkan. No Swift-side
capture was added.

The presentation block of `MetalRender::drawFrame` became
`Impl::encodeComposition(command, destination, scene)`. The drawable and the
poster both go through it, so a poster carries the final composition — fit,
fill or crop, user zoom, letterbox clear, horizontal flip — at the drawable's
size and pixel format, not the internal `_rt_default`. `MetalPosterCapture`
allocates a shared-storage texture only when `wants_poster()` answers true,
reads it back in the command buffer's completion handler, hands the bytes over
as stored with the BGRA flag, and releases the texture. The layer stays
`framebufferOnly`; no drawable is read or held, and there is no
`waitUntilCompleted`. One capture is in flight at a time; a second request
reports `Busy` without consuming the host's request, which is what bounds and
merges bursts. Surface release/reset, graph clear and destroy bump a
generation, and a capture from an older generation is dropped in the handler.

An idle or user-paused scene still answers. The host mailbox gained
`bind_poster_wake`; the render handler binds it to a new `POSTER_REQUEST`
command and unbinds before the info is replaced or the handler dies.
`MetalRender::ServicePosterRequest` re-composes the retained output image in a
command buffer of its own: no drawable, no scene passes, no `Tick`, no clock
restart. Before the first frame of the current graph it reports `NoFrameYet`,
and the first drawn frame polls the still-pending request. The mailbox is now
mutex-guarded because Metal delivers from a completion thread, and it credits a
delivery to the request id that was in flight when that capture started, so old
pixels cannot satisfy a newer request. A retried capture records its id twice;
already-answered ids are skipped at delivery so the leftover copy cannot swallow
the next request's pixels (found and fixed at integration).

Limits: on the compatibility backend a request made while the user has paused
is still served only on the next drawn frame — Vulkan can only poll inside a
frame and frame requests are dropped while paused. A `Submitted` poster also
costs one redundant on-demand frame from the generic post-command frame request.

### Backend creation

`SceneRendererHandle` starts empty. `INIT_VULKAN` (name kept: it is host
message vocabulary) only retains the surface description and dispatches scene
loading; `selectSceneBackend()` is the single creation site: native →
`createMetal` directly; prepare failure → failure recorded against the scene,
`createVulkan`, legacy published with the concrete reason; legacy → reuse a
working Vulkan renderer or create one. Offscreen and layer-less surfaces still
create Vulkan at init, so probes and tests are unchanged. Every forwarder is
safe on an empty handle, and an empty handle reports `UnknownInput` demand,
never "static". Settings that arrive before a backend exists are recorded and
applied by `reapplySurfaceState()` (which now also seeds `render_scale`);
surface reconfigure in that window just replaces the info. "Backend created",
`first_frame_ok` and the clock's running state remain three separate facts;
`owe_scene_wallpaper_backend()` returns -1 until a backend exists
(`SceneBackendSelection::created`), which the panel shows as preparing.

Scene parsing had exactly one renderer dependency: `LOAD_SCENE` waited for
`renderInited()`. It now waits for the surface description instead.

Found at integration and fixed by the lead: a failed native `drawFrame` used to
suspend the wallpaper. It now falls back to the compatibility backend as a
whole scene, rebuilds the graph and redraws, with the failure remembered so it
does not flip back.

Limit: a backend switch still tears one renderer down and builds the other; the
parsed scene is reused through `rebuildRenderGraph()`, GPU resources are not.
What this saves is start-up and switch work. It is not a measured power result.

### Effect chains and same-frame multi-pass

The blanket rejections for `post_processes`, `HasImgEffect`, `_rt_link_*`
textures and "samples the image it is drawing into" are gone. The one shared
render graph is lowered; there is no second effects parser and no substitute
filter. `MetalGraphRejection` walks passes in execution order and rejects only
what the draw path cannot do: an unknown node type; a read of a target that no
earlier pass wrote and a later one does ("the scene uses a history feedback
effect", which is what `_rt_MipMappedFrameBuffer` scenes hit); an unbroken
read-while-write in one pass; depth or MSAA targets.

Now executed natively: sequential effect chains with their ping-pong targets,
link textures, the graph's own read-while-write break copy, post-process
passes, per-pass camera override, effect visibility, and multiple writers of
one target with the graph's load/clear decisions. Target sizing mirrors
`VulkanRender::setRenderTargetSize` — screen-bound, author-sized, `bind`
fractions and mip levels — so an author's effect downscale and the user's
renderScale compose rather than flatten. Unequal copies are a real resampling
pass (pipelines built at compile time), and a copy that cannot be encoded fails
the frame instead of being skipped. Mip levels are generated after the last
writer before each reader. Every texture key keeps its own texture, so an
intermediate outlives its last consumer trivially; nothing is pooled.

Demand: effect and post-process passes are custom-shader passes, so the
existing reflection walk covers them, and an animated effect keeps the scene
ticking. The R03 static-subgraph cache remains compatibility-only and was not
ported; the settings row says so while a scene runs natively.

### Video textures

`MetalVideoTextures` opens sources through `AcquireVideoTextureSource`, the
same registry call the texture cache makes, so packaged sources, playback
state, loop and resync behaviour are shared and each layer keeps independent
playback (D01 sharing applies only where it already did). BGRA frames are
imported zero-copy through a `CVMetalTextureCache` on the renderer's device.
NV12 video- and full-range frames get one compute conversion per frame
generation, encoded into the frame's own command buffer into a three-slot
private destination ring; colour parameters come from the existing derivation
via the new `AppleVideoFrameColorParams`. The older pool helpers were not
reused because `CreateConvertedMetalTexture` blocks on `waitUntilCompleted`.
Pixel buffers, Core Video wrappers and destinations are owned by a block the
completion handler holds, never by the object. Pause keeps the last texture;
there is no new clock, and content pacing stays off. A playing video reports
`DynamicReason::VideoInput`, evaluated per call so pause changes it without a
recompile.

Anything else — 10-bit, P010, HDR, other chroma — fails `prepare` with the
format named and the whole scene falls back; a decode or import failure
mid-playback fails the frame and takes the fallback above. Plain video
wallpapers (`single_video_source`) and sprite sheets still reject.

### Still falls back as a whole scene

Particle emitters, dynamic lighting, perspective cameras, per-frame mesh
rebuilds, non-triangle primitives, puppets, sprite sheets, plain video
wallpapers, history-feedback effects, depth/MSAA targets, unsupported video
formats, shaders that do not translate, and scenes loaded before Native Metal
was selected. The lock-screen extension stays on Compatibility.

### Not done, and not verified

- The direct dual-plane Y/UV sampling fast path is not implemented; NV12 always
  takes the GPU pre-conversion.
- No effect chain, post-process, video scene or Metal poster has been seen on a
  display or compared with the compatibility backend on a real wallpaper.
- GPU coverage of the effect work is partial: the smoke test proves
  intermediate sizing, the equal-size blit, the resampling copy and same-frame
  consumption by readback, but not an author shader sampling a link target,
  mip generation, or a camera override.
- Video texture tests use synthetic IOSurface-backed frames through an injected
  source; no real decoder ran through the Metal path.
- The lazy creation path, the poster wake and the draw-failure fallback are
  compiled and reasoned; none has run in a desktop session.


Three features. Whole-scene on-demand updating and the user-asset relocation
are complete. The native Metal scene backend is the third and is reported
separately at the end of this section, because it has a different completion
state and must not be described as if it shipped alongside the other two.

### P02 — a scene that has nothing to do stops ticking

Round 6 let the renderer skip redrawing render targets whose pixels had not
changed. It did not stop the frame loop: scripts, animations, the particle
step, the video clock and the whole DRAW message still ran at the configured
rate. This round stops that loop outright for scenes that can be shown to have
no continuing update need.

**The two questions are kept separate on purpose.** "This target's pixels can
be reused" and "this scene's runtime can sleep" are different, and answering
the second with the first would stop scripts, sound and timelines on a scene
whose image merely happened to be still. A scene may idle only when *both* the
renderer's shader analysis and the runtime's own registries report nothing that
advances on its own.

What the runtime contributes comes from
`SceneRuntimeContext::DescribeTimeAdvancingWork`, which mirrors `Tick` loop for
loop: an unpaused video texture with a positive rate, a scalar/zoom/material
alpha animation, a scripted value or SceneScript, a node transform or material
constant bound to a dynamic value, a bound text layer, a puppet layer, or a
sound layer whose stream is still held. What the renderer contributes is the
union of every pass's reflection-derived dynamic inputs, already computed for
round 6's reuse analysis and now published as
`VulkanRender::ShaderUpdateDemandReasons()`.

Two of the renderer's reasons are deliberately *not* carried across:
`PointerUniform` and `RuntimeImage`. Both make a target ineligible for pixel
reuse, but neither means the scene changes on its own — they mean it changes
when something happens. A pointer-reactive scene sleeps and is woken by pointer
movement.

**The clock genuinely stops.** `ThreadTimer` gained an idle state that waits on
its condition variable with no deadline at all, rather than a very long
interval: a long interval still wakes to discover there is nothing to do.
`WakeOnce` is a latch taken under the same mutex the waiter re-checks, so a
wake that lands between the decision to sleep and the wait itself still
produces exactly one frame instead of being lost. `WakeAt` keeps a single
appointment for content that knows when it next changes, and the appointment is
consumed once rather than left to spin on an expired deadline.

**Waking is done in one place, not at every call site.** Every render-handler
command except the draw itself requests a frame, so a command added later wakes
the scene by default; forgetting produces one redundant frame rather than a
wallpaper that stops responding to a setting. Pointer input is the one event
that never passes through the looper, so it wakes explicitly — and only when a
pass actually samples the pointer, because waking on every mouse move would
give a still wallpaper a frame rate equal to the pointer sample rate.

A request is dropped while the clock is stopped, so no event can resume a
wallpaper the user paused.

**Conservative by construction.** The demand starts at `UnknownInput` and is
only ever narrowed by evidence. No scene, no renderer, no compiled graph, no
runtime, an unrecognised pass kind, or no completed first frame all keep the
scene running. Idling before the first good frame would leave whatever was on
the surface before the wallpaper started.

Default off, in Settings → Performance → Scene wallpapers.

### Live status, not a restated preference

The panel shows what each running scene is actually doing: continuously
updating with the reasons listed, waiting for events, waiting for a deadline,
paused by the user, suspended by policy, not applicable, or unknown. A scene
that is running but cannot be read is emitted as a row with `unknown`, never
omitted and never shown as `continuous` — "running but unreadable" and "nothing
running" are different facts.

This is published through direct pull-only C getters, not through the renderer
counters. Counters are opt-in diagnostics, and building a settings snapshot
must not switch diagnostics on as a side effect. Reading costs a few relaxed
atomic loads taken under the registry lock that also keeps the scene alive for
the duration of the read. No timer, display link or periodic task was added.

`unknown_input` is surfaced verbatim rather than folded into a generic message:
it means the renderer found an input it could not account for and therefore
kept the scene running, and it is the whole diagnosis when a user asks why
on-demand updating did nothing for their wallpaper.

### User assets — the store moved, the bridge did not

Round 6 staged user-picked files inside the wallpaper package, at
`<project>/.mwe-user-assets/`. That tied user data to a directory Steam can
replace. The canonical store is now `<support>/UserAssets/<wallpaperId>/…`
with a manifest recording the asset id, the user's original path, size, mtime,
a content digest and the import kind. Identity is the stable library id plus
the property id plus the digest, never the wallpaper's display name or entry
file name, so a Workshop update or re-download does not orphan a selection.

**The in-project directory still exists, and this is a deliberate consequence
rather than an oversight.** A `WKWebView` may only read below a root that is an
ancestor of its entry file; files outside it are blocked, symlinks are resolved
and refused, and hard links load. There is no scheme handler or local server
for wallpaper pages, and adding one would change the page origin and break the
`'file:///' + value` contract author pages rely on. So `.mwe-user-assets` is
demoted to a derived, regenerable bridge of hard links onto the store's copies,
holding no bytes that exist nowhere else. Deleting the whole bridge loses
nothing; deleting and re-downloading the project loses nothing. Data flows
store → bridge only.

Migration publishes into the store first, then updates references, and never
deletes anything in the old location. A failure leaves the old reference
working. It runs once, recorded in the manifest.

An asset whose original source is gone but which is present in the store stays
usable and is served from the store. One missing from both is reported as
missing rather than silently cleared.

`scripts/clean.py` keeps `--user-assets` for the regenerable bridge and gains a
separate, explicit flag for the managed store that says it destroys imported
files. Neither the default run nor `--all` touches the store.

### R04 — a native Metal scene backend that actually draws

`src/Scene/MetalRender/` is a real Metal renderer, not a route to one. It
builds `MTLRenderPipelineState` objects from the author's own shaders,
translated to MSL, and issues `drawPrimitives` / `drawIndexedPrimitives` from an
`MTLRenderCommandEncoder`. Pipelines and libraries are built in the prepare
step, never inside a frame; frames are bounded by a `dispatch_semaphore` with a
completion handler, and there is no `waitUntilCompleted` on the per-frame path.

**MSL comes from the existing compiler, not a new one.** `crates/shader` already
parsed author GLSL with naga and emitted SPIR-V; it now also emits MSL from the
same validated module. Bindings are explicit — `fake_missing_bindings` is off,
and a resource the map cannot cover fails the compile instead of silently
inventing a slot. Entry points are read from the emitted metadata because naga
renames `main` to `main_`. The program cache key includes the target, so a
SPIR-V entry can never be served for an MSL request.

**No clip-space flip is applied, in either direction.** The Vulkan path uses a
negative-height viewport, which is not an extra transform: it is what makes
Vulkan's +Y-down NDC behave like Metal's +Y-up NDC against a top-left-origin
target. Both produce the same window mapping, so the fold matrix is the
identity. It is derived from both viewport conventions rather than hardcoded,
and the test compares full author-space → window-pixel mappings, so it fails if
someone adds a flip *and* if someone deletes the derivation. Cull mode is set to
none explicitly, with the reason written down: a future "optimisation" that
enabled back-face culling would interact with any flip that was ever added.

**What it draws, proven by pixels.** `metal_scene_draw_smoke` parses a real
project, translates its shaders, compiles them with `newLibraryWithSource:`,
draws three frames and reads the target back, asserting the target holds pixels
only the author's fragment shader could have produced. Suppressing the draw call
fails it — checked by doing exactly that.

v1 draws 2D image layers, layer order, translate/scale/rotate/opacity, the five
blend modes, basic texture sampling, the author canvas with fit/fill/crop, and
internal renderScale. Particles, puppets, video textures, sprite sheets,
feedback passes, unrecognised pass kinds and shaders that fail translation fall
back — as a whole scene, with a specific reason the settings pane shows
verbatim. A pipeline that fails to build does so later, when the render graph
is compiled; that also falls back to the compatibility backend and records the
failure against the scene so it cannot flip-flop. The boundary is what the code implements, never a
wallpaper-ID list.

**Routing is in the production path.** The surface always starts on the
compatibility backend, because the backend choice needs the parsed scene and
that does not exist at init. Once the scene arrives, `SelectSceneBackend`
decides, and `SceneRendererHandle` switches by destroying one renderer before
creating the other — a layer has exactly one drawable producer, so holding one
backend means not holding the other, structurally rather than by convention. A
prepare failure is recorded against that scene so it cannot flip-flop, and the
compatibility backend is re-established rather than leaving the surface with no
renderer. Scaling, flip, playback rate and pause are re-applied after a switch:
a wallpaper the user paused must not start playing because they changed a
renderer preference.

The Metal backend reports its update demand in the same vocabulary as the
Vulkan one, so a static Metal scene participates in on-demand updating. A
tautological assertion was found there — `EXPECT_TRUE(reasons != 0 || true)`,
under a comment promising a check that was not being made — and replaced. To be
precise about what that did and did not find: the original derivation was
**not** shown to be wrong. It reported zero for the test fixture, and zero is
the correct answer for that fixture, whose shader binds no frame-varying
uniform. The replacement is a hardening, not a caught defect: demand is now
derived from the Metal backend's own pass descriptions rather than from render-
graph pass objects, and a compiled graph that yields no shader pass reports
`UnknownInput` instead of zero. The test now asserts the property that would
catch the dangerous case — an unanalysed renderer must report `UnknownInput`,
never a value a caller could read as "nothing changes".

### What is not done

- **No Metal frame has ever been presented to a screen.** The evidence is an
  offscreen readback in a test. Visual correctness on a real wallpaper, on a
  real display, is unobserved, and the production switch path compiles and is
  reasoned but has never run on a desktop.
- No power comparison between the two backends was measured. Nothing here is a
  power claim.
- **Metal-backed scenes produce no desktop poster.** `wants_poster` /
  `poster_ready` are polled only by the Vulkan draw path, and the Metal
  `MetalRenderInitInfo` does not carry them, so a scene routed native leaves the
  desktop poster stale. The backend and fallback text in the settings pane must
  not be read as implying parity here.
- The lock-screen extension keeps the compatibility backend.
- Web wallpapers have no lock-screen support and this round did not add any.
  That combination is reported as not applicable, never as failed.
- No scene was observed stopping its clock on a real wallpaper: there is no
  desktop session here. No power measurement was taken and no saving is
  claimed. On-demand updating removes work; whether that is visible on a power
  meter is the user's to measure.
- Deadline-driven updating (`WaitingForDeadline`) is plumbed end to end but
  nothing registers a deadline yet; a bound text layer keeps the scene
  continuous rather than waking on the minute.

## Round 6 — scene optimisation, web audio/media, user files

Same scope discipline as round 5: implement, wire to the UI, keep it building,
fix only what this round broke. Visual, real-wallpaper, desktop-behaviour and
power acceptance remain the user's and are not claimed here.

### What now exists

| Feature | State | Default |
|---|---|---|
| R03 static subgraph reuse | Implemented for the legacy scene backend | **On** |
| R03 redundant copy removal | Implemented: dead copies and alias-able copies | **On** (same switch) |
| Web audio listener | `wallpaperRegisterAudioListener`, real 64+64 spectrum | Per wallpaper, on |
| Stereo capture and analysis | Stereo CoreAudio tap, two independent FFTs | Automatic |
| Web media listeners | All five official listeners | Off, opt-in |
| `file` / `directory` properties | Implemented with native picker and staging | Per wallpaper |
| `wallpaperRequestRandomFileForProperty` | Implemented | Per wallpaper |
| `fetchall` directory change events | Implemented over FSEvents | Per wallpaper |

### R03: what is reused, and what makes it safe

The unit of reuse is a **render target**, never a single pass. Passes writing
one target are batched into a single render pass whose first entry may carry a
clear, so skipping part of a batch would either lose a draw or composite one
twice. All writers of a target are skipped together or not at all.

A target is reusable only when every one of these holds:

- No writer binds a self-advancing uniform. This comes from the shader
  reflection captured at `InitUniforms`, exposed as
  `IShaderValueUpdater::FrameVaryingUniforms`, **not** from searching shader
  source for `g_Time`. The default implementation reports every kind, so an
  updater that does not track reflection can never make a pass look reusable by
  omission.
- No writer has a video texture, a dynamic mesh, a multi-frame sprite, or an
  input image the runtime may swap underneath it.
- It does not read a target it also writes, directly or through a cycle.
  Feedback and cycles lose cacheability rather than read a stale input.
- Every input target is itself reusable; non-reusability propagates downstream
  to a fixpoint.
- Its allocation is **pinned**. The render-target pool aliases unpinned images
  to other keys, so an unpinned target's previous pixels are not guaranteed to
  still be there. Pinning is budgeted at 192 MiB per renderer; beyond that a
  target keeps taking part in the pool and simply re-renders.

Per frame, each pass contributes a sample folding its node and parent
transforms, material constants, mesh revision, sprite frame, visibility and
target extent. A target's signature combines its writers' samples with its
inputs' signatures, so a change at the head of a chain invalidates everything
below it.

Scripts, animations and the scene runtime still tick every frame. Only GPU
recording and the uniform upload are skipped, so no script or event side effect
is lost.

### R03: which copies are removed

Two compile-time rules, both conservative:

- **Dead** — nothing anywhere reads the destination. The final blit's read of
  `_rt_default` counts, so the presented target is never mistaken for an unread
  result.
- **Alias** — the source is never written again after the copy, the destination
  is never written by anything else and never read before it, the two agree on
  the texture key the pool itself uses for interchangeability, and the copy is
  not the step that builds a mip chain. The destination then shares the
  source's image.

A copy that exists to break a feedback loop always has a later writer of its
source, so it is never eliminated.

### Audio: genuinely stereo

The CoreAudio tap was previously created with
`initMonoGlobalTapButExcludeProcesses`, and the analyser wrote
`left64 = right64 = average64`. Delivering that to a page as a 64+64 stereo
spectrum would have been a duplicated mono signal presented as stereo.

The tap is now stereo, the resampler keeps both channels through 12 kHz /
200-frame blocks, and the analyser runs two independent FFTs.
`AudioSpectrumSnapshot.stereo` records **how the PCM was submitted**, not
whether the two halves happen to differ: stereo content that is identical in
both channels is still stereo, and a mono source is never described as stereo.
`AudioFrameConsumer::submit_mono_audio_frames` became a required trait method
precisely so no default could duplicate mono into fake stereo.

The mono fallback is reachable — an absent selector, a nil initialiser, or a tap
whose stream format reports fewer than two channels — but was not exercised,
because this machine takes the stereo branch.

### User files: where they are staged, and why there

A `WKWebView`'s read-access root must be an ancestor of the page's entry file;
a non-ancestor root fails the navigation outright. Files outside the root are
blocked, **symlinks into the root are blocked** because WebKit resolves them,
and **hard links load**. All four were measured, not assumed.

So anything a page can read has to live inside the project tree. User
selections are hard-linked (copied across volumes) into
`<project>/.mwe-user-assets/<propertyId>/`, removed by clearing the property or
by `python3 scripts/clean.py --user-assets`. No authored wallpaper file and no
user original is ever modified. A read-only project folder surfaces a specific
reason rather than failing silently.

Round 7 changed where the bytes live without changing any of the measured
facts above: the app's own copy is now the canonical one, under
`<support>/UserAssets/`, and `<project>/.mwe-user-assets/` became a derived
bridge onto it that exists only to satisfy the read-access rule. See
`docs/features/web-wallpapers.md`.

The value handed to a page is the staged absolute path with its leading `/`
removed and only `%`, `#` and `?` escaped, so the page's own
`'file:///' + value` forms a valid URL. Spaces, CJK, `+`, `&` and `'` were
verified to load unescaped; over-escaping would break pages that use the value
as a plain path.

### Known gaps this round does not close

- Scene optimisation is legacy-scene-backend only. Native video, plain video
  and web wallpapers are unaffected.
- The panel reports the **saved** scene-optimisation preference, not a
  read-back from the renderer.
- Media integration depends on the private `MediaRemote` framework, which is
  entitlement-gated on macOS 15.4 and later. It will most likely report
  unavailable. That is from the framework's documented behaviour and a symbol
  check — the API was never called and the runtime outcome is unobserved.
- The panel reports audio delivery and media availability from the running web
  host, so "you switched it on", "the page actually asked for data" and "the
  panel cannot tell" are three distinct states rather than one sentence. With
  no desktop wallpaper running the keys are absent and the panel says it cannot
  tell; it never reports "not delivering" from an observation it did not make.
- The lock-screen extension is sandboxed and cannot read staged user assets.
- `owe_audio_current_spectrum_128` clamps bins to `[0, 1]`. The official
  documentation says values may occasionally exceed 1.0; the clamp is
  pre-existing scene-path behaviour and was left alone.
- Whole-scene sleep when everything is static is not implemented. This round
  removes repeated GPU work for static subgraphs; scheduling is separate.

## Round 5 — three features, shipped and operable

Round 5 was scoped to delivery, not audit: implement, wire to the UI, keep it
building, fix what this round broke. Visual, real-wallpaper and power acceptance
are the user's, and are explicitly not claimed here.

### What now exists

| Feature | State | Default |
|---|---|---|
| R01 internal render scale | Implemented end to end for the legacy scene backend | 100%, no change |
| Video backend selection | Implemented, with the actually-running backend reported per display | Compatibility |
| Battery quality profile | Implemented, explicit opt-in | Off |
| Content pacing | Promoted from environment variable to a setting | Off |
| D01 shared video decode | Implemented for the legacy pure-video path | Off |

### R01: what actually changed size

Three sizes are now distinct where two were conflated:

- **Output** — the swapchain. Untouched by the scale.
- **Authored canvas** — `Scene::scene_extent`, latched once when the scene is
  built. Presentation layout, fit/fill, user zoom, crop and cursor mapping all
  resolve against this, so the hit test cannot drift when the raster shrinks.
- **Internal raster** — `scene_extent x render_scale`. Sizes `_rt_default`, every
  screen-bound target at its own relative scale, and the author-sized effect and
  scratch buffers.

`ResolveSceneSourceExtent` previously read `_rt_default`'s size, which is exactly
what made a naive implementation move the letterbox: shrink the default target
and the presentation layout would have followed it. The latched extent is what
separates the two.

Sizes are derived from a latched `authored_width`/`authored_height` per target
rather than from the target's current size, so 100% -> 50% -> 75% -> 100% returns
the exact original numbers instead of drifting a rounding step each way. Pinned
by `render_scale_test.ReturningToFullScaleRestoresTheExactAuthoredSize`.

`g_Screen` and `g_TexelSize` now describe the raster, not the canvas — a
half-scale buffer must report half-scale texels or every neighbour-tap effect
samples at the wrong step. `g_TexelSize` had never been set in production at all
and sat at a hardcoded 1/1920 x 1/1080; it is now correct for every canvas size.

Changing quality does not restart the wallpaper. `VulkanRender::ApplyRenderScale`
quiesces, destroys only the prepared pass state, drops only render-target
textures through a new `TextureCache::ClearRenderTargets`, resizes and
re-prepares. The parsed scene, the render graph, uploaded images, animation time
and live video decoders all survive. The pre-existing `clearLastRenderGraph`
would have destroyed `m_video_tex_map` and reopened the file.

**Not applicable, and reported as such rather than silently ignored:** plain
video wallpapers, native video, and web wallpapers. A video render target holds a
frame already decoded at its own resolution, so shrinking it resamples twice and
makes nothing upstream cheaper; those targets are marked `media_sized` and the
panel disables the control when nothing running can honour it.

**Geometry, not a power claim.** 75% per axis is 56.25% of the pixels. Text
sharpness, decode cost and WindowServer compositing do not scale with it. No
power measurement was taken.

### D01: what is shared and what is not

Shared: one decoder instance, one decode thread, one frame queue. Not shared:
the GPU import, visibility, pause, target frame rate and presentation resources
— each surface renders on its own Vulkan device, so those could not be shared
even if it were desirable.

Sessions are keyed on **canonical path plus size and modification time**. Keying
on the project-relative name would have been wrong in a way that shows: for video
projects that name is the entry file, so two unrelated wallpapers both containing
a `video.mp4` would have shared one decoder and one display would have shown the
other's video. Pinned by
`shared_video_session_test.SameFileNameInDifferentProjectsIsNotShared`.

Each consumer holds its **own retained reference** to the frame it is showing,
taken under the decoder's own lock. Without it, one surface promoting a new frame
would free the buffer another surface was still importing, and a paused surface
could not hold the frame it was displaying. One consumer drives the clock; the
others' scene times are ignored, which is what stops two slightly different scene
clocks from seeking the shared decoder back and forth every frame.

A consumer that asks for a playback rate the session is not running is split onto
its own decoder rather than forced onto someone else's timeline. In-memory
package payloads are never shared: they have no path identity and could not be
reopened for a split.

**No audio risk on this path, and not because it was solved.** The legacy
pure-video source decodes no audio at all — `videoAudioEnabled` is set and never
read. The native AVFoundation backend does play audio and is untouched by D01.

### Tests added, and one removed for being vacuous

`render_scale_test` (8) and `shared_video_session_test` (8), both wired into
`scripts/check_renderer.py`.

`PausingOneSurfaceLeavesTheOtherPlaying` failed on first run. The cause was the
test, not the product: a tight sync/refresh loop only advances the requested
timestamp, while the decoder fills its queue on its own thread, so nothing is
ever promoted. A control against an unshared source failed identically, which is
what identified it. The fix was to let real time pass between steps.

That same mistake had made `AFrameStaysValidAfterTheDecoderMovesOn` pass for the
wrong reason: the decoder never moved on, so the retention it claimed to test was
never exercised. It now asserts that the driving consumer really advanced past
the held frame before checking that the held frame survived.

### Known limitations

- Render scale applies to the legacy scene backend only.
- `_rt_shadowAtlas` and the fixed-fraction scratch buffers follow the scale with
  everything else; shadow resolution therefore drops with the tier.
- Shared decode is legacy pure video only. Native-backend wallpapers keep one
  player each.
- Text sharpness, pixel-exact shaders and heavy post-processing at 50% are the
  cases most likely to look wrong, and none of them has been looked at.

## Round 4 — the six questions this round was set, answered

**0. Was this round's own work correct?** No — not on the first pass, and the
list matters more than the headline. Fifteen further defects were found in it by
review and measurement after it was first reported done, including one that
reopened the accounting hole the round existed to close, two that could leave a
display showing nothing at all, one that could orphan a window on the user's
desktop, and one attempted fix that deadlocked the renderer on real hardware.
All fifteen are fixed and pinned; they are enumerated
below rather than folded silently into the sections above.

**1. What does the 81 MiB peak cover, and is the budget's accounting correct?**
It covered the idle reuse cache and nothing else — one 6144x3456 BGRA8 slot.
Destinations on loan and destinations the import had just allocated were both
invisible, so the figure was low by a factor of four and the ceiling could not
constrain the live set even in principle. It is now a three-state,
mutually-exclusive ledger; the same workload's live peak is 339,738,624 B. See
*R02: what the 81 MiB peak actually covered*.

**2. Which real media is accepted or refused, and on what basis?** Whole-number
24/25/30/60 and NTSC 24000/1001, 30000/1001, 60000/1001 are accepted at or
above their own rate; anything whose *fastest declared interval* exceeds the
target is refused, including 60 at 59 and 29.97 at 29, which round 3's
one-frame slack admitted. Interlaced and unbounded-rate tracks are refused
rather than guessed at. The basis is `minFrameDuration` compared as a rational
plus `nominalFrameRate` with representation-error slack only, whichever is
higher. Read-back values per fixture are tabulated.

**3. Is a rejection re-evaluated once its cause changes?** Yes. Refusals are
keyed on an admission key over media path, file length, mtime and target fps,
and retained per `(wallpaper id, admission key)` so one display's refusal cannot
erase another's. Raising the target, restoring a supported setting, or replacing
the file re-offers the wallpaper; a refusal carrying a stale key is dropped
rather than recorded. A *running* player is re-admitted too, not just a pending
offer. Fifteen bridge cases and five host cases cover it.

**4. Which real player and poster paths are verified?** Load, readiness,
playback-time advance, two loop boundaries, poster from the playing item after
those boundaries with zero generator fallbacks, concurrent-request coalescing,
paused poster without resuming, stale-request suppression, and balanced
create/release counters — all through the production `NativeVideoPlayer`
against real files, in the opt-in media suite. Playback *failure* after a
successful admission now hands the wallpaper to the scene engine instead of
leaving a black display, checked in the host suite separately from metadata
refusals.

**5. Build and test results.** Renderer gate exit 0, `playback_gpu_test` 36/36
on real Metal, `video_conversion_budget_test` 23/23, cargo workspace green with
257 bridge cases, media suite 7/7, Release app and extension built. The app
suite is 362 tests with **one pre-existing failure** in the control panel's
web-layout test, which this round did not touch and does not claim to fix.

**6. What still needs an authorized desktop session?** Everything about actual
presentation: first frame on a screen, loop and pause behaviour as seen, poster
on the desktop, single- and dual-display visibility, the refusal handing back
to the scene engine without oscillation, and only then a paired power
measurement. The minimum ordered checklist is at the end of this round's
sections.

## Round 4 — status by task ID

| ID | implementation | automated verification | runtime verification | visual | power |
|---|---|---|---|---|---|
| R02 live ledger + domain | done | `video_conversion_budget_test` (37), `playback_gpu_test` (39, real Metal) | — | synthetic GPU pixel comparison only | — |
| R02 counters and diagnostics | done | `RuntimeDiagnosticsReportTests` (8) | — | — | — |
| V04 frame-rate admission | done, off by default | `NativeVideoAdmissionTests` (15, real media) | — | — | — |
| V04 rejection re-evaluation | done, off by default | `native_video_routing` (15, bridge) | — | — | — |
| V04 host routing, re-admission and poster staleness | done, off by default | `NativeVideoWallpaperHostTests` (25) | — | — | — |
| V04 real player and poster | done, off by default | `NativeVideoPlayerMediaTests` (9, opt-in, real decode) | — | — | — |
| I01 | unchanged | — | — | — | — |

"runtime verification" is empty on every row and that is the honest state: no
wallpaper has been displayed by this backend on a real desktop, in this round
or any previous one. The media tests decode real files and read real pixels,
which is more than round 3 had, but an `AVPlayerLayer` that never joins a
window's layer tree presents nothing to a screen.

## Round 4 — commands actually run

| Command | Result |
|---|---|
| `python3 scripts/test.py` | 377 tests, **1 failed** — `ControlPanelLayoutTests/testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes`. See below. |
| `python3 scripts/check_renderer.py` | Pass, exit 0; 10 cases `pixels_equal=true`, 0 diagnostics, reload cycles 0 |
| `cargo test --release --workspace` | Pass; 969 cases total, `wallpaper-bridge` 264 including `native_video_routing` (19) |
| `playback_gpu_test` | Pass, 39/39 on a real Apple M3 Max — Metal NV12 conversion, readback and 6144x3456 imports all executed |
| `video_conversion_budget_test` | Pass, 37/37 (CPU only) |
| `MAC_WALLPAPER_ENGINE_MEDIA_TESTS=1 … NativeVideoPlayerMediaTests` | Pass, 7/7 with real decode |
| `python3 scripts/build.py --renderer-only` | Pass; bindings carry `admissionKey`, the new `rejectNativeVideo` signature and `videoConversionLiveBytes` / `videoConversionPeakLiveBytes` |
| `python3 scripts/build.py --configuration Release` | **BUILD SUCCEEDED**; app and embedded `MacWallpaperExtension.appex` |

**The one failure is outside this round.**
`testDiscoverGridReportsFullRowsAsPageSizeAndFollowsResizes` fails
deterministically, in isolation as well as in the suite, asserting that a full
Discover page does not scroll (`overflow: 52` px at `tile: 166`, 5 columns, 4
rows, in a 960x640 web view). It is a `WKWebView` layout arithmetic check over
`WebUI/`. Nothing this round touched can reach it: no file under `WebUI/`,
`App/Views/ControlPanel/` or `Tests/Unit/Panel/` was modified, and the FFI
change adds a field to a native-video record the panel never reads. Round 3
recorded this suite green at 325 tests, so it regressed between then and now
for a reason outside this tree — most plausibly the WebKit in the current
toolchain. It is reported rather than worked around, and it is **not** claimed
as fixed or as passing.

### Round 4 build identity

Round 4 started from `c0461f7d88450a26aae51321c6512b94b6f672a6` on `main` with
a genuinely clean tree: `git status --porcelain --untracked-files=all` was
empty, so round 3's reported results correspond exactly to that commit. Nothing
was reset, stashed, reverted, committed or pushed, and no history was rewritten.

The tree now carries 32 modified paths and 5 untracked ones. The untracked
files are source, not scratch, and belong to this round's record:
`App/Services/NativeVideo/NativeVideoAdmission.swift`,
`App/Services/NativeVideo/NativeVideoPlayer.swift`,
`Tests/Unit/NativeVideo/NativeVideoAdmissionTests.swift`,
`Tests/Unit/NativeVideo/NativeVideoPlayerMediaTests.swift` and
`Tests/Unit/NativeVideo/SyntheticVideoFixture.swift`. A `git diff` alone would
not describe what was built.

---

## Round 4 — R02: what the 81 MiB peak actually covered

Round 3 reported "peak resident pool bytes 84,934,656" for a 6144x3456 clip
over 17 imports. Both halves of that phrase were wrong.

**It was a cache statistic, not a memory figure.** `peak_pooled_bytes` was the
high-water mark of the *idle* reuse pool: exactly one 6144x3456 BGRA8
destination (6144 x 3456 x 4 = 84,934,656, and `MTLTexture.allocatedSize`
matches the nominal product for this shape). Three things were invisible to it:

- **A destination on loan left the books entirely.** `Take` subtracted the
  slot's bytes from the pooled total and pushed a bare `void*` onto a loan
  vector with no byte accounting at all.
- **A freshly allocated destination never reached the books.** The import
  allocated it inside `CreateAppleVideoFrameLease`, and the budget first heard
  about it when the frame that owned it died and offered it back. Between
  allocation and first recycle the process held 81 MiB per frame that nothing
  counted.
- **Admission was tested against cached bytes only**, so the ceiling could not
  constrain the live set even in principle.

**It was also not residency.** `resident` is now banned from this code. These
are allocation ledgers: the budget cannot observe paging, purgeable state or
compression. Decode `CVPixelBuffer`s and their `IOSurface`s, Core Video plane
wrappers, Vulkan images, the swapchain, staging buffers and render targets are
all outside the ledger, and the headers say so. A total here is a lower bound
on what video playback costs, never the whole cost.

### The ledger now

One destination is in exactly one of three states and its measured bytes are
counted in exactly one place:

| State | Accessor | Meaning |
|---|---|---|
| Available | `available_cached_bytes()` | idle in the reuse pool |
| CheckedOut | `checked_out_bytes()` | handed to an import that has not yet reported GPU reference |
| AwaitingGpu | `awaiting_gpu_completion_bytes()` | referenced by a live imported frame |

`total_live_conversion_allocation_bytes()` is the sum of exactly those three,
`peak_live_conversion_allocation_bytes()` its running maximum, and
`reserved_estimate_bytes()` is a deliberately separate fourth quantity —
granted-but-unmade allocations, which are intents, not allocations, and are not
part of the live total. They still count against the ceiling, because an intent
the caller is about to act on is about to become real.

`CreateAppleVideoFrameLease` now reports the destination it allocated through a
borrowed out-parameter, so the ledger keys on one identity from allocation to
release. That is the hole that made the old number low by a factor of four.

### The same workload, measured again

| Figure | Round 3 | Round 4 |
|---|---|---|
| peak cached (Available only) | 84,934,656 | 84,934,656 |
| peak live (all three states) | not measured | **339,738,624** |
| destinations created | 4 | 4 |
| destinations reused | 13 | 13 |

Reuse is unchanged, and that is the point: the allocation behaviour round 3
reported was already correct, and what was wrong was the figure used to
describe the memory it cost. (An earlier draft of this table showed
"17 created / 0 reused" as the round 3 baseline. That was a misattribution on
my part: 17 allocations with zero reuses was a *regression introduced and then
fixed inside this round*, described below — never round 3's behaviour. Round 3
measured 4 created and 13 reused over 17 imports, and so does round 4.)

339,738,624 is four 84,934,656-byte destinations alive at once: three held by
the imported frames `TextureCache` retains and one checked out to the import in
progress. The per-generation trace, emitted by `playback_gpu_test` as a
`RecordProperty` and read back from its XML:

```
gen=1  allocate  live=169869312  cached=0  in_flight=2  peak_live=169869312
gen=2  allocate  live=254803968  cached=0  in_flight=3  peak_live=254803968
gen=3  allocate  live=339738624  cached=0  in_flight=4  peak_live=339738624
gen=4..16 reuse  live=339738624  cached=0  in_flight=4  peak_live=339738624
                                           peak_cached=84934656
```

Four allocations, thirteen reuses, zero refusals. `created` is a cumulative
total and is not a concurrent count; `in_flight` is the concurrent figure, and
the two are reported separately precisely because round 3 read one as the other.
`cached` reads 0 at the end of each update because the same update took the
cached slot straight back out; `peak_cached` is that one idle slot in the
window between `Recycle` and `Take`.

### What the ceiling governs, and what may exceed it

The per-pool ceiling is 256 MiB and it governs *live* allocation, enforced by
evicting cached destinations. It cannot refuse a destination the renderer needs
for correctness: the frame is already decoded, and refusing would drop it. So
`ReserveAllocation` evicts this budget's cache and then grants regardless,
setting `over_ceiling` and counting `over_ceiling_grants()`.

**The overshoot is stated and reported, not enforced, and that is a measured
conclusion rather than a preference.** The destinations legitimately in flight
at once are `kMaxPendingVideoImportSubmissions` (2, per cache), plus
`kMaxImportedVideoFramesPerVideoTex` (4) for each live video texture, plus the
one destination each consumer retains while it is still displaying its last
import. `in_flight_slot_cap()` carries that expectation and
`in_flight_cap_breaches()` counts every reservation granted past it, with one
log line per episode. Nothing refuses.

Two earlier drafts of this document claimed otherwise, and both were wrong.
The first called the overshoot "bounded by `kCoexistingSlots` slots" when
nothing capped it at all. The second made it a real refusal — and that is when
the interesting part happened. Driven through the production path on a real
M3 Max (seven `CustomShaderPass`es over one `VideoTex`, each going through
`TextureCache::UpdateVideoFrame` and `PinVideoFrame`), a refusing cap
**deadlocked**: refusals per generation went 1, 8, 14, 19, 23 while `created`
froze at 6, `reused` stayed at 0, and the video texture stuck on generation 5
for the rest of the run.

The mechanism is structural, not a bad constant. What holds the extra
destination is `CustomShaderPass::desc().vk_textures[i]` — the `ImageSlotsRef`
that `UpdateVideoFrame` itself handed the consumer. A consumer releases its
previous destination by re-binding, and it re-binds by receiving the very
import a refusal withholds. So refusing is *what stops* the destinations coming
back. No finite denying cap degrades gracefully here; it converts a memory
ceiling into a permanent stall, which is exactly the failure mode the plan
forbids. Picking a larger number would only have made it rarer.

`InFlightCapReached` was therefore removed from `VideoConversionRefusal`
entirely rather than kept as a value that never gates, and
`KeepsGrantingWhenTheConsumerReleasesOnlyOnTheNextImport` pins the recovered
behaviour over 40 generations.

339,738,624 therefore exceeds the 268,435,456-byte ceiling, legitimately and
visibly: `HostsAllSlots` is false for this shape (six slots would need
509,607,936) and the grant is counted rather than hidden.

**A separate regression, found and fixed earlier in the same area.** The first
version of `LiveAllocationAtCeiling` refused *admission* whenever live + slot
exceeded the ceiling. Measured on real hardware, that destroyed reuse for
exactly the clips R02 exists for: 17 allocations, 0 reuses, 13 refusals,
`peak_cached` 0 — an 81 MiB `MTLTexture` allocated and freed every frame. And
it saved nothing: `peak_live` was 339,738,624 with or without the refusal,
because `Admit` re-admits bytes that are *already live*. The rule now tests the
refusal before the eviction loop and gates it on the cache already holding a
slot the incoming key could reuse, so an empty cache always admits and the
refusal stays reachable only for speculative caching beyond live demand. The
GPU test that caught it was not re-pinned.

### Per-pool versus per-process

One budget belongs to one pool, one pool to one `TextureCache`, one
`TextureCache` to one renderer instance. `VideoConversionMemoryDomain` is the
process-wide total those per-pool ceilings add up into: 512 MiB by default, a
mutex-protected table each budget publishes its live and cached bytes to, and a
budget's effective ceiling is `min(own ceiling, domain.headroom_for(this))`.

It is deliberately cooperative, not authoritative. A budget only ever evicts
*its own* cache — the domain never reaches into another budget, because those
budgets run on other renderer threads — so shedding takes effect at the other
pool's next conversion. That latency is documented in the header rather than
denied.

**Nothing coordinates across processes.** The lock-screen extension runs its own
renderer in its own address space with its own domain. There is no system-wide
GPU memory ceiling here and none is claimed.

---

## Round 4 — V04 rejection: a refusal now expires with the thing it described

Round 3 keyed refusals on the wallpaper id alone and kept them for the session,
clearing them only when the backend was toggled. Four consequences, all real:
a 60 fps clip refused at target 30 stayed refused after the user raised the
target to 60; restoring an unsupported setting never re-evaluated; replacing the
media file at the same path never re-evaluated; and a late asynchronous refusal
from a previous configuration could mark the current one dead. The last is a
correctness bug, not a missed optimisation.

`BridgeNativeVideoWallpaper` now carries an `admission_key: u64` — FNV-1a over
the resolved media path, the file's length, its modification time and the
display's effective target fps. FNV-1a rather than `DefaultHasher` because the
key crosses the FFI boundary to the host and back, and `DefaultHasher`'s output
is explicitly not stable across Rust releases. Length and mtime stand in for
contents; hashing the media would read hundreds of megabytes per activation.
The cost is stated rather than hidden: two clips of equal length written to the
same path inside one timestamp tick are indistinguishable, which loses a
re-evaluation and never shows a wrong frame.

`reject_native_video` takes the key the host decided against. A refusal whose
key does not match the wallpaper's current key is stale and is dropped with a
log line instead of recorded, and `native_video_media()` ignores and prunes a
record whose key no longer matches. A repeat refusal with a *matching* key
still triggers no second reconcile, which is round 3's guarantee and is kept.

The key is computed per display slot, so one wallpaper on two displays at
different target rates has two keys and a refusal on one display does not drag
the other off the native player. A mirror deliberately keeps its source's key:
`build()` gives a mirror a scene only by copying its source's, so a mirror
cannot fall back on its own, and admitting or refusing it together with its
source is what stops the mirror display going black.

Twelve `native_video_routing` cases cover it, including
`a_refusal_at_one_target_rate_does_not_survive_a_new_target_rate`,
`a_refusal_stops_applying_when_the_setting_it_describes_is_restored`,
`replacing_the_media_file_at_the_same_path_re_offers_the_wallpaper`,
`a_refusal_carrying_a_stale_admission_key_is_dropped` and
`exactly_one_backend_renders_a_wallpaper_across_a_refusal`.

**Host side.** The host's own `refused` set is keyed on the same `UInt64`, so
it cannot disagree with the bridge, and the decision is cached per key in a
16-entry table so a reconcile storm is not a file read per pass.
`testTheRefusalTravelsWithTheKeyItWasDecidedAgainst` pins that the key is
reported with the refusal, and
`testChangingTheTargetRateIsEvaluatedAgainRatherThanStayingRefused` pins that a
new configuration does not inherit the old verdict.

## Round 4 — fifteen defects found in round 4's own work, after it was first called done

Everything above was written, tested and reported green. A second review pass
over the same code found five more faults in it. They are recorded here rather
than quietly folded into the sections above, because the pattern matters: each
one is a case where the *new* rule was correct in the situation it was written
for and wrong one step outside it, and every one of them was reachable by
reading the code rather than by running it.

**1. The domain could hand the same bytes to two pools.** `PublishToDomain`
published `total_live_conversion_allocation_bytes()`, which deliberately
excludes reservations, and `headroom_for` summed only `live`. So a reservation
counted against its own budget's ceiling but was invisible to the process-wide
one — asymmetric for no reason. Worse, `ReserveAllocation` took the domain lock
twice, once to read headroom and once to publish, so two pools could read the
same headroom and both reserve it. Fixed: reservations are published, other
budgets' `live + reserved` is what headroom subtracts, and the fit test and the
record now happen inside one locked `AcquireHeadroom` call. `headroom_for`
stayed a `const` query that counts nothing; shed requests are counted on the
mutating call where the decision is actually taken.

**2. The overage was counted, not bounded — and then the bound turned out to
be unenforceable.** This went through three states, and only the third is
right. It was counted but uncapped; then I made `InFlightCapReached` a real
refusal; then measurement showed a refusing cap **deadlocks** the production
path, and it was removed. The full argument and the numbers are under *What the
ceiling governs*. Two smaller errors along the way: my first spec capped on
`live_slot_count()`, which includes cached slots and so would refuse the very
reservation a full reuse pool exists to serve, and the cap was sized per pool
from a constant that is per video texture. Both were caught before landing.

**3. An average could admit a clip on its own.** The new rule required a
bound, but `presentationRateBound` fell back to `nominalFrameRate` when
`minFrameDuration` was unusable. A track reporting a 24 fps average with an
invalid minimum was therefore *accepted* at a target of 30 — and a 24 fps
average is equally consistent with a clip that sits at 12 and bursts to 60.
That is round 3's fault reached through a different field. An upper bound now
requires a usable `minFrameDuration`; the average can only ever make the
verdict stricter, never admit. Falsified: against the previous rule,
`testAPositiveNominalRateAloneNeverAdmitsAClip` fails with
`(rate: 24.0, source: "nominalFrameRate")`.

**4. A running player outlived the decision that admitted it.**
`apply` replaced a surface only when the wallpaper *id* changed, so lowering
the target rate under a running clip, or replacing the media at the same path,
left the player running and merely pushed the new descriptor at it. A 60 fps
clip carried on playing at 60 under a 30 fps target — precisely what admission
exists to prevent, arrived at by never re-running admission. A surface is now
bound to the admission key it was accepted under, and a changed key tears it
down and goes through admission from the start. Falsified: reverting the
condition fails seven assertions across two tests.

**5. Playback failure had no hand-off at all.** Admission reads metadata;
nothing observed whether the asset actually *played*. `AVPlayerItem.status`
becoming `.failed` was not watched, and `NativeVideoSurface` had no failure
channel, so an asset that probed cleanly and then failed to decode stayed
native-selected with the scene engine excluded: a black display for as long as
it was assigned. The player now observes both the item's and the looper's
status, reports once, and the host stops the surface and hands the wallpaper
back through the same path a metadata refusal uses — with the surface
generation checked, so a late failure cannot condemn its successor.
`playbackFailed` is a distinct, settled refusal from `preparationFailed`.

**6. One refusal could erase another display's.** The bridge stored one
rejection per wallpaper id, but a wallpaper has one admission key *per display
slot*. The same clip refused on two displays at different target rates meant
the second refusal overwrote the first; the first display's record then looked
stale, was pruned, and the clip was offered natively again to a host that had
already refused that exact key. That display ended up with neither backend.
Rejections are now retained per `(wallpaper id, admission key)` and pruned
against all of a wallpaper's live keys. Three multi-display cases cover it, and
restoring the single-record store fails two of them.

**7. The cap was never enforced on the production path, and made things worse.**
Once `InFlightCapReached` existed, `TextureCache` never read
`ReserveFresh(...).granted`: it allocated anyway, and `CommitFresh` then
early-returned on the denied reservation, leaving the new texture **uncounted**.
The enforcement added at the end of the round had reopened the exact accounting
hole the round existed to close. `TextureCache` now reads `granted`, allocates
nothing on a denial, counts `conversion_reservations_refused`, and fails that
frame's import. The denial path itself is now unreachable for capacity, but the
guard stays for memory pressure and unsatisfiable sizes, where failing the
import genuinely is recoverable.

**8. A failure on one display was discarded because another display opened.**
`handlePreparationFailure` compared the reported generation against the
host-wide `surfaceGeneration`, which moves whenever *any* display opens a
surface. Open display 7, then display 9, and display 7's real playback failure
compared unequal and was dropped as stale — leaving it native-selected with the
scene engine excluded, showing black. Staleness is now surface identity, which
is what the poster path already used.

**9. The failure observer watched an item that never plays.** It observed the
`AVPlayerLooper`'s *template* item, which the SDK states is not used for
playback — the looper enqueues copies. It also subscribed to looper status with
`.new` only, after construction, and the host installed its callback *after*
`load`. So a synchronous failure could be raised with nobody listening and
dropped. The observation now follows `player.currentItem` across loop
boundaries, takes `.initial`, and a failure raised before a callback exists is
held and delivered on install. Honest scope note: of these, only the buffered
delivery is proven load-bearing by a test — removing it fails
`testAFailureRaisedBeforeTheCallbackIsInstalledIsStillDelivered`. Removing the
`currentItem` observation does **not** fail the real truncated-asset test,
because the looper's status reports that particular fault; it is retained as
defence for a mid-playback item failure that no test here produces, and is not
claimed as verified.

**10. Two refusal caches with different lifetimes left a display blank.** The
host kept its own permanent `refused` set of admission keys. The bridge prunes a
rejection whose key no longer matches a live display slot, so going 30 → 60 → 30
brings key 30 back as a legitimate fresh offer — which the host silently
skipped, while the bridge had already excluded the scene engine for that
display. Neither backend, nothing on screen. Toggling the backend off reproduced
it too, since that clears only the bridge's map. The bridge is now the sole
authority: the host keeps only an in-flight guard against reporting the same
refusal twice concurrently, and answers every offer it is given. Two existing
host tests asserted "handed back exactly once" across repeated offers; that was
pinning the defect, so they were rewritten rather than worked around —
loop-freedom is the bridge's guarantee and is tested there.

**11. A denied reservation still allocated, and the denial was never read.**
`TextureCache` ignored `ReserveFresh(...).granted`, allocated anyway, and
`CommitFresh` then early-returned on the denied reservation — leaving the new
texture uncounted. The enforcement added at the end of the round had reopened
the exact hole the round existed to close. `TextureCache` now reads `granted`,
allocates nothing on a denial, counts `conversion_reservations_refused`, and
fails that frame's import so the previous frame stays on screen.

**12. Known-unsatisfiable allocations were retried every frame.**
`ReportAllocationFailure` recorded the failing size but only `Admit` consulted
it, so after a real Metal allocation failure the next import attempted the same
allocation again, failed again, and logged again, per frame — the repeatedly
failing allocation the plan forbids. `ReserveAllocation` now denies at or above
a recorded failing size with `AllocationUnsatisfiable`, counted separately from
every capacity number, with `Reset` as the stated recovery. Denying here is safe
for the reason capacity denial is not: an allocation already known to fail was
never going to produce a destination, so it cannot withhold a release a later
request depends on.

**13. A buffered failure could orphan a desktop window.** Fixing defect 9 by
holding a pre-install failure created a new fault: installing the callback
delivers it *synchronously*, so the hand-off closed the surface in the middle of
`open` — and `open` then carried on to `update` and `present`, ordering a
stopped, unregistered window onto the desktop that nothing owned and nothing
could close. `open` now re-checks that the surface is still registered after
installing the callback. Falsified: removing that check leaves the host suite
unable to complete.

**14. Mirrors bypassed the frame-rate rule entirely.** A mirror got its own
`fps` but inherited the source's `admission_key`, and the host caches verdicts
by key — so a 60 fps clip accepted for a source display at target 60 handed that
cached acceptance to a mirror at target 30, which never evaluated 30 at all. The
one path that skipped admission completely. A mirror group is now judged against
its strictest member: `admission_fps` is the group minimum, every member shares
one key, and a refusal sends the group back together — which is the only
coherent outcome, since `build()` gives a mirror a scene only by copying its
source's.

**15. The "no video track" case was never exercised against real media.** It
asserted a hand-built probe with `hasVideoTrack: false`. It now writes a real
LPCM audio-only movie and probes it; AVFoundation returns an empty video track
list and the refusal reads `no video track`. Writing an audio track is file I/O
— no device is opened and nothing is played.

Apart from the admission key and `admission_fps` the FFI surface is unchanged.
Three existing tests were rewritten because they pinned defects 10 and 15; two
others were briefly trimmed to fit the refusing cap and then reverted to
byte-identical when the cap was removed.

---

## Round 4 — V04 admission: the frame-rate rule was wrong in both directions

Round 3 refused a wallpaper when `Float(targetFps) + 1.0 < nominalFrameRate`.
Three separate faults, all source-confirmed in the round 3 tree.

**The one-frame slack admitted genuinely over-limit content.** It was written
to stop 29.97 being refused against a target of 30. It was never needed for
that — 29.97 is already below 30, and a rational comparison has no
representation error to absorb — and it silently admitted every clip within one
frame above the target. A 60 fps clip at a target of 59 evaluated
`59 + 1 < 60` → false → accepted, which is exactly the silent rate change the
target is there to prevent. `testARateLessThanOneFrameAboveTheTargetIsStillRefused`
drives both that case and 29.97 against 29 through real files and fails against
the old rule.

**`nominalFrameRate` was treated as a ceiling.** It is an average over the
track, and for interlaced content it is the field rate. A clip whose average is
30 but whose shortest declared frame is 1/60 s can present 60 frames in a
second. The rule now reads `AVAssetTrack.minFrameDuration` as well, compares it
to the target as the rational it is — `CMTimeCompare(minFrameDuration,
CMTime(value: 1, timescale: targetFps))`, no tolerance — and takes the *larger*
of the two implied rates as the bound. `testAnAverageRateBelowTheTargetDoesNotExcuseAFasterInterval`
pins it.

**Unusable metadata became a huge frame rate.** `minFrameDuration` comes back
invalid, indefinite or zero for tracks AVFoundation cannot summarise, and each
of those divides through into nonsense. `NativeVideoAdmission.isUsable` rejects
all of them, and a track where neither field is usable is refused as
`frameRateNotDeterminable` rather than admitted on a guess. Interlaced tracks
(`kCMFormatDescriptionExtension_FieldCount > 1`) are refused for the same
reason: this backend cannot tell which rate the display path will choose, and
the scene engine paces its own frames.

The float comparison keeps one tolerance, and only one:
`floatRepresentationSlack = 1e-4`, relative, for `nominalFrameRate` being a
`Float`. That is four parts in ten thousand against a smallest meaningful
difference of one part in a thousand (30 vs 29.97). It absorbs representation
error and nothing else.

**Settled and unsettled failures are now different things.** Round 3 folded a
thrown metadata load into `notPlayable`, which recorded a permanent refusal. An
I/O error, a file still being written or a contended decoder says nothing about
the content. `NativeVideoRefusal.preparationFailed` is unsettled: the host
retries it up to `admissionAttemptLimit` (3) times, 150 ms apart, and only then
hands the wallpaper over. Without the split one blip demotes a wallpaper for the
session; without the bound a file that never loads leaves the display blank for
as long as it is offered. Both halves are pinned —
`testATransientMetadataFailureIsRetriedRatherThanDemotingTheWallpaper` and
`testAPersistentMetadataFailureStopsRetryingAndHandsOffOnce`.

**Probing does not repeat.** `reconcile` runs on display changes, wallpaper
changes and suspension changes. The host caches the decision per admission key
in a 16-entry table, so a reconcile storm is not a file read per pass, and the
probe itself is `AVURLAsset`'s asynchronous property loading — never a
synchronous read on the main thread, and never a walk of the file.

### What real media actually returned

`Tests/Unit/NativeVideo/SyntheticVideoFixture.swift` writes the clips with
`AVAssetWriter`; `NativeVideoAdmissionTests` reads them back through
`NativeVideoAdmission.probe` and logs the API's own answer next to the verdict.
The rate a fixture was *asked* for is never asserted as a result — only what
`nominalFrameRate` and `minFrameDuration` report about the finished file.

| Fixture written | `nominalFrameRate` read back | `minFrameDuration` read back | Target | Verdict |
|---|---|---|---|---|
| 24/1 | 24.0 | 1/24 | 24, 54 | accepted |
| 25/1 | 25.0 | 1/25 | 25, 55 | accepted |
| 30/1 | 30.0 | 1/30 | 30, 60 | accepted |
| 60/1 | 60.0 | 1/60 | 60, 90 | accepted |
| 60/1 | 60.0 | 1/60 | 30 | refused, bound 60 from `minFrameDuration` |
| 60/1 | 60.0 | 1/60 | **59** | refused — the case the old one-frame slack admitted |
| 24000/1001 | 23.976025 | 1001/24000 | 24 | accepted, no tolerance needed |
| 30000/1001 | 29.97003 | 1001/30000 | 30 | accepted, no tolerance needed |
| 60000/1001 | 59.94006 | 1001/60000 | 60 | accepted, no tolerance needed |
| 30000/1001 | 29.97003 | 1001/30000 | **29** | refused — over by less than one frame |
| VFR, 15 fps with a 60 fps burst | 24.0 | 15/900 (= 60 fps) | 30 | refused on the fastest interval, not the average |
| corrupt file | — | — | 60 | refused, `notPlayable` ("asset reports itself unplayable") |
| absent file | — | — | 60 | refused, `preparationFailed`, no crash |
| interlaced, fieldCount 2 | 29.97 | 1001/30000 | 60 | refused, `frameRateNotDeterminable` |
| nominal 0 + invalid `minFrameDuration` | 0 | invalid | 60 | refused, `frameRateNotDeterminable` |
| any | 30.0 | 1/30 | **0** | refused, never divided through |

Two things in that table are worth reading carefully, because both are cases
where the generator's intent and the file's contents diverged.

**The NTSC fixtures nearly were not NTSC.** The first run came back 24.0 / 30.0
/ 60.0 with `minFrameDuration` 25/600, 20/600 and 10/600: `AVAssetWriter` had
re-timed the track to its own 600 timescale, in which 1001/24000 s per frame
cannot be represented. The test caught it because it asserts the *read-back*
rate, not the requested one — an assertion on the requested rate would have
passed while testing nothing. The fixture now pins
`AVAssetWriterInput.mediaTimeScale`, and the rationals above are what the files
actually contain.

**The VFR clip's average is not what it was asked for either** — 24.0 rather
than 15 — but its shortest frame is 15/900 s, exactly 60 fps, and that is what
the refusal cites. That is the rule working: the average was misleading and the
fastest interval was not.

The last four rows are built as `NativeVideoTrackProbe` values rather than
files. The encoder available here does not produce interlaced or metadata-less
tracks, and claiming a file had produced them would be a fabricated result.
They exercise the same `decide` function the real files go through.

The fixtures are generated with the hardware encoder explicitly disabled
(`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false`).
They run in the routine gate, which is not a device test; eight 64x36 frames
cost nothing in software, and the gate stays off the media engine.

---

## Round 4 — V04 poster: it was a second decoder, and it did not follow the loop

source-confirmed in round 3: `posterImage()` built an `AVAssetImageGenerator`
from `player.currentItem?.asset` on every request. The comment above it said
"the existing player is asked for it; a second player would mean decoding the
same clip twice" — and an image generator is exactly a second decode. There was
also no bound on concurrent requests: five requests built five generators.

What it does now:

- Reads from an `AVPlayerItemVideoOutput` attached to the item that is
  **playing**, re-resolved on every polling step. `AVPlayerLooper` replaces
  `currentItem` at each loop boundary, so an output attached once would stop
  producing after the first wrap. `testAPosterIsProducedFromTheItemPlayingAfterTwoLoops`
  waits for two observed wraps before asking.
- Detaches the output when the request ends, always. A permanently attached
  output is a continuous readback of every frame for a picture nobody asked
  for; `posterOutputIsAttachedForTest` is asserted false after every request.
- Coalesces concurrent requests into one `Task`, so overlapping callers share
  one read and get the identical `CGImage`.
- Falls back to a one-shot `AVAssetImageGenerator` only after a bounded wait
  (12 × 25 ms), and counts it as `nativeVideoPosterFallback`. A fallback that
  became the normal path is then a visible number rather than an inference.
  Nothing is retained between requests, so a failure leaves no converter and no
  second decoder behind.
- Never resumes playback. A paused player answers from the last frame it
  produced; `testAPausedPlayerAnswersAPosterWithoutResuming` asserts the rate is
  still zero afterwards.
- A stopped surface answers `nil`, its in-flight request is cancelled, and the
  host checks the surface is still the one bound to that display before
  publishing. `testAPosterFromAReplacedSurfaceIsNotPublished` replaces the
  wallpaper mid-request and asserts nothing is delivered.

**Readiness evidence stays separated.** `AVPlayerLayer.isReadyForDisplay` means
the layer has a frame it could show. The media tests record asset loaded, item
`readyToPlay`, playback time advanced, pixel obtained and layer ready as five
distinct observations, and on-screen presentation as `unavailable` — this
backend has no presentation-feedback source and none is invented.

### What the real player run actually established

`NativeVideoPlayerMediaTests`, 9/9, with `MAC_WALLPAPER_ENGINE_MEDIA_TESTS=1`.
These drive the production `NativeVideoPlayer` — real `AVQueuePlayer`,
`AVPlayerLooper`, `AVPlayerLayer`, `AVPlayerItemVideoOutput` — against
generated silent clips, so they decode on this machine's media hardware. That
is why they are opt-in and why `scripts/test.py` forwards the variable as
`TEST_RUNNER_…`: `xcodebuild` does not hand its own environment to the hosted
test process, so without that the suite silently skips.

| Observation | Result |
|---|---|
| asset loaded | yes |
| item reached `readyToPlay` | yes |
| playback time advanced | yes |
| loop boundaries crossed | 2 observed wraps, 3 queued items, queue never ran dry |
| pixel obtained after 2 loops | yes, 64x36, `nativeVideoPosterFallback` = 0 |
| video output left attached afterwards | no |
| concurrent requests | 3 requests, one shared `CGImage` |
| paused poster | frame returned, `player.rate` still 0 |
| release | `nativeVideoItemCreated` == `nativeVideoItemReleased`, stopped surface answers `nil` |
| layer `isReadyForDisplay` | true |
| **on screen** | **unavailable** — no presentation feedback exists for this backend |

`fallbacks = 0` is the load-bearing number: the poster came from the playing
item across two loop boundaries, not from the image generator. The generator
path exists and is counted, but it was not the path taken.

---

## Round 4 — I01: what last round's memory numbers actually were

No I01 code changed this round. Round 3's two figures were reported side by
side as if they were the same kind of evidence. They are not.

| Figure | What produced it |
|---|---|
| 4,079,616 B growth for a 67,244,350 B clip | A real measurement on the real production path, but a **single sample from one round 3 run**. `VideoSourceInput.LargeLocalFileIsNeverResident` reads `task_vm_info.phys_footprint` before and after `CreateVideoProjectImage` → `CreateVideoTextureSource` → `prime`. The test asserts only `growth < 16 MiB`; the exact byte figure is printed on failure, so a green run does not re-emit it and this round did not re-derive it. |
| 134,316,128 B for a 64 MiB file | **Provenance unverified.** No test in the tree measures the old path's footprint, and nothing records which program produced this number or which metric it used. It is exactly 2 × 67,158,064, which is consistent with an arithmetic doubling of the media size — but consistency is not proof, and a throwaway control program that no longer exists would fit equally well. It is not usable as a comparator until its origin and metric are re-established. |

The metric in row 1 is `phys_footprint`: the delta in the process's physical
footprint across scene load, sampled twice. It is not peak RSS, not a
high-water mark over the interval, and not a count of allocated bytes — a peak
between the two samples would not appear in it. The in-package payload path
that row 2 models still exists in the tree for media inside a `.pkg`, and it is
unmeasured.

So the durable, reproducible claim is the test's own bound: opening a plain
local video of 64 MiB grows this process's physical footprint by under 16 MB,
and no copy of the media is written to the temp directory.
`check_renderer.py` re-confirmed that bound this round (`video_source_input_test`
11/11). The "twice the media size" comparison is withdrawn as a claim: it may
well be true, but nothing in the tree establishes it, and a number whose origin
and metric are both unknown is not evidence for a before/after improvement.

---

## Round 4 — the desktop session that is still required

Not executed. No desktop control, screen capture, wallpaper change, app
install, lock/unlock, audio capture or elevated sampling was performed or
authorized this round, and `python3 scripts/test.py --ui` was not run. This is
the minimum list that a single authorized session would have to cover, in
order, for V04 to have runtime and visual evidence at all:

1. Launch `build/Build/Products/Release/MacWallpaperEngine.app` with
   `MAC_WALLPAPER_ENGINE_DIAGNOSTICS=120` and an isolated
   `MAC_WALLPAPER_ENGINE_HOME`.
2. Turn the native video backend on and assign one plain local video whose
   frame rate is at or below the display's target, so admission accepts it.
3. Observe, on one visible display: first frame appears; playback loops at
   least twice without a visible seam; user pause stops it and resume restarts
   it; a poster request produces the current frame rather than a black
   rectangle.
4. Hide and reveal that display (occlusion), then repeat with two displays, and
   confirm the hidden one stops while the visible one keeps playing.
5. Assign a clip the rule refuses — 60 fps under a 30 fps target — and confirm
   the scene engine takes it, the wallpaper still renders, and nothing
   oscillates between the two backends.
6. Only then, the paired power measurement from
   [testing/power-benchmark.md](testing/power-benchmark.md): same clip, same
   output geometry, same *measured* presented frame rate, legacy and native in
   two separate runs.

Two rules for step 6. Do not run both builds at once to compare them — two
wallpaper renderers on one machine measure each other. Do not change content
pacing, output resolution or quality tier in the same comparison; if the two
paths do not present at the same measured rate, there is no equal-quality
saving to report and none may be quoted.

---

## Round 3 — status by task ID

| ID | implementation | automated verification | runtime verification | visual | power |
|---|---|---|---|---|---|
| P02 stale-wait fix | done | `timer_tests` (counter-example) | — | — | — |
| P02 pacing made opt-in | done | `video_frame_pacing_test` | — | — | — |
| Counter attribution | done | `renderer_counters` (bridge), `RuntimeDiagnosticsReportTests` | — | — | — |
| R02 conversion budget | done | `video_conversion_budget_test`, `playback_gpu_test` | — | synthetic GPU pixel comparison only | — |
| I01 direct file input | done | `video_source_input_test`, `video_decode_pump_test` | — | — | — |
| V04 routing and host rules | done, off by default | `native_video_routing` (bridge), `NativeVideoWallpaperHostTests` | — | — | — |
| V04 player and window | done, off by default | none — needs a desktop | — | — | — |

"visual" needs care. `playback_gpu_test` compares real GPU output against a CPU
reference for synthetic frames, so R02's pixels are checked at that level. No
wallpaper has been displayed on a real desktop and no authored reference frame
has been compared, in this round or any previous one. V04 in particular has
never put a pixel on a screen.

## Round 3 — commands actually run

| Command | Result |
|---|---|
| `python3 scripts/test.py` | Pass, 325 tests, 0 failed (314 before this round) |
| `python3 scripts/check_renderer.py` | Pass, exit 0; 10 cases `pixels_equal=true`, 0 diagnostics; every binary exit 0, now including `video_conversion_budget_test` (11) and `video_source_input_test` (11) |
| `cargo test --release --workspace` | Pass; 251 `wallpaper-bridge` cases including `native_video_routing` (7) |
| `python3 scripts/build.py --renderer-only` | Pass; bindings carry `nativeVideoWallpapers`, `setNativeVideoBackendEnabled`, `rejectNativeVideo` |
| `python3 scripts/build.py --configuration Release` | **BUILD SUCCEEDED**; app and embedded extension |
| `tests/timer_tests` | Pass, 20 cases (2 new) |
| `tests/playback_gpu_test` | Pass, 34 cases (2 new from R02) |

Build identity: this round started from `6bfaa1d840f2ca84feb7ff600e7b32e78a6e9610`
with 41 modified and 9 untracked files already present from round 2, verified
rather than assumed. Nothing was reset, stashed, reverted or committed. The
tree now carries 51 modified and 16 untracked paths; the new sources are
`App/Services/Diagnostics/`, `App/Services/NativeVideo/`,
`Tests/Unit/Diagnostics/`, `Tests/Unit/NativeVideo/`,
`crates/bridge/src/tests/{renderer_counters,native_video_routing}.rs`,
`crates/core/src/render/counters.rs`, `src/Core/RendererCounters.{h,hpp}`,
`src/Video/VideoFramePacing.{hpp,cpp}`, `src/Video/VideoConversionBudget.{hpp,cpp}`
and three new gtest files.

One environment fault cost real time and is worth recording: a scratch CMake
build directory configured without `scripts/build.py`'s environment linked the
default Homebrew `ffmpeg` keg instead of the pinned `ffmpeg@8`, which produced
dangling `libvpx`/`x264`/`x265` dylibs at launch and looked like a broken
machine. The fix is to configure with the project's own `PKG_CONFIG_PATH`, not
to set `DYLD_FALLBACK_LIBRARY_PATH`. A stale cmake cache under
`target/release/build/wallpaper-core/*/out` with `BUILD_TESTS=ON` also broke
`build.py --renderer-only` until that one directory was deleted.

---

## Round 3 — P02: the "at most one frame" claim was wrong

Round 2 wrote that a rate transition could cost at most one frame. That was
derived from the estimator's arithmetic and did not survive looking at the
scheduler.

**Defect found, on the production path.** `ThreadTimer::SetInterval` stored the
new interval and returned. The timer thread was already inside
`m_condition.wait_for(lock, m_interval.load(), …)`, whose duration is read once
at entry and whose predicate only fires on stop. A shortened interval therefore
did not apply until the previous period had elapsed in full. With a scene paced
at 2 s and a demand change to 20 ms, the next draw was ~1.95 s late.

counter-example: `AShortenedIntervalDoesNotSleepOutTheOldOne` and
`RaisingTheTargetFpsInterruptsAPacedWait` drive the real `FrameTimer` and
`ThreadTimer` and both failed against the old code — the first with
`draws == 0` after a 600 ms budget — and pass now. The second is the same fault
reached through the user's own setting rather than through content: raising the
target FPS during a paced wait used to take a full content period to apply.

fixed-in-production: the timer thread now waits to a deadline computed from the
last tick and the *current* interval, recomputed on every wake, and
`SetInterval` notifies. An early wake is not a tick; the loop re-checks the
deadline. A longer interval moves the deadline out without dropping the tick.

**The residual bound cannot be removed here, so pacing became opt-in.** Even
with the wait interruptible, the content period only reaches the clock from
`refreshFrameDemand`, which runs after a completed frame. A source whose rate
turns out to be tighter than the interval being waited out produces frames that
are superseded before the next frame boundary — up to `interval / period - 1`
of them, not one. Removing that needs the source to wake the clock itself,
which is a different change and is not in this round's scope.

So the default is now the safe baseline: tick at the configured ceiling.
`MAC_WALLPAPER_ENGINE_CONTENT_PACING=1` turns pacing on and is also the A/B
entry point. The switch's polarity was inverted from round 2's opt-out, and
`PacingIsOffUnlessTheEnvironmentExplicitlyOptsIn` pins the default.

**What was checked and did not need changing.** The round 2 suspension-threshold
fix is compatible with `Run`/`Stop`: `Run` resets the frame clock only when the
timer was not already running, `Stop` leaves the busy count to `Run` to clear,
and `StoppingWithADrawPendingDoesNotReplayTheStoppedTime` covers the pending-draw
case. No new failing counter-example was found, so the clock architecture was
not changed further.

**Still not established.** That a real video wallpaper loses no frame at a rate
transition with pacing on. The selection counters can falsify it on a desktop
run; no such run has happened. The honest position is the one now in the code
and the docs: pacing is opt-in and its bound is stated rather than denied.

---

## Round 3 — counter attribution

Round 2 grouped counters by a `video_` prefix, which put two different things in
one bucket and keyed source work on a file path. Both are fixed.

- **Consumer work** — selected, reused, skipped, selected generation, **and the
  colour conversions and GPU imports**. The texture cache that performs a
  conversion is per surface, so conversion is that surface's own work; round 2
  filed it as shared source work, which was wrong.
- **Source work** — decode outputs and seeks, plus `OWE_RC_VIDEO_SOURCE_COUNT`
  and `OWE_RC_VIDEO_SOURCE_INSTANCE`.
- **Identity** — `FfmpegVideoTextureSource` carries a process-unique
  `instance_id` assigned at construction. It is never derived from the path or
  from content, so two decoders reading one file are two identities.
  `TextureCache::publishVideoSourceIdentity` reports the count and, when there
  is exactly one, its id; zero or several reports `0`, which the report renders
  as `unknown` rather than picking one.
- **Aggregation** — `RuntimeDiagnosticsSession.sourceRollupLines` totals decode
  work once per instance. Two consumers of one decoder each report that
  decoder's running total, so the instance total is the maximum, not the sum;
  two decoders on one file stay separate; a surface with no single identifiable
  decoder is reported `decode_outputs=unknown`, never `0`.

Tests: `a_source_identity_names_a_running_decoder_not_a_file`,
`a_surface_without_one_identifiable_decoder_reports_unknown`,
`testOneDecoderConsumedTwiceIsTotalledOnce`,
`testTwoDecodersOnTheSameFileAreNeverFoldedTogether`,
`testASurfaceWithNoSingleDecoderIsReportedUnknownNotZero`.

**A hidden surface does not fake stopping.** Nothing clears a counter on
suspension, and `a_paused_surface_keeps_the_work_it_already_did` asserts a
paused row still carries its accumulated submissions and present requests — a
row that zeroed itself would make every surface look like it had always been
idle.

Preserved from round 2: a present request is not a displayed frame,
`unavailable` is not `0`, and the diagnostic session starts no periodic sampling
thread when it is off.

Not done: two decoders at different consumption rates were exercised only
through the reporting layer and through the single-cache GPU fixture. A true
two-surface, one-source case needs D01, which is out of scope.

---

## Round 3 — R02 conversion budget

Implemented in `src/Video/VideoConversionBudget.{hpp,cpp}` — slot sizing,
admission, eviction choice, loan tracking and the exhaustion policy over opaque
handles, with no GPU dependency — and executed by
`AppleVideoMetalTexturePool` and `TextureCache`.

- Reuse is keyed on decoded width, height and destination pixel format; cost is
  the Metal texture's real `allocatedSize`. A display's resolution never reaches
  the key.
- The ceiling is 256 MiB per pool, one pool per `TextureCache`, derived from the
  six destinations that can coexist for one video texture at a 3840x2160
  reference. It replaces a flat 64 MiB that refused any single destination above
  roughly 4096x4096.
- `Take` opens a loan and `Recycle` — called from the lease deleter, after the
  frame fence — closes it. A destination still referenced can never be lent
  again. The pre-existing renderer path was checked and already gated recycling
  on GPU completion; the rule is now enforced at the pool boundary instead of
  being an emergent property.
- Exhaustion stops caching, logs once per reason, and refuses a size an
  allocation already failed at, so an unsatisfiable allocation is never retried
  in a loop. Memory pressure is read synchronously at `Recycle` from Metal's
  `currentAllocatedSize` against `recommendedMaxWorkingSetSize`; there is no
  notification source and no extra thread.

Measured, not estimated: a warm 6144x3456 clip over 17 imports produced
`converted_destinations_created=4`, `converted_destinations_reused=13`,
`pool_hits=13`, `pool_misses=4`, `pool_evictions=0`, `pool_refusals=0`, peak
resident pool bytes 84,934,656. Creation plateaus at the imported-frame cap from
generation 5 and every later generation is a pool hit. Under the old 64 MiB
ceiling the same clip's `created` count kept climbing while `reused` stayed at
0. Every rule was confirmed load-bearing by deleting it and observing the
matching test fail.

No power claim. This is allocation behaviour, not watts.

---

## Round 3 — I01 direct file input

A plain local video no longer goes file → `ImageData` → `m_payload` → hash →
temp file → reopen. `Image::videoFilePath` carries the source kind: non-empty
means "already a file, open it"; empty keeps the in-package inline-payload path.

Production path, verified rather than assumed:
`MainHandler::loadScene` → `ResolveSceneSourcePaths` (type Video) →
`loadNonSceneProject` → `CreateVideoProjectScene` →
`video::CreateVideoProjectImage`, which resolves, canonicalises and
containment-checks the entry, probes dimensions, and returns an `Image` with an
empty `slots` vector. `TextureCache`'s video branch was confirmed never to read
`slots`.

- In-package extraction is now published atomically: unique staging name, size
  completion check, rename. A concurrent open cannot observe a partial file.
- The inline payload is released as soon as the decoder is open.
- Manifest entries are canonicalised before the containment test, so a symlink
  is followed first rather than after.
- Error semantics: one message became unreachable
  (`failed to read video project media file`) because nothing reads the file;
  nothing referenced it. One is new
  (`video project media file escapes the project directory`). Every other
  message is preserved verbatim and no existing test needed changing.

Measured startup peak, load time only: a 67,244,350-byte wallpaper grew the
process footprint by 4,079,616 bytes. The previous shape's two copies were
measured directly at 134,316,128 bytes for a 64 MiB file. So scene-load peak
goes from roughly twice the media size to a small fixed cost, and no copy of the
media is written to the temp directory for the local-file case.

Steady-state power: no measurement and no claim.

---

## Round 3 — V04 native video backend, default off

One candidate only: `AVQueuePlayer` + `AVPlayerLooper` + `AVPlayerLayer`. No
second prototype exists.

**It is in the production routing, not beside it.**
`ActivationInputs::build_native_video` produces the descriptors and
`ActivationInputs::build` *excludes* those ids, so a natively routed wallpaper
gets no `SceneDesc` at all.
`a_natively_routed_wallpaper_is_not_also_given_to_the_scene_engine` asserts
exactly that — two renderers for one display would decode and present the same
clip twice.

**Default off.** `AppConfig.experimental.native_video_backend` defaults to
false, `native_video_wallpapers()` returns empty while it is off, and
`the_backend_is_off_until_it_is_turned_on` pins it.

**The frame-rate rule, which is where an easy lie would live.** There is no
supported way to cap an `AVPlayerLayer`'s presentation rate. Lowering the
playback rate would slow the video down, and dropping frames by hand would mean
copying every frame through the CPU. So a target frame rate below the clip's
`nominalFrameRate` — with one frame of tolerance, so 29.97 is not refused
against 30 — is **refused**, and the wallpaper goes back to the scene engine. A
60 fps clip is never silently played at 60 while the user asked for 30.

**The fallback terminates.** A refusal is recorded once in the host and once in
the bridge (`native_video_rejected`), and
`a_refused_wallpaper_goes_back_to_the_engine_and_stays_there` asserts that a
repeat refusal triggers no second reconcile. Turning the backend off clears the
refusals, because they described a configuration the user has since changed.

**Wired into the rest of the app.** `MWENativeVideoDesktopWindow` was added to
`WallpaperPresentationPolicy.wallpaperWindowClassNames`; without that the
display would be invisible to occlusion tracking. The host takes both the global
and the per-display suspension, and the user's own pause stays independent:
`testRevealingADisplayDoesNotStartAWallpaperTheUserPaused` and
`testAGlobalResumeKeepsADisplayThatIsStillHiddenStopped`. A wallpaper that
leaves the native backend stops playing in the same pass, before anything else
starts. Poster requests are answered from the player that is already running —
no second player and no legacy renderer is kept for posters.

**Declared subset.** Local plain-video projects; volume, mute, user pause,
per-display suspension, fill and stretch scaling, looping, on-demand poster.
Outside it: playback speed, horizontal flip, audio response, property overrides,
in-package media, and any target rate below the clip's own. Those keep the scene
engine.

**Observability.** `nativeVideoItemCreated` / `nativeVideoItemReleased` are
counted separately so a leaked player is a visible difference rather than an
inference, and `queuedItemCount` reports what `AVPlayerLooper` actually queues
rather than claiming a single item. Decode and present counts inside
AVFoundation are not observable and are not invented.

**The tests do not open a window, and that was a correction.** The first version
of `NativeVideoWallpaperHostTests` let an accepted wallpaper build a real
`NativeVideoWallpaperWindow` and call `orderFrontRegardless()`. That is a
desktop-level window on the user's screen from an automated run, which this
project's rules do not permit without explicit authorization, and no existing
suite does it — the web wallpaper tests never construct their window either. The
host now takes a `NativeVideoSurface` factory; the real implementation is the
window plus the platform player, and the tests inject a fake. The controller
rules — refusal handed back once, surfaces opened and stopped, suspension
independent of the user's pause — are all checked through that boundary.

**Not verified.** No frame has ever been displayed by this backend. Readiness,
playback-time advance and actual on-screen presentation are three different
things and none of them has been observed. `NativeVideoWallpaperWindow` and
`NativeVideoPlayer` themselves have no automated coverage at all: nothing
exercises `AVQueuePlayer`, `AVPlayerLooper`, `AVPlayerLayer`, the real
`nominalFrameRate` probe or the poster generator. All of that needs the
authorized desktop run.

---

## Round 2 — status by task ID

Blank means the field is not claimed. Nothing in the last three columns is
claimed anywhere in this document.

| ID | implementation | automated verification | runtime verification | visual | power |
|---|---|---|---|---|---|
| M00 renderer counters | done | `timer_tests`, `video_frame_pacing_test`, `renderer_counters` (bridge), `RuntimeDiagnosticsReportTests` | — | — | — |
| M00 diagnostic session | done | `RuntimeDiagnosticsReportTests` | — | — | — |
| P02 pacing evidence | done | `video_frame_pacing_test` | — | — | — |
| P02 playback speed | done | `video_frame_pacing_test` (resolution function) | — | — | — |
| P02 suspension boundary | done | `timer_tests` (counter-example) | — | — | — |
| P02 A/B switch | done | `video_frame_pacing_test` | — | — | — |
| P01 / W02 / E01 | unchanged from round 1 | unchanged | — | — | — |

"runtime verification" means the shipped application ran and its counters were
read. That did not happen: it needs an authorized desktop session. Everything in
the second column ran in this environment.

## Round 2 — commands actually run

| Command | Result |
|---|---|
| `python3 scripts/test.py` | Pass, 314 tests, 0 failed (310 before this round) |
| `python3 scripts/check_renderer.py` | Pass, exit 0; 10 generated cases `pixels_equal=true`, 0 diagnostics; every test binary exit 0 |
| `cargo test --release --workspace` (`CARGO_TARGET_DIR` unset) | Pass; 241 `wallpaper-bridge` cases, every other crate green |
| `python3 scripts/build.py --renderer-only` | Pass; bindings regenerated with `rendererCounters` and `setRendererCountersEnabled` |
| `python3 scripts/build.py --configuration Release` | **BUILD SUCCEEDED**; app and embedded extension at `build/Build/Products/Release/MacWallpaperEngine.app` |
| `tests/timer_tests` | Pass, 18 cases (11 pre-existing, 7 new) |
| `tests/video_frame_pacing_test` | Pass, 21 cases (all new) |
| `tests/playback_gpu_test` | Pass, 32 cases |
| `tests/video_decode_pump_test` | Pass, 13 cases |
| `tests/video_color_conversion_test` | Pass, 9 cases |

Counter-example check, run explicitly rather than asserted: with
`FrameTimer::SuspensionThreshold` temporarily reduced to the old fixed floor and
`timer_tests` rebuilt, `AContentWaitAtTheClampIsNotMistakenForASuspension` and
`TheSuspensionThresholdFollowsTheIntervalAndNeverDropsBelowTheFloor` fail; with
the real implementation restored, all 18 pass. The temporary edit was reverted
and the file re-verified before the suites above were run.

Not exercised, and therefore a skip rather than a pass: the local wallpaper
corpus, `scripts/test.py --ui`, and every desktop, visual or power measurement.

---

## Round 2 — M00's renderer-side counters

Round 1 recorded that the renderer half of M00 was not built and that P01, W02
and P02 could not be accepted without it. That is what this round built.

**implementation.** Counting lives where the work happens:

- `src/Core/RendererCounters.h` — the counter list as a C enum, included by the
  bindgen-visible `SceneWallpaperBindings.h`, so the names have one definition
  rather than one per language.
- `src/Core/RendererCounters.hpp` — an array of relaxed atomics behind one
  process-wide enable flag, default off. No thread, no timer, no output stream;
  reading is a pull.
- `FrameTimer` — counts a tick, the draw it posted, and separately a tick that
  posted nothing because a draw was still in flight, plus the interval and the
  content period it resolved.
- `SceneWallpaper`'s DRAW handler — draws executed, draws dropped because
  rendering was blocked, simulation ticks, render failures, and the effective
  pause reasons as independent bits recomputed on every transition that can
  change one.
- `VulkanRender` — queue submissions, present requests and frame-fence
  completions, on both the swapchain and the offscreen path.
- `TextureCache::UpdateVideoFrame` — the decoder's outputs and seeks, and the
  selected / reused / skipped accounting derived from the displayed generation
  sequence; conversions and imports mirrored from the stats it already kept.
- `FfmpegVideoTextureSource` — its own decoded-frame and seek totals, and the
  pacing evidence, reported through the new `VideoTextureSource::sourceStats`.

**Source work and surface work are separate.** `OWE_RC_TIMER_WAKEUPS` through
`OWE_RC_SIMULATION_TICKS` are work one surface performs alone and must stop when
nobody can see it. `OWE_RC_VIDEO_*` describe the decoded source, which may
legitimately keep running for another consumer. The Swift report prints them as
two labelled rows per surface, and
`RuntimeDiagnosticsReportTests.testSurfaceExclusiveWorkIsReportedApartFromSharedSourceWork`
asserts that a hidden surface's row does not carry decode counts.

**Exposure.** `owe_scene_wallpaper_counters` and `owe_renderer_shared_counters`
over the C ABI; `wallpaper_core::render::RendererSurfaceCounters` and
`WallpaperEngine::renderer_counters` with an actor message that performs no
snapshot update and no renderer mutation; the uniffi
`renderer_counters()` returning `BridgeRendererCountersReport` with named fields
only — no caller outside the renderer handles a raw index; and
`RuntimeDiagnosticsSession`, which opens both counter surfaces for a bounded
window and produces one aggregated report.

**Cost of the switch itself.** Enabling is a single relaxed atomic store; each
counted event is one relaxed load plus, when on, one relaxed add on a path that
already submits a command buffer or decodes a frame. Nothing polls. The
application only opens a session when `MAC_WALLPAPER_ENGINE_DIAGNOSTICS=<seconds>`
is set, the in-process session expires on its own, and the renderer side is
turned off again when it does. No per-frame JSON reaches Swift, and there is no
screenshot, pixel readback or periodic disk write anywhere in the path.

**What the counters can and cannot distinguish.** Covered by tests:

- Requested then cancelled: a tick that found a draw in flight increments
  `draw_ticks_suppressed`, not `draw_requests`
  (`timer_tests.CountersRecordWhatTheProductionSchedulerDid`). A posted draw
  that reached a blocked renderer increments `draws_dropped`, not
  `draws_executed`.
- Submitted but not yet complete: `render_submissions` is incremented at the
  queue submit and `gpu_completions` only after the frame fence signals, so the
  two differ while a frame is in flight.
- The same video frame used again: `video_frames_reused`
  (`video_frame_pacing_test.ANewGenerationIsSelectedAndARepeatIsReused`).
- A hidden surface that does not present while a shared source still serves
  another screen:
  `renderer_counters.a_hidden_surface_stops_its_own_work_while_a_shared_source_keeps_serving_the_other`.

**What is reported as unavailable.** `present_requests` counts requests. This
backend is MoltenVK over a `CAMetalLayer` swapchain and has no
presentation-feedback source, so the frames a compositor actually displayed are
reported as `presented_frames=unavailable` and are never approximated by the
request count. `a_request_to_present_is_never_reported_as_a_displayed_frame`
and `testPresentRequestsAreNeverReportedAsDisplayedFrames` pin that.

**Honest limit on the bridge-level tests.** The increments are in the renderer;
the bridge tests drive a fake facade and therefore check the reporting contract
— identity, separation, labelling — not the increments. The increments are
covered by `timer_tests` against the real `FrameTimer` and `ThreadTimer`, and by
`video_frame_pacing_test` against the real selection accounting. Whether the
full chain rises and stops on a real desktop is unverified.

---

## Round 2 — P02 re-examination

Three concerns were raised. One was falsified, two were confirmed as real
defects and fixed, and a fourth defect was found while checking them.

### Falsified: the `min` was taken over the wrong quantity

It was not. `ProbeShortestFrameDurationSeconds` computed `period = 1.0 / fps`
for each declared rate and took the smallest **period**, which is `1 / max(fps)`.
`ShortestPeriodComesFromTheHighestDeclaredRate` pins it in both argument orders.
The unit confusion does not exist and the concern is withdrawn.

### Confirmed: metadata alone was not evidence

source-confirmed: `frameDurationSeconds()` returned a value derived only from
`avg_frame_rate` and `r_frame_rate`, and the frame clock paced on it as soon as
the container was probed. `avg_frame_rate` is an average and `r_frame_rate` is
libavformat's estimate; neither describes a particular gap. A clip whose average
is 10 fps but which contains a 60 fps burst would have had five frames of that
burst stepped over per tick.

fixed-in-production: `Video/VideoFramePacing.{hpp,cpp}` adds a
`VideoFramePacingEstimator` that the decoder feeds with real presentation
timestamps. It reports **nothing** until it has `kMinimumSamples` usable gaps,
so an unproven stream keeps the fixed cadence. The reported period is the
smallest of the declared bound and every observed gap, and is monotonically
non-increasing, so a burst seen once keeps the clock fast afterwards. Deltas
across a loop seam or a seek are discarded because they describe the seam. A
repeated, rewound or non-finite timestamp is not counted as evidence at all,
which leaves the fixed cadence in place rather than pacing on a guess.

counter-example coverage in `video_frame_pacing_test` (21 cases): the VFR burst,
missing and invalid declared rates, a declared rate that bounds an over-optimistic
observation, a non-zero start timestamp, 23.976 and 29.97 as exact rationals,
duplicate and rewound timestamps, a non-finite timestamp, the loop seam, the seek
discontinuity, reset between streams, and 0.5x / 1x / 2x playback.

Bounded honestly: at most one frame can be missed at the first transition into a
rate tighter than both the declared bound and everything observed so far. That is
visible as `video_frames_skipped`, not hidden.

### Confirmed: playback speed was ignored

source-confirmed: `refreshFrameDemand` pushed the source's period straight to
the frame clock. `m_speed` is a real production parameter — `CMD_SET_SPEED`
forwards it to `SetVideoPlaybackRate`, and the DRAW handler advances scene time
by `IdeaTime() * m_speed`. At 2x a 30 fps clip delivers a new frame every 16.7 ms
of wall time, so pacing at 33.3 ms would have dropped every other frame.

fixed-in-production: `ResolveContentPeriodSeconds(source_period, rate)` divides
by the rate, and `refreshFrameDemand` now calls it and is re-run on
`CMD_SET_SPEED`. A non-positive or non-finite rate reports unknown and falls back
to the fixed cadence rather than inventing a period.

Gap: the resolution function is unit-tested; `refreshFrameDemand` itself needs a
loaded scene and is not covered by a headless test.

### Confirmed: the 5 s constant collided with the pacing clamp

source-confirmed: `ResolveInterval` clamped the content period to
`MAX_FRAME_DURATION` (5 s), and `FrameBegin` treated `elapsed > MAX_FRAME_DURATION`
as a suspension and replaced the elapsed time with one ideal frame. A scene paced
at the clamp therefore had every ordinary frame boundary misread as a resume, and
since that elapsed time is what advances the video clock, playback fell behind by
the difference on every frame — the "plays slower and slower" failure.

fixed-in-production: `FrameTimer::SuspensionThreshold()` is
`max(5 s, tick_interval × 3)`. An unpaced clock keeps the old floor exactly; a
paced clock gets a threshold proportional to the interval it is actually using.

counter-example: `AContentWaitAtTheClampIsNotMistakenForASuspension` and
`TheSuspensionThresholdFollowsTheIntervalAndNeverDropsBelowTheFloor` fail against
the old fixed floor and pass now; this was checked by temporarily restoring the
old expression, rebuilding and running, then reverting. `ARealSuspensionIsStillDetectedAtAPacedInterval`
keeps the other side: an eight-hour gap at a 5 s interval is still a resume, and
the scene is not handed eight hours of simulation.

Also covered now: several consecutive low-frequency updates keep reporting real
elapsed time rather than compressing it, and stopping with a draw pending does
not replay the stopped time or inherit a draw that will never complete.

### Withdrawn: "the failure mode is only that it does not save power"

Round 1 wrote that. It was wrong, and it is removed. Two of the three defects
above are frame loss or clock drift, not a missed saving. The acceptance signal
is no longer "fewer renders": `video_frames_selected`, `video_frames_reused`,
`video_frames_skipped` and `video_selected_generation` distinguish a frame
dropped by the configured FPS ceiling from one dropped by late decoding and from
one the pacing decision stepped over. A gap between two displayed generations is
exactly the number of decoded frames that never reached the screen.

### Not attempted, deliberately

The video presentation backend was not rewritten, and the static-scene classifier
was not built. `Unknown` stays conservative.

---

## Round 2 — phase C admission

| Task | Admission | Blocker |
|---|---|---|
| P02 static-scene classification | **blocked** | Needs a runtime-verified counter trail first: a wrong verdict freezes a live wallpaper, and `video_frames_skipped` plus `simulation_ticks` only bound it once they have been read from a real session |
| R01 render resolution split | **open, safe to develop** | Independent of measurement; `OutputExtent` / `SceneExtent` / `RasterExtent` is a correctness and plumbing change, and the quality tiers it exposes are user-selected rather than defaulted |
| D01 shared decode sessions | **open, safe to develop** | The counters now name `source_id` separately from `surface_id`, which is the identity a session would key on; correctness (independent pause, independent visibility) is testable headlessly. Any default-on sharing waits for measurement |
| R03 frame-graph work | **opt-in prototype only** | Static subgraph caching must ship behind a switch with a full time-series equivalence check, not a single still frame |
| A01 real-time audio path | **open, safe to develop** | SPSC ring, worker-thread FFT and anti-aliasing are correctness and latency work with their own tests; the saving claim waits for measurement |
| New native Metal backend | **prototype only, never default** | Requires the paired power measurement and the presentation-feedback question answered; this backend cannot currently report displayed frames at all |

Nothing above is blocked on power measurement for *development*. What power
measurement gates is which of them may become the **default**.

---

## Round 1 — status by task ID

| ID | Phase | Status | Power evidence |
|---|---|---|---|
| M00 | A | Implemented (minimal, as instructed) | n/a — makes measurement recordable |
| V01 | A | Implemented | correctness fix, not a saving |
| V02 | A | Implemented | correctness fix, prerequisite for V05/R04 |
| V03 | A | Implemented | correctness fix, not a saving |
| W01 | A | Implemented | removes repeated page rebuilds; unmeasured |
| P01 | B | Implemented | unmeasured |
| W02 | B | Implemented | unmeasured; page-side effect needs a desktop run |
| A01 | B | Consumer gating implemented; real-time path untouched | unmeasured |
| E01 | B | Implemented | unmeasured |
| P02 | B | First version implemented (content-rate pacing) | unmeasured |

## Round 1 — commands actually run

| Command | Result |
|---|---|
| `python3 scripts/test.py` (baseline, before any change) | Pass, 267 tests |
| `python3 scripts/test.py` (after phase A, P01, W02, A01) | Pass, 299 tests |
| `python3 scripts/test.py` (final, with E01) | Pass, 310 tests, 0 failed |
| `python3 scripts/check_renderer.py` | Pass, exit 0; 10 generated cases `pixels_equal=true`, 0 diagnostics; all seven test binaries exit 0 |
| `cargo test --release --workspace` (renderer, `CARGO_TARGET_DIR` unset) | Pass; 233 bridge cases, all other crates green |
| `python3 scripts/build.py --renderer-only` | Pass; bindings regenerated with the new API |
| `python3 scripts/tests/test_power_benchmark.py` | Pass, 11 cases |
| `artifacts/renderer/bin/tests/video_decode_pump_test` | Pass, 13 cases |
| `artifacts/renderer/bin/tests/video_color_conversion_test` | Pass, 9 cases |
| `artifacts/renderer/bin/tests/playback_gpu_test` (outside the sandbox) | Pass, 32 cases |
| `artifacts/renderer/bin/tests/timer_tests` | Pass, 11 cases (6 pre-existing, 5 new) |

Nothing was skipped silently. The local wallpaper corpus was not exercised; that
is a skip, not a pass.

---

## M00 — power baseline, per-backend counters, signpost

**Status: implemented (minimal form).**

- source-confirmed: the tree had no runtime counter surface and no benchmark
  configuration record. `AppLog` carries lifecycle text only.
- fixed-in-production:
  - `App/Services/Diagnostics/RuntimeCounters.swift` — per-surface counters
    behind a self-expiring session, off by default, bounded surface table with a
    `droppedSurfaceEvents` overflow count, and an aggregated (never per-frame)
    report. `RuntimeSurfaceKey` keys on kind + display id + generation so a
    reused display id across a hot-plug is not merged. Incremented by the
    presentation policy (P01), the web host and page (W01, W02).
  - `scripts/power_benchmark.py` — writes the configuration manifest from §6.1
    of the plan to `artifacts/power/`. It measures nothing: every condition is
    written `measured: false` and `measurement_tool` stays `null`.
- new tests: `Tests/Unit/Diagnostics/RuntimeCountersTests.swift` (8 cases),
  `scripts/tests/test_power_benchmark.py` (11 cases).
- docs: `docs/testing/power-benchmark.md`, indexed in `docs/README.md`.
- power-verified: **no**, by design.
- rollback: delete the two sources, the two test files, the doc and the
  `docs/README.md` row.

Deliberately not built: signpost instrumentation of the renderer and per-backend
GPU counters. Those need the GPU/desktop layer that is unavailable here.

---

## V01 — FFmpeg EAGAIN, EOF drain, cancellation state machine

**Status: implemented.**

- source-confirmed: in `FfmpegVideoTextureSource.cpp`, `decodeNextFrame()` called
  `av_packet_unref` immediately after `avcodec_send_packet` regardless of
  `AVERROR(EAGAIN)`, so a rejected packet was dropped; on `AVERROR_EOF` from
  `av_read_frame` it seeked and called `avcodec_flush_buffers` without ever
  sending a drain packet, discarding reordered tail frames; and neither the
  outer read loop nor the inner receive loop checked for cancellation.
- counter-example: `tests/video_decode_pump_test.cpp` reproduces the previous
  order in `LegacyDecodeNextFrame` and asserts it loses the rejected packet's
  frame (`received_frames == [2]`) and the reordered tail of every loop
  (`[1, 2, 5, 6]` instead of `[1, 2, 3, 4, 5, 6]`), while the new pump produces
  every frame. The fixture therefore distinguishes the two algorithms.
- fixed-in-production:
  - `src/Video/VideoDecodePump.{hpp,cpp}` — receive-first state machine over an
    abstract `VideoDecodeSource`. A packet is released exactly once and only
    after the decoder accepts it; the drain request is sent once per end of
    input; the stream restarts only after the decoder reports end of stream;
    cancellation is polled between every step; consecutive no-progress steps are
    bounded and reported as a failure; `ResetForSeek` and `fail` both release a
    held packet exactly once, tracked separately from the phase.
  - `FfmpegVideoTextureSource.cpp` — `Impl::DecodeSource` implements that
    interface over libavformat/libavcodec, skipping foreign-stream packets
    within a bound; the format context is allocated up front so an
    `AVIOInterruptCB` can abort a stalled read; `stop()` publishes an atomic
    cancel flag before taking the lock; `decodeNextFrame` returns
    `Frame/Cancelled/Failed` so a stop records no user-visible error; a minimum
    playback position that no frame satisfies stops being enforced after one
    full loop instead of filtering forever.
- new tests: 13 cases in `tests/video_decode_pump_test.cpp`, built and run by
  `scripts/check_renderer.py`.
- tests-passing: yes (13/13, and the renderer gate is green).
- not done: no synthetic H.264/HEVC B-frame clip is decoded end to end. The
  reordering contract is covered at the state-machine level with a scripted
  decoder, not with a real codec. Recorded as a gap, not a pass.
- visually-verified / power-verified: **no.**
- rollback: revert the two new files, the `Video/VideoDecodePump.cpp` line in
  `src/CMakeLists.txt`, the test target, and the `FfmpegVideoTextureSource.cpp`
  hunks.

---

## V02 — Core Video / Metal resource lifetime and FrameLease

**Status: implemented.**

- source-confirmed: `CreatePixelBufferBackedMetalTexture` released the
  `CVMetalTextureRef` before returning, keeping only the vended `MTLTexture`.
  Apple documents the wrapper as the object whose lifetime governs the texture.
- fixed-in-production:
  - `FfmpegVideoInterop.mm` — `AppleVideoFrameLease` owns the `MTLTexture`, the
    Core Video texture wrapper per plane, and the `CVPixelBuffer` (an imported
    frame outlives the decoder slot it came from). `CreateAppleVideoFrameLease`
    replaces `CreateAppleVideoMetalTextureForDevice`;
    `AppleVideoFrameLeaseTexture` borrows the texture;
    `TakeAppleVideoFrameLeaseDestination` hands a poolable conversion
    destination to the pool exactly once; `ReleaseAppleVideoFrameLease` releases
    everything once. The unused `CreateAppleVideoMetalTexture` was removed
    rather than left as a shim.
  - `Vulkan/TextureCache.{cpp,hpp}` — `ImportedVideoFrame::frame_lease` holds the
    lease; its deleter returns the destination to the pool before releasing.
  - `tests/playback_gpu_test.mm` migrated to the lease API.
- tests-passing: `playback_gpu_test` 32/32 outside the command sandbox, covering
  pool reuse, generation dedup, cache eviction, recording-discard recovery and
  fault injection.
- not done: no Metal API-validation or leak-instrumented run. Release/retain
  balance is argued from the code and from the passing lifetime tests, not from
  a validation layer. Recorded as a gap.
- rollback: revert `FfmpegVideoInterop.{hpp,mm}`, `TextureCache.{cpp,hpp}` and
  the GPU test hunk.

---

## V03 — limited-range colour conversion, CPU and Metal

**Status: implemented.**

- source-confirmed: both the CPU converter and the `nv12_to_bgra` kernel read
  chroma as `sample/255 - 0.5` while applying limited-range luma handling and
  the standard coefficients. Limited-range 8-bit chroma spans 224 code values
  around 128, so every studio-swing frame was desaturated and shifted.
- counter-example: `VideoColorConversion.LimitedRangeChromaUsesItsOwnExcursion`
  asserts the reference result for BT.709 `Y=126, Cb=128, Cr=160` is
  `(185, 111, 128)` and that the previous formula gives `(179, 113, 128)` — the
  same two values the plan derived by hand.
- fixed-in-production:
  - `src/Video/VideoColorConversion.{hpp,cpp}` — one description
    (matrix, range, bit depth, whether the matrix was inferred) and one
    parameter struct with independent luma and chroma offset and scale, derived
    from the Kr/Kb coefficients. Unspecified metadata is inferred from the
    resolution and logged once per distinct colorimetry instead of silently
    using BT.601. Constant-luminance BT.2020 is substituted with NCL and marked
    inferred rather than claimed as supported.
  - `FfmpegVideoInterop.mm` — the CPU NV12 and planar paths call the shared
    conversion; the Metal kernel takes the same struct, field for field.
- new tests: `tests/video_color_conversion_test.cpp` (9 cases: the worked
  example, neutral chroma, studio black/white with clamping, full-swing range,
  75% colour bars round-tripped from their RGB primaries, matrix separation,
  resolution inference, bit-depth scaling) plus
  `PlaybackGPU.MetalConversionMatchesTheCpuColorReference`, which compares the
  Metal kernel against the CPU reference for six sample triples across both
  ranges and BT.601/709/2020.
- tests-passing: yes (9/9 headless, and the GPU comparison passes).
- visually-verified: **no.** No real wallpaper was displayed or compared; there
  is no authored reference frame for a Wallpaper Engine video in this repo.
- rollback: revert the two new files, the `src/CMakeLists.txt` line, the test
  target and the `FfmpegVideoInterop.mm` colour hunks.

---

## W01 — Web identity, committed-state replay, crash budget

**Status: implemented (all three sub-items).**

### W01-a entry identity

- source-confirmed: `WebWallpaperHost.apply` compared
  `window.page.entryURL.lastPathComponent == wallpaper.entryFile`, so an entry
  such as `sub/index.html` never matched itself and every reconcile rebuilt the
  page.
- fixed-in-production: `WebWallpaperPage.canonicalEntryURL(projectURL:entryFile:)`
  resolves symlinks, standardizes the path, rejects an absolute entry and
  rejects anything outside the project folder; the host compares that value and
  reports a rejected entry instead of opening a page.
- counter-example / tests: `testRepeatedIdenticalReconcilesDoNotRebuildANestedEntryPage`
  fails on the old comparison (`webPageCreated` would rise per reconcile) and
  passes now; plus nested/normalized/escaping-entry cases.

### W01-b committed-state replay

- source-confirmed: `flush()` cleared the pending property, general and paused
  values, and `didFinish` re-flushed an empty set, so a reload after a crash
  restored nothing; the host's descriptor diff sends nothing when nothing
  changed.
- fixed-in-production: the page keeps one `CommittedState` snapshot and replays
  all of it on every new document generation; every async host call carries the
  generation it was issued for and is dropped if the document moved on;
  `load()` and `stop()` both advance the generation.
- tests: `testAReloadedDocumentGetsTheWholeCommittedStateBack`,
  `testUserPauseSurvivesAReloadAndPresentationResume`,
  `testLoadInvalidatesHostCallsIssuedForTheOldDocument`.
- plan deviation: the plan asks for `committedSnapshot` plus `pendingDelivery`.
  A separate pending layer turned out to be unnecessary — "not yet loaded" is
  the only pending state, and the committed snapshot already coalesces repeated
  values — so there is one layer plus an `isLoaded` gate.

### W01-c crash budget

- source-confirmed: `didFinish` reset `recoveryAttempted` to false, so a page
  crashing after each successful load could be restarted forever.
- fixed-in-production: a time-windowed restart history with exponential backoff
  capped at `maximumBackoff`, a failure reported once the budget is spent, and a
  budget that is only returned when the previous document ran for
  `recovery.stableRun` — measured from the clock at the crash, not from a timer
  that a test or a fast crash could collapse.
- tests: `testRepeatedCrashesAfterASuccessfulLoadExhaustTheBudget`,
  `testAStableRunReturnsTheRestartBudget`,
  `testCrashesOutsideTheWindowDoNotCountAgainstTheBudget`,
  `testStoppingAPageCancelsAPendingRestart`.
- not done: the static-poster degradation the plan mentions for an exhausted
  budget. The current behaviour reports the failure and leaves the last frame;
  it does not save and install a poster for that case.
- rollback: revert `WebWallpaperWindow.swift`, `WebWallpaperHost.swift` and
  `Tests/Unit/WebWallpaper/WebWallpaperRecoveryTests.swift`.

---

## P01 — per-surface and per-display presentation suspension

**Status: implemented.**

- source-confirmed: `WallpaperPresentationPolicy` held a single `isSuspended`
  and `desktopIsVisible()` returned true when *any* wallpaper window was
  visible; the bridge held a single `presentation_suspended` bool and applied it
  with `set_all_paused`; `WebWallpaperHost` pushed one `suspended` value to
  every page.
- fixed-in-production:
  - Swift `WallpaperPresentationPolicy` now maps display id to
    `WallpaperSurfaceVisibility`, keeps global reasons (display sleep, session
    lock) apart from per-display occlusion, resumes immediately but debounces
    occlusion-driven suspension, drops state for displays that disappear,
    serializes delivery with one transition in flight, and does not retry a
    rejected transition in a loop. `stop()` resumes every surface it suspended.
  - Rust: `BridgeActorState.suspended_displays` beside the global flag;
    `ActivationInputs` resolves each scene's and web descriptor's paused state
    from its own display, mirrors included; `EngineFacade::set_display_paused`
    maps a display to its scene handle; a global resume re-applies the displays
    that are still hidden; the new uniffi
    `set_display_presentation_suspended(display_id, suspended)` carries one
    display's decision. Mouse polling follows whether any display still
    presents.
  - `WebWallpaperHost.setPresentationSuspended(_:forDisplay:)` and
    `AppDelegate` wiring deliver the per-display decision to both the pages and
    the renderer.
- invariants held by tests: a hidden display does not pause a visible one
  (`testHidingOneDisplayLeavesTheOtherRunning`,
  `suspending_one_display_leaves_the_other_rendering`); a visible display does
  not resume a hidden one (`testRevealingOneDisplayResumesOnlyThatDisplay`,
  `resuming_one_display_does_not_resume_a_display_that_is_still_hidden`); a
  global resume keeps a covered display paused
  (`a_global_resume_keeps_a_display_that_is_still_covered_paused`,
  `testGlobalSuspensionDoesNotClearAPerDisplaySuspension`); a user pause is
  never cleared by visibility (`a_user_pause_survives_per_display_resume`);
  hot-plug and occlusion flapping settle without a burst of transitions; a
  rejected transition rolls back and is retried later.
- two real defects were found by these tests and fixed: the delivery queue did
  not drain after a successful transition (only one display would ever be told),
  and a decision that changed while in flight was dropped.
- tests-passing: yes — Swift policy suite and
  `crates/bridge/src/tests/display_presentation.rs`.
- **counters do not yet prove the renderer stopped.** The assertions are on the
  decision and on the descriptor state the next reconcile builds. Whether
  `render_submission` and `present` actually stop for a hidden surface needs the
  renderer-side counters (M00's unbuilt half) and a desktop run. Unverified.
- power-verified: **no.**
- rollback: revert `WallpaperPresentationPolicy.swift`, the `AppDelegate` and
  `BridgeStore` hunks, `WebWallpaperHost.swift`, and the Rust hunks in
  `actor/{state,messages,bridge}.rs`, `engine/{facade,activation}.rs`,
  `api/mod.rs`; then rerun `scripts/build.py --renderer-only` to regenerate
  bindings without the new method.

---

## W02 — real web suspension

**Status: implemented; the page-side effect is unverified here.**

- source-confirmed: `setPresentationSuspended` only reached the page's optional
  `wallpaperPropertyListener.setPaused`, so a page that ignores it kept its
  timers, workers, WebGL and media running.
- fixed-in-production, three host-side controls that do not need the page's
  cooperation:
  1. `WKWebView.setAllMediaPlaybackSuspended(true/false)` — suspend and
     unsuspend, never `pauseAllMediaPlayback`, so media the user had paused is
     not started by a resume.
  2. The web view is removed from the window tree, which is the documented
     trigger for WebKit's inactive scheduling policy, and
     `WKPreferences.inactiveSchedulingPolicy = .suspend` is set on the
     configuration. `WebWallpaperWindow` now hosts the web view inside a stable
     container view so the desktop poster sync keeps identifying the surface by
     the same content layer.
  3. A snapshot taken before detaching stays on screen as a placeholder; a
     resume that overtakes the asynchronous snapshot cancels the detach through
     a generation counter.
  Pointer delivery is gated: a suspended page receives no events.
- no `requestAnimationFrame` wrapper and no signal to the shared WebContent
  process are used.
- tests: `Tests/Unit/WebWallpaper/WebWallpaperSuspensionTests.swift` — detach
  and reattach with the placeholder installed and removed, counters per surface,
  flapping settling attached, pointer gating, and a surface that is already
  hidden never attaching in the first place. The document generation is asserted
  unchanged across a suspension, so suspension does not silently reload the page
  and lose its state.
- **not verified here:** that the page's own rAF, timers, CSS animations, WebGL,
  media and workers actually stop. Two observations from this round bound what
  can be claimed: a detached web view with `.suspend` stops answering
  `callAsyncJavaScript` at all (consistent with suspension, and the reason the
  headless tests assert host state instead), and in a windowless test container
  script execution is unreliable even before detaching. A real measurement needs
  a desktop window and `WebContent` process observation. Recorded as unverified.
- not done: the third tier the plan describes — destroying and rebuilding the
  web view for a page that still cannot be suspended, under an explicit user
  choice.
- rollback: revert the `WebWallpaperWindow.swift` suspension section, the
  container change, the `inactiveSchedulingPolicy` line and the test file.

---

## A01 — audio consumers

**Status: consumer control implemented; the real-time path is untouched.**

- source-confirmed: `apply_engine_pause` called
  `set_audio_capture_suspended(paused)` with the same global pause flag, so
  system audio capture followed the pause bool rather than whether anything
  consumed audio.
- fixed-in-production: `BridgeActor::audio_capture_suspended()` derives the
  decision from the built scene list — a scene counts as a consumer only when it
  has `audio_response_enabled` **and** is not paused for its own display — and
  falls back to the global condition when the scene list cannot be resolved.
  Both the global and the per-display transition apply it.
- tests: `audio_capture_stops_when_the_only_audio_consumer_is_hidden`,
  `a_presentation_transition_never_opens_the_tap_without_a_consumer`,
  `muting_a_wallpaper_does_not_stop_its_audio_response`.
- one existing test was updated, not deleted:
  `presentation_suspension_pauses_without_changing_playback_state` asserted
  `audio_capture_suspend_calls() == [true, false]` for a bridge with no
  wallpapers at all. Under A01 a resume with no consumer must not open the tap,
  so it now asserts `[true, true]` with that reason stated in the test.
- deliberately **not** done, as instructed: the real-time callback was not
  rewritten. There is no SPSC ring, no worker-thread FFT, no resampler buffer
  reuse and no anti-aliasing review. `AudioCaptureController`'s existing
  enabled-handle and global-suspend design is unchanged apart from what feeds
  it.
- web pages are not counted as audio consumers; web audio response is still
  unimplemented, as `docs/features/web-wallpapers.md` states.
- power-verified: **no.**

---

## E01 — desktop, lock screen and preview presentation ownership

**Status: implemented.**

- source-confirmed: `Extension/WallpaperSurface.applyPolicy()` computed

  ```swift
  scene.paused || displaysAsleep || activity == "suspended"
    || (!preview && !locked && presentation != "locked" && presentation != "idle")
  ```

  The `!preview &&` guard makes the whole consumer clause false for a preview,
  so **a preview surface was never suspended by presentation state**: once it
  produced its readiness frame it kept rendering for as long as it existed.
  That is exactly the plan's "first-frame success must not become a permanent
  right to keep presenting". Non-preview surfaces were already correct — the
  policy is applied after the readiness frame, and the desktop is a frozen
  poster — so that half was not re-implemented.
- source-confirmed: there was no way to observe both processes together.
  `RuntimeCounters` was application-only, so "no instance keeps presenting with
  no consumer" could not be read from the extension at all.
- fixed-in-production:
  - `Shared/WallpaperPresentationAuthority.swift` — one presentation-eligibility
    rule set compiled into both targets. Reasons are an `OptionSet`
    (`userPaused`, `displaysAsleep`, `hostSuspended`, `noConsumer`,
    `previewBudgetSpent`) so clearing one never clears another and the user's
    pause stays independent of visibility. A lock-screen surface presents only
    while the session is locked or the host reports a presenting mode; a preview
    presents for a bounded `previewBudget` (10s) and then holds its last frame,
    unless continuous preview is explicitly requested. `nextReevaluation` tells
    the caller when the decision changes on its own, so nothing polls.
  - `Extension/WallpaperSurface.swift` — builds that request, applies the
    decision, and schedules its own preview expiry so a preview stops without
    waiting for a host update that may never arrive. `presentingSince` is set by
    the first frame and is separate from the readiness reply, and the readiness
    frame is counted as `readinessFrameRendered` rather than as authorized
    presentation. `releaseRenderer` cancels the expiry task and clears the
    presenting clock.
  - `Shared/RuntimeCounters.swift` — moved from `App/Services/Diagnostics/` so
    both processes count the same events through one implementation instead of
    evolving separate vocabularies; `presentationAuthorized` and
    `readinessFrameRendered` were added for the extension's surfaces.
    `WallpaperController` passes the surface revision as the counter generation.
- new tests: `Tests/Unit/LockScreen/WallpaperPresentationAuthorityTests.swift`
  (11 cases): lock-screen consumer conditions and unlock, display sleep and host
  suspension overriding a visible lock screen, the user's pause surviving
  visibility changes in both directions, every reason reported rather than the
  first, the preview budget and its expiry, the readiness frame not buying
  permanent playback, explicit continuous preview still yielding to a user
  pause, a closed preview stopping immediately rather than waiting out its
  budget, and which requests schedule their own re-evaluation.
- tests-passing: yes. `scripts/test.py` builds the embedded extension, so the
  shared files are also confirmed to compile under
  `APPLICATION_EXTENSION_API_ONLY`.
- **not verified:** no lock, unlock, display-sleep or preview-close transition
  was exercised against the real extension, and no joint per-process submission
  count was captured. The rules are tested; the extension's behaviour under
  those system events needs an authorized desktop run. The app and extension
  still do not exchange presentation state at runtime — the shared rule set
  makes them agree by construction rather than by negotiation, which is weaker
  than the plan's "bounded generation authorization" and is recorded as such.
- rollback: revert `Extension/WallpaperSurface.swift` and
  `Extension/WallpaperController.swift`, delete
  `Shared/WallpaperPresentationAuthority.swift` and the test file, and move
  `Shared/RuntimeCounters.swift` back to `App/Services/Diagnostics/`.

## P02 — demand-driven scheduling (first version)

**Status: first version implemented — content-rate pacing for the one scene
whose demand is provable. No static-scene classification was attempted.**

Two findings shaped the scope, and both are worth keeping:

1. **Pausing already stops the clock.** `SceneWallpaper`'s `CMD_STOP` handler
   calls `frame_timer.Stop()`, and `FrameTimer` is a condition-variable timer,
   so a paused or render-blocked scene is not ticking at all. The plan's
   "suspended surfaces stop producing work" is therefore already true for the
   pause path that P01 now drives per display. Not re-implemented.
2. **The tick rate was the user/display ceiling, not the content rate.** The
   required FPS comes from `config.fps` (the monitor's target clamped to the
   display refresh rate), so a 30 fps video on a 60 fps target rendered twice
   per decoded frame and presented a duplicate every other frame. That is the
   plan's own acceptance item about a 24/30/60 fps video not being driven by the
   display refresh rate, and it is what this first version fixes.

- source-confirmed: `FrameTimer`'s tick period was always `m_ideatime`, derived
  only from `SetRequiredFps`. Nothing in the engine reported how often content
  could change.
- fixed-in-production:
  - `src/Scene/Timer/FrameTimer.{hpp,cpp}` — a `FrameDemand` value carrying a
    `content_period`, pushed with `SetFrameDemand` and resolved into the tick
    interval by `ResolveInterval`. The period can only **lengthen** the
    interval: it is ignored unless it exceeds the ideal frame time, so the
    user's and the display's ceiling always wins, and it is clamped to
    `MAX_FRAME_DURATION` (5s) so a bad period cannot stall a scene. Zero or
    negative means unknown and keeps the fixed cadence. `TickInterval()` exposes
    the result. The single-DRAW-in-flight backpressure is untouched.
  - `src/Scene/include/Scene/Scene.h` — `single_video_source`, set **only** by
    `CreateVideoProjectScene`, next to the construction that justifies it: one
    video texture, a copy shader, a `NoOpShaderValueUpdater`, and no script,
    particle, audio or pointer input. Authored scenes never set it.
  - `src/Video/VideoTextureSource.hpp` + `FfmpegVideoTextureSource` —
    `frameDurationSeconds()` reports the **shortest** plausible period
    (`min` over `avg_frame_rate` and `r_frame_rate`), not the average. A
    variable-frame-rate clip whose average is longer than its tightest gap would
    otherwise lose the frames inside that gap; the shortest period can only ever
    render more often than needed. Zero before priming, which reads as unknown.
  - `src/Vulkan/TextureCache.cpp` — `ShortestVideoFramePeriod()` returns the
    shortest period across live video sources, and returns 0 (unknown) if **any**
    source cannot report one, because pacing on the others could skip its
    changes.
  - `src/Scene/VulkanRender/VulkanRender.cpp` — forwards it.
  - `src/Scene/SceneWallpaper.cpp` — `refreshFrameDemand()` pushes the period
    from the **render thread** after each completed frame and on every
    stop/resume transition. It reports a period only for a `single_video_source`
    scene with an initialized renderer; every other scene reports nothing and
    keeps the fixed cadence, because an authored scene may change on a time
    uniform, a script write, a particle system, audio reactivity or a feedback
    texture that this code does not enumerate. The demand is pushed rather than
    pulled precisely so the timer thread never reaches into scene or renderer
    state.
- new tests: 5 cases in `tests/timer/frame_timer_test.cpp` —
  content that changes less often lowers the tick rate; the configured FPS stays
  the ceiling (a 60 fps video does not make a 30 fps wallpaper render at 60); an
  unknown, zero, negative or absurdly long period cannot stall the scene (1h is
  clamped to 5s); dropping the demand restores the fixed cadence rather than
  inheriting the previous scene's; and pacing does not change how many draws may
  be in flight. `timer_tests` was added to `scripts/check_renderer.py`, which did
  not previously run it.
- tests-passing: yes (11/11 in `timer_tests`; the renderer gate is green with
  `pixels_equal=true` on all ten generated cases and no diagnostics).
- **not verified:** that a real video wallpaper now renders once per decoded
  frame. The interval arithmetic and its bounds are tested; the end-to-end
  effect needs a desktop run reading the existing video submission counters, and
  it must be checked against equal presented frame rate and identical pixels.
  Recorded as unverified.
- invariant check: this does **not** lower FPS, resolution or quality to fake a
  saving. It removes renders that would present pixels identical to the previous
  frame, for a scene whose only time-varying input is the video, and it cannot
  raise or lower the rate outside the ceiling and the 5s floor.
- deliberately not done: static-scene classification. A `KnownStatic` verdict
  needs a positive answer about every dynamic render-graph input — time
  uniforms, SceneScript writes, particles, audio reactivity, feedback textures,
  dynamic visibility — and a wrong verdict freezes a live wallpaper. The
  mechanism is in place for it; the classifier is not, and `Unknown` stays
  conservative.
- rollback: revert `FrameTimer.{hpp,cpp}`, the `Scene.h` field and its assignment
  in `SceneWallpaper.cpp`, `refreshFrameDemand` and its two call sites, the
  `frameDurationSeconds` additions in `VideoTextureSource.hpp`/
  `FfmpegVideoTextureSource.{hpp,cpp}`, `ShortestVideoFramePeriod` in
  `TextureCache` and `VulkanRender`, the `SyntheticVideo` override in
  `playback_gpu_test.mm`, the five timer cases, and the `timer_tests` entries in
  `scripts/check_renderer.py`.

---

## Next actionable task

Everything reachable without a real desktop has been done. What remains needs
authorization, and each item below states exactly what would be run.

### 1. Authorized desktop run with a counter session

Launch the Release build with `MAC_WALLPAPER_ENGINE_DIAGNOSTICS=120` and an
isolated `MAC_WALLPAPER_ENGINE_HOME`, then exercise, in one session:

- Two displays, a window fully covering one wallpaper, then uncovering it.
- Both displays covered, then a Space switch, then display sleep and wake.
- Lock and unlock; a system preview opened and closed.
- A wallpaper switch on one display and a hot-plug.

The three claims to check against the report:

- **A.** With one display hidden, its `surface=` row stops rising —
  `render_submissions`, `present_requests`, `gpu_completions`, `draws_executed`
  — while the other display's keeps rising, and `reasons=` names
  `clockStopped` on the hidden one only.
- **B.** A web wallpaper that implements no Wallpaper Engine pause callback
  actually stops. This needs more than `webDetached`: the page must be off the
  window tree rather than merely hidden, and `requestAnimationFrame`,
  `setInterval`, CSS animation, WebGL, a Worker and media each have to be
  checked separately, on resume as well as on suspend. The probe itself must not
  wake the page it is measuring, resume must not clear a pause the user chose,
  and a failing page must not turn recovery into a reload loop.
- **C.** With a 24/30 fps clip on a 60 Hz display, `draw_requests` falls toward
  the content rate while `video_frames_skipped` stays at zero,
  `video_frames_selected` tracks `video_decode_outputs`, and the playback
  timeline is unchanged. Repeat at 0.5x and 2x. Then repeat the whole run with
  `MAC_WALLPAPER_ENGINE_DISABLE_CONTENT_PACING=1` for the A/B pair.

Environment to record before starting, not assumed from an earlier session: the
chip, the attached displays with their pixel geometry and refresh rate, the
macOS build, and the charging and thermal state. `scripts/power_benchmark.py`
writes exactly that.

Requires: desktop control, wallpaper changes, lock/unlock and display sleep.
None of it is authorized yet.

### 2. Paired power measurement

Following [testing/power-benchmark.md](testing/power-benchmark.md): equal
content, equal output geometry, equal real presented frame rate, observing the
application, `WebContent`, the extension and `WindowServer` — not the main
process alone. Two builds, if compared, need separate build directories and
isolated application data, measured serially. Until raw samples exist, only work
counts may be reported, never watts or a percentage.

Requires: `powermetrics` or an equivalent, which needs elevation.

### 3. Phase C, in the admission order recorded above

R01, D01 and the A01 real-time path can be developed now. R03's static subgraph
cache and any new backend stay opt-in. P02's static-scene classifier stays
blocked until 1 has produced a counter trail that can falsify a static verdict.
