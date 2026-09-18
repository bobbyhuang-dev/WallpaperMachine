// Synthetic H.264 media for tests that need a real decodable file.
//
// Encoding is the slow part, so one group of pictures is encoded once per test
// binary and muxed as many times as a given size needs. Tests that want media
// of their own get it from here rather than shipping a fixture.

#pragma once

#include <gtest/gtest.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>
}

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace wallpaper::video
{
namespace testing_media
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

} // namespace testing_media
} // namespace wallpaper::video
