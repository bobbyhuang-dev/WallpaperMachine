// What a pure-video wallpaper is allowed to do with the user's media file.
//
// A plain local file is decode input, not a payload: it must be opened where it
// lies, never read into the process and never copied into the shared cache.
// Media that only exists inside a package still has to be extracted, and that
// extraction must be published whole so a second opener cannot observe a
// half-written file. Everything below drives the production construction path -
// `CreateVideoProjectImage` followed by `CreateVideoTextureSource` - over media
// the test encodes for itself.

#include "Image.hpp"
#include "Video/FfmpegVideoTextureSource.hpp"
#include "Video/VideoTextureSource.hpp"

#include <gtest/gtest.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>
}

#include <mach/mach.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace wallpaper::video
{
namespace
{

constexpr int kFrameWidth  = 640;
constexpr int kFrameHeight = 360;
constexpr int kGopFrames   = 30;

/// One encoded group of pictures, reused by every test in the binary.
///
/// Encoding is the slow part; muxing the same packets `repeats` times is not,
/// so a multi-megabyte file costs no more encoder time than a small one.
struct EncodedGop {
    std::vector<AVPacket*> packets;
    AVCodecParameters*     parameters { nullptr };
    AVRational             time_base {};
    int64_t                frame_span { 0 };
};

const EncodedGop& SharedGop() {
    static const EncodedGop gop = []() {
        EncodedGop      encoded;
        const AVCodec*  codec = avcodec_find_encoder_by_name("h264_videotoolbox");
        if (codec == nullptr) return encoded;

        AVCodecContext* context = avcodec_alloc_context3(codec);
        context->width          = kFrameWidth;
        context->height         = kFrameHeight;
        context->time_base      = AVRational { 1, 30 };
        context->framerate      = AVRational { 30, 1 };
        context->pix_fmt        = AV_PIX_FMT_YUV420P;
        context->gop_size       = kGopFrames;
        // Noise at a high bitrate is what makes a repeatable gop big enough to
        // tell "read the file" apart from "opened the file" in memory terms.
        context->bit_rate       = 200000000;
        context->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (avcodec_open2(context, codec, nullptr) < 0) {
            avcodec_free_context(&context);
            return encoded;
        }

        AVFrame* frame = av_frame_alloc();
        frame->width   = kFrameWidth;
        frame->height  = kFrameHeight;
        frame->format  = AV_PIX_FMT_YUV420P;
        av_frame_get_buffer(frame, 0);

        const auto drain = [&]() {
            while (true) {
                AVPacket* packet = av_packet_alloc();
                if (avcodec_receive_packet(context, packet) < 0) {
                    av_packet_free(&packet);
                    return;
                }
                encoded.packets.push_back(packet);
            }
        };

        for (int index = 0; index < kGopFrames; ++index) {
            av_frame_make_writable(frame);
            for (int y = 0; y < kFrameHeight; ++y) {
                uint8_t* row = frame->data[0] + y * frame->linesize[0];
                for (int x = 0; x < kFrameWidth; ++x) {
                    row[x] = static_cast<uint8_t>(
                        (static_cast<uint32_t>(x * 131 + y * 17 + index * 7919) * 2654435761u) >> 13);
                }
            }
            for (int y = 0; y < kFrameHeight / 2; ++y) {
                std::memset(frame->data[1] + y * frame->linesize[1], 128, kFrameWidth / 2);
                std::memset(frame->data[2] + y * frame->linesize[2], 128, kFrameWidth / 2);
            }
            frame->pts = index;
            avcodec_send_frame(context, frame);
            drain();
        }
        avcodec_send_frame(context, nullptr);
        drain();

        encoded.parameters = avcodec_parameters_alloc();
        avcodec_parameters_from_context(encoded.parameters, context);
        encoded.time_base  = context->time_base;
        encoded.frame_span = kGopFrames;
        av_frame_free(&frame);
        avcodec_free_context(&context);
        return encoded;
    }();
    return gop;
}

/// Writes a decodable MP4 holding `repeats` copies of the shared gop.
///
/// `salt` goes into a container metadata tag so two files with the same frame
/// count still differ byte for byte, which keeps one test's extraction cache
/// entry out of another's way.
bool WriteSyntheticVideo(const std::filesystem::path& path, int repeats, const std::string& salt) {
    const EncodedGop& gop = SharedGop();
    if (gop.packets.empty()) return false;

    AVFormatContext* output = nullptr;
    if (avformat_alloc_output_context2(&output, nullptr, nullptr, path.string().c_str()) < 0) {
        return false;
    }
    AVStream* stream = avformat_new_stream(output, nullptr);
    avcodec_parameters_copy(stream->codecpar, gop.parameters);
    stream->time_base = gop.time_base;
    av_dict_set(&output->metadata, "comment", salt.c_str(), 0);
    if (avio_open(&output->pb, path.string().c_str(), AVIO_FLAG_WRITE) < 0) {
        avformat_free_context(output);
        return false;
    }
    bool ok = avformat_write_header(output, nullptr) >= 0;
    for (int repeat = 0; ok && repeat < repeats; ++repeat) {
        const int64_t base = gop.frame_span * repeat;
        for (auto* source : gop.packets) {
            AVPacket* packet    = av_packet_clone(source);
            packet->stream_index = 0;
            packet->pts          = base + source->pts;
            packet->dts          = base + (source->dts == AV_NOPTS_VALUE ? source->pts : source->dts);
            av_packet_rescale_ts(packet, gop.time_base, stream->time_base);
            ok = av_interleaved_write_frame(output, packet) >= 0;
            av_packet_free(&packet);
            if (!ok) break;
        }
    }
    if (ok) ok = av_write_trailer(output) >= 0;
    avio_closep(&output->pb);
    avformat_free_context(output);
    return ok;
}

std::vector<char> ReadWholeFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input.good()) return {};
    const auto size = static_cast<size_t>(input.tellg());
    input.seekg(0, std::ios::beg);
    std::vector<char> bytes(size);
    input.read(bytes.data(), static_cast<std::streamsize>(size));
    return bytes;
}

