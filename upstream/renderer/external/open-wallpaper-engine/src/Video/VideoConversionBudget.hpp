#pragma once

#include <cstddef>
#include <cstdint>
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
    /// The destination is still on loan. It was handed out by `Take` and the
    /// GPU completion that ends its use has not been reported, so pooling it
    /// would let a second frame overwrite a texture the first one still reads.
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
    /// not cached until `Reset`, so a failing allocation is attempted once
    /// instead of once per frame.
    AllocationUnsatisfiable,
    /// The platform reported memory pressure. Nothing is cached until
    /// `ClearMemoryPressure`.
    MemoryPressure,
};

[[nodiscard]] const char* VideoConversionRefusalName(VideoConversionRefusal);

struct VideoConversionAdmission {
    bool                   accepted { false };
    VideoConversionRefusal refusal { VideoConversionRefusal::None };
};

/// Ceiling, reuse ledger and degradation policy for video conversion
/// destinations.
///
/// Slot sizing, admission, eviction choice and the exhaustion policy live here
/// and are expressed in byte counts and opaque handles, so the platform pool
/// only executes decisions it does not make. Nothing in this class knows about
/// Metal, Core Video or Vulkan.
///
/// **What the ceiling covers.** One budget belongs to one conversion pool, one
/// pool belongs to one texture cache, and one texture cache belongs to one
/// renderer instance. Several displays driven by one scene share that single
/// pool and therefore one ceiling; a process that runs N renderer instances
/// can hold N ceilings, and this class does not and cannot police that total.
class VideoConversionBudget {
public:
    /// Destinations that can coexist for a single video texture: the imported
    /// frames a texture cache keeps
    /// (`TextureCache::kMaxImportedVideoFramesPerVideoTex`) plus the ones an
    /// unretired import submission still references
    /// (`TextureCache::kMaxPendingVideoImportSubmissions`). Those two caps are
    /// what bounds the count; the budget derives its sizing from them rather
    /// than inventing a number of its own.
    static constexpr std::uint32_t kCoexistingSlots = 6;
    /// Bytes one 3840x2160 BGRA8 destination costs. This is the reference
    /// resolution the default ceiling is sized against, not a limit.
    static constexpr std::uint64_t kReferenceSlotBytes = 3840ull * 2160ull * 4ull;
    /// `kCoexistingSlots` reference slots come to 189.8 MiB. The default
    /// ceiling is that rounded up to a whole 256 MiB, per pool.
    static constexpr std::uint64_t kDefaultCeilingBytes = 256ull * 1024ull * 1024ull;

    explicit VideoConversionBudget(std::uint64_t ceiling_bytes = kDefaultCeilingBytes);

    /// Bytes every coexisting slot of this size costs together. Saturates
    /// rather than wrapping, because a wrapped total reads as "fits".
    [[nodiscard]] static std::uint64_t RequiredBytesForAllSlots(std::uint64_t slot_bytes);
    /// Whether the ceiling can hold the full coexisting slot count for this
    /// size. False does not stop reuse; it means reuse is partial, which is
    /// worth reporting once per resolution.
    [[nodiscard]] bool HostsAllSlots(std::uint64_t slot_bytes) const;

    [[nodiscard]] std::uint64_t ceiling_bytes() const { return m_ceiling_bytes; }
    [[nodiscard]] std::uint64_t pooled_bytes() const { return m_pooled_bytes; }
    [[nodiscard]] std::size_t   pooled_count() const { return m_pooled.size(); }
    [[nodiscard]] std::uint64_t peak_pooled_bytes() const { return m_peak_pooled_bytes; }
    [[nodiscard]] std::uint64_t hits() const { return m_hits; }
    [[nodiscard]] std::uint64_t misses() const { return m_misses; }
    [[nodiscard]] std::uint64_t admissions() const { return m_admissions; }
    [[nodiscard]] std::uint64_t evictions() const { return m_evictions; }
    [[nodiscard]] std::uint64_t refusals() const { return m_refusals; }
    [[nodiscard]] std::uint64_t refusals(VideoConversionRefusal) const;
    [[nodiscard]] std::size_t   loan_count() const { return m_on_loan.size(); }
    [[nodiscard]] bool          memory_pressure() const { return m_memory_pressure; }
    [[nodiscard]] std::uint64_t unsatisfiable_bytes() const { return m_unsatisfiable_bytes; }

    /// Hands out a pooled destination whose key matches exactly, or null. What
    /// it returns is on loan until `ReportGpuComplete` or `EndLoan`, so it can
    /// never be handed to a second frame in the meantime.
    [[nodiscard]] void* Take(const VideoConversionSlotKey& key);

    /// The GPU has finished with a destination and it may be pooled again.
    /// Returns false when the handle was not on loan, which is the ordinary
    /// case for a destination allocated outside the pool.
    bool ReportGpuComplete(void* resource);

    /// Ends a loan without pooling the destination: the import that borrowed
    /// it never used it, or the pool is going away.
    void EndLoan(void* resource);

    /// Decides whether a destination may be pooled for reuse. Resources the
    /// caller must release are appended to `evicted` in the order they were
    /// chosen, including when admission is refused.
    VideoConversionAdmission Admit(const VideoConversionSlot& slot, std::vector<void*>& evicted);

    /// Drops every pooled destination whose key differs from `key`, so a
    /// resolution change stops paying for shapes nothing asks for any more.
    void DropOtherKeys(const VideoConversionSlotKey& key, std::vector<void*>& evicted);

    /// Empties the pool: playback close, scene switch, cancellation, or a lost
    /// device.
    void Drain(std::vector<void*>& evicted);

    /// A destination of `slot_bytes` could not be allocated. The pool gives
    /// back what it holds and refuses that size and larger until `Reset`.
    void ReportAllocationFailure(std::uint64_t slot_bytes, std::vector<void*>& evicted);

    /// The platform reported memory pressure. The pool gives back what it
    /// holds and caches nothing until `ClearMemoryPressure`.
    void ReportMemoryPressure(std::vector<void*>& evicted);
    void ClearMemoryPressure();

    /// Forgets the exhaustion state, which a new resolution or a released
    /// allocation invalidates. Pooled slots and loans are untouched.
    void Reset();

private:
    struct PooledSlot {
        VideoConversionSlotKey key {};
        std::uint64_t          bytes { 0 };
        void*                  resource { nullptr };
        std::uint64_t          sequence { 0 };
    };

    VideoConversionAdmission Refuse(VideoConversionRefusal);
    void                     Evict(std::size_t index, std::vector<void*>& evicted);
    /// Index of the slot to give up first for an incoming `key`: a shape the
    /// request cannot use before one it can, oldest before newest.
    [[nodiscard]] std::size_t ChooseVictim(const VideoConversionSlotKey& key) const;

    std::uint64_t           m_ceiling_bytes { kDefaultCeilingBytes };
    std::vector<PooledSlot> m_pooled;
    std::vector<void*>      m_on_loan;
    std::uint64_t           m_pooled_bytes { 0 };
    std::uint64_t           m_peak_pooled_bytes { 0 };
    std::uint64_t           m_sequence { 0 };
    std::uint64_t           m_hits { 0 };
    std::uint64_t           m_misses { 0 };
    std::uint64_t           m_admissions { 0 };
    std::uint64_t           m_evictions { 0 };
    std::uint64_t           m_refusals { 0 };
    std::uint64_t           m_refusals_by_reason[6] {};
    /// Smallest size a real allocation has already failed at, or 0.
    std::uint64_t           m_unsatisfiable_bytes { 0 };
    bool                    m_memory_pressure { false };
};

} // namespace wallpaper::video
