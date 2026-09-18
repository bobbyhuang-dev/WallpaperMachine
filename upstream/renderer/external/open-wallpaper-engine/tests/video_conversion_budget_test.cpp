// Budgeting for video conversion destinations. The budget stores opaque
// handles and byte counts, so every rule below is exercised without a Metal
// device, a decoder or a surface.
#include "Video/VideoConversionBudget.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <thread>
#include <vector>

namespace {
using wallpaper::video::SharedVideoConversionMemoryDomain;
using wallpaper::video::VideoConversionBudget;
using wallpaper::video::VideoConversionMemoryDomain;
using wallpaper::video::VideoConversionRefusal;
using wallpaper::video::VideoConversionSlot;
using wallpaper::video::VideoConversionSlotKey;

// Stand-ins for retained id<MTLTexture> values. The budget never dereferences
// a resource, which is exactly why this test needs no GPU.
void* Handle(std::uintptr_t id) { return reinterpret_cast<void*>(id); }

// MTLPixelFormatBGRA8Unorm and MTLPixelFormatRGBA8Unorm. The budget treats
// them as opaque identity, not as a size.
constexpr std::uint32_t kBgra = 80;
constexpr std::uint32_t kRgba = 70;

constexpr VideoConversionSlotKey k720 { 1280, 720, kBgra };
constexpr VideoConversionSlotKey k1080 { 1920, 1080, kBgra };
constexpr VideoConversionSlotKey k4k { 3840, 2160, kBgra };
constexpr VideoConversionSlotKey k8k { 7680, 4320, kBgra };
// 8192x4608, the widest shape these tests use. Two of its destinations do not
// fit the default ceiling; two 7680x4320 ones do.
constexpr VideoConversionSlotKey k8kWide { 8192, 4608, kBgra };

constexpr std::uint64_t Bytes(const VideoConversionSlotKey& key)
{
    return static_cast<std::uint64_t>(key.width) * key.height * 4ull;
}

// The ceiling this task replaced: a flat 64 MiB, which refused any single
// destination above roughly 4096x4096.
constexpr std::uint64_t kRetiredCeilingBytes = 64ull * 1024ull * 1024ull;

VideoConversionSlot Slot(const VideoConversionSlotKey& key, std::uintptr_t id)
{
    return { key, Bytes(key), Handle(id) };
}

// One destination allocated outside the reuse pool and carried to the point
// where a live imported frame references it: reserve, commit the measured
// size, then report the import succeeded.
void AllocateInFlight(VideoConversionBudget&        budget,
                      const VideoConversionSlotKey& key,
                      std::uintptr_t                id,
                      std::vector<void*>&           evicted)
{
    const auto reservation = budget.ReserveAllocation(key, Bytes(key), evicted);
    ASSERT_TRUE(reservation.granted);
    budget.CommitAllocation(reservation, Slot(key, id));
    budget.MarkAwaitingGpu(Handle(id));
}

} // namespace

TEST(VideoConversionBudget, PoolsASingleDestinationLargerThanTheRetiredCeiling)
{
    // 4096x4097 is the shape the retired 64 MiB ceiling rejected outright, so
    // a 6K or 8K wallpaper reallocated its destination on every frame.
    constexpr VideoConversionSlotKey key { 4096, 4097, kBgra };
    ASSERT_GT(Bytes(key), kRetiredCeilingBytes);
    ASSERT_GT(Bytes(k8k), kRetiredCeilingBytes);

    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(key, 1), evicted).accepted);
    EXPECT_TRUE(evicted.empty());
    EXPECT_EQ(budget.available_cached_count(), 1u);
    EXPECT_EQ(budget.available_cached_bytes(), Bytes(key));
    EXPECT_EQ(budget.peak_available_cached_bytes(), Bytes(key));
    EXPECT_EQ(budget.Take(key), Handle(1));
    EXPECT_EQ(budget.hits(), 1u);
    EXPECT_EQ(budget.available_cached_bytes(), 0u);

    VideoConversionBudget eight_k;
    ASSERT_TRUE(eight_k.Admit(Slot(k8k, 2), evicted).accepted);
    EXPECT_EQ(eight_k.Take(k8k), Handle(2));
}

TEST(VideoConversionBudget, KeepsOnlyOneOfTwoRequiredSlotsThatCannotBothFit)
{
    VideoConversionBudget budget;
    // The ceiling is sized for the coexisting slot count at the 4K reference
    // resolution. Above that, reuse is real but partial, which is the bounded
    // degradation this budget is allowed to report rather than a failure.
    EXPECT_TRUE(budget.HostsAllSlots(Bytes(k4k)));
    EXPECT_FALSE(budget.HostsAllSlots(Bytes(k8k)));
    EXPECT_EQ(VideoConversionBudget::RequiredBytesForAllSlots(Bytes(k8k)),
              Bytes(k8k) * VideoConversionBudget::kCoexistingSlots);

    std::vector<void*> evicted;
    // Two 7680x4320 destinations still fit, so the pair below fails for its
    // size and not because the ceiling only ever holds one slot.
    ASSERT_LT(2 * Bytes(k8k), budget.ceiling_bytes());
    ASSERT_TRUE(budget.Admit(Slot(k8k, 1), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k8k, 2), evicted).accepted);
    ASSERT_TRUE(evicted.empty());
    budget.Drain(evicted);
    evicted.clear();

    ASSERT_GT(2 * Bytes(k8kWide), budget.ceiling_bytes());
    ASSERT_TRUE(budget.Admit(Slot(k8kWide, 3), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k8kWide, 4), evicted).accepted);
    EXPECT_EQ(evicted, std::vector<void*> { Handle(3) });
    EXPECT_EQ(budget.available_cached_count(), 1u);
    EXPECT_EQ(budget.available_cached_bytes(), Bytes(k8kWide));
    EXPECT_EQ(budget.Take(k8kWide), Handle(4));
    EXPECT_EQ(budget.Take(k8kWide), nullptr);
}

TEST(VideoConversionBudget, NeverSharesASlotAcrossAWidthHeightOrFormatSwitch)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k1080, 1), evicted).accepted);

    EXPECT_EQ(budget.Take({ 1920, 1088, kBgra }), nullptr);
    EXPECT_EQ(budget.Take({ 1024, 1080, kBgra }), nullptr);
    EXPECT_EQ(budget.Take({ 1920, 1080, kRgba }), nullptr);
    EXPECT_EQ(budget.misses(), 3u);
    EXPECT_EQ(budget.available_cached_count(), 1u);
    EXPECT_EQ(budget.Take(k1080), Handle(1));
    EXPECT_EQ(budget.hits(), 1u);
}

TEST(VideoConversionBudget, RefusesASlotLargerThanTheWholeCeilingWithoutSpendingWhatItHolds)
{
    VideoConversionBudget budget(Bytes(k4k));
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);

    const auto refused = budget.Admit(Slot(k8k, 2), evicted);
    EXPECT_FALSE(refused.accepted);
    EXPECT_EQ(refused.refusal, VideoConversionRefusal::SlotExceedsCeiling);
    // A slot that can never fit must not cost the pool the one it can reuse.
    EXPECT_TRUE(evicted.empty());
    EXPECT_EQ(budget.available_cached_count(), 1u);
    EXPECT_EQ(budget.Take(k4k), Handle(1));

    // A destination the budget cannot measure is one it cannot show to fit.
    const auto unmeasured = budget.Admit({ k4k, 0, Handle(3) }, evicted);
    EXPECT_FALSE(unmeasured.accepted);
    EXPECT_EQ(unmeasured.refusal, VideoConversionRefusal::SlotExceedsCeiling);
    EXPECT_EQ(budget.available_cached_count(), 0u);
}

TEST(VideoConversionBudget, StopsPoolingASizeAnAllocationAlreadyFailedAt)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);

    std::vector<void*> reclaimed;
    budget.ReportAllocationFailure(Bytes(k4k), reclaimed);
    EXPECT_EQ(reclaimed, std::vector<void*> { Handle(1) });
    EXPECT_EQ(budget.available_cached_count(), 0u);
    EXPECT_EQ(budget.unsatisfiable_bytes(), Bytes(k4k));

    const auto same_size = budget.Admit(Slot(k4k, 2), evicted);
    EXPECT_FALSE(same_size.accepted);
    EXPECT_EQ(same_size.refusal, VideoConversionRefusal::AllocationUnsatisfiable);
    const auto larger = budget.Admit(Slot(k8k, 3), evicted);
    EXPECT_FALSE(larger.accepted);
    EXPECT_EQ(larger.refusal, VideoConversionRefusal::AllocationUnsatisfiable);
    // Refused once each, never a retry loop, and each refusal is counted.
    EXPECT_EQ(budget.refusals(VideoConversionRefusal::AllocationUnsatisfiable), 2u);
    EXPECT_EQ(budget.available_cached_count(), 0u);

    // A size the failure says nothing about keeps working.
    EXPECT_TRUE(budget.Admit(Slot(k1080, 4), evicted).accepted);

    budget.Reset();
    EXPECT_EQ(budget.unsatisfiable_bytes(), 0u);
    EXPECT_TRUE(budget.Admit(Slot(k4k, 5), evicted).accepted);
}