/// Builds the in-package shape: the media bytes ride inside the image itself,
/// exactly as `WPTexImageParser` hands them over for a packaged asset.
std::shared_ptr<Image> MakeInlinePayloadImage(const std::string& key,
                                              const std::vector<char>& payload) {
    auto image                      = std::make_shared<Image>();
    image->key                      = key;
    image->header.isVideo           = true;
    image->header.count             = 1;
    image->header.width             = kFrameWidth;
    image->header.height            = kFrameHeight;

    Image::Slot slot;
    slot.width  = kFrameWidth;
    slot.height = kFrameHeight;

    ImageData mip;
    mip.width  = kFrameWidth;
    mip.height = kFrameHeight;
    mip.size   = static_cast<isize>(payload.size());
    mip.data   = ImageDataPtr(new uint8_t[payload.size()], [](uint8_t* data) { delete[] data; });
    std::memcpy(mip.data.get(), payload.data(), payload.size());
    slot.mipmaps.push_back(std::move(mip));
    image->slots.push_back(std::move(slot));
    return image;
}

std::filesystem::path VideoCacheDirectory() {
    return std::filesystem::temp_directory_path() / "wallpaper-engine-video";
}

/// The cache is shared with anything else running on this machine, so tests
/// compare snapshots of it instead of clearing it.
std::set<std::filesystem::path> VideoCacheEntries() {
    std::set<std::filesystem::path> entries;
    std::error_code                 ec;
    for (const auto& entry : std::filesystem::directory_iterator(VideoCacheDirectory(), ec)) {
        entries.insert(entry.path());
    }
    return entries;
}

uint64_t PhysicalFootprintBytes() {
    task_vm_info_data_t    info {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) !=
        KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint;
}

