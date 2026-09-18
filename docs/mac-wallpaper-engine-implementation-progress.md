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
