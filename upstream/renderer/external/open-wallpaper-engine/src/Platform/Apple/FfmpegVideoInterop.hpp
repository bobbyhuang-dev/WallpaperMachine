#pragma once

#include "Video/VideoTextureSource.hpp"

#include <cstdint>
#include <memory>
#include <string>

struct AVBufferRef;
struct AVFrame;

namespace wallpaper::video
{

bool CreateVideoToolboxDeviceContext(AVBufferRef** hw_device_ctx, std::string* error);
bool ExtractVideoToolboxFrame(const AVFrame* frame,
                              VideoTextureFrame* out,
                              std::string* error);
bool ExtractAppleVideoFrame(const AVFrame* frame,
                            VideoTextureFrame* out,
                            std::string* error);
void ReleaseAppleVideoFrame(VideoTextureFrame* frame);
std::string DescribeAppleVideoFrame(const VideoTextureFrame& frame);

// Imports one decoded frame and returns an opaque owned lease, or null on
// failure. The lease retains every object the Metal texture's validity depends
// on — the Core Video texture wrapper and the pixel buffer, not just the
// MTLTexture — and must be released exactly once with
// ReleaseAppleVideoFrameLease once the GPU is finished with the frame.
//
// reusable_destination is borrowed; success always takes an independent +1
// retain, and failure never consumes the caller's retain. When it is given,
// destination_allocation_failed reports whether the failure was the
// conversion destination's own allocation — the one failure that a retry at
// the same size cannot fix.
//
// created_destination reports the conversion destination this call allocated
// itself, which is the case exactly when reusable_destination was null and the
// import converted. The pointer is borrowed: the lease still owns the retain,
// and the caller must not release it. It exists so the destination can be put
// on the conversion budget's books the moment it exists rather than the first
// time it is recycled, because everything in between is memory the process is
// holding and nothing was counting.
void* CreateAppleVideoFrameLease(const VideoTextureFrame& frame,
                                 void* metal_device,
                                 void* reusable_destination,
                                 std::string* error,
                                 bool* destination_allocation_failed = nullptr,
                                 void** created_destination = nullptr);
// Borrowed id<MTLTexture> of a lease. Valid until the lease is released.
void* AppleVideoFrameLeaseTexture(void* lease);
// Moves ownership of a recyclable conversion destination out of the lease, so
// it can be handed to AppleVideoMetalTexturePool::Recycle. Returns null when
// the lease holds no poolable destination; the lease never releases a
// destination it has given away.
void* TakeAppleVideoFrameLeaseDestination(void* lease);
void ReleaseAppleVideoFrameLease(void* lease);
// Releases a retained destination texture owned outside a lease, which is what
// AppleVideoMetalTexturePool stores.
void ReleaseAppleVideoMetalTexture(void* handle);

/// What one conversion pool has done. Counted per pool, which is per texture
/// cache, which is per renderer instance.
///
/// **What these bytes are and are not.** Every figure here is an allocation
/// ledger over the BGRA8 conversion destinations this pool created or was
/// handed back: the sum of the sizes Metal reported for those `MTLTexture`s.
/// It is not physical residency, not a working-set measurement and not a
/// process footprint. Decode `CVPixelBuffer`s, the Core Video plane wrappers
/// the NV12 kernel samples, the Vulkan images that alias these textures, the
/// swapchain and every other intermediate are outside it and are never added
/// in.
struct AppleVideoConversionPoolStats {
    /// Destinations idle in the reuse pool, and their bytes. This is the
    /// Available state alone: a destination an import is using is not here.
    uint64_t cached_texture_count { 0 };
    uint64_t cached_bytes { 0 };
    uint64_t peak_cached_bytes { 0 };
    /// Handed to an import that has not yet reported the GPU may reference it.
    uint64_t checked_out_bytes { 0 };
    /// Referenced by a live imported frame.
    uint64_t awaiting_gpu_bytes { 0 };
    /// `cached_bytes + checked_out_bytes + awaiting_gpu_bytes`: every
    /// conversion destination this pool is keeping alive right now, whether or
    /// not it is reusable. The cached figure alone hides the destinations that
    /// are in flight, which is most of them while playback runs.
    uint64_t live_bytes { 0 };
    uint64_t peak_live_bytes { 0 };
    /// Granted reservations that have not become allocations yet. An intent,
    /// not memory, so it is deliberately not part of `live_bytes`.
    uint64_t reserved_estimate_bytes { 0 };
    /// Reservations granted although the effective ceiling had no room.
    /// Refusing one would drop the frame, so the budget grants and counts.
    uint64_t over_ceiling_grants { 0 };
    /// Destinations in any of the three live states.
    uint64_t live_slot_count { 0 };
    uint64_t hits { 0 };
    uint64_t misses { 0 };
    uint64_t recycles { 0 };
    uint64_t evictions { 0 };
    /// Destinations the pool declined to take back into its cache. This is
    /// about admission only; a reservation is never refused.
    uint64_t refusals { 0 };
    /// Reservations granted while the caller was already holding
    /// `in_flight_slot_cap()` destinations in flight. Reported, never
    /// enforced — see `ReserveFresh`.
    uint64_t in_flight_cap_breaches { 0 };
};

/// A granted-but-uncommitted intent to allocate one conversion destination.
///
/// It owns nothing: copying it duplicates no texture and no memory, only the
/// estimate the budget is holding open. Exactly one of `CommitFresh` or
/// `CancelFresh` must follow a reservation that was granted, or the estimate
/// stays on the books forever. A default-constructed value is not granted and
/// both calls ignore it, which is what the paths that never reserve pass.
struct AppleVideoConversionReservation {
    /// Whether this stands for an allocation the budget has booked. **A caller
    /// must read it before allocating, and this really does come back false.**
    ///
    /// `ReserveFresh` refuses exactly one thing, and it is not capacity: a
    /// request whose estimate is at or above a size a real Metal allocation
    /// has already failed at. Retrying that size cannot succeed, so the
    /// reservation is denied rather than granted into a certain failure. A
    /// default-constructed value is also not granted, which is what the paths
    /// that never reserve carry.
    ///
    /// Either way the rule is the same and it is not optional: allocate
    /// nothing, call neither `CommitFresh` nor `CancelFresh` for it, and fail
    /// the frame's import so the previously imported frame stays on screen. A
    /// texture created behind an unbooked reservation is one the ledger never
    /// sees, which is the uncounted memory this budget exists to eliminate.
    bool     granted { false };
    /// Everything below is the budget's business, not the caller's, except
    /// the two `first_*_report` flags, which exist so a condition is logged
    /// once per episode rather than once per frame.
    ///
    /// Granted although the estimate did not fit under the effective ceiling.
    bool     over_ceiling { false };
    uint64_t estimated_bytes { 0 };
    /// `VideoConversionRefusal` as an integer, so this header needs none of
    /// the budget's own types. Meaningful only when `granted` is false.
    uint32_t refusal { 0 };
    /// Set on the first unsatisfiable-size denial of an episode. The episode
    /// re-opens only at the budget's `Reset`, which `Clear` performs.
    bool     first_unsatisfiable_report { false };
    /// Granted although the caller already held `in_flight_slot_cap()`
    /// destinations in flight. A breach is reported, never refused: see
    /// `ReserveFresh` for why refusing for capacity cannot be recovered from.
    bool     in_flight_cap_breached { false };
    /// Set on the first breach of an episode and on no other reservation. A
    /// returned destination, or a raised expectation, starts a new episode.
    bool     first_in_flight_cap_report { false };
};

/// Imported frames one video texture can hold at once, and import submissions
/// one texture cache can leave unretired.
///
/// These are the two cache-side terms of the in-flight slot expectation; the
/// third, the destination each consumer of a video texture retains, is only
/// observable to the cache and reaches this layer already folded into
/// `SetInFlightSlotExpectation`. Nothing here computes with them: they are
/// published so the `ReserveFresh` contract above can state the structural
/// bound, and so tests can assert against it.
///
/// Both numbers are owned by `wallpaper::vulkan::TextureCache`, as
/// `kMaxImportedVideoFramesPerVideoTex` and
/// `kMaxPendingVideoImportSubmissions`. They are mirrored here because this
/// layer must not include a Vulkan header, and `TextureCache.cpp`
/// `static_assert`s each mirror against its owner so the pair cannot drift.
/// Nothing else may hard-code either value.
inline constexpr std::uint32_t kImportedVideoFramesPerSource { 4 };
inline constexpr std::uint32_t kPendingVideoImportSubmissions { 2 };

/// Reuse pool for the BGRA8 textures the NV12 conversion writes into.
///
/// The pool executes; `VideoConversionBudget` decides. Reuse is keyed on the
/// decoded frame's width, height and the destination pixel format, so a
/// differently shaped texture is never handed out for an incompatible
/// request, and the ceiling is expressed in the bytes Metal reports it
/// allocated rather than in a texture count.
///
/// **One destination, one state.** A destination is idle in the pool, checked
/// out to an import, or referenced by a live imported frame — never two at
/// once, and its bytes stay counted through all three. The sequence one import
/// drives is `RetainOnly`, then either `Take` (reuse) or
/// `ReserveFresh`/`CommitFresh` (allocate), then `MarkGpuPending`, and finally
/// `Recycle` from the lease deleter. Every path out of the middle of that
/// sequence unwinds the ledger: `CancelFresh` for an allocation that never
/// happened, `EndLoan` for a borrow the import never used.
///
/// The pool attaches its budget to `SharedVideoConversionMemoryDomain()`, so
/// several renderer instances in one process see each other's live bytes. That
/// coordination is process-wide only: the lock-screen extension is a separate
/// process and there is no cross-process channel here at all.
class AppleVideoMetalTexturePool {
public:
    explicit AppleVideoMetalTexturePool(void* metal_device);
    ~AppleVideoMetalTexturePool();
    AppleVideoMetalTexturePool(const AppleVideoMetalTexturePool&) = delete;
    AppleVideoMetalTexturePool& operator=(const AppleVideoMetalTexturePool&) = delete;
    // Borrows a destination for a decoded frame of exactly this size, or
    // returns null. width and height are the decoded frame's; a surface or
    // display resolution is a different quantity and must never be passed
    // here. The returned retain belongs to the caller, and the loan stays open
    // until Recycle or EndLoan, so one texture is never lent to two frames.
    // Its measured bytes stay on the live books throughout: a reused
    // destination leaves the cache, it does not leave the process.
    void* Take(uint32_t width, uint32_t height);
    // Publishes how many conversion destinations the texture cache above it
    // can legitimately hold in flight right now. The pool cannot work this out
    // for itself: it is the cache's pending import submissions, plus for every
    // live video texture its imported-frame cap and the destination each of
    // that texture's consumers retains, and only the cache observes the last
    // two. The budget floors it, so a pool that is never told keeps the
    // single-video-texture value and behaves as it always did.
    void SetInFlightSlotExpectation(std::uint32_t slots) noexcept;
    // Declares the intent to allocate a fresh destination of this size, before
    // the allocation is attempted. The budget evicts its own cached slots to
    // make room and then grants. A shape that merely does not fit the ceiling
    // is granted and reported, because a destination the conversion needs is
    // not optional and refusing it would drop the frame.
    //
    // It denies exactly one thing, and it is not capacity: a request whose
    // estimate is at or above a size a real Metal allocation has already
    // failed at. That retry cannot succeed, so denying is strictly better
    // than granting into a certain failure, and it is recoverable — nothing
    // about the denial prevents destinations from coming back.
    //
    // Capacity, by contrast, is reported and never enforced, and that is
    // structural rather than a choice of number. The destination that would
    // satisfy the next request is released by a consumer re-binding, and a
    // consumer re-binds by receiving the very import a refusal would withhold
    // — so refusing for capacity removes the only route back and the texture
    // stops advancing for good. Measured on the retained-consumer shape, a
    // refusing cap produced 1, 8, 14, 19 and 23 refusals over five successive
    // generations with allocations frozen and reuse stuck at zero, and never
    // recovered. Granting instead, the same shape converges: allocation stops
    // of its own accord and reuse carries playback indefinitely, because a
    // consumer retains one destination per slot and never a list. The bound
    // is therefore pending import submissions, plus each live video texture's
    // imported-frame cap and its consumer count, which is what
    // `SetInFlightSlotExpectation` publishes; `in_flight_cap_breaches` counts
    // reservations made beyond it, so a breach means a destination that
    // stopped being returned rather than a busy scene.
    //
    // The caller MUST check `granted` and allocate nothing when it is false;
    // see `AppleVideoConversionReservation::granted`.
    [[nodiscard]] AppleVideoConversionReservation ReserveFresh(uint32_t width, uint32_t height);
    // The allocation succeeded. `destination` is the borrowed handle
    // CreateAppleVideoFrameLease reported; the pool asks Metal what it really
    // allocated and replaces the reservation's estimate with that number.
    void CommitFresh(const AppleVideoConversionReservation& reservation,
                     void*                                  destination) noexcept;
    // The allocation failed or was abandoned; drops the estimate only.
    void CancelFresh(const AppleVideoConversionReservation& reservation) noexcept;
    // The import succeeded and a live imported frame can now reference the
    // destination. Nothing about the byte total changes — only which state is
    // holding it, which is what makes a stuck import distinguishable from a
    // frame the GPU is still using.
    void MarkGpuPending(void* destination) noexcept;
    // Ends a loan whose import never used the destination, releasing it.
    void EndLoan(void* retained_destination) noexcept;
    // Offers a destination back now that the GPU has finished with it. The
    // renderer calls this from the frame lease's deleter, which runs after the
    // imported frame's last holder drops it — after the draw fence that
    // sampled the frame signalled, and after the Vulkan image aliasing the
    // texture was destroyed.
    void Recycle(void* retained_destination) noexcept;
    // Drops cached destinations of every size other than this one, so a
    // resolution change stops holding shapes nothing requests any more.
    void RetainOnly(uint32_t width, uint32_t height) noexcept;
    // A fresh destination of this size could not be allocated. The pool gives
    // back what it holds and stops caching that size and larger, so an
    // unsatisfiable allocation is attempted once instead of once per frame.
    void ReportAllocationFailure(uint32_t width, uint32_t height) noexcept;
    void Clear() noexcept;
    [[nodiscard]] AppleVideoConversionPoolStats Stats() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace wallpaper::video