class VideoSourceInput : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_FALSE(SharedGop().packets.empty())
            << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
        static std::atomic<uint64_t> serial { 0 };
        project_dir = std::filesystem::temp_directory_path() /
                      ("owe-video-source-" + std::to_string(::getpid()) + "-" +
                       std::to_string(serial.fetch_add(1)));
        std::filesystem::create_directories(project_dir);
    }

    void TearDown() override {
        std::error_code ec;
        std::filesystem::remove_all(project_dir, ec);
        std::filesystem::remove_all(outside_dir, ec);
        for (const auto& path : published_cache_entries) {
            std::filesystem::remove(path, ec);
        }
    }

    /// A directory deliberately outside the project, for containment cases.
    const std::filesystem::path& OutsideDir() {
        if (outside_dir.empty()) {
            outside_dir = project_dir.parent_path() / (project_dir.filename().string() + "-outside");
            std::filesystem::create_directories(outside_dir);
        }
        return outside_dir;
    }

    /// Records whatever the cache gained since `before` so TearDown can undo it.
    std::set<std::filesystem::path> CacheEntriesAddedSince(
        const std::set<std::filesystem::path>& before) {
        std::set<std::filesystem::path> added;
        for (const auto& path : VideoCacheEntries()) {
            if (before.count(path) == 0) added.insert(path);
        }
        published_cache_entries.insert(added.begin(), added.end());
        return added;
    }

    std::filesystem::path           project_dir;
    std::filesystem::path           outside_dir;
    std::set<std::filesystem::path> published_cache_entries;
};

TEST_F(VideoSourceInput, PlainLocalFileIsDecodedWhereItLies) {
    const auto media = project_dir / "media.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "plain-local"));
    const auto original_size  = std::filesystem::file_size(media);
    const auto original_write = std::filesystem::last_write_time(media);
    const auto cache_before   = VideoCacheEntries();

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "media.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    // No slots is the whole point: there is no second copy of the media to own.
    EXPECT_TRUE(image->slots.empty());
    EXPECT_EQ(image->videoFilePath, std::filesystem::canonical(media).string());
    EXPECT_EQ(image->header.width, kFrameWidth);
    EXPECT_EQ(image->header.height, kFrameHeight);

    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());
    EXPECT_GT(source->durationSeconds(), 0.0);

    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
    EXPECT_EQ(std::filesystem::file_size(media), original_size);
    EXPECT_EQ(std::filesystem::last_write_time(media), original_write);
}

TEST_F(VideoSourceInput, LargeLocalFileIsNeverResident) {
    const auto media = project_dir / "large.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 96, "large-local"));
    const auto media_size = std::filesystem::file_size(media);
    ASSERT_GT(media_size, 48u * 1024u * 1024u);
    const auto cache_before = VideoCacheEntries();

    const uint64_t before = PhysicalFootprintBytes();
    ASSERT_GT(before, 0u);

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "large.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    ASSERT_TRUE(source->currentFrame().valid());

    const uint64_t after  = PhysicalFootprintBytes();
    const uint64_t growth = after > before ? after - before : 0;
    // Decoded 640x360 frames and FFmpeg's own buffers are megabytes; a copy of
    // the media would be tens of them, twice over.
    EXPECT_LT(growth, 16u * 1024u * 1024u)
        << "opening a " << media_size << " byte file grew the footprint by " << growth << " bytes";
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(VideoSourceInput, ConcurrentOpensOfOneFileEachGetTheirOwnDecoder) {
    const auto media = project_dir / "shared.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "concurrent-local"));
    const auto cache_before = VideoCacheEntries();

    constexpr int              kOpeners = 4;
    std::vector<std::thread>   threads;
    std::vector<std::string>   errors(kOpeners);
    std::vector<uint64_t>      instance_ids(kOpeners, 0);
    std::atomic<int>           primed { 0 };
    for (int index = 0; index < kOpeners; ++index) {
        threads.emplace_back([&, index]() {
            auto image = CreateVideoProjectImage(project_dir, "shared.mp4", &errors[index]);
            if (image == nullptr) return;
            auto source = CreateVideoTextureSource(*image, &errors[index]);
            if (source == nullptr) return;
            if (!source->prime(&errors[index])) return;
            instance_ids[index] = source->sourceStats().instance_id;
            primed.fetch_add(1);
        });
    }
    for (auto& thread : threads) thread.join();

    EXPECT_EQ(primed.load(), kOpeners) << errors[0] << "|" << errors[1] << "|" << errors[2] << "|"
                                       << errors[3];
    const std::set<uint64_t> distinct(instance_ids.begin(), instance_ids.end());
    EXPECT_EQ(distinct.size(), static_cast<size_t>(kOpeners));
    EXPECT_EQ(distinct.count(0), 0u);
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(VideoSourceInput, MissingMediaIsReportedAndNotOpened) {
    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "absent.mp4", &error), nullptr);
    EXPECT_NE(error.find("failed to open video project media file"), std::string::npos) << error;

    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "", &error), nullptr);
    EXPECT_EQ(error, "video project file entry must not be empty");

    // A file that disappears between resolution and decode fails on prime
    // rather than at construction, and still reports rather than crashing.
    const auto media = project_dir / "vanishing.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 1, "vanishing"));
    error.clear();
    auto image = CreateVideoProjectImage(project_dir, "vanishing.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    std::filesystem::remove(media);
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    error.clear();
    EXPECT_FALSE(source->prime(&error));
    EXPECT_FALSE(error.empty());
}