TEST(VideoConversionBudget, StopsPoolingWhileMemoryPressureIsReported)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);

    std::vector<void*> reclaimed;
    budget.ReportMemoryPressure(reclaimed);
    EXPECT_EQ(reclaimed, std::vector<void*> { Handle(1) });
    EXPECT_EQ(budget.available_cached_bytes(), 0u);

    const auto refused = budget.Admit(Slot(k4k, 2), evicted);
    EXPECT_FALSE(refused.accepted);
    EXPECT_EQ(refused.refusal, VideoConversionRefusal::MemoryPressure);
    EXPECT_EQ(budget.Take(k4k), nullptr);

    budget.ClearMemoryPressure();
    EXPECT_TRUE(budget.Admit(Slot(k4k, 3), evicted).accepted);
    EXPECT_EQ(budget.Take(k4k), Handle(3));
}

TEST(VideoConversionBudget, NeverPoolsOrLendsADestinationThatIsStillOnLoan)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);

    void* loaned = budget.Take(k4k);
    ASSERT_EQ(loaned, Handle(1));
    EXPECT_EQ(budget.loan_count(), 1u);
    // One destination, one frame: the loan is what stops a second consumer
    // from being handed a texture the first one is still reading.
    EXPECT_EQ(budget.Take(k4k), nullptr);

    const auto early = budget.Admit({ k4k, Bytes(k4k), loaned }, evicted);
    EXPECT_FALSE(early.accepted);
    EXPECT_EQ(early.refusal, VideoConversionRefusal::StillOnLoan);
    EXPECT_EQ(budget.available_cached_count(), 0u);
    EXPECT_EQ(budget.Take(k4k), nullptr);

    EXPECT_TRUE(budget.ReportGpuComplete(loaned));
    EXPECT_EQ(budget.loan_count(), 0u);
    ASSERT_TRUE(budget.Admit({ k4k, Bytes(k4k), loaned }, evicted).accepted);

    const auto again = budget.Admit({ k4k, Bytes(k4k), loaned }, evicted);
    EXPECT_FALSE(again.accepted);
    EXPECT_EQ(again.refusal, VideoConversionRefusal::AlreadyPooled);
    EXPECT_EQ(budget.available_cached_count(), 1u);

    // A destination allocated outside the pool was never on loan, and pools
    // on its first offer all the same.
    EXPECT_FALSE(budget.ReportGpuComplete(Handle(9)));
    EXPECT_TRUE(budget.Admit(Slot(k1080, 9), evicted).accepted);
}

TEST(VideoConversionBudget, EndsALoanTheImportNeverUsed)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);

    void* loaned = budget.Take(k4k);
    ASSERT_EQ(loaned, Handle(1));
    budget.EndLoan(loaned);
    EXPECT_EQ(budget.loan_count(), 0u);
    // The loan ended, so its bytes left the ledger with it: the caller owns
    // the destination now and either offers it back or releases it.
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    // The handle is gone, but a later destination at the same address is not
    // presumed to still be in flight.
    EXPECT_TRUE(budget.Admit({ k4k, Bytes(k4k), loaned }, evicted).accepted);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));
}

TEST(VideoConversionBudget, GivesBackShapesAResolutionChangeNoLongerRequests)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k720, 1), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k1080, 2), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k4k, 3), evicted).accepted);
    ASSERT_EQ(budget.available_cached_count(), 3u);
    const std::uint64_t peak = Bytes(k720) + Bytes(k1080) + Bytes(k4k);
    ASSERT_EQ(budget.available_cached_bytes(), peak);

    std::vector<void*> reclaimed;
    budget.DropOtherKeys(k1080, reclaimed);
    std::sort(reclaimed.begin(), reclaimed.end());
    std::vector<void*> expected { Handle(1), Handle(3) };
    std::sort(expected.begin(), expected.end());
    EXPECT_EQ(reclaimed, expected);
    EXPECT_EQ(budget.available_cached_count(), 1u);
    EXPECT_EQ(budget.available_cached_bytes(), Bytes(k1080));
    EXPECT_EQ(budget.Take(k720), nullptr);
    EXPECT_EQ(budget.Take(k4k), nullptr);

    reclaimed.clear();
    budget.Drain(reclaimed);
    EXPECT_EQ(reclaimed, std::vector<void*> { Handle(2) });
    EXPECT_EQ(budget.available_cached_count(), 0u);
    EXPECT_EQ(budget.available_cached_bytes(), 0u);
    // The high-water mark is the figure a ceiling is judged against, so it
    // survives the reclamation that follows a close or a switch.
    EXPECT_EQ(budget.peak_available_cached_bytes(), peak);
    EXPECT_EQ(budget.peak_live_conversion_allocation_bytes(), peak);
}

TEST(VideoConversionBudget, GivesUpAShapeTheRequestCannotUseBeforeOneItCan)
{
    // Room for exactly two slots of this cost.
    VideoConversionBudget budget(2 * Bytes(k4k));
    // Same byte cost, shape the 4K request cannot be satisfied by.
    constexpr VideoConversionSlotKey transposed { 2160, 3840, kBgra };
    ASSERT_EQ(Bytes(transposed), Bytes(k4k));

    std::vector<void*> evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(transposed, 2), evicted).accepted);
    ASSERT_TRUE(evicted.empty());

    ASSERT_TRUE(budget.Admit(Slot(k4k, 3), evicted).accepted);
    EXPECT_EQ(evicted, std::vector<void*> { Handle(2) });
    std::vector<void*> remaining { budget.Take(k4k), budget.Take(k4k) };
    std::sort(remaining.begin(), remaining.end());
    std::vector<void*> expected { Handle(1), Handle(3) };
    std::sort(expected.begin(), expected.end());
    EXPECT_EQ(remaining, expected);
}

TEST(VideoConversionBudget, KeepsALoanedDestinationOnTheLiveBooks)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);
    ASSERT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));

    void* loaned = budget.Take(k4k);
    ASSERT_EQ(loaned, Handle(1));
    // Handing a destination out moves its bytes between states. It does not
    // make them stop existing, which is the accounting bug this replaces: the
    // texture is at its most expensive precisely while a frame is using it.
    EXPECT_EQ(budget.available_cached_bytes(), 0u);
    EXPECT_EQ(budget.checked_out_bytes(), Bytes(k4k));
    EXPECT_EQ(budget.awaiting_gpu_completion_bytes(), 0u);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));
    EXPECT_EQ(budget.live_slot_count(), 1u);
    EXPECT_EQ(budget.available_cached_count(), 0u);
    // Invisible to a second consumer for as long as it is out.
    EXPECT_EQ(budget.Take(k4k), nullptr);

    budget.MarkAwaitingGpu(loaned);
    EXPECT_EQ(budget.checked_out_bytes(), 0u);
    EXPECT_EQ(budget.awaiting_gpu_completion_bytes(), Bytes(k4k));
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));
    EXPECT_EQ(budget.live_slot_count(), 1u);
    EXPECT_EQ(budget.Take(k4k), nullptr);
    // A handle that is not checked out cannot be moved into that state.
    budget.MarkAwaitingGpu(Handle(77));
    budget.MarkAwaitingGpu(nullptr);
    EXPECT_EQ(budget.awaiting_gpu_completion_bytes(), Bytes(k4k));

    EXPECT_TRUE(budget.ReportGpuComplete(loaned));
    EXPECT_EQ(budget.awaiting_gpu_completion_bytes(), 0u);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    EXPECT_EQ(budget.live_slot_count(), 0u);
}

