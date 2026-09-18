#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace wallpaper::video
{

/// Shape and format of one video conversion destination.
///
/// The conversion kernel writes the destination in full and the importer
/// reinterprets its bytes, so a destination can only satisfy a request with
/// exactly the same width, height and pixel format. These are the dimensions
/// of the *decoded* frame: a surface or display size is a different quantity
/// and never belongs in this key.
struct VideoConversionSlotKey {
    std::uint32_t width { 0 };
    std::uint32_t height { 0 };
    std::uint32_t pixel_format { 0 };
};

[[nodiscard]] constexpr bool operator==(const VideoConversionSlotKey& lhs,
                                        const VideoConversionSlotKey& rhs)
{
    return lhs.width == rhs.width && lhs.height == rhs.height &&
           lhs.pixel_format == rhs.pixel_format;
}

/// One conversion destination as the budget accounts for it.
struct VideoConversionSlot {
    VideoConversionSlotKey key {};
    /// Bytes the platform reports it actually allocated. A width * height *
    /// bytes-per-pixel product is not this number; alignment and tiling make
    /// the real cost larger, and a budget that guesses it is not a budget.
    std::uint64_t bytes { 0 };
    /// Opaque platform handle. The budget stores and returns it, and never
    /// dereferences it, which is what keeps this arithmetic testable without
    /// a GPU.
    void* resource { nullptr };
};

/// Why a destination was not taken into the reuse pool. Every value is a final
/// answer for the inputs it was returned for: the caller releases the
/// destination and does not ask again with the same size until the budget is
/// told something changed.
enum class VideoConversionRefusal {
    None,
    /// The destination is still on loan. It was handed out by `Take` or
    /// committed by `CommitAllocation`, and the GPU completion that ends its
    /// use has not been reported, so pooling it would let a second frame
    /// overwrite a texture the first one still reads.
    StillOnLoan,
    /// Already pooled. Admitting the same handle twice would hand one texture
    /// to two frames at once.
    AlreadyPooled,
    /// One slot of this size does not fit the whole ceiling, so caching this
    /// resolution can never succeed and is not attempted again. Also the
    /// answer for a slot with no handle or no measured size: a destination the
    /// budget cannot account for is one it cannot show to fit.
    SlotExceedsCeiling,
    /// A destination of this size failed to allocate. That size and larger are
    /// neither cached nor attempted again until `Reset`, so a failing
    /// allocation costs one attempt instead of one per frame. This is the one
    /// reason `ReserveAllocation` denies a reservation, and it is not a
    /// capacity answer — see that function for why denying here withholds
    /// nothing.
    AllocationUnsatisfiable,
    /// The platform reported memory pressure. Nothing is cached until
    /// `ClearMemoryPressure`.
    MemoryPressure,
    /// The pool already caches a destination this request could itself reuse,
    /// and the bytes in flight — checked out, awaiting GPU completion, and
    /// covered by granted reservation estimates — leave no room under the
    /// effective ceiling for a second one. Caching that second idle slot would
    /// bet on more concurrency than the ceiling admits, so it is refused, and
    /// refused before anything is evicted so the slot already proven reusable
    /// stays cached.
    ///
    /// The *first* cached slot of a shape is never refused for capacity, however
    /// full the ledger is. Admission does not allocate: the destination exists
    /// already, and it is exactly the one the caller's next import would
    /// allocate, so refusing it lowers no peak and only buys an allocate/free
    /// pair per frame. Unlike `SlotExceedsCeiling` this is a statement about
    /// right now, not about the size: it stops applying when those frames
    /// retire, and the caller may ask again at the next frame.
    LiveAllocationAtCeiling,
};

[[nodiscard]] const char* VideoConversionRefusalName(VideoConversionRefusal);

struct VideoConversionAdmission {
    bool                   accepted { false };
    VideoConversionRefusal refusal { VideoConversionRefusal::None };
};

/// What `VideoConversionBudget::ReserveAllocation` granted.
///
/// A plain aggregate: copyable, owning nothing, safe to store beside the
/// allocation it describes and to hand back later. It must be handed to
/// `CommitAllocation` or `CancelReservation` exactly once, because the budget
/// releases the estimate by subtracting `estimated_bytes` and cannot mark a
/// caller's copy as spent.
struct VideoConversionReservation {
    /// An estimate is booked and must be released exactly once, by
    /// `CommitAllocation` or `CancelReservation`. False means no estimate was
    /// booked and there is nothing to release, which both of those calls
    /// handle: either `ReserveAllocation` denied the request — see `refusal`,
    /// and `AllocationUnsatisfiable` is the only value it ever takes — or this
    /// is the default-constructed value a caller carries when it never asked
    /// for a reservation at all.
    bool          granted { false };
    /// Granted even though the request does not fit under the effective
    /// ceiling with an empty cache. The allocation still happens — see
    /// `ReserveAllocation` for why refusing for capacity is not an option —
    /// and `over_ceiling_grants()` counts it so the overshoot is visible.
    bool          over_ceiling { false };
    std::uint64_t estimated_bytes { 0 };
    /// Why the request was denied, or `None`. `ReserveAllocation` has exactly
    /// one denial reason, `AllocationUnsatisfiable`, and it is never a
    /// capacity one: capacity is reported, never refused.
    VideoConversionRefusal refusal { VideoConversionRefusal::None };
    /// Set on the first `AllocationUnsatisfiable` denial of an episode and on
    /// no other reservation, so a caller that asks every frame logs once
    /// instead of once per frame. `Reset` — which is also what clears the
    /// recorded failing size — starts a new episode.
    bool          first_unsatisfiable_report { false };
    /// `loan_count()` was already at or above `in_flight_slot_cap()` when this
    /// was granted. A diagnostic and nothing else: the reservation was granted
    /// regardless, because refusing deadlocks. See `in_flight_cap_breaches()`.
    bool          in_flight_cap_breached { false };
    /// Set on the first breach of an episode and on no other reservation, so a
    /// caller that asks every frame reports the condition once instead of once
    /// per frame. A returned destination, or `Reset`, starts a new episode.
    bool          first_in_flight_cap_report { false };
};

class VideoConversionMemoryDomain;

/// Ceiling, live-allocation ledger and degradation policy for video conversion
/// destinations.
///
/// Slot sizing, admission, eviction choice and the exhaustion policy live here
/// and are expressed in byte counts and opaque handles, so the platform pool
/// only executes decisions it does not make. Nothing in this class knows about
/// Metal, Core Video or Vulkan.
///
/// **One destination, one state.** Every destination the budget has been told
/// about is in exactly one of three states, and its measured bytes are counted
/// in exactly one of three places:
///
/// * `Available`   — idle in the reuse pool, counted by
///                   `available_cached_bytes()`.
/// * `CheckedOut`  — handed to an import that has not yet reported the GPU may
///                   reference it, counted by `checked_out_bytes()`.
/// * `AwaitingGpu` — referenced by a live imported frame, counted by
///                   `awaiting_gpu_completion_bytes()`.
///
/// `total_live_conversion_allocation_bytes()` is the sum of exactly those
/// three. A handle never contributes to two of them, and it leaves the ledger
/// entirely when the caller reports GPU completion — at that moment the caller
/// owns it outright and either re-admits it with `Admit` or releases it.
///
/// `reserved_estimate_bytes()` is a fourth and separate quantity: estimates
/// for allocations that have been granted but not yet made. Those are intents,
/// not allocations, so they are deliberately not part of the live total. They
/// do count against the ceiling, because an intent the caller is about to act
/// on is about to become real, and they are released by `CommitAllocation`
/// (replaced by the measured cost) or `CancelReservation` (dropped).
///
/// **What these numbers are not.** This is a ledger of allocations the
/// platform reported for video conversion destinations, and for nothing else.
/// It is not physical memory residency: the budget cannot observe paging,
/// purgeable state or compression, and never claims to. Decode
/// `CVPixelBuffer`s and the `IOSurface`s behind them, Vulkan swapchain images,
/// staging buffers, shader resources, render targets and every other
/// intermediate are outside this ledger and are never counted by it. A total
/// here is a lower bound on what video playback costs, never the whole cost.
///
/// **What the ceiling covers.** One budget belongs to one conversion pool, one
/// pool belongs to one texture cache, and one texture cache belongs to one
/// renderer instance. Several displays driven by one scene share that single
/// pool and therefore one ceiling. A process that runs N renderer instances
/// holds N ceilings; `VideoConversionMemoryDomain` is how those N are made to
/// add up, and it is opt-in through `AttachDomain`. Nothing coordinates across
/// processes: the lock-screen extension runs its own renderer in its own
/// address space with its own domain, and this class has no visibility into
/// it whatsoever.
class VideoConversionBudget {
public:
    /// Destinations that can coexist for a single video texture: the imported
    /// frames a texture cache keeps
    /// (`TextureCache::kMaxImportedVideoFramesPerVideoTex`) plus the ones an
    /// unretired import submission still references
    /// (`TextureCache::kMaxPendingVideoImportSubmissions`). Those two caps are
    /// what bounds the count; the budget derives its sizing from them rather
    /// than inventing a number of its own.
    ///
    /// This is the *floor* of the reported in-flight threshold, not the
    /// threshold itself. It is the whole answer for a pool serving one video
    /// texture; a pool serving several raises it through
    /// `SetInFlightSlotCap`, because the per-video-texture term scales with
    /// the number of them. Ceiling sizing keeps using this floor, so the
    /// default ceiling stays a statement about one video texture's working set
    /// rather than about however many a scene happens to show.
    static constexpr std::uint32_t kCoexistingSlots = 6;
    /// Bytes one 3840x2160 BGRA8 destination costs. This is the reference
    /// resolution the default ceiling is sized against, not a limit.
    static constexpr std::uint64_t kReferenceSlotBytes = 3840ull * 2160ull * 4ull;
    /// `kCoexistingSlots` reference slots come to 189.8 MiB. The default
    /// ceiling is that rounded up to a whole 256 MiB, per pool.
    static constexpr std::uint64_t kDefaultCeilingBytes = 256ull * 1024ull * 1024ull;

    explicit VideoConversionBudget(std::uint64_t ceiling_bytes = kDefaultCeilingBytes);
    ~VideoConversionBudget();

    // The domain registers a budget by its address, so a budget cannot be
    // copied or moved out from under its registration.
    VideoConversionBudget(const VideoConversionBudget&) = delete;
    VideoConversionBudget& operator=(const VideoConversionBudget&) = delete;

    /// Bytes every coexisting slot of this size costs together. Saturates
    /// rather than wrapping, because a wrapped total reads as "fits".
    [[nodiscard]] static std::uint64_t RequiredBytesForAllSlots(std::uint64_t slot_bytes);
    /// Whether the ceiling can hold the full coexisting slot count for this
    /// size. False does not stop reuse; it means reuse is partial, which is
    /// worth reporting once per resolution.
    [[nodiscard]] bool HostsAllSlots(std::uint64_t slot_bytes) const;

    [[nodiscard]] std::uint64_t ceiling_bytes() const { return m_ceiling_bytes; }
    /// Bytes of destinations sitting idle in the reuse pool, ready for `Take`.
    [[nodiscard]] std::uint64_t available_cached_bytes() const { return m_available_cached_bytes; }
    [[nodiscard]] std::size_t   available_cached_count() const { return m_pooled.size(); }
    [[nodiscard]] std::uint64_t peak_available_cached_bytes() const
    {
        return m_peak_available_cached_bytes;
    }
    /// Bytes handed out and not yet reported as GPU-referenced.
    [[nodiscard]] std::uint64_t checked_out_bytes() const { return m_checked_out_bytes; }
    /// Bytes a live imported frame references. They come back only when the
    /// caller reports GPU completion.
    [[nodiscard]] std::uint64_t awaiting_gpu_completion_bytes() const
    {
        return m_awaiting_gpu_bytes;
    }
    /// Available + checked out + awaiting GPU completion, and nothing else.
    [[nodiscard]] std::uint64_t total_live_conversion_allocation_bytes() const;
    /// Running maximum of the above, over every transition that raised it.
    [[nodiscard]] std::uint64_t peak_live_conversion_allocation_bytes() const
    {
        return m_peak_live_bytes;
    }
    /// Granted-but-uncommitted reservation estimates. Intents, not
    /// allocations: not part of the live total, but charged against the
    /// ceiling until committed or cancelled.
    [[nodiscard]] std::uint64_t reserved_estimate_bytes() const
    {
        return m_reserved_estimate_bytes;
    }
    /// Reservations granted above the effective ceiling with an empty cache.
    /// A reason, not a bound: what bounds the excess is stated at
    /// `in_flight_cap_breaches()`, which this class reports and does not
    /// enforce.
    [[nodiscard]] std::uint64_t over_ceiling_grants() const { return m_over_ceiling_grants; }
    /// Reservations granted while `loan_count()` was already at or above
    /// `in_flight_slot_cap()`.
    ///
    /// **The bound.** Destinations legitimately in flight at once are
    /// `TextureCache::kMaxPendingVideoImportSubmissions` (per texture cache)
    /// plus `TextureCache::kMaxImportedVideoFramesPerVideoTex` for each live
    /// video texture the pool serves, plus the one destination each consumer
    /// retains while it displays the frame it last imported. That structural
    /// quantity — not a flat `kCoexistingSlots`, and not a flat six — is what
    /// bounds the excess over the effective ceiling. The pool publishes the
    /// first two terms through `SetInFlightSlotCap`, and this counter reports
    /// how often the result was passed.
    ///
    /// **Reported, never enforced.** Refusing at the threshold deadlocks. A
    /// consumer holds the destination it last imported until a *new* import
    /// replaces it, so refusing that import removes the only event that would
    /// have returned one: the count cannot fall, the next request breaches for
    /// the same reason, and the video texture stops on the generation it had.
    /// That was measured on a real GPU rather than reasoned about — under a
    /// denying cap the refusals climbed 1, 8, 14, 19, 23 across consecutive
    /// generations while created stayed frozen and reused stayed at zero,
    /// permanently. The release is caused by the very import a refusal
    /// cancels, which is why this is structural and not a threshold that could
    /// be tuned into working. A breach therefore means the bound above was
    /// passed and is worth investigating; it never means the budget stopped
    /// anything.
    [[nodiscard]] std::uint64_t in_flight_cap_breaches() const
    {
        return m_in_flight_cap_breaches;
    }
    /// Whether a breach has already been reported in the current episode. A
    /// returned destination or `Reset` starts a new one.
    [[nodiscard]] bool in_flight_cap_reported() const { return m_in_flight_cap_reported; }
    /// Destinations whose bytes are in `total_live_conversion_allocation_bytes()`,
    /// in every state.
    [[nodiscard]] std::size_t live_slot_count() const
    {
        return m_pooled.size() + m_live.size();
    }
    [[nodiscard]] std::uint64_t hits() const { return m_hits; }
    [[nodiscard]] std::uint64_t misses() const { return m_misses; }
    [[nodiscard]] std::uint64_t admissions() const { return m_admissions; }
    [[nodiscard]] std::uint64_t evictions() const { return m_evictions; }
    /// Admissions refused, in total and by reason. `ReserveAllocation`'s
    /// denials are counted apart, by `unsatisfiable_denials()`, so a number
    /// about caching a destination is never mixed with one about allocating
    /// it.
    [[nodiscard]] std::uint64_t refusals() const { return m_refusals; }
    [[nodiscard]] std::uint64_t refusals(VideoConversionRefusal) const;
    /// Destinations the caller holds in flight: checked out plus awaiting GPU
    /// completion. None of them can be evicted, drained or handed out again,
    /// and this — not `live_slot_count()` — is the quantity
    /// `in_flight_slot_cap()` is a threshold on, because a cached slot has
    /// already been returned.
    [[nodiscard]] std::size_t   loan_count() const { return m_live.size(); }
    [[nodiscard]] bool          memory_pressure() const { return m_memory_pressure; }
    /// Smallest size a real allocation has already failed at, or 0 when none
    /// has. That size and larger are neither cached nor reserved until
    /// `Reset`.
    [[nodiscard]] std::uint64_t unsatisfiable_bytes() const { return m_unsatisfiable_bytes; }
    /// Reservations denied because `unsatisfiable_bytes()` says an allocation
    /// of that size already failed. Counted here and nowhere else: it is not
    /// an admission refusal, not an over-ceiling grant and not an in-flight
    /// breach, and confusing it with any of them would read as a capacity
    /// problem when it is a failed allocation.
    [[nodiscard]] std::uint64_t unsatisfiable_denials() const
    {
        return m_unsatisfiable_denials;
    }
    /// Whether a denial has already been reported in the current episode.
    /// `Reset` — which also clears the recorded failing size — starts a new
    /// one.
    [[nodiscard]] bool unsatisfiable_reported() const { return m_unsatisfiable_reported; }
    [[nodiscard]] VideoConversionMemoryDomain* domain() const { return m_domain; }

    /// The reported threshold on destinations in flight: `kCoexistingSlots`
    /// until `SetInFlightSlotCap` says otherwise. Passing it is counted by
    /// `in_flight_cap_breaches()` and is never refused.
    [[nodiscard]] std::uint32_t in_flight_slot_cap() const { return m_in_flight_slot_cap; }

    /// Sets the threshold whose breaches this budget reports, floored at
    /// `kCoexistingSlots`.
    ///
    /// The quantity belongs to the pool, not to the budget. It is
    /// `TextureCache::kMaxPendingVideoImportSubmissions +
    /// TextureCache::kMaxImportedVideoFramesPerVideoTex * live video
    /// textures`, and only the texture cache knows that last factor;
    /// `AppleVideoMetalTexturePool::SetLiveSourceCount` computes it and calls
    /// this. A budget never told keeps `kCoexistingSlots`, the value for a
    /// single video texture, so an unconfigured pool reports exactly as it did
    /// before this existed.
    ///
    /// This is a threshold, not a gate. It changes what is reported and
    /// nothing else: lowering it below what is already in flight reclaims
    /// nothing, refuses nothing and releases nothing, and the next reservation
    /// is still granted — merely counted as a breach.
    void SetInFlightSlotCap(std::uint32_t slots);

    /// Opts this budget into a process-wide domain, or out of it with null.
    /// While attached, the effective ceiling for a reservation or an admission
    /// is `min(ceiling_bytes(), domain->headroom_for(this))`, and the budget
    /// republishes its ledger after every state change.
    void AttachDomain(VideoConversionMemoryDomain* domain);

    /// Hands out a pooled destination whose key matches exactly, or null.
    /// The returned handle moves Available -> CheckedOut: its measured bytes
    /// stay on the live books, and it can never be handed to a second frame
    /// until `ReportGpuComplete` or `EndLoan`.
    [[nodiscard]] void* Take(const VideoConversionSlotKey& key);

    /// Books a destination the caller is about to allocate.
    ///
    /// It never refuses for capacity. The caller asks because the renderer
    /// needs this destination to convert a frame it has already decoded, and
    /// answering "no" drops that frame. So the budget evicts its own cached
    /// slots — never another budget's — and grants; when even an empty cache
    /// cannot fit the request under the effective ceiling the grant is still
    /// made, `VideoConversionReservation::over_ceiling` is set and
    /// `over_ceiling_grants()` counts it.
    ///
    /// It does not refuse past the in-flight threshold either, and that is
    /// deliberate rather than unfinished: a refusal there deadlocks the very
    /// return it waits for. The argument, the measurement behind it and the
    /// structural quantity that bounds the excess instead are all at
    /// `in_flight_cap_breaches()`. A request made at or above the threshold is
    /// granted with `in_flight_cap_breached` set, and once per episode with
    /// `first_in_flight_cap_report` set as well.
    ///
    /// The threshold is on destinations in flight, not on `live_slot_count()`:
    /// cached slots have already been returned and are what the next import
    /// reuses, so counting them would report a breach exactly when reuse is
    /// working.
    ///
    /// **The one denial.** A request at or above `unsatisfiable_bytes()` is
    /// denied with `VideoConversionRefusal::AllocationUnsatisfiable`, before
    /// anything else is examined and without booking an estimate. That is not
    /// a capacity answer and the deadlock argument above does not reach it: an
    /// allocation already known to fail was never going to produce a
    /// destination, so denying it withholds nothing the consumer would
    /// otherwise have received and cannot suppress the release a later request
    /// depends on. The import fails either way; what the denial removes is a
    /// futile allocation attempt and a log line, once per frame, for as long
    /// as the condition lasts. It is counted by `unsatisfiable_denials()`,
    /// reported once per episode through `first_unsatisfiable_report`, and
    /// ends only at `Reset` — which the pool calls from `Clear`, and which is
    /// also what clears the recorded size. Nothing on this path touches the
    /// in-flight threshold, its breach counter or its reporting episode.
    ///
    /// With a domain attached, the fit test and the record of this
    /// reservation happen in one locked step, so a second pool cannot be told
    /// the same headroom is free.
    VideoConversionReservation ReserveAllocation(const VideoConversionSlotKey& key,
                                                 std::uint64_t                 estimated_bytes,
                                                 std::vector<void*>&           evicted);

    /// The allocation succeeded. `slot.bytes` is the platform's real allocated
    /// size, which replaces the estimate, and the handle enters the live
    /// ledger as CheckedOut. A reservation that was not granted, or a slot
    /// with no handle or no measured size, only releases the estimate.
    void CommitAllocation(const VideoConversionReservation& reservation,
                          const VideoConversionSlot&        slot);

    /// The allocation failed or was abandoned. Releases the estimate and
    /// nothing else.
    void CancelReservation(const VideoConversionReservation& reservation);

    /// The import succeeded and the GPU may now reference the destination:
    /// CheckedOut -> AwaitingGpu. A no-op for a handle that is not checked
    /// out, including null.
    void MarkAwaitingGpu(void* resource);

    /// The GPU has finished with a destination. It leaves the live ledger
    /// entirely, because the caller now either re-admits it with `Admit` or
    /// releases it. Returns false when the handle was not on the ledger, which
    /// is the ordinary case for a destination allocated outside the pool.
    bool ReportGpuComplete(void* resource);

    /// Ends a loan without pooling the destination: the import that borrowed
    /// it never used it, or the pool is going away.
    void EndLoan(void* resource);

    /// Decides whether a destination may be pooled for reuse, and puts its
    /// bytes on the Available books when it may. Resources the caller must
    /// release are appended to `evicted` in the order they were chosen,
    /// including when admission is refused. The capacity test is against the
    /// live total plus the reserved estimates, not against cached bytes alone,
    /// and it only ever refuses a second cached slot of a shape already in the
    /// pool — see `VideoConversionRefusal::LiveAllocationAtCeiling`.
    VideoConversionAdmission Admit(const VideoConversionSlot& slot, std::vector<void*>& evicted);

    /// Drops every pooled destination whose key differs from `key`, so a
    /// resolution change stops paying for shapes nothing asks for any more.
    /// Destinations in flight are not touched: they are still being read.
    void DropOtherKeys(const VideoConversionSlotKey& key, std::vector<void*>& evicted);

    /// Empties the reuse pool: playback close, scene switch, cancellation, or
    /// a lost device. Only Available slots are given back; a checked-out or
    /// GPU-pending destination is never reclaimed early.
    void Drain(std::vector<void*>& evicted);

    /// A destination of `slot_bytes` could not be allocated. The pool gives
    /// back what it holds, and that size and larger are neither cached by
    /// `Admit` nor reserved by `ReserveAllocation` until `Reset` — so a
    /// failing allocation is attempted once rather than once per frame.
    void ReportAllocationFailure(std::uint64_t slot_bytes, std::vector<void*>& evicted);

    /// The platform reported memory pressure. The pool gives back what it
    /// holds and caches nothing until `ClearMemoryPressure`.
    void ReportMemoryPressure(std::vector<void*>& evicted);
    void ClearMemoryPressure();

    /// Forgets the exhaustion state, which a new resolution or a released
    /// allocation invalidates: the recorded unsatisfiable size is cleared, so
    /// a size that was being denied is attempted again. Also starts fresh
    /// reporting episodes for both the unsatisfiable denial and the in-flight
    /// breach. Pooled slots, loans and reservations are untouched. This is the
    /// whole recovery path: the pool calls it from `Clear`, and nothing else
    /// re-opens either episode.
    void Reset();

private:
    struct PooledSlot {
        VideoConversionSlotKey key {};
        std::uint64_t          bytes { 0 };
        void*                  resource { nullptr };
        std::uint64_t          sequence { 0 };
    };

    /// A destination the caller holds. `Available` is not represented here:
    /// those live in `m_pooled`, which is the state's storage.
    enum class LiveState { CheckedOut, AwaitingGpu };

    struct LiveSlot {
        void*         resource { nullptr };
        std::uint64_t bytes { 0 };
        LiveState     state { LiveState::CheckedOut };
    };

    VideoConversionAdmission Refuse(VideoConversionRefusal);
    void                     Evict(std::size_t index, std::vector<void*>& evicted);
    /// Index of the slot to give up first for an incoming `key`: a shape the
    /// request cannot use before one it can, oldest before newest.
    [[nodiscard]] std::size_t ChooseVictim(const VideoConversionSlotKey& key) const;
    /// Whether the pool already holds a destination a request for `key` could
    /// be satisfied by.
    [[nodiscard]] bool CachesReusableSlot(const VideoConversionSlotKey& key) const;
    /// Bytes no eviction can recover: everything in flight plus the estimates
    /// the caller has been granted and is about to spend.
    [[nodiscard]] std::uint64_t ImmovableBytes() const;
    /// `min(own ceiling, domain headroom)`, recording this budget's state and
    /// `reserved_after` in the domain under the same lock that computes the
    /// answer. Without a domain, the own ceiling.
    [[nodiscard]] std::uint64_t AcquireEffectiveCeiling(std::uint64_t reserved_after);
    void                        NoteLiveTotal();
    void                        PublishToDomain() const;

    std::uint64_t                  m_ceiling_bytes { kDefaultCeilingBytes };
    std::vector<PooledSlot>        m_pooled;
    std::vector<LiveSlot>          m_live;
    VideoConversionMemoryDomain*   m_domain { nullptr };
    std::uint64_t                  m_available_cached_bytes { 0 };
    std::uint64_t                  m_peak_available_cached_bytes { 0 };
    std::uint64_t                  m_checked_out_bytes { 0 };
    std::uint64_t                  m_awaiting_gpu_bytes { 0 };
    std::uint64_t                  m_reserved_estimate_bytes { 0 };
    std::uint64_t                  m_peak_live_bytes { 0 };
    std::uint64_t                  m_over_ceiling_grants { 0 };
    std::uint64_t                  m_sequence { 0 };
    std::uint64_t                  m_hits { 0 };
    std::uint64_t                  m_misses { 0 };
    std::uint64_t                  m_admissions { 0 };
    std::uint64_t                  m_evictions { 0 };
    std::uint64_t                  m_refusals { 0 };
    std::uint64_t                  m_refusals_by_reason[7] {};
    /// Smallest size a real allocation has already failed at, or 0. With the
    /// reservations denied on its account and whether that has been reported
    /// in this episode.
    std::uint64_t                  m_unsatisfiable_bytes { 0 };
    std::uint64_t                  m_unsatisfiable_denials { 0 };
    bool                           m_unsatisfiable_reported { false };
    bool                           m_memory_pressure { false };
    /// Reservations granted at or above `m_in_flight_slot_cap`, and whether
    /// this breach episode has already been reported.
    std::uint64_t                  m_in_flight_cap_breaches { 0 };
    bool                           m_in_flight_cap_reported { false };
    /// The threshold breaches are reported against, floored at
    /// `kCoexistingSlots`. Published by the pool, which is the only party that
    /// knows how many video textures it serves. Never a gate.
    std::uint32_t                  m_in_flight_slot_cap { kCoexistingSlots };
};

/// The video conversion total across several budgets in one process.
///
/// Separate renderer instances run on separate threads, so every operation is
/// mutex-protected. This is a scoreboard and a ceiling, not an allocator: it
/// NEVER mutates a registered budget and NEVER releases anyone's resources. A
/// budget only ever evicts its own cache.
///
/// That makes shedding **cooperative and late**. When the domain is over its
/// ceiling, the budget that shrinks is whichever one next performs an
/// operation, because that is the only moment a budget consults
/// `headroom_for`. A renderer instance that is paused, or is showing a still
/// image, keeps its cached destinations until something asks it for one. The
/// delay is real and is the price of never freeing memory another thread
/// believes it owns; the alternative — one budget draining another — is how
/// a texture gets released while a command buffer is still reading it.
///
/// Process-wide is not system-wide. The lock-screen extension runs its own
/// renderer in a different process with a different domain. No cross-process
/// coordination exists, and no number here implies one.
class VideoConversionMemoryDomain {
public:
    /// Two reference pools' worth of conversion destinations. Process-wide,
    /// not system-wide, and not a claim about physical memory.
    static constexpr std::uint64_t kDefaultCeilingBytes = 512ull * 1024ull * 1024ull;

    explicit VideoConversionMemoryDomain(std::uint64_t ceiling_bytes = kDefaultCeilingBytes);

    /// Records what one budget currently holds. `live_bytes` is that budget's
    /// `total_live_conversion_allocation_bytes()`, `cached_bytes` is the
    /// Available part of it — the only part anyone could shed — and
    /// `reserved_bytes` is its granted-but-uncommitted estimates. Reserved
    /// bytes are published because they are charged against the ceiling: a
    /// budget that accounted for its own intents but hid them from the domain
    /// would let a second pool spend the same bytes twice.
    void Publish(const void*   budget,
                 std::uint64_t live_bytes,
                 std::uint64_t cached_bytes,
                 std::uint64_t reserved_bytes);

    /// Records a budget's post-operation state and answers how much of the
    /// ceiling is available to it, in ONE locked step.
    ///
    /// Splitting those apart — query the headroom, decide, record later — is
    /// exactly what lets two pools read the same free bytes and both spend
    /// them. This cannot: the caller's new `reserved_bytes` is in the table
    /// before any other budget computes its own answer. Returns
    /// `ceiling - other budgets' (live + reserved)`, saturating at zero, and
    /// counts a shed request when it answers zero.
    [[nodiscard]] std::uint64_t AcquireHeadroom(const void*   budget,
                                                std::uint64_t live_bytes,
                                                std::uint64_t cached_bytes,
                                                std::uint64_t reserved_bytes);
    /// Removes a budget from the total, on detach or destruction.
    void Forget(const void* budget);

    [[nodiscard]] std::uint64_t ceiling_bytes() const;
    /// Sum of every registered budget's live total.
    [[nodiscard]] std::uint64_t live_bytes() const;
    [[nodiscard]] std::uint64_t peak_live_bytes() const;
    /// The reclaimable part of `live_bytes()`: how much the registered budgets
    /// could still shed if each were asked. Everything else is in flight.
    [[nodiscard]] std::uint64_t cached_bytes() const;
    /// Granted-but-uncommitted estimates across every registered budget.
    /// Intents, not allocations, so they are not part of `live_bytes()`, but
    /// they are subtracted from everyone else's headroom.
    [[nodiscard]] std::uint64_t reserved_bytes() const;
    /// The ceiling minus what every *other* budget holds live or has reserved,
    /// saturating at zero. A budget never counts against its own headroom, so
    /// asking twice without allocating gives the same answer. This is a pure
    /// query for diagnostics and does not record anything; the operations that
    /// act on the answer use `AcquireHeadroom` instead.
    [[nodiscard]] std::uint64_t headroom_for(const void* budget) const;
    /// How many times `AcquireHeadroom` had to answer zero: the other budgets
    /// alone had already reached the ceiling, so the asking budget was told to
    /// give up everything it could.
    [[nodiscard]] std::uint64_t shed_requests() const;
    [[nodiscard]] std::size_t   budget_count() const;

private:
    struct Entry {
        const void*   budget { nullptr };
        std::uint64_t live { 0 };
        std::uint64_t cached { 0 };
        std::uint64_t reserved { 0 };
    };

    /// Caller holds `m_mutex`.
    [[nodiscard]] std::uint64_t HeadroomLocked(const void* budget) const;
    void                        RecordLocked(const void*   budget,
                                             std::uint64_t live_bytes,
                                             std::uint64_t cached_bytes,
                                             std::uint64_t reserved_bytes);

    mutable std::mutex m_mutex;
    std::uint64_t      m_ceiling_bytes { kDefaultCeilingBytes };
    std::vector<Entry> m_entries;
    std::uint64_t      m_peak_live_bytes { 0 };
    std::uint64_t      m_shed_requests { 0 };
};

/// The domain a process's renderer instances share when they opt in. Nothing
/// attaches to it implicitly; a pool calls `AttachDomain` or it does not.
VideoConversionMemoryDomain& SharedVideoConversionMemoryDomain();

} // namespace wallpaper::video