TEST_F(VideoSourceInput, EmptyMediaIsReported) {
    const auto media = project_dir / "empty.mp4";
    std::ofstream(media, std::ios::binary).close();
    ASSERT_TRUE(std::filesystem::exists(media));

    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "empty.mp4", &error), nullptr);
    EXPECT_NE(error.find("video project media file is empty"), std::string::npos) << error;
}

TEST_F(VideoSourceInput, CorruptMediaFailsWithoutTouchingTheCache) {
    const auto media = project_dir / "corrupt.mp4";
    {
        std::ofstream output(media, std::ios::binary);
        std::vector<char> noise(64 * 1024);
        for (size_t i = 0; i < noise.size(); ++i) noise[i] = static_cast<char>(i * 31 + 7);
        output.write(noise.data(), static_cast<std::streamsize>(noise.size()));
    }
    const auto cache_before = VideoCacheEntries();

    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "corrupt.mp4", &error), nullptr);
    EXPECT_FALSE(error.empty());

    // The same bytes offered as a packaged payload must fail on prime, not on
    // an unchecked decode.
    auto image  = MakeInlinePayloadImage("corrupt-inline", ReadWholeFile(media));
    error.clear();
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    error.clear();
    EXPECT_FALSE(source->prime(&error));
    EXPECT_FALSE(error.empty());
    source.reset();

    // A rejected payload may leave its extraction behind, but never a partial
    // one: nothing staged is allowed to survive under the ".part" name.
    for (const auto& path : CacheEntriesAddedSince(cache_before)) {
        EXPECT_NE(path.extension(), ".part") << path;
    }
}