TEST(VideoConversionBudget, BooksAnAllocationThatWasNeverPooled)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;

    const auto reservation = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(reservation.granted);
    EXPECT_FALSE(reservation.over_ceiling);
    EXPECT_FALSE(reservation.in_flight_cap_breached);
    EXPECT_EQ(reservation.estimated_bytes, Bytes(k4k));
    EXPECT_EQ(budget.reserved_estimate_bytes(), Bytes(k4k));
    // An intent is not an allocation: nothing has been allocated yet.
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    EXPECT_EQ(budget.live_slot_count(), 0u);

    // Alignment and tiling make the real cost larger than the estimate, and
    // the measured figure is the one that goes on the books.
    const std::uint64_t measured = Bytes(k4k) + 4096;
    budget.CommitAllocation(reservation, { k4k, measured, Handle(1) });
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);
    EXPECT_EQ(budget.checked_out_bytes(), measured);
    EXPECT_EQ(budget.available_cached_count(), 0u);
    // On the live books before it was ever admitted to the reuse pool.
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), measured);
    EXPECT_EQ(budget.peak_live_conversion_allocation_bytes(), measured);
    EXPECT_EQ(budget.live_slot_count(), 1u);
    EXPECT_EQ(budget.Take(k4k), nullptr);

    budget.MarkAwaitingGpu(Handle(1));
    ASSERT_TRUE(budget.ReportGpuComplete(Handle(1)));
    ASSERT_TRUE(budget.Admit({ k4k, measured, Handle(1) }, evicted).accepted);
    // Re-admitting what GPU completion released is the same destination
    // changing state, not a second allocation.
    EXPECT_EQ(budget.available_cached_bytes(), measured);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), measured);
    EXPECT_EQ(budget.peak_live_conversion_allocation_bytes(), measured);
    EXPECT_EQ(budget.live_slot_count(), 1u);
}

TEST(VideoConversionBudget, ReleasesTheEstimateWhenAnAllocationNeverHappens)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);

    const auto reservation = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    ASSERT_TRUE(reservation.granted);
    EXPECT_EQ(budget.reserved_estimate_bytes(), Bytes(k4k));
    // The estimate is charged against the ceiling but is not an allocation,
    // so it stays out of the live total.
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));

    std::vector<void*> reclaimed;
    budget.ReportAllocationFailure(Bytes(k4k), reclaimed);
    budget.CancelReservation(reservation);
    EXPECT_EQ(reclaimed, std::vector<void*> { Handle(1) });
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    EXPECT_EQ(budget.live_slot_count(), 0u);

    // Committing a reservation the allocation never produced releases the
    // estimate and adds nothing, which is what a caller that routes every
    // outcome through Commit depends on.
    budget.Reset();
    const auto empty = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    budget.CommitAllocation(empty, { k4k, 0, nullptr });
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    EXPECT_EQ(budget.live_slot_count(), 0u);

    // A reservation that was never granted is inert in both directions.
    budget.CancelReservation({});
    budget.CommitAllocation({}, Slot(k4k, 2));
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    EXPECT_EQ(budget.live_slot_count(), 0u);
}

TEST(VideoConversionBudget, NeverReclaimsADestinationBeforeGpuCompletion)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);
    void* in_flight = budget.Take(k4k);
    ASSERT_EQ(in_flight, Handle(1));
    budget.MarkAwaitingGpu(in_flight);
    ASSERT_TRUE(budget.Admit(Slot(k1080, 2), evicted).accepted);

    // A resolution change gives back the cached shape and leaves the one a
    // live frame is reading exactly where it is.
    std::vector<void*> reclaimed;
    budget.DropOtherKeys(k1080, reclaimed);
    EXPECT_TRUE(reclaimed.empty());
    reclaimed.clear();
    budget.DropOtherKeys(k4k, reclaimed);
    EXPECT_EQ(reclaimed, std::vector<void*> { Handle(2) });
    EXPECT_EQ(budget.awaiting_gpu_completion_bytes(), Bytes(k4k));

    reclaimed.clear();
    budget.Drain(reclaimed);
    EXPECT_TRUE(reclaimed.empty());
    EXPECT_EQ(budget.live_slot_count(), 1u);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));

    const auto early = budget.Admit({ k4k, Bytes(k4k), in_flight }, evicted);
    EXPECT_FALSE(early.accepted);
    EXPECT_EQ(early.refusal, VideoConversionRefusal::StillOnLoan);

    // Neither emergency gets to release a texture the GPU is reading.
    std::vector<void*> pressure;
    budget.ReportMemoryPressure(pressure);
    EXPECT_TRUE(pressure.empty());
    std::vector<void*> failure;
    budget.ReportAllocationFailure(Bytes(k4k), failure);
    EXPECT_TRUE(failure.empty());
    EXPECT_EQ(budget.awaiting_gpu_completion_bytes(), Bytes(k4k));
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));
    EXPECT_EQ(budget.live_slot_count(), 1u);

    // It comes back only when the frame that held it says so.
    EXPECT_TRUE(budget.ReportGpuComplete(in_flight));
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
}

TEST(VideoConversionBudget, AdmitsARecycledDestinationWhenNothingCachedCanServeTheRequest)
{
    // The shape that exposed this: four imported 6144x3456 BGRA frames come to
    // 339,738,624 bytes, so the ledger sits permanently past the per-pool
    // ceiling for as long as the clip plays.
    constexpr VideoConversionSlotKey k6k { 6144, 3456, kBgra };
    ASSERT_GT(4 * Bytes(k6k), VideoConversionBudget::kDefaultCeilingBytes);

    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    for (std::uintptr_t id = 1; id <= 4; ++id) AllocateInFlight(budget, k6k, id, evicted);
    ASSERT_EQ(budget.live_slot_count(), 4u);
    const std::uint64_t peak = budget.peak_live_conversion_allocation_bytes();
    ASSERT_EQ(peak, 4 * Bytes(k6k));

    // Each generation retires the oldest frame and offers its destination
    // back. Admission allocates nothing — those bytes are already live — so
    // refusing for capacity frees nothing and only guarantees the caller
    // allocates the identical texture again on the next generation.
    for (std::uintptr_t id = 1; id <= 4; ++id) {
        ASSERT_TRUE(budget.ReportGpuComplete(Handle(id)));
        const auto readmitted = budget.Admit(Slot(k6k, id), evicted);
        EXPECT_TRUE(readmitted.accepted);
        EXPECT_EQ(readmitted.refusal, VideoConversionRefusal::None);
        EXPECT_EQ(budget.available_cached_bytes(), Bytes(k6k));
        // The next import takes it straight back out instead of allocating.
        EXPECT_EQ(budget.Take(k6k), Handle(id));
        budget.MarkAwaitingGpu(Handle(id));
    }
    EXPECT_EQ(budget.refusals(), 0u);
    EXPECT_EQ(budget.hits(), 4u);
    EXPECT_EQ(budget.misses(), 0u);
    EXPECT_TRUE(evicted.empty());
    EXPECT_EQ(budget.live_slot_count(), 4u);
    // Caching the recycled destination cost nothing at peak, which is the
    // whole reason refusing it would have been pointless.
    EXPECT_EQ(budget.peak_live_conversion_allocation_bytes(), peak);
}

TEST(VideoConversionBudget, RefusesASecondCachedSlotTheInFlightBytesLeaveNoRoomFor)
{
    VideoConversionBudget budget(2 * Bytes(k4k));
    std::vector<void*>    evicted;
    for (std::uintptr_t id = 1; id <= 3; ++id) AllocateInFlight(budget, k4k, id, evicted);
    ASSERT_EQ(budget.awaiting_gpu_completion_bytes(), 3 * Bytes(k4k));
    ASSERT_TRUE(evicted.empty());

    // The first cached slot of the shape in demand is the destination the next
    // import would allocate anyway, so it is admitted however full the ledger.
    ASSERT_TRUE(budget.ReportGpuComplete(Handle(1)));
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);
    ASSERT_EQ(budget.available_cached_bytes(), Bytes(k4k));
    ASSERT_EQ(budget.refusals(), 0u);

    // A second idle slot of that shape is not. It bets on more frames at once
    // than the ceiling admits, and the bytes in flight leave no room for it.
    const auto refused = budget.Admit(Slot(k4k, 4), evicted);
    EXPECT_FALSE(refused.accepted);
    EXPECT_EQ(refused.refusal, VideoConversionRefusal::LiveAllocationAtCeiling);
    EXPECT_EQ(budget.refusals(VideoConversionRefusal::LiveAllocationAtCeiling), 1u);
    // Refused before anything was given up, so the slot already proven
    // reusable is still the one in the pool.
    EXPECT_TRUE(evicted.empty());
    EXPECT_EQ(budget.available_cached_count(), 1u);
    EXPECT_EQ(budget.Take(k4k), Handle(1));
    budget.MarkAwaitingGpu(Handle(1));

    // It is about right now, not about the size: a retired frame makes the
    // same offer succeed, and the cache stays at one slot because the ceiling
    // bounds it by eviction rather than by refusal.
    ASSERT_TRUE(budget.ReportGpuComplete(Handle(2)));
    ASSERT_TRUE(budget.Admit(Slot(k4k, 2), evicted).accepted);
    EXPECT_TRUE(evicted.empty());
    ASSERT_TRUE(budget.ReportGpuComplete(Handle(3)));
    ASSERT_TRUE(budget.Admit(Slot(k4k, 3), evicted).accepted);
    EXPECT_EQ(evicted, std::vector<void*> { Handle(2) });
    EXPECT_EQ(budget.available_cached_count(), 1u);
    EXPECT_EQ(budget.available_cached_bytes(), Bytes(k4k));
}

