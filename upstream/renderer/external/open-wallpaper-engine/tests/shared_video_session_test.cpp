// What several display surfaces are allowed to share when they show the same
// video, and what they must keep to themselves.
//
// Sharing is only ever offered for media that is genuinely the same file, and
// only while the consumers want the same timeline. Everything a surface owns -
// its pause, the frame it is currently showing, its claim on the decoder - has
// to stay independent, because a hidden or paused display must not stop another
// display's playback and must not free the frame that display is still using.
//
// The registry is driven through its real entry point against media the test
// encodes for itself; nothing here stands in a fake source.

#include "Image.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Video/FfmpegVideoTextureSource.hpp"
#include "Video/SharedVideoSession.hpp"
#include "Video/VideoTextureSource.hpp"
#include "synthetic_video.hpp"

#include <gtest/gtest.h>

#include <unistd.h>

#include <atomic>
#include <chrono>
#include <filesystem>
#include <memory>
#include <thread>
#include <string>

namespace wallpaper::video
{
namespace
{

using testing_media::WriteSyntheticVideo;

/// Drives a consumer forward until the decoder promotes a different frame.
///
/// Real elapsed time matters: the decoder fills its queue on its own thread, so
/// a tight loop that only moves the requested timestamp asks for frames that
/// have not been decoded yet and observes nothing. Every step therefore waits
/// about one frame period.
bool AdvanceUntilFrameChanges(const std::shared_ptr<VideoTextureSource>& source,
                              std::uint64_t                              from_generation,
                              double                                     start_seconds = 0.0) {
    std::string error;
    for (int step = 1; step <= 120; ++step) {
        const double seconds = start_seconds + step * (1.0 / 30.0);
        if (! source->syncPlayback(VideoPlaybackState { false, 1.0f, seconds }, &error)) return false;
        if (source->refreshFrame(&error) &&
            source->currentFrame().generation != from_generation) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

class SharedVideoSessionTest : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_FALSE(testing_media::SharedGop().packets.empty())
            << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
        static std::atomic<uint64_t> serial { 0 };
        dir = std::filesystem::temp_directory_path() /
              ("owe-shared-video-" + std::to_string(::getpid()) + "-" +
               std::to_string(serial.fetch_add(1)));
        std::filesystem::create_directories(dir);
        SetSharedVideoDecodeEnabled(true);
    }

    void TearDown() override {
        SetSharedVideoDecodeEnabled(false);
        ReleaseIdleVideoSessions();
        std::error_code ec;
        std::filesystem::remove_all(dir, ec);
    }

    /// A project image pointing at a real file, which is the shape the registry
    /// can identify and therefore the only shape it will share.
    std::shared_ptr<Image> MakeFileImage(const std::string& name, const std::string& salt) {
        const auto media = dir / name;
        if (! WriteSyntheticVideo(media, 1, salt)) return nullptr;
        std::string error;
        return CreateVideoProjectImage(dir, name, &error);
    }

    std::filesystem::path dir;
};

TEST_F(SharedVideoSessionTest, EquivalentConsumersShareOneDecoder) {
    auto image = MakeFileImage("media.mp4", "shared");
    ASSERT_NE(image, nullptr);

    std::string error;
    auto        first = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(first, nullptr) << error;
    auto second = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(second, nullptr) << error;

    EXPECT_EQ(SharedVideoDecodeSessionCount(), 1u);
    EXPECT_EQ(SharedVideoDecodeConsumerCount(), 2u);

    ASSERT_TRUE(first->prime(&error)) << error;
    // One decoder instance, so both consumers report the same source identity.
    // A roll-up that de-duplicates on it therefore counts one decode, not two.
    EXPECT_NE(first->sourceStats().instance_id, 0u);
    EXPECT_EQ(first->sourceStats().instance_id, second->sourceStats().instance_id);
}

TEST_F(SharedVideoSessionTest, SameFileNameInDifferentProjectsIsNotShared) {
    // The project-relative name is identical; the files are not. Sharing on the
    // name alone would show one wallpaper's video on the other's display.
    auto first_image = MakeFileImage("video.mp4", "first");
    ASSERT_NE(first_image, nullptr);

    const auto other_dir = dir / "other";
    std::filesystem::create_directories(other_dir);
    ASSERT_TRUE(WriteSyntheticVideo(other_dir / "video.mp4", 2, "second"));
    std::string error;
    auto        second_image = CreateVideoProjectImage(other_dir, "video.mp4", &error);
    ASSERT_NE(second_image, nullptr) << error;

    EXPECT_EQ(first_image->key, second_image->key);
    EXPECT_NE(first_image->videoFilePath, second_image->videoFilePath);

    auto first = AcquireVideoTextureSource(*first_image, &error);
    ASSERT_NE(first, nullptr) << error;
    auto second = AcquireVideoTextureSource(*second_image, &error);
    ASSERT_NE(second, nullptr) << error;

    EXPECT_EQ(SharedVideoDecodeSessionCount(), 2u);
    ASSERT_TRUE(first->prime(&error)) << error;
    ASSERT_TRUE(second->prime(&error)) << error;
    EXPECT_NE(first->sourceStats().instance_id, second->sourceStats().instance_id);
}

TEST_F(SharedVideoSessionTest, PausingOneSurfaceLeavesTheOtherPlaying) {
    auto image = MakeFileImage("media.mp4", "pause");
    ASSERT_NE(image, nullptr);

    std::string error;
    auto        playing = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(playing, nullptr) << error;
    auto paused = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(paused, nullptr) << error;
    ASSERT_TRUE(playing->prime(&error)) << error;

    const VideoPlaybackState running { false, 1.0f, 0.0 };
    ASSERT_TRUE(playing->syncPlayback(running, &error)) << error;
    ASSERT_TRUE(playing->refreshFrame(&error)) << error;
    ASSERT_TRUE(paused->syncPlayback(running, &error)) << error;
    ASSERT_TRUE(paused->refreshFrame(&error)) << error;

    const auto held_while_playing = paused->currentFrame();
    ASSERT_TRUE(held_while_playing.valid());

    // One surface pauses. The other keeps asking for frames and must still get
    // new ones: the shared decoder is only idle when every consumer is.
    ASSERT_TRUE(paused->syncPlayback(VideoPlaybackState { true, 1.0f, 0.0 }, &error)) << error;

    EXPECT_TRUE(AdvanceUntilFrameChanges(playing, held_while_playing.generation))
        << "a paused surface stopped the surface that is still playing";

    // The paused surface keeps exactly the frame it had. Advancing it would
    // make its pause depend on another display, and releasing it would free a
    // buffer it is still presenting.
    ASSERT_TRUE(paused->refreshFrame(&error));
    EXPECT_EQ(paused->currentFrame().generation, held_while_playing.generation);
    EXPECT_EQ(paused->currentFrame().pixel_buffer, held_while_playing.pixel_buffer);
}

TEST_F(SharedVideoSessionTest, AFrameStaysValidAfterTheDecoderMovesOn) {
    auto image = MakeFileImage("media.mp4", "retain");
    ASSERT_NE(image, nullptr);

    std::string error;
    auto        holder = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(holder, nullptr) << error;
    auto driver = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(driver, nullptr) << error;
    ASSERT_TRUE(holder->prime(&error)) << error;

    ASSERT_TRUE(holder->syncPlayback(VideoPlaybackState { false, 1.0f, 0.0 }, &error)) << error;
    ASSERT_TRUE(holder->refreshFrame(&error)) << error;
    const auto held = holder->currentFrame();
    ASSERT_TRUE(held.valid());

    // The other consumer drives the decoder past that frame. Asserting that it
    // really moved is the point: if the decoder never promoted anything, the
    // retention below would hold trivially and prove nothing.
    ASSERT_TRUE(driver->syncPlayback(VideoPlaybackState { false, 1.0f, 0.0 }, &error)) << error;
    ASSERT_TRUE(driver->refreshFrame(&error)) << error;
    ASSERT_TRUE(AdvanceUntilFrameChanges(driver, held.generation))
        << "the decoder never moved past the held frame, so retention is untested";
    ASSERT_NE(driver->currentFrame().pixel_buffer, held.pixel_buffer);

    EXPECT_EQ(holder->currentFrame().pixel_buffer, held.pixel_buffer);
    VideoTextureFrame retained {};
    EXPECT_TRUE(holder->retainCurrentFrame(&retained));
    EXPECT_EQ(retained.pixel_buffer, held.pixel_buffer);
    ReleaseAppleVideoFrame(&retained);
}

TEST_F(SharedVideoSessionTest, AnIncompatibleRateSplitsOntoItsOwnDecoder) {
    auto image = MakeFileImage("media.mp4", "rate");
    ASSERT_NE(image, nullptr);

    std::string error;
    auto        normal = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(normal, nullptr) << error;
    auto faster = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(faster, nullptr) << error;
    ASSERT_TRUE(normal->prime(&error)) << error;

    ASSERT_TRUE(normal->syncPlayback(VideoPlaybackState { false, 1.0f, 0.0 }, &error)) << error;
    EXPECT_EQ(SharedVideoDecodeSessionCount(), 1u);

    // A second speed cannot be served by one timeline, so this consumer gets
    // its own decoder rather than being forced onto someone else's rate.
    ASSERT_TRUE(faster->syncPlayback(VideoPlaybackState { false, 2.0f, 0.0 }, &error)) << error;
    EXPECT_EQ(SharedVideoDecodeSessionCount(), 2u);
    EXPECT_EQ(SharedVideoDecodeConsumerCount(), 2u);
    ASSERT_TRUE(faster->prime(&error)) << error;
    EXPECT_NE(normal->sourceStats().instance_id, faster->sourceStats().instance_id);
}

TEST_F(SharedVideoSessionTest, TheDecoderOutlivesOneConsumerAndNotBoth) {
    auto image = MakeFileImage("media.mp4", "lifetime");
    ASSERT_NE(image, nullptr);

    std::string error;
    auto        first = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(first, nullptr) << error;
    auto second = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(second, nullptr) << error;
    ASSERT_TRUE(first->prime(&error)) << error;
    const auto instance = first->sourceStats().instance_id;

    // One surface goes away. The decoder must not, because the other is still
    // consuming it.
    second.reset();
    EXPECT_EQ(SharedVideoDecodeSessionCount(), 1u);
    EXPECT_EQ(SharedVideoDecodeConsumerCount(), 1u);
    ASSERT_TRUE(first->syncPlayback(VideoPlaybackState { false, 1.0f, 0.1 }, &error)) << error;
    EXPECT_EQ(first->sourceStats().instance_id, instance);

    // The last surface goes away, and with it the decoder: nothing is left to
    // consume what it would produce.
    first.reset();
    EXPECT_EQ(SharedVideoDecodeSessionCount(), 0u);
    EXPECT_EQ(SharedVideoDecodeConsumerCount(), 0u);
}

TEST_F(SharedVideoSessionTest, SharingOffGivesEveryConsumerItsOwnDecoder) {
    SetSharedVideoDecodeEnabled(false);
    auto image = MakeFileImage("media.mp4", "disabled");
    ASSERT_NE(image, nullptr);

    std::string error;
    auto        first = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(first, nullptr) << error;
    auto second = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(second, nullptr) << error;
    ASSERT_TRUE(first->prime(&error)) << error;
    ASSERT_TRUE(second->prime(&error)) << error;

    EXPECT_NE(first->sourceStats().instance_id, second->sourceStats().instance_id);
    // Nothing is registered either, so the reported counts describe real
    // sharing rather than every decoder in the process.
    EXPECT_EQ(SharedVideoDecodeSessionCount(), 0u);
}

TEST_F(SharedVideoSessionTest, InPackageMediaIsNeverShared) {
    // An in-memory payload has no path to identify it and could not be reopened
    // for a later split, so it stays private whatever the setting says.
    auto image                    = std::make_shared<Image>();
    image->key                    = "packaged.mp4";
    image->header.isVideo         = true;
    image->header.width           = 64;
    image->header.height          = 64;

    std::string error;
    auto        source = AcquireVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    EXPECT_EQ(SharedVideoDecodeSessionCount(), 0u);
}

} // namespace
} // namespace wallpaper::video
