#include "Vulkan/TextureCache.hpp"

#include <gtest/gtest.h>

namespace wallpaper
{
namespace
{

TEST(VideoTextureSubmissionSmoke, MergesGlobalAndLayerVideoPlaybackState) {
    video::VideoPlaybackState global_state {
        .paused                = true,
        .rate                  = 2.0f,
        .scene_elapsed_seconds = 100.0,
    };
    video::VideoPlaybackState layer_state {
        .paused                = false,
        .rate                  = 0.25f,
        .scene_elapsed_seconds = 4.5,
    };

    const auto merged =
        vulkan::ResolveEffectiveVideoPlaybackState(global_state, layer_state);

    EXPECT_TRUE(merged.paused);
    EXPECT_FLOAT_EQ(merged.rate, 0.5f);
    EXPECT_DOUBLE_EQ(merged.scene_elapsed_seconds, 4.5);
}

TEST(VideoTextureSubmissionSmoke, ClampsNegativeVideoPlaybackRates) {
    video::VideoPlaybackState global_state {
        .paused = false,
        .rate   = -2.0f,
    };
    video::VideoPlaybackState layer_state {
        .paused = true,
        .rate   = 3.0f,
    };

    const auto merged =
        vulkan::ResolveEffectiveVideoPlaybackState(global_state, layer_state);

    EXPECT_TRUE(merged.paused);
    EXPECT_FLOAT_EQ(merged.rate, 0.0f);
}

TEST(VideoTextureSubmissionSmoke, AllowsNewImportWhenSubmissionSlotIsAvailable) {
    vulkan::VideoImportSubmissionPlan plan {
        .pending_submissions = 1,
        .available_slots     = 2,
        .must_destroy_resource = false,
    };

    EXPECT_FALSE(vulkan::VideoImportSubmissionNeedsFenceWait(plan));
}

TEST(VideoTextureSubmissionSmoke, WaitsBeforeReusingAllBusySubmissionSlots) {
    vulkan::VideoImportSubmissionPlan plan {
        .pending_submissions = 2,
        .available_slots     = 2,
        .must_destroy_resource = false,
    };

    EXPECT_TRUE(vulkan::VideoImportSubmissionNeedsFenceWait(plan));
}

TEST(VideoTextureSubmissionSmoke, WaitsBeforeDestroyingImportedFrameResources) {
    vulkan::VideoImportSubmissionPlan plan {
        .pending_submissions = 1,
        .available_slots     = 2,
        .must_destroy_resource = true,
    };

    EXPECT_TRUE(vulkan::VideoImportSubmissionNeedsFenceWait(plan));
}

} // namespace
} // namespace wallpaper