TEST(VideoConversionBudget, ChargesGrantedEstimatesAgainstTheCeilingLikeAllocations)
{
    VideoConversionBudget budget(2 * Bytes(k4k));
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k4k, 2), evicted).accepted);
    ASSERT_EQ(budget.available_cached_count(), 2u);
    ASSERT_TRUE(evicted.empty());

    // A granted estimate is an intent the caller is about to act on, so it
    // holds the ceiling like an allocation and costs the pool a cached slot.
    const auto pending = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    ASSERT_TRUE(pending.granted);
    EXPECT_EQ(evicted, std::vector<void*> { Handle(1) });
    EXPECT_EQ(budget.reserved_estimate_bytes(), Bytes(k4k));
    EXPECT_EQ(budget.available_cached_count(), 1u);
    // It is still not an allocation, so it stays out of the live total.
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), Bytes(k4k));

    // The estimate, and no allocation, is what costs the next admission the
    // slot it would otherwise have cached alongside.
    ASSERT_TRUE(budget.Admit(Slot(k4k, 3), evicted).accepted);
    EXPECT_EQ(evicted, (std::vector<void*> { Handle(1), Handle(2) }));
    EXPECT_EQ(budget.available_cached_count(), 1u);

    budget.CancelReservation(pending);
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);
    evicted.clear();
    // With the intent withdrawn the ceiling holds two slots again.
    EXPECT_TRUE(budget.Admit(Slot(k4k, 4), evicted).accepted);
    EXPECT_TRUE(evicted.empty());
    EXPECT_EQ(budget.available_cached_count(), 2u);
}

TEST(VideoConversionBudget, GrantsOverTheCeilingRatherThanDroppingAFrame)
{
    VideoConversionBudget budget(2 * Bytes(k4k));
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 100), evicted).accepted);

    for (std::uintptr_t id = 1; id <= VideoConversionBudget::kCoexistingSlots; ++id) {
        AllocateInFlight(budget, k4k, id, evicted);
    }

    // The cache went first: it is the only thing this budget may give up.
    EXPECT_EQ(evicted, std::vector<void*> { Handle(100) });
    EXPECT_EQ(budget.available_cached_bytes(), 0u);
    // No frame is dropped for capacity, so every grant was made...
    EXPECT_EQ(budget.live_slot_count(),
              static_cast<std::size_t>(VideoConversionBudget::kCoexistingSlots));
    EXPECT_GT(budget.total_live_conversion_allocation_bytes(), budget.ceiling_bytes());
    // ...and each grant made above the ceiling is counted rather than hidden.
    // The first two fitted; the rest did not.
    EXPECT_EQ(budget.over_ceiling_grants(), VideoConversionBudget::kCoexistingSlots - 2);
    // The overshoot is bounded by what the caller can hold at once, which is
    // kCoexistingSlots destinations of the requested shape.
    EXPECT_LE(budget.total_live_conversion_allocation_bytes(),
              VideoConversionBudget::RequiredBytesForAllSlots(Bytes(k4k)));
    EXPECT_EQ(budget.peak_live_conversion_allocation_bytes(),
              VideoConversionBudget::kCoexistingSlots * Bytes(k4k));
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);

    // Recovery: the over-budget frames retire and the ledger empties.
    for (std::uintptr_t id = 1; id <= VideoConversionBudget::kCoexistingSlots; ++id) {
        EXPECT_TRUE(budget.ReportGpuComplete(Handle(id)));
    }
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    EXPECT_EQ(budget.live_slot_count(), 0u);

    std::vector<void*> reclaimed;
    budget.ReportMemoryPressure(reclaimed);
    budget.ClearMemoryPressure();
    budget.Reset();
    evicted.clear();
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k4k, 2), evicted).accepted);
    EXPECT_TRUE(evicted.empty());
    EXPECT_EQ(budget.available_cached_count(), 2u);
    EXPECT_EQ(budget.available_cached_bytes(), 2 * Bytes(k4k));
    // Caching normally again is not a new overshoot.
    EXPECT_EQ(budget.over_ceiling_grants(), VideoConversionBudget::kCoexistingSlots - 2);
}

TEST(VideoConversionBudget, LeavesNoBytesBehindWhenEveryDestinationIsReleased)
{
    VideoConversionMemoryDomain domain;
    {
        VideoConversionBudget budget;
        budget.AttachDomain(&domain);
        std::vector<void*> evicted;
        // Every route a destination can take through the ledger at once.
        ASSERT_TRUE(budget.Admit(Slot(k1080, 1), evicted).accepted);
        ASSERT_TRUE(budget.Admit(Slot(k4k, 2), evicted).accepted);
        void* taken = budget.Take(k4k);
        ASSERT_EQ(taken, Handle(2));
        budget.MarkAwaitingGpu(taken);
        AllocateInFlight(budget, k720, 3, evicted);
        const auto cancelled = budget.ReserveAllocation(k720, Bytes(k720), evicted);
        budget.CancelReservation(cancelled);
        ASSERT_GT(budget.total_live_conversion_allocation_bytes(), 0u);
        ASSERT_EQ(budget.live_slot_count(), 3u);

        EXPECT_TRUE(budget.ReportGpuComplete(taken));
        budget.EndLoan(Handle(3));
        std::vector<void*> reclaimed;
        budget.Drain(reclaimed);
        EXPECT_EQ(reclaimed, std::vector<void*> { Handle(1) });

        EXPECT_EQ(budget.available_cached_bytes(), 0u);
        EXPECT_EQ(budget.checked_out_bytes(), 0u);
        EXPECT_EQ(budget.awaiting_gpu_completion_bytes(), 0u);
        EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);
        EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
        EXPECT_EQ(budget.live_slot_count(), 0u);
        EXPECT_EQ(budget.loan_count(), 0u);
        EXPECT_EQ(budget.available_cached_count(), 0u);
        // The high-water marks are the figures a ceiling is judged against.
        EXPECT_GT(budget.peak_live_conversion_allocation_bytes(), 0u);
        EXPECT_EQ(domain.live_bytes(), 0u);
    }
    // A budget that goes away takes its row in the domain with it.
    EXPECT_EQ(domain.budget_count(), 0u);
    EXPECT_EQ(domain.live_bytes(), 0u);
    EXPECT_EQ(domain.cached_bytes(), 0u);
}

TEST(VideoConversionBudget, SaturatesSlotArithmeticInsteadOfWrapping)
{
    constexpr std::uint64_t max = std::numeric_limits<std::uint64_t>::max();
    EXPECT_EQ(VideoConversionBudget::RequiredBytesForAllSlots(0), 0u);
    EXPECT_EQ(VideoConversionBudget::RequiredBytesForAllSlots(Bytes(k4k)),
              Bytes(k4k) * VideoConversionBudget::kCoexistingSlots);
    EXPECT_EQ(VideoConversionBudget::RequiredBytesForAllSlots(max / 2), max);

    // A wrapped product reads as a small total, which would answer "the
    // ceiling hosts every slot" for a size that cannot hold even one.
    VideoConversionBudget budget;
    EXPECT_FALSE(budget.HostsAllSlots(max / 2));
    EXPECT_FALSE(budget.HostsAllSlots(max));
}

TEST(VideoConversionBudget, SaturatesTheLiveTotalInsteadOfWrapping)
{
    constexpr std::uint64_t max = std::numeric_limits<std::uint64_t>::max();
    VideoConversionBudget   budget(max);
    std::vector<void*>      evicted;

    const auto first = budget.ReserveAllocation(k4k, max - 1, evicted);
    budget.CommitAllocation(first, { k4k, max - 1, Handle(1) });
    const auto second = budget.ReserveAllocation(k4k, max - 1, evicted);
    budget.CommitAllocation(second, { k4k, max - 1, Handle(2) });

    // Wrapped, the sum of two near-maximal allocations reads as a small
    // number, and a small number answers "there is room".
    EXPECT_EQ(budget.checked_out_bytes(), max);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), max);
    EXPECT_EQ(budget.peak_live_conversion_allocation_bytes(), max);

    EXPECT_TRUE(budget.ReportGpuComplete(Handle(1)));
    EXPECT_TRUE(budget.ReportGpuComplete(Handle(2)));
    // Saturation is not reversible, but releasing must not underflow into an
    // astronomically large total on the way out.
    EXPECT_EQ(budget.checked_out_bytes(), 0u);
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), 0u);
    EXPECT_EQ(budget.live_slot_count(), 0u);
}

