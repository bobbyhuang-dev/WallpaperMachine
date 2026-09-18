#include "VulkanRender/CopyElision.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <vector>

using wallpaper::vulkan::CopyElision;
using wallpaper::vulkan::DynamicReason;
using wallpaper::vulkan::ElisionPassDesc;
using wallpaper::vulkan::PlanCopyElision;
using wallpaper::vulkan::StaticPassDesc;
using wallpaper::vulkan::StaticPassSample;
using wallpaper::vulkan::StaticSubgraphCache;

namespace
{

StaticPassDesc Pass(std::string target, std::vector<std::string> inputs = {},
                    uint32_t reasons = 0)
{
    StaticPassDesc desc;
    desc.target          = std::move(target);
    desc.inputs          = std::move(inputs);
    desc.dynamic_reasons = reasons;
    return desc;
}

/// Pins every target the analysis found cacheable, as the renderer does when
/// the memory budget allows it.
void PinAllCacheable(StaticSubgraphCache& cache, uint64_t bytes = 1024)
{
    for (std::size_t i = 0; i < cache.TargetCount(); ++i) {
        if (cache.TargetCacheable(i)) cache.SetTargetPinned(i, true, bytes);
    }
}

std::vector<uint8_t> RunFrame(StaticSubgraphCache& cache, std::vector<StaticPassSample> samples)
{
    std::vector<uint8_t> skip(samples.size(), 0);
    cache.Plan(samples, skip);
    return skip;
}

ElisionPassDesc Custom(std::string writes, std::vector<std::string> reads = {})
{
    ElisionPassDesc desc;
    desc.kind   = ElisionPassDesc::Kind::Custom;
    desc.writes = std::move(writes);
    desc.reads  = std::move(reads);
    return desc;
}

ElisionPassDesc Copy(std::string dst, std::string src, bool compatible = true,
                     bool generates_mipmaps = false)
{
    ElisionPassDesc desc;
    desc.kind                   = ElisionPassDesc::Kind::Copy;
    desc.writes                 = std::move(dst);
    desc.reads                  = { std::move(src) };
    desc.copy_compatible        = compatible;
    desc.copy_generates_mipmaps = generates_mipmaps;
    return desc;
}

ElisionPassDesc Present(std::string reads)
{
    ElisionPassDesc desc;
    desc.kind  = ElisionPassDesc::Kind::Present;
    desc.reads = { std::move(reads) };
    return desc;
}

constexpr StaticPassSample kStable { .hash = 7, .visible = true };

} // namespace

TEST(StaticSubgraphCache, FirstFrameAlwaysRenders)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);

    const auto first = RunFrame(cache, { kStable });
    EXPECT_EQ(first[0], 0) << "nothing has been drawn yet, so there is nothing to reuse";

    const auto second = RunFrame(cache, { kStable });
    EXPECT_EQ(second[0], 1);
}

TEST(StaticSubgraphCache, AChangedInputReRendersItsTarget)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    const StaticPassSample moved { .hash = 99, .visible = true };
    EXPECT_EQ(RunFrame(cache, { moved })[0], 0);
    EXPECT_EQ(RunFrame(cache, { moved })[0], 1) << "the new state becomes the reusable one";
}

TEST(StaticSubgraphCache, VisibilityChangeReRendersEvenWhenTheHashIsStable)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    const StaticPassSample hidden { .hash = kStable.hash, .visible = false };
    EXPECT_EQ(RunFrame(cache, { hidden })[0], 0);
}

TEST(StaticSubgraphCache, ADynamicUniformKeepsItsWholeTargetOutOfTheCache)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_default"),
        Pass("_rt_default", {}, static_cast<uint32_t>(DynamicReason::TimeUniform)),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable });
    const auto skip = RunFrame(cache, { kStable, kStable });
    EXPECT_EQ(skip[0], 0) << "all writers of one target share its fate: the batch may clear";
    EXPECT_EQ(skip[1], 0);
}

TEST(StaticSubgraphCache, DynamicInputsPropagateDownstream)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a", {}, static_cast<uint32_t>(DynamicReason::VideoInput)),
        Pass("_rt_b", { "_rt_a" }),
        Pass("_rt_default", { "_rt_b" }),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable, kStable });
    const auto skip = RunFrame(cache, { kStable, kStable, kStable });
    EXPECT_EQ(skip[0], 0);
    EXPECT_EQ(skip[1], 0) << "a target fed by a video frame cannot be stable";
    EXPECT_EQ(skip[2], 0);
}

TEST(StaticSubgraphCache, AnUnchangedChainIsReusedEndToEnd)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a"),
        Pass("_rt_b", { "_rt_a" }),
        Pass("_rt_default", { "_rt_b" }),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable, kStable });
    const auto skip = RunFrame(cache, { kStable, kStable, kStable });
    EXPECT_EQ(skip[0], 1);
    EXPECT_EQ(skip[1], 1);
    EXPECT_EQ(skip[2], 1);
}

TEST(StaticSubgraphCache, AChangeAtTheHeadInvalidatesEverythingBelowIt)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a"),
        Pass("_rt_b", { "_rt_a" }),
        Pass("_rt_default", { "_rt_b" }),
    });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable, kStable, kStable });
    ASSERT_EQ(RunFrame(cache, { kStable, kStable, kStable })[2], 1);

    const StaticPassSample moved { .hash = 4242, .visible = true };
    const auto             skip = RunFrame(cache, { moved, kStable, kStable });
    EXPECT_EQ(skip[0], 0);
    EXPECT_EQ(skip[1], 0) << "its input was redrawn, so its own pixels are stale";
    EXPECT_EQ(skip[2], 0);
}

