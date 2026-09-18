// Budgeting for video conversion destinations. The budget stores opaque
// handles and byte counts, so every rule below is exercised without a Metal
// device, a decoder or a surface.
#include "Video/VideoConversionBudget.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <limits>
#include <vector>

namespace {
using wallpaper::video::VideoConversionBudget;
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
    EXPECT_EQ(budget.pooled_count(), 1u);
    EXPECT_EQ(budget.pooled_bytes(), Bytes(key));
    EXPECT_EQ(budget.peak_pooled_bytes(), Bytes(key));
    EXPECT_EQ(budget.Take(key), Handle(1));
    EXPECT_EQ(budget.hits(), 1u);
    EXPECT_EQ(budget.pooled_bytes(), 0u);

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
    EXPECT_EQ(budget.pooled_count(), 1u);
    EXPECT_EQ(budget.pooled_bytes(), Bytes(k8kWide));
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
    EXPECT_EQ(budget.pooled_count(), 1u);
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
    EXPECT_EQ(budget.pooled_count(), 1u);
    EXPECT_EQ(budget.Take(k4k), Handle(1));

    // A destination the budget cannot measure is one it cannot show to fit.
    const auto unmeasured = budget.Admit({ k4k, 0, Handle(3) }, evicted);
    EXPECT_FALSE(unmeasured.accepted);
    EXPECT_EQ(unmeasured.refusal, VideoConversionRefusal::SlotExceedsCeiling);
    EXPECT_EQ(budget.pooled_count(), 0u);
}

TEST(VideoConversionBudget, StopsPoolingASizeAnAllocationAlreadyFailedAt)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k4k, 1), evicted).accepted);

    std::vector<void*> reclaimed;
    budget.ReportAllocationFailure(Bytes(k4k), reclaimed);
    EXPECT_EQ(reclaimed, std::vector<void*> { Handle(1) });
    EXPECT_EQ(budget.pooled_count(), 0u);
    EXPECT_EQ(budget.unsatisfiable_bytes(), Bytes(k4k));

    const auto same_size = budget.Admit(Slot(k4k, 2), evicted);
    EXPECT_FALSE(same_size.accepted);
    EXPECT_EQ(same_size.refusal, VideoConversionRefusal::AllocationUnsatisfiable);
    const auto larger = budget.Admit(Slot(k8k, 3), evicted);
    EXPECT_FALSE(larger.accepted);
    EXPECT_EQ(larger.refusal, VideoConversionRefusal::AllocationUnsatisfiable);
    // Refused once each, never a retry loop, and each refusal is counted.
    EXPECT_EQ(budget.refusals(VideoConversionRefusal::AllocationUnsatisfiable), 2u);
    EXPECT_EQ(budget.pooled_count(), 0u);

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
    EXPECT_EQ(budget.pooled_bytes(), 0u);

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
    EXPECT_EQ(budget.pooled_count(), 0u);
    EXPECT_EQ(budget.Take(k4k), nullptr);

    EXPECT_TRUE(budget.ReportGpuComplete(loaned));
    EXPECT_EQ(budget.loan_count(), 0u);
    ASSERT_TRUE(budget.Admit({ k4k, Bytes(k4k), loaned }, evicted).accepted);

    const auto again = budget.Admit({ k4k, Bytes(k4k), loaned }, evicted);
    EXPECT_FALSE(again.accepted);
    EXPECT_EQ(again.refusal, VideoConversionRefusal::AlreadyPooled);
    EXPECT_EQ(budget.pooled_count(), 1u);

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
    // The handle is gone, but a later destination at the same address is not
    // presumed to still be in flight.
    EXPECT_TRUE(budget.Admit({ k4k, Bytes(k4k), loaned }, evicted).accepted);
}

TEST(VideoConversionBudget, GivesBackShapesAResolutionChangeNoLongerRequests)
{
    VideoConversionBudget budget;
    std::vector<void*>    evicted;
    ASSERT_TRUE(budget.Admit(Slot(k720, 1), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k1080, 2), evicted).accepted);
    ASSERT_TRUE(budget.Admit(Slot(k4k, 3), evicted).accepted);
    ASSERT_EQ(budget.pooled_count(), 3u);
    const std::uint64_t peak = Bytes(k720) + Bytes(k1080) + Bytes(k4k);
    ASSERT_EQ(budget.pooled_bytes(), peak);

    std::vector<void*> reclaimed;
    budget.DropOtherKeys(k1080, reclaimed);
    std::sort(reclaimed.begin(), reclaimed.end());
    std::vector<void*> expected { Handle(1), Handle(3) };
    std::sort(expected.begin(), expected.end());
    EXPECT_EQ(reclaimed, expected);
    EXPECT_EQ(budget.pooled_count(), 1u);
    EXPECT_EQ(budget.pooled_bytes(), Bytes(k1080));
    EXPECT_EQ(budget.Take(k720), nullptr);
    EXPECT_EQ(budget.Take(k4k), nullptr);

    reclaimed.clear();
    budget.Drain(reclaimed);
    EXPECT_EQ(reclaimed, std::vector<void*> { Handle(2) });
    EXPECT_EQ(budget.pooled_count(), 0u);
    EXPECT_EQ(budget.pooled_bytes(), 0u);
    // The high-water mark is the figure a ceiling is judged against, so it
    // survives the reclamation that follows a close or a switch.
    EXPECT_EQ(budget.peak_pooled_bytes(), peak);
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