TEST(VideoConversionMemoryDomain, RegistersNothingUntilABudgetOptsIn)
{
    VideoConversionMemoryDomain& shared = SharedVideoConversionMemoryDomain();
    const std::size_t            before = shared.budget_count();

    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);
    // A pool that never opted in is in nobody's total, so the domain ceiling
    // governs the budgets that attached to it and no others.
    EXPECT_EQ(budget.domain(), nullptr);
    EXPECT_EQ(shared.budget_count(), before);

    budget.AttachDomain(&shared);
    EXPECT_EQ(budget.domain(), &shared);
    EXPECT_EQ(shared.budget_count(), before + 1);
    EXPECT_EQ(shared.ceiling_bytes(), VideoConversionMemoryDomain::kDefaultCeilingBytes);

    budget.AttachDomain(nullptr);
    EXPECT_EQ(budget.domain(), nullptr);
    EXPECT_EQ(shared.budget_count(), before);
}

// The threshold a pool serving two video textures publishes:
// `TextureCache::kMaxPendingVideoImportSubmissions` (2, per cache) plus
// `TextureCache::kMaxImportedVideoFramesPerVideoTex` (4, per video texture)
// times two live video textures. The budget is told the product, never the
// factors — those belong to the texture cache.
constexpr std::uint32_t kTwoSourceCap = 2 + 4 * 2;

TEST(VideoConversionBudget, GrantsPastTheInFlightThresholdAndReportsTheBreachOncePerEpisode)
{
    // A ceiling far larger than the workload, so the only thing under test is
    // the structural threshold and not the byte total.
    VideoConversionBudget budget(64 * Bytes(k4k));
    std::vector<void*>    evicted;
    for (std::uintptr_t id = 1; id <= VideoConversionBudget::kCoexistingSlots; ++id) {
        AllocateInFlight(budget, k4k, id, evicted);
    }
    ASSERT_EQ(budget.loan_count(),
              static_cast<std::size_t>(VideoConversionBudget::kCoexistingSlots));
    ASSERT_EQ(budget.in_flight_cap_breaches(), 0u);
    ASSERT_FALSE(budget.in_flight_cap_reported());

    // At the threshold the reservation is granted exactly like any other one.
    // Refusing here would remove the only event that returns a destination:
    // the consumer holds its last import until a new import replaces it.
    const auto breach = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(breach.granted);
    EXPECT_TRUE(breach.in_flight_cap_breached);
    EXPECT_TRUE(breach.first_in_flight_cap_report);
    EXPECT_TRUE(budget.in_flight_cap_reported());
    EXPECT_EQ(budget.in_flight_cap_breaches(), 1u);
    // A breach is not a refusal and is never counted as one.
    EXPECT_EQ(budget.refusals(), 0u);
    // Granted means the estimate is booked, which is what makes committing or
    // cancelling it the caller's job.
    EXPECT_EQ(budget.reserved_estimate_bytes(), Bytes(k4k));
    budget.CommitAllocation(breach, Slot(k4k, 7));
    // Past the threshold, which is the proof that nothing here gates.
    EXPECT_EQ(budget.loan_count(),
              static_cast<std::size_t>(VideoConversionBudget::kCoexistingSlots) + 1);
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);

    // A caller that asks every frame is granted every frame and reports once.
    const auto again = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(again.granted);
    EXPECT_TRUE(again.in_flight_cap_breached);
    EXPECT_FALSE(again.first_in_flight_cap_report);
    EXPECT_EQ(budget.in_flight_cap_breaches(), 2u);
    budget.CancelReservation(again);

    // Reset starts a fresh reporting episode without disturbing the loans.
    budget.Reset();
    EXPECT_FALSE(budget.in_flight_cap_reported());
    EXPECT_EQ(budget.loan_count(),
              static_cast<std::size_t>(VideoConversionBudget::kCoexistingSlots) + 1);
    const auto after_reset = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(after_reset.granted);
    EXPECT_TRUE(after_reset.first_in_flight_cap_report);
    budget.CancelReservation(after_reset);
}

TEST(VideoConversionBudget, GrantsEveryReservationHoweverFarPastTheThreshold)
{
    // The rule head-on: at the threshold and arbitrarily beyond it, a
    // reservation is still granted. No capacity answer is left in
    // `ReserveAllocation` at all.
    VideoConversionBudget budget(64 * Bytes(k4k));
    std::vector<void*>    evicted;
    constexpr std::uintptr_t kFarPast = 3 * VideoConversionBudget::kCoexistingSlots;
    for (std::uintptr_t id = 1; id <= kFarPast; ++id) {
        const auto reservation = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
        ASSERT_TRUE(reservation.granted) << "refused at in-flight destination " << id;
        // Breached for every request made once the loans already reached the
        // threshold, and for no earlier one.
        EXPECT_EQ(reservation.in_flight_cap_breached,
                  id > VideoConversionBudget::kCoexistingSlots);
        budget.CommitAllocation(reservation, Slot(k4k, id));
        budget.MarkAwaitingGpu(Handle(id));
        ASSERT_EQ(budget.loan_count(), static_cast<std::size_t>(id));
    }
    EXPECT_EQ(budget.in_flight_cap_breaches(),
              static_cast<std::uint64_t>(kFarPast - VideoConversionBudget::kCoexistingSlots));
    EXPECT_EQ(budget.refusals(), 0u);
}

TEST(VideoConversionBudget, KeepsGrantingWhenTheConsumerReleasesOnlyOnTheNextImport)
{
    // The shape that deadlocked a denying cap on a real GPU. The consumer
    // holds the destination it last imported and gives it back only when a new
    // import replaces it, so a refusal cancels the very release it waits for:
    // the loan count never falls, every later request fails for the same
    // reason, and the video texture freezes on the generation it had. Every
    // generation here must still get its destination.
    VideoConversionBudget budget(64 * Bytes(k4k));
    std::vector<void*>    evicted;
    constexpr std::size_t       kRetained = VideoConversionBudget::kCoexistingSlots;
    constexpr std::uintptr_t    kGenerations = 40;
    std::vector<std::uintptr_t> held;
    std::uint64_t               created = 0;
    std::uint64_t               first_reports = 0;
    for (std::uintptr_t generation = 1; generation <= kGenerations; ++generation) {
        const auto reservation = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
        ASSERT_TRUE(reservation.granted) << "froze at generation " << generation;
        if (reservation.first_in_flight_cap_report) ++first_reports;
        budget.CommitAllocation(reservation, Slot(k4k, generation));
        budget.MarkAwaitingGpu(Handle(generation));
        ++created;
        held.push_back(generation);
        // The release a refusal would have cancelled. It happens only because
        // this import succeeded.
        if (held.size() > kRetained) {
            ASSERT_TRUE(budget.ReportGpuComplete(Handle(held.front())));
            held.erase(held.begin());
        }
    }
    // Created keeps climbing instead of freezing, and the retained set stays
    // bounded instead of growing without end.
    EXPECT_EQ(created, static_cast<std::uint64_t>(kGenerations));
    EXPECT_EQ(budget.loan_count(), kRetained);
    EXPECT_EQ(budget.refusals(), 0u);
    // The condition persists once retention reaches the threshold, and is
    // reported once for the whole episode rather than once per frame.
    EXPECT_EQ(budget.in_flight_cap_breaches(),
              static_cast<std::uint64_t>(kGenerations) - kRetained);
    EXPECT_EQ(first_reports, 1u);
}

TEST(VideoConversionBudget, ReportsAgainstTheSingleTextureFloorUntilToldOtherwise)
{
    // A budget nothing configures, and a pool that publishes a count below one
    // video texture's worth, both report exactly as they did before the
    // threshold was configurable. The floor is what keeps an unconfigured pool
    // meaningful.
    VideoConversionBudget unconfigured(64 * Bytes(k4k));
    EXPECT_EQ(unconfigured.in_flight_slot_cap(), VideoConversionBudget::kCoexistingSlots);

    VideoConversionBudget floored(64 * Bytes(k4k));
    floored.SetInFlightSlotCap(0);
    EXPECT_EQ(floored.in_flight_slot_cap(), VideoConversionBudget::kCoexistingSlots);
    floored.SetInFlightSlotCap(1);
    EXPECT_EQ(floored.in_flight_slot_cap(), VideoConversionBudget::kCoexistingSlots);

    std::vector<void*> evicted;
    for (std::uintptr_t id = 1; id <= VideoConversionBudget::kCoexistingSlots; ++id) {
        AllocateInFlight(floored, k4k, id, evicted);
    }
    // Nothing below the floor is reported, and the floor is where reporting
    // starts.
    EXPECT_EQ(floored.in_flight_cap_breaches(), 0u);
    const auto breach = floored.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(breach.granted);
    EXPECT_TRUE(breach.in_flight_cap_breached);
    EXPECT_EQ(floored.in_flight_cap_breaches(), 1u);
    floored.CancelReservation(breach);
}