TEST(StaticSubgraphCache, AnUnpinnedTargetIsNeverReused)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    // Deliberately not pinned: the render-target pool may hand this image to
    // another key, so last frame's pixels are not guaranteed to still be there.
    RunFrame(cache, { kStable });
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 0);
}

TEST(StaticSubgraphCache, UnpinningDropsTheRetainedResult)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    cache.SetTargetPinned(0, false, 0);
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 0);
    EXPECT_EQ(cache.stats().pinned_bytes, 0u);
}

TEST(StaticSubgraphCache, FeedbackIsNeverCached)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_a", { "_rt_a" }) });
    ASSERT_EQ(cache.TargetCount(), 1u);
    EXPECT_FALSE(cache.TargetCacheable(0));
    EXPECT_TRUE(cache.TargetDynamicReasons(0) & DynamicReason::Feedback);
}

TEST(StaticSubgraphCache, ADependencyCycleLosesCacheabilityRatherThanReadingStaleInputs)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a", { "_rt_b" }),
        Pass("_rt_b", { "_rt_a" }),
    });
    EXPECT_FALSE(cache.TargetCacheable(0));
    EXPECT_FALSE(cache.TargetCacheable(1));
}

TEST(StaticSubgraphCache, InvalidateAllForcesOneFullRedraw)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector { Pass("_rt_default") });
    PinAllCacheable(cache);
    RunFrame(cache, { kStable });
    ASSERT_EQ(RunFrame(cache, { kStable })[0], 1);

    cache.InvalidateAll();
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 0);
    EXPECT_EQ(RunFrame(cache, { kStable })[0], 1);
}

TEST(StaticSubgraphCache, StatsCountEveryPassExactlyOnce)
{
    StaticSubgraphCache cache;
    cache.Compile(std::vector {
        Pass("_rt_a"),
        Pass("_rt_b", {}, static_cast<uint32_t>(DynamicReason::TimeUniform)),
    });
    PinAllCacheable(cache);

    RunFrame(cache, { kStable, kStable });
    RunFrame(cache, { kStable, kStable });
    const auto& stats = cache.stats();
    EXPECT_EQ(stats.executed_passes + stats.skipped_passes, 4u);
    EXPECT_EQ(stats.skipped_passes, 1u) << "only the static target is reused, on the second frame";
}

TEST(CopyElisionPlan, ACopyNobodyReadsIsRemoved)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_unused", "_rt_a"),
        Present("_rt_a"),
    };
    const auto plan = PlanCopyElision(passes);
    EXPECT_EQ(plan[1], CopyElision::Dead);
}

TEST(CopyElisionPlan, ACopyOfAnImageNothingRewritesBecomesAnAlias)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_snapshot", "_rt_a"),
        Custom("_rt_default", { "_rt_snapshot" }),
        Present("_rt_default"),
    };
    const auto plan = PlanCopyElision(passes);
    EXPECT_EQ(plan[1], CopyElision::Alias);
}

TEST(CopyElisionPlan, AFeedbackCopyIsKept)
{
    // The source is written again after the copy, which is the entire reason
    // the copy exists: it holds the previous contents for the pass below.
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_prev", "_rt_a"),
        Custom("_rt_a", { "_rt_prev" }),
        Present("_rt_a"),
    };
    const auto plan = PlanCopyElision(passes);
    EXPECT_EQ(plan[1], CopyElision::None);
}

TEST(CopyElisionPlan, AnIncompatibleCopyIsKept)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_b", "_rt_a", /*compatible=*/false),
        Custom("_rt_default", { "_rt_b" }),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[1], CopyElision::None);
}

TEST(CopyElisionPlan, ACopyThatBuildsAMipChainIsKept)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_mipped", "_rt_a", /*compatible=*/true, /*generates_mipmaps=*/true),
        Custom("_rt_default", { "_rt_mipped" }),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[1], CopyElision::None);
}

TEST(CopyElisionPlan, ACopyWhoseDestinationIsWrittenElsewhereIsKept)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_b", "_rt_a"),
        Custom("_rt_b"),
        Custom("_rt_default", { "_rt_b" }),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[1], CopyElision::None);
}

TEST(CopyElisionPlan, ADestinationReadBeforeTheCopyIsKept)
{
    // The earlier read consumes what the target held before this frame's copy,
    // which aliasing would replace with the source's current contents.
    const std::vector passes {
        Custom("_rt_default", { "_rt_b" }),
        Custom("_rt_a"),
        Copy("_rt_b", "_rt_a"),
        Present("_rt_default"),
    };
    EXPECT_EQ(PlanCopyElision(passes)[2], CopyElision::None);
}

TEST(CopyElisionPlan, ThePresentedTargetIsNotTreatedAsUnread)
{
    const std::vector passes {
        Custom("_rt_a"),
        Copy("_rt_default", "_rt_a"),
        Present("_rt_default"),
    };
    EXPECT_NE(PlanCopyElision(passes)[1], CopyElision::Dead)
        << "the final blit reads it, so its result has a consumer";
}
