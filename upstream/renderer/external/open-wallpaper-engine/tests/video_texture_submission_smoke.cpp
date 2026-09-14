#include "Vulkan/TextureCache.hpp"

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace wallpaper
{
namespace
{

std::string ReadTextFile(const std::filesystem::path& path) {
    std::ifstream input(path);
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
}

std::string ExtractFunctionBody(std::string_view source, std::string_view signature) {
    const std::size_t signature_offset = source.find(signature);
    if (signature_offset == std::string_view::npos) return {};

    const std::size_t body_start = source.find('{', signature_offset);
    if (body_start == std::string_view::npos) return {};

    std::size_t depth = 0;
    for (std::size_t offset = body_start; offset < source.size(); ++offset) {
        if (source[offset] == '{') {
            ++depth;
        } else if (source[offset] == '}') {
            --depth;
            if (depth == 0) {
                return std::string(source.substr(body_start, offset - body_start + 1));
            }
        }
    }
    return {};
}

std::string ExtractBlockAfter(std::string_view source, std::string_view marker) {
    const std::size_t marker_offset = source.find(marker);
    if (marker_offset == std::string_view::npos) return {};

    const std::size_t body_start = source.find('{', marker_offset);
    if (body_start == std::string_view::npos) return {};

    std::size_t depth = 0;
    for (std::size_t offset = body_start; offset < source.size(); ++offset) {
        if (source[offset] == '{') {
            ++depth;
        } else if (source[offset] == '}') {
            --depth;
            if (depth == 0) {
                return std::string(source.substr(body_start, offset - body_start + 1));
            }
        }
    }
    return {};
}

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

TEST(VideoTextureSubmissionSmoke, ImportStatsDefaultToZero) {
    vulkan::VideoTextureSubmissionStats stats;

    EXPECT_EQ(stats.update_calls, 0u);
    EXPECT_EQ(stats.cache_hits, 0u);
    EXPECT_EQ(stats.new_imports, 0u);
    EXPECT_EQ(stats.fence_waits, 0u);
    EXPECT_EQ(stats.evictions, 0u);
    EXPECT_EQ(stats.import_submission_slots, 0u);
    EXPECT_EQ(stats.command_buffer_allocations, 0u);
    EXPECT_EQ(stats.fence_allocations, 0u);
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

TEST(VideoTextureSubmissionSmoke, PerFrameUpdatePathDoesNotUseDeviceWaitIdle) {
    const std::filesystem::path source_path =
        std::filesystem::path(__FILE__).parent_path().parent_path() / "src" / "Vulkan" /
        "TextureCache.cpp";
    const std::string source = ReadTextFile(source_path);
    ASSERT_FALSE(source.empty()) << source_path;

    const std::string body = ExtractFunctionBody(
        source, "bool TextureCache::UpdateVideoFrame(std::string_view                 key,");
    ASSERT_FALSE(body.empty());

    EXPECT_EQ(body.find("WaitIdle("), std::string::npos);
    EXPECT_EQ(body.find("DeviceWaitIdle"), std::string::npos);
}

TEST(VideoTextureSubmissionSmoke, RuntimeImageReplacementPathDoesNotUseDeviceWaitIdle) {
    const std::filesystem::path source_path =
        std::filesystem::path(__FILE__).parent_path().parent_path() / "src" / "Vulkan" /
        "TextureCache.cpp";
    const std::string source = ReadTextFile(source_path);
    ASSERT_FALSE(source.empty()) << source_path;

    const std::string body = ExtractFunctionBody(
        source,
        "ImageSlotsRef TextureCache::ReplaceTex(Image& image, std::string_view previous_key)");
    ASSERT_FALSE(body.empty());

    EXPECT_EQ(body.find("WaitIdle("), std::string::npos);
    EXPECT_EQ(body.find("DeviceWaitIdle"), std::string::npos);
}

TEST(VideoTextureSubmissionSmoke, RuntimeImageReplacementUsesDeferredUploadPath) {
    const std::filesystem::path source_path =
        std::filesystem::path(__FILE__).parent_path().parent_path() / "src" / "Vulkan" /
        "TextureCache.cpp";
    const std::string source = ReadTextFile(source_path);
    ASSERT_FALSE(source.empty()) << source_path;

    const std::string body = ExtractFunctionBody(
        source,
        "ImageSlotsRef TextureCache::ReplaceTex(Image& image, std::string_view previous_key)");
    ASSERT_FALSE(body.empty());

    EXPECT_NE(body.find("TextureUploadSynchronization::Deferred"), std::string::npos);
    EXPECT_EQ(body.find("CreateTex(image)"), std::string::npos);
}

TEST(VideoTextureSubmissionSmoke, VideoRefreshReusesCurrentFrameBeforeWaitingForExactFrame) {
    const std::filesystem::path source_path =
        std::filesystem::path(__FILE__).parent_path().parent_path() / "src" / "Video" /
        "FfmpegVideoTextureSource.cpp";
    const std::string source = ReadTextFile(source_path);
    ASSERT_FALSE(source.empty()) << source_path;

    const std::string body = ExtractFunctionBody(source, "bool refreshFrame(std::string* error)");
    ASSERT_FALSE(body.empty());

    const std::size_t reuse_current_frame = body.find(
        "if (m_display_frame_ready) {\n"
        "            m_condition.notify_all();\n"
        "            return true;\n"
        "        }");
    const std::size_t wait_deadline = body.find("const auto deadline");
    ASSERT_NE(reuse_current_frame, std::string::npos);
    ASSERT_NE(wait_deadline, std::string::npos);

    EXPECT_LT(reuse_current_frame, wait_deadline);
}

TEST(VideoTextureSubmissionSmoke, DeferredTextureUploadPathDoesNotUseDeviceWaitIdle) {
    const std::filesystem::path source_path =
        std::filesystem::path(__FILE__).parent_path().parent_path() / "src" / "Vulkan" /
        "TextureCache.cpp";
    const std::string source = ReadTextFile(source_path);
    ASSERT_FALSE(source.empty()) << source_path;

    const std::string body =
        ExtractFunctionBody(source, "ImageSlotsRef TextureCache::CreateTex(Image& image,");
    ASSERT_FALSE(body.empty());

    const std::size_t deferred_branch = body.find("TextureUploadSynchronization::Deferred");
    ASSERT_NE(deferred_branch, std::string::npos);

    const std::string deferred_body =
        ExtractBlockAfter(body, "synchronization == TextureUploadSynchronization::Deferred");
    ASSERT_FALSE(deferred_body.empty());
    EXPECT_EQ(deferred_body.find("WaitIdle("), std::string::npos);
    EXPECT_EQ(deferred_body.find("DeviceWaitIdle"), std::string::npos);
}

} // namespace
} // namespace wallpaper