TEST(VideoConversionBudget, ReportsNoBreachForInFlightDemandTheThresholdCovers)
{
    // Two video wallpapers sharing one texture cache legitimately hold more
    // destinations in flight than one does, because the per-video-texture
    // import cap is per video texture. A flat `kCoexistingSlots` would report
    // the seventh of ten structurally legitimate destinations as a breach and
    // send someone hunting a leak that is not there.
    VideoConversionBudget budget(64 * Bytes(k4k));
    budget.SetInFlightSlotCap(kTwoSourceCap);
    ASSERT_EQ(budget.in_flight_slot_cap(), kTwoSourceCap);
    ASSERT_GT(kTwoSourceCap, VideoConversionBudget::kCoexistingSlots);

    std::vector<void*> evicted;
    for (std::uintptr_t id = 1; id <= kTwoSourceCap; ++id) {
        AllocateInFlight(budget, k4k, id, evicted);
        EXPECT_EQ(budget.loan_count(), static_cast<std::size_t>(id));
    }
    EXPECT_EQ(budget.in_flight_cap_breaches(), 0u);
    EXPECT_FALSE(budget.in_flight_cap_reported());
    EXPECT_EQ(budget.over_ceiling_grants(), 0u);

    // Past what the pool's own structure accounts for, so it is reported —
    // and, as ever, granted.
    const auto breach = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(breach.granted);
    EXPECT_TRUE(breach.in_flight_cap_breached);
    EXPECT_TRUE(breach.first_in_flight_cap_report);
    EXPECT_EQ(budget.in_flight_cap_breaches(), 1u);
    budget.CancelReservation(breach);
}

TEST(VideoConversionBudget, LoweringTheThresholdNeverRetractsWhatIsAlreadyInFlight)
{
    // A video texture going away lowers the threshold. The destinations
    // already in flight are being read by the GPU: nothing is reclaimed,
    // nothing is released and nothing is retroactively reported. Only the next
    // reservation is judged against the new value.
    VideoConversionBudget budget(64 * Bytes(k4k));
    budget.SetInFlightSlotCap(kTwoSourceCap);
    std::vector<void*>       evicted;
    constexpr std::uintptr_t kHeld = VideoConversionBudget::kCoexistingSlots + 1;
    for (std::uintptr_t id = 1; id <= kHeld; ++id) {
        AllocateInFlight(budget, k4k, id, evicted);
    }
    const std::uint64_t live_before = budget.total_live_conversion_allocation_bytes();
    // Well within the two-texture threshold, so nothing has been reported yet.
    ASSERT_EQ(budget.in_flight_cap_breaches(), 0u);

    budget.SetInFlightSlotCap(VideoConversionBudget::kCoexistingSlots);
    EXPECT_EQ(budget.in_flight_slot_cap(), VideoConversionBudget::kCoexistingSlots);
    EXPECT_EQ(budget.loan_count(), static_cast<std::size_t>(kHeld));
    EXPECT_EQ(budget.total_live_conversion_allocation_bytes(), live_before);
    EXPECT_TRUE(evicted.empty());
    EXPECT_EQ(budget.in_flight_cap_breaches(), 0u);

    // The next reservation, and only it, sees the lower threshold — and is
    // granted regardless.
    const auto next = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(next.granted);
    EXPECT_TRUE(next.in_flight_cap_breached);
    EXPECT_EQ(budget.in_flight_cap_breaches(), 1u);
    EXPECT_EQ(budget.loan_count(), static_cast<std::size_t>(kHeld));
    budget.CancelReservation(next);
}

TEST(VideoConversionBudget, CachedSlotsBreachNoThresholdValue)
{
    // The reported quantity is `loan_count()` at every threshold, never
    // `live_slot_count()`. A cached slot has already been returned and is what
    // the next import reuses, so counting it would report a breach exactly
    // when reuse is working.
    VideoConversionBudget budget(64 * Bytes(k4k));
    budget.SetInFlightSlotCap(kTwoSourceCap);
    std::vector<void*> evicted;
    for (std::uintptr_t id = 1; id <= kTwoSourceCap - 1; ++id) {
        AllocateInFlight(budget, k4k, id, evicted);
    }
    for (std::uintptr_t id = 100; id < 100 + VideoConversionBudget::kCoexistingSlots; ++id) {
        ASSERT_TRUE(budget.Admit(Slot(k720, id), evicted).accepted);
    }
    ASSERT_EQ(budget.available_cached_count(),
              static_cast<std::size_t>(VideoConversionBudget::kCoexistingSlots));
    ASSERT_GT(budget.live_slot_count(), static_cast<std::size_t>(kTwoSourceCap));

    // Well past the threshold in live slots, one below it in flight: no breach.
    const auto clean = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(clean.granted);
    EXPECT_FALSE(clean.in_flight_cap_breached);
    EXPECT_EQ(budget.in_flight_cap_breaches(), 0u);
    budget.CommitAllocation(clean, Slot(k4k, kTwoSourceCap));
    ASSERT_EQ(budget.loan_count(), static_cast<std::size_t>(kTwoSourceCap));

    // And once the loans alone reach it, the breach is about them: the cache
    // is untouched by the decision either way.
    const std::size_t cached_before = budget.available_cached_count();
    const auto        breach = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(breach.granted);
    EXPECT_TRUE(breach.in_flight_cap_breached);
    EXPECT_EQ(budget.available_cached_count(), cached_before);
    budget.CancelReservation(breach);
}

TEST(VideoConversionBudget, StopsReportingOnceTheCountIsUnderTheThresholdAgain)
{
    // Bounded reporting, not a permanent alarm. The condition clears the
    // moment a destination is returned, and clears the same way when a new
    // video texture raises the threshold.
    VideoConversionBudget budget(64 * Bytes(k4k));
    budget.SetInFlightSlotCap(kTwoSourceCap);
    std::vector<void*> evicted;
    for (std::uintptr_t id = 1; id <= kTwoSourceCap; ++id) {
        AllocateInFlight(budget, k4k, id, evicted);
    }
    const auto breach = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    ASSERT_TRUE(breach.in_flight_cap_breached);
    ASSERT_TRUE(budget.in_flight_cap_reported());
    budget.CancelReservation(breach);

    // A return puts the count back under the threshold.
    ASSERT_TRUE(budget.ReportGpuComplete(Handle(1)));
    EXPECT_FALSE(budget.in_flight_cap_reported());
    const auto clean = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(clean.granted);
    EXPECT_FALSE(clean.in_flight_cap_breached);
    EXPECT_EQ(budget.in_flight_cap_breaches(), 1u);
    budget.CommitAllocation(clean, Slot(k4k, kTwoSourceCap + 1));
    ASSERT_EQ(budget.loan_count(), static_cast<std::size_t>(kTwoSourceCap));

    // Back at the threshold, so a new episode is reported.
    const auto breach_again = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    ASSERT_TRUE(breach_again.in_flight_cap_breached);
    EXPECT_TRUE(breach_again.first_in_flight_cap_report);
    budget.CancelReservation(breach_again);

    // A third video texture raises the threshold past what is in flight, which
    // ends the episode for the same reason a return does.
    budget.SetInFlightSlotCap(kTwoSourceCap + 4);
    EXPECT_FALSE(budget.in_flight_cap_reported());
    const auto after_raise = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(after_raise.granted);
    EXPECT_FALSE(after_raise.in_flight_cap_breached);
    budget.CancelReservation(after_raise);
}