TEST_F(VideoSourceInput, MediaOutsideTheProjectIsRejected) {
    const auto outside = OutsideDir() / "outside.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(outside, 1, "outside"));
    const auto inside = project_dir / "inside.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(inside, 1, "inside"));

    std::string error;
    const auto  traversal =
        std::filesystem::path("..") / OutsideDir().filename() / "outside.mp4";
    EXPECT_EQ(CreateVideoProjectImage(project_dir, traversal.string(), &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, outside.string(), &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    // A symlink is resolved before the containment test, so pointing out of the
    // project is rejected even though the link itself lives inside it.
    std::error_code ec;
    std::filesystem::create_symlink(outside, project_dir / "escape.mp4", ec);
    ASSERT_FALSE(ec);
    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "escape.mp4", &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    // A link that stays inside the project is still ordinary media.
    std::filesystem::create_symlink(inside, project_dir / "alias.mp4", ec);
    ASSERT_FALSE(ec);
    error.clear();
    auto image = CreateVideoProjectImage(project_dir, "alias.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    EXPECT_EQ(image->videoFilePath, std::filesystem::canonical(inside).string());
}

TEST_F(VideoSourceInput, InPackagePayloadIsPublishedWhole) {
    const auto media = project_dir / "packaged.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "packaged-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const auto cache_before = VideoCacheEntries();

    auto        image = MakeInlinePayloadImage("packaged.mp4", payload);
    std::string error;
    auto        source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());

    const auto added = CacheEntriesAddedSince(cache_before);
    ASSERT_EQ(added.size(), 1u);
    const auto& published = *added.begin();
    EXPECT_EQ(published.extension(), ".mp4");
    EXPECT_EQ(std::filesystem::file_size(published), payload.size());
}

TEST_F(VideoSourceInput, ConcurrentPackagedOpensPublishExactlyOneFile) {
    const auto media = project_dir / "packaged-race.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "race-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const auto cache_before = VideoCacheEntries();

    constexpr int            kOpeners = 4;
    std::vector<std::thread> threads;
    std::vector<std::string> errors(kOpeners);
    std::atomic<int>         primed { 0 };
    for (int index = 0; index < kOpeners; ++index) {
        threads.emplace_back([&, index]() {
            auto image  = MakeInlinePayloadImage("packaged-race.mp4", payload);
            auto source = CreateVideoTextureSource(*image, &errors[index]);
            if (source == nullptr) return;
            if (!source->prime(&errors[index])) return;
            if (!source->currentFrame().valid()) return;
            primed.fetch_add(1);
        });
    }
    for (auto& thread : threads) thread.join();

    EXPECT_EQ(primed.load(), kOpeners) << errors[0] << "|" << errors[1] << "|" << errors[2] << "|"
                                       << errors[3];
    const auto added = CacheEntriesAddedSince(cache_before);
    ASSERT_EQ(added.size(), 1u) << "racing extractions must converge on one published file";
    EXPECT_EQ(std::filesystem::file_size(*added.begin()), payload.size());
}

TEST_F(VideoSourceInput, EvictingTheCacheDoesNotDisturbAnOpenSource) {
    const auto media = project_dir / "evicted.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "evicted-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const auto cache_before = VideoCacheEntries();

    auto        image = MakeInlinePayloadImage("evicted.mp4", payload);
    std::string error;
    auto        source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;

    const auto added = CacheEntriesAddedSince(cache_before);
    ASSERT_EQ(added.size(), 1u);
    const auto published = *added.begin();
    ASSERT_TRUE(std::filesystem::remove(published));

    // The decoder holds the file open, so deleting the cache entry underneath it
    // must not interrupt playback.
    VideoPlaybackState state;
    state.scene_elapsed_seconds = 0.5;
    error.clear();
    EXPECT_TRUE(source->syncPlayback(state, &error)) << error;
    error.clear();
    EXPECT_TRUE(source->refreshFrame(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());

    // A later opener of the same payload re-publishes it rather than inheriting
    // the hole left by the eviction.
    auto second_image  = MakeInlinePayloadImage("evicted.mp4", payload);
    error.clear();
    auto second_source = CreateVideoTextureSource(*second_image, &error);
    ASSERT_NE(second_source, nullptr) << error;
    ASSERT_TRUE(second_source->prime(&error)) << error;
    ASSERT_TRUE(std::filesystem::exists(published));
    EXPECT_EQ(std::filesystem::file_size(published), payload.size());
}

TEST_F(VideoSourceInput, DestroyingASourceMidDecodeCancelsPromptly) {
    const auto media = project_dir / "cancelled.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 96, "cancelled"));
    const auto cache_before = VideoCacheEntries();

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "cancelled.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;

    // The decode thread is reading a large file; tearing the source down has to
    // abort that read instead of waiting for it.
    const auto start = std::chrono::steady_clock::now();
    source.reset();
    const auto elapsed = std::chrono::steady_clock::now() - start;
    EXPECT_LT(elapsed, std::chrono::seconds(2));

    // A source that is dropped before it is ever primed opens nothing at all.
    auto unprimed_image  = CreateVideoProjectImage(project_dir, "cancelled.mp4", &error);
    ASSERT_NE(unprimed_image, nullptr) << error;
    auto unprimed_source = CreateVideoTextureSource(*unprimed_image, &error);
    ASSERT_NE(unprimed_source, nullptr) << error;
    unprimed_source.reset();

    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

} // namespace
} // namespace wallpaper::video