TEST(VideoConversionBudget, DeniesAReservationForASizeAnAllocationAlreadyFailedAt)
{
    // Without this the pool retries the identical failing allocation every
    // frame: it fails, it logs, and nothing about the next frame is different.
    // Denying is safe here in a way a capacity refusal is not — the allocation
    // was never going to produce a destination, so the import fails either way
    // and no release a later request depends on is withheld.
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    budget.ReportAllocationFailure(Bytes(k4k), evicted);
    ASSERT_EQ(budget.unsatisfiable_bytes(), Bytes(k4k));

    const auto denied = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_FALSE(denied.granted);
    EXPECT_EQ(denied.refusal, VideoConversionRefusal::AllocationUnsatisfiable);
    EXPECT_TRUE(denied.first_unsatisfiable_report);
    EXPECT_TRUE(budget.unsatisfiable_reported());
    EXPECT_EQ(budget.unsatisfiable_denials(), 1u);
    // Nothing was booked and nothing was given up for a request that was never
    // going to allocate.
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);
    EXPECT_TRUE(evicted.empty());
    // A denied reservation carries no estimate to release and no allocation to
    // record, so handing it back changes nothing.
    budget.CommitAllocation(denied, Slot(k4k, 1));
    EXPECT_EQ(budget.live_slot_count(), 0u);
    EXPECT_EQ(budget.reserved_estimate_bytes(), 0u);

    // Larger is denied too, and a caller asking every frame logs once.
    const auto larger = budget.ReserveAllocation(k8k, Bytes(k8k), evicted);
    EXPECT_FALSE(larger.granted);
    EXPECT_EQ(larger.refusal, VideoConversionRefusal::AllocationUnsatisfiable);
    EXPECT_FALSE(larger.first_unsatisfiable_report);
    EXPECT_EQ(budget.unsatisfiable_denials(), 2u);

    // A size the failure says nothing about still allocates.
    const auto smaller = budget.ReserveAllocation(k1080, Bytes(k1080), evicted);
    EXPECT_TRUE(smaller.granted);
    EXPECT_EQ(smaller.refusal, VideoConversionRefusal::None);
    EXPECT_EQ(smaller.estimated_bytes, Bytes(k1080));
    EXPECT_EQ(budget.reserved_estimate_bytes(), Bytes(k1080));
    EXPECT_EQ(budget.unsatisfiable_denials(), 2u);
    budget.CancelReservation(smaller);

    // `Reset` is the whole recovery path: the size is attempted again.
    budget.Reset();
    EXPECT_EQ(budget.unsatisfiable_bytes(), 0u);
    EXPECT_FALSE(budget.unsatisfiable_reported());
    const auto recovered = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(recovered.granted);
    EXPECT_EQ(recovered.refusal, VideoConversionRefusal::None);
    budget.CancelReservation(recovered);

    // A later failure opens a new episode, which is reported again rather than
    // staying silent because an older one was.
    budget.ReportAllocationFailure(Bytes(k4k), evicted);
    const auto denied_again = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_FALSE(denied_again.granted);
    EXPECT_TRUE(denied_again.first_unsatisfiable_report);
    EXPECT_EQ(budget.unsatisfiable_denials(), 3u);
}

TEST(VideoConversionBudget, CountsAnUnsatisfiableDenialApartFromTheCapacityNumbers)
{
    // A denial is about an allocation that failed, not about capacity. Mixing
    // it into an over-ceiling grant or an in-flight breach would read as
    // pressure this budget is not under, so it is counted on its own — even
    // when the loans happen to sit at the threshold at the same moment.
    VideoConversionBudget budget(64 * Bytes(k4k));
    std::vector<void*>    evicted;
    for (std::uintptr_t id = 1; id <= VideoConversionBudget::kCoexistingSlots; ++id) {
        AllocateInFlight(budget, k4k, id, evicted);
    }
    budget.ReportAllocationFailure(Bytes(k4k), evicted);
    // A failure report gives back cached slots only; the loans stand.
    ASSERT_EQ(budget.loan_count(),
              static_cast<std::size_t>(VideoConversionBudget::kCoexistingSlots));

    const auto denied = budget.ReserveAllocation(k4k, Bytes(k4k), evicted);
    ASSERT_FALSE(denied.granted);
    EXPECT_EQ(budget.unsatisfiable_denials(), 1u);
    // The threshold logic is not on this path: no breach counted, no episode
    // opened and no flag set, though the loans are exactly at the threshold.
    EXPECT_FALSE(denied.in_flight_cap_breached);
    EXPECT_FALSE(denied.first_in_flight_cap_report);
    EXPECT_EQ(budget.in_flight_cap_breaches(), 0u);
    EXPECT_FALSE(budget.in_flight_cap_reported());
    // Nor is it an over-ceiling grant, nor an admission refusal.
    EXPECT_EQ(budget.over_ceiling_grants(), 0u);
    EXPECT_EQ(budget.refusals(), 0u);
    EXPECT_EQ(budget.refusals(VideoConversionRefusal::AllocationUnsatisfiable), 0u);
}

TEST(VideoConversionMemoryDomain, OneBudgetsLiveAllocationsReduceTheOthersHeadroom)
{
    // The domain ceiling is well below what either budget would allow on its
    // own, so every effect below is the domain's and not a local ceiling's.
    VideoConversionMemoryDomain domain(4 * Bytes(k4k));
    VideoConversionBudget       first(8 * Bytes(k4k));
    VideoConversionBudget       second(8 * Bytes(k4k));
    first.AttachDomain(&domain);
    second.AttachDomain(&domain);
    ASSERT_EQ(domain.budget_count(), 2u);
    EXPECT_EQ(domain.headroom_for(&first), 4 * Bytes(k4k));

    std::vector<void*> evicted;
    ASSERT_TRUE(second.Admit(Slot(k1080, 50), evicted).accepted);
    ASSERT_EQ(second.available_cached_count(), 1u);

    for (std::uintptr_t id = 1; id <= 4; ++id) AllocateInFlight(first, k4k, id, evicted);
    EXPECT_EQ(domain.live_bytes(), 4 * Bytes(k4k) + Bytes(k1080));
    EXPECT_GT(domain.live_bytes(), domain.ceiling_bytes());
    // Only what is cached could ever be given back; the rest is in flight.
    EXPECT_EQ(domain.cached_bytes(), Bytes(k1080));
    // First was told it was over by the domain, not by its own ceiling, which
    // would have accommodated all four.
    EXPECT_EQ(first.over_ceiling_grants(), 1u);
    EXPECT_LT(4 * Bytes(k4k), first.ceiling_bytes());

    // One pool's live allocations are what reduce the others' headroom, and a
    // budget never counts against its own.
    EXPECT_EQ(domain.headroom_for(&second), 0u);
    EXPECT_EQ(domain.headroom_for(&first), 4 * Bytes(k4k) - Bytes(k1080));
    // Shedding is cooperative and late: nothing has reached into second yet.
    EXPECT_EQ(second.available_cached_count(), 1u);

    const std::uint64_t shed_before = domain.shed_requests();
    std::vector<void*>  shed;
    // Second shrinks on its own next operation: it gives up the shape nothing
    // asks for any more and keeps exactly the one destination the shape now in
    // demand needs, which its next import would have allocated regardless.
    EXPECT_TRUE(second.Admit(Slot(k4k, 51), shed).accepted);
    EXPECT_GT(domain.shed_requests(), shed_before);
    EXPECT_EQ(shed, std::vector<void*> { Handle(50) });
    EXPECT_EQ(second.available_cached_count(), 1u);
    EXPECT_EQ(second.available_cached_bytes(), Bytes(k4k));

    // A second idle slot of that shape is where the domain says no: the other
    // budget's live bytes leave no headroom for speculative caching.
    shed.clear();
    const auto refused = second.Admit(Slot(k4k, 52), shed);
    EXPECT_FALSE(refused.accepted);
    EXPECT_EQ(refused.refusal, VideoConversionRefusal::LiveAllocationAtCeiling);
    EXPECT_TRUE(shed.empty());
    EXPECT_EQ(second.available_cached_count(), 1u);
    // Nothing of first's was touched by any of it.
    EXPECT_EQ(first.live_slot_count(), 4u);
    EXPECT_EQ(first.awaiting_gpu_completion_bytes(), 4 * Bytes(k4k));
    EXPECT_EQ(first.total_live_conversion_allocation_bytes(), 4 * Bytes(k4k));

    // When first's frames retire the domain opens up again, with no budget
    // having released anything belonging to another.
    for (std::uintptr_t id = 1; id <= 4; ++id) EXPECT_TRUE(first.ReportGpuComplete(Handle(id)));
    EXPECT_EQ(domain.live_bytes(), Bytes(k4k));
    EXPECT_EQ(domain.peak_live_bytes(), 5 * Bytes(k4k));
    shed.clear();
    EXPECT_TRUE(second.Admit(Slot(k4k, 52), shed).accepted);
    EXPECT_TRUE(shed.empty());
    EXPECT_EQ(second.available_cached_count(), 2u);
    EXPECT_EQ(second.available_cached_bytes(), 2 * Bytes(k4k));
    EXPECT_EQ(domain.cached_bytes(), 2 * Bytes(k4k));
}

TEST(VideoConversionMemoryDomain, CountsAGrantedReservationAgainstTheOtherBudgetsHeadroom)
{
    VideoConversionMemoryDomain domain(4 * Bytes(k4k));
    VideoConversionBudget       first(8 * Bytes(k4k));
    VideoConversionBudget       second(8 * Bytes(k4k));
    first.AttachDomain(&domain);
    second.AttachDomain(&domain);
    ASSERT_EQ(domain.headroom_for(&second), 4 * Bytes(k4k));

    std::vector<void*> evicted;
    const auto         pending = first.ReserveAllocation(k4k, 3 * Bytes(k4k), evicted);
    ASSERT_TRUE(pending.granted);
    // Nothing has been allocated yet, so the live total is still zero...
    EXPECT_EQ(domain.live_bytes(), 0u);
    EXPECT_EQ(domain.reserved_bytes(), 3 * Bytes(k4k));
    // ...but the intent is visible to the other pool at once. A budget that
    // charged its own ceiling for an estimate and hid it from the domain would
    // let the second pool spend the same bytes over again.
    EXPECT_EQ(domain.headroom_for(&second), Bytes(k4k));
    // A budget still never counts against its own headroom.
    EXPECT_EQ(domain.headroom_for(&first), 4 * Bytes(k4k));

    const auto competing = second.ReserveAllocation(k4k, 3 * Bytes(k4k), evicted);
    // Both were granted, because a decoded frame is never dropped for
    // capacity, but only the first one fitted.
    EXPECT_TRUE(competing.granted);
    EXPECT_FALSE(pending.over_ceiling);
    EXPECT_TRUE(competing.over_ceiling);
    EXPECT_EQ(first.over_ceiling_grants(), 0u);
    EXPECT_EQ(second.over_ceiling_grants(), 1u);
    EXPECT_EQ(domain.reserved_bytes(), 6 * Bytes(k4k));

    // Committing turns the intent into an allocation without double counting.
    first.CommitAllocation(pending, { k4k, 3 * Bytes(k4k), Handle(1) });
    EXPECT_EQ(domain.reserved_bytes(), 3 * Bytes(k4k));
    EXPECT_EQ(domain.live_bytes(), 3 * Bytes(k4k));
    EXPECT_EQ(domain.headroom_for(&second), Bytes(k4k));

    // Withdrawing an intent gives its headroom straight back.
    second.CancelReservation(competing);
    EXPECT_EQ(domain.reserved_bytes(), 0u);
    EXPECT_EQ(domain.headroom_for(&first), 4 * Bytes(k4k));
    EXPECT_EQ(domain.headroom_for(&second), Bytes(k4k));
}

TEST(VideoConversionMemoryDomain, TwoPoolsCannotBothBeToldTheSameHeadroomIsFree)
{
    // Exactly one destination's worth of room in the whole domain.
    VideoConversionMemoryDomain domain(Bytes(k4k));
    VideoConversionBudget       first(8 * Bytes(k4k));
    VideoConversionBudget       second(8 * Bytes(k4k));
    first.AttachDomain(&domain);
    second.AttachDomain(&domain);

    std::vector<void*> evicted;
    // Neither has allocated anything, so both would read the whole ceiling as
    // free if the fit test and the record of the reservation were two separate
    // locked steps with a gap between them.
    const auto a = first.ReserveAllocation(k4k, Bytes(k4k), evicted);
    const auto b = second.ReserveAllocation(k4k, Bytes(k4k), evicted);
    ASSERT_TRUE(a.granted);
    ASSERT_TRUE(b.granted);
    // The room was handed out once. The first asker fitted; the second was
    // told it is over, because recording and answering happen under one lock.
    EXPECT_FALSE(a.over_ceiling);
    EXPECT_TRUE(b.over_ceiling);
    EXPECT_EQ(domain.reserved_bytes(), 2 * Bytes(k4k));
    EXPECT_EQ(domain.live_bytes(), 0u);
    EXPECT_EQ(domain.shed_requests(), 1u);

    // A third pool, with both estimates still outstanding, is over as well.
    VideoConversionBudget third(8 * Bytes(k4k));
    third.AttachDomain(&domain);
    const auto c = third.ReserveAllocation(k4k, Bytes(k4k), evicted);
    EXPECT_TRUE(c.granted);
    EXPECT_TRUE(c.over_ceiling);
    EXPECT_EQ(domain.shed_requests(), 2u);

    first.CancelReservation(a);
    second.CancelReservation(b);
    third.CancelReservation(c);
    EXPECT_EQ(domain.reserved_bytes(), 0u);
    EXPECT_EQ(domain.headroom_for(&second), Bytes(k4k));
}

TEST(VideoConversionMemoryDomain, SumsEveryBudgetAndGivesTheRoomBackWhenOneGoesAway)
{
    VideoConversionMemoryDomain domain(8 * Bytes(k4k));
    VideoConversionBudget       first(8 * Bytes(k4k));
    VideoConversionBudget       second(8 * Bytes(k4k));
    std::vector<void*>          evicted;
    {
        VideoConversionBudget third(8 * Bytes(k4k));
        first.AttachDomain(&domain);
        second.AttachDomain(&domain);
        third.AttachDomain(&domain);
        ASSERT_EQ(domain.budget_count(), 3u);

        AllocateInFlight(first, k4k, 1, evicted);
        AllocateInFlight(second, k4k, 2, evicted);
        AllocateInFlight(third, k4k, 3, evicted);
        ASSERT_TRUE(second.Admit(Slot(k1080, 10), evicted).accepted);

        EXPECT_EQ(domain.live_bytes(), 3 * Bytes(k4k) + Bytes(k1080));
        EXPECT_EQ(domain.peak_live_bytes(), 3 * Bytes(k4k) + Bytes(k1080));
        // Only the cached slot could ever be shed; the rest is in flight.
        EXPECT_EQ(domain.cached_bytes(), Bytes(k1080));
        // Each budget's headroom excludes its own bytes and nobody else's.
        EXPECT_EQ(domain.headroom_for(&first), 6 * Bytes(k4k) - Bytes(k1080));
        EXPECT_EQ(domain.headroom_for(&second), 6 * Bytes(k4k));
    }
    // A budget that goes away takes its row with it and gives its bytes back
    // to the others, without anything of theirs having been touched.
    EXPECT_EQ(domain.budget_count(), 2u);
    EXPECT_EQ(domain.live_bytes(), 2 * Bytes(k4k) + Bytes(k1080));
    EXPECT_EQ(domain.cached_bytes(), Bytes(k1080));
    EXPECT_EQ(domain.headroom_for(&first), 7 * Bytes(k4k) - Bytes(k1080));
    EXPECT_EQ(domain.headroom_for(&second), 7 * Bytes(k4k));
    EXPECT_EQ(first.live_slot_count(), 1u);
    EXPECT_EQ(second.live_slot_count(), 2u);
    // The peak is the figure a ceiling is judged against, so it survives.
    EXPECT_EQ(domain.peak_live_bytes(), 3 * Bytes(k4k) + Bytes(k1080));
}

TEST(VideoConversionMemoryDomain, HandsTheSameRoomOutOnlyOnceUnderContention)
{
    // Separate renderer instances run on separate threads, so this is the one
    // case that exercises the domain the way production does. It is a
    // contention test: what it proves deterministically is that the totals
    // never tear and that exactly one asker can ever see the room as free.
    constexpr int               kThreads = 8;
    VideoConversionMemoryDomain domain(Bytes(k4k));

    std::vector<std::unique_ptr<VideoConversionBudget>> budgets;
    budgets.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        budgets.push_back(std::make_unique<VideoConversionBudget>(8 * Bytes(k4k)));
        budgets.back()->AttachDomain(&domain);
    }
    ASSERT_EQ(domain.budget_count(), static_cast<std::size_t>(kThreads));

    std::atomic<int>         ready { 0 };
    std::atomic<bool>        go { false };
    std::vector<char>        fitted(kThreads, 0);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        threads.emplace_back([&, i] {
            std::vector<void*> evicted;
            ready.fetch_add(1);
            while (! go.load()) std::this_thread::yield();
            const auto reservation = budgets[static_cast<std::size_t>(i)]->ReserveAllocation(
                k4k, Bytes(k4k), evicted);
            fitted[static_cast<std::size_t>(i)] =
                (reservation.granted && ! reservation.over_ceiling) ? 1 : 0;
        });
    }
    while (ready.load() < kThreads) std::this_thread::yield();
    go.store(true);
    for (auto& thread : threads) thread.join();

    // Every frame was granted, because capacity never drops one...
    EXPECT_EQ(domain.reserved_bytes(), static_cast<std::uint64_t>(kThreads) * Bytes(k4k));
    EXPECT_EQ(domain.live_bytes(), 0u);
    // ...and the one destination's worth of room was handed out exactly once.
    // More than one would mean two pools were told the same bytes were free.
    EXPECT_EQ(std::count(fitted.begin(), fitted.end(), 1), 1);
    // Everyone else was told to shed.
    EXPECT_EQ(domain.shed_requests(), static_cast<std::uint64_t>(kThreads) - 1);
}
