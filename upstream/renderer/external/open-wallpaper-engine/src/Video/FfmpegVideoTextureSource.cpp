#include "Video/FfmpegVideoTextureSource.hpp"

#include "Image.hpp"
#include "Video/VideoMetadata.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
}

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <fstream>
#include <limits>
#include <mutex>
#include <span>
#include <string>
#include <thread>
#include <vector>

namespace wallpaper::video
{
namespace
{

constexpr auto kPrimeTimeout = std::chrono::seconds(2);
constexpr auto kPausedPoll = std::chrono::milliseconds(10);
constexpr auto kDecodePoll = std::chrono::milliseconds(2);

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

std::string AvErrorString(int error_code)
{
    std::array<char, AV_ERROR_MAX_STRING_SIZE> buffer {};
    av_strerror(error_code, buffer.data(), buffer.size());
    return std::string(buffer.data());
}

double WrapSeconds(double seconds, double duration_seconds)
{
    if (!(duration_seconds > 0.0) || !std::isfinite(seconds)) return 0.0;
    double wrapped = std::fmod(seconds, duration_seconds);
    if (wrapped < 0.0) wrapped += duration_seconds;
    if (wrapped >= duration_seconds) wrapped = 0.0;
    return wrapped;
}

double CircularDistance(double left, double right, double duration_seconds)
{
    if (!(duration_seconds > 0.0)) return std::abs(left - right);
    const double direct = std::abs(left - right);
    return std::min(direct, duration_seconds - direct);
}

std::filesystem::path WriteVideoPayloadToTemp(std::string_view debug_label,
                                              const std::vector<char>& payload,
                                              std::string* error)
{
    if (payload.empty()) {
        SetError(error, "video texture payload is empty");
        return {};
    }

    std::filesystem::path temp_dir = std::filesystem::temp_directory_path() / "wallpaper-engine-video";
    std::error_code       ec;
    std::filesystem::create_directories(temp_dir, ec);
    if (ec) {
        SetError(error, "failed to create temporary video cache directory");
        return {};
    }

    const std::filesystem::path media_path =
        temp_dir / (utils::genSha1(std::span(payload.data(), payload.size())) + ".mp4");
    if (std::filesystem::exists(media_path, ec) &&
        !ec &&
        std::filesystem::file_size(media_path, ec) == static_cast<uintmax_t>(payload.size())) {
        return media_path;
    }

    std::ofstream output(media_path, std::ios::binary | std::ios::trunc);
    if (!output.good()) {
        SetError(error, "failed to open temporary video cache file");
        return {};
    }

    output.write(payload.data(), static_cast<std::streamsize>(payload.size()));
    output.close();
    if (!output.good()) {
        SetError(error, "failed to write temporary video cache file");
        return {};
    }

    LOG_INFO("prepared FFmpeg video payload cache for \"%s\": %s",
             std::string(debug_label).c_str(),
             media_path.string().c_str());
    return media_path;
}

double ProbeDurationSeconds(AVFormatContext* format_context, AVStream* stream)
{
    if (stream != nullptr && stream->duration > 0) {
        const double stream_duration = stream->duration * av_q2d(stream->time_base);
        if (std::isfinite(stream_duration) && stream_duration > 0.0) return stream_duration;
    }
    if (format_context != nullptr && format_context->duration > 0) {
        const double format_duration =
            static_cast<double>(format_context->duration) / static_cast<double>(AV_TIME_BASE);
        if (std::isfinite(format_duration) && format_duration > 0.0) return format_duration;
    }
    return 0.0;
}

double ProbeFrameDurationSeconds(AVStream* stream)
{
    if (stream == nullptr) return 1.0 / 60.0;
    const AVRational frame_rate = stream->avg_frame_rate.num != 0 && stream->avg_frame_rate.den != 0
        ? stream->avg_frame_rate
        : stream->r_frame_rate;
    if (frame_rate.num > 0 && frame_rate.den > 0) {
        const double fps = av_q2d(frame_rate);
        if (std::isfinite(fps) && fps > 0.0) return 1.0 / fps;
    }
    return 1.0 / 60.0;
}

bool ProbeStreamDimensions(AVStream* stream, uint32_t* width, uint32_t* height, std::string* error)
{
    if (stream == nullptr) return SetError(error, "FFmpeg video stream must not be null");
    if (width == nullptr) return SetError(error, "video width output must not be null");
    if (height == nullptr) return SetError(error, "video height output must not be null");
    if (stream->codecpar == nullptr) return SetError(error, "FFmpeg video stream has no codec parameters");

    uint32_t resolved_width = static_cast<uint32_t>(std::max(0, stream->codecpar->width));
    uint32_t resolved_height = static_cast<uint32_t>(std::max(0, stream->codecpar->height));
    if (resolved_width == 0 || resolved_height == 0) {
        return SetError(error, "FFmpeg video stream returned an invalid size");
    }

    const AVPacketSideData* display_side_data = av_packet_side_data_get(
        stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    if (display_side_data != nullptr &&
        display_side_data->data != nullptr &&
        display_side_data->size >= static_cast<int>(9 * sizeof(int32_t))) {
        const auto* display_matrix = reinterpret_cast<const int32_t*>(display_side_data->data);
        const double rotation = av_display_rotation_get(display_matrix);
        if (std::isfinite(rotation)) {
            const double abs_rotation = std::fmod(std::abs(rotation), 360.0);
            if (std::abs(abs_rotation - 90.0) < 1.0 || std::abs(abs_rotation - 270.0) < 1.0) {
                std::swap(resolved_width, resolved_height);
            }
        }
    }

    *width = resolved_width;
    *height = resolved_height;
    return true;
}

#if defined(__APPLE__)
AVPixelFormat SelectAppleHardwareFormat(AVCodecContext* context, const AVPixelFormat* formats)
{
    if (context == nullptr || formats == nullptr) return AV_PIX_FMT_NONE;

    const AVPixelFormat desired_format =
        context->opaque != nullptr
        ? *reinterpret_cast<const AVPixelFormat*>(context->opaque)
        : AV_PIX_FMT_NONE;
    for (auto* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == desired_format) {
            return *format;
        }
    }

    for (auto* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        const auto* descriptor = av_pix_fmt_desc_get(*format);
        if (descriptor != nullptr &&
            (descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL) == 0) {
            return *format;
        }
    }

    return formats[0];
}
#endif

double FramePtsSeconds(const AVFrame* frame, AVRational time_base, double fallback_seconds)
{
    if (frame == nullptr) return fallback_seconds;
    if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        const double seconds = frame->best_effort_timestamp * av_q2d(time_base);
        if (std::isfinite(seconds) && seconds >= 0.0) return seconds;
    }
    if (frame->pts != AV_NOPTS_VALUE) {
        const double seconds = frame->pts * av_q2d(time_base);
        if (std::isfinite(seconds) && seconds >= 0.0) return seconds;
    }
    return fallback_seconds;
}

} // namespace

class FfmpegVideoTextureSource::Impl {
public:
    explicit Impl(const Image& image)
        : m_debug_label(image.key)
    {
        if (!image.header.isVideo) {
            m_initial_error = "image is not marked as a video texture";
            return;
        }
        if (image.slots.empty() || image.slots.front().mipmaps.empty()) {
            m_initial_error = "video texture has no mip payload";
            return;
        }

        const auto& mip = image.slots.front().mipmaps.front();
        if (mip.data == nullptr || mip.size <= 0) {
            m_initial_error = "video texture payload is empty";
            return;
        }

        m_payload.assign(
            reinterpret_cast<const char*>(mip.data.get()),
            reinterpret_cast<const char*>(mip.data.get()) + static_cast<size_t>(mip.size));
    }

    ~Impl()
    {
        stop();
        clearFrames();
        closeDecoder();
    }

    bool prime(std::string* error)
    {
        std::unique_lock lock(m_mutex);
        if (m_primed) return true;
        if (!m_initial_error.empty()) return SetError(error, m_initial_error);
        lock.unlock();

        std::string local_error;
        if (!openDecoder(&local_error)) {
            return SetError(error, std::move(local_error));
        }

        {
            std::lock_guard state_lock(m_mutex);
            m_scene_absolute_seconds = 0.0;
            m_clock_base_seconds = 0.0;
            m_clock_initialized = true;
            m_running = true;
            m_stop_requested = false;
        }

        m_decode_thread = std::thread([this]() { decodeLoop(); });

        lock.lock();
        const auto ready = m_condition.wait_for(
            lock,
            kPrimeTimeout,
            [this]() {
                return m_display_frame_ready || !m_last_error.empty();
            });
        if (!ready) {
            lock.unlock();
            stop();
            return SetError(error, "timed out waiting for the first FFmpeg video frame");
        }
        if (!m_last_error.empty()) {
            const std::string failure = m_last_error;
            lock.unlock();
            stop();
            return SetError(error, failure);
        }

        m_primed = true;
        return true;
    }

    bool syncPlayback(const VideoPlaybackState& state, std::string* error)
    {
        if (state.rate < 0.0f) return SetError(error, "negative video playback rates are not supported");

        std::lock_guard lock(m_mutex);
        if (!m_last_error.empty()) return SetError(error, m_last_error);

        const auto now = std::chrono::steady_clock::now();
        const double requested_absolute_seconds = std::max(0.0, state.scene_elapsed_seconds);
        m_scene_absolute_seconds = requested_absolute_seconds;
        m_clock_base_seconds = WrapSeconds(requested_absolute_seconds, m_duration_seconds);
        m_clock_base_time = now;
        m_clock_initialized = true;
        m_playback_state = state;
        m_playback_state.rate = std::max(state.rate, 0.0f);
        const double discontinuity_threshold = std::max(0.5, m_frame_duration_seconds * 8.0);
        if (m_display_frame_ready &&
            requested_absolute_seconds + discontinuity_threshold < m_display_frame.absolute_seconds) {
            clearDisplayFrameLocked();
            requestSeekLocked(requested_absolute_seconds);
        }
        m_condition.notify_all();
        return true;
    }

    bool refreshFrame(std::string* error)
    {
        std::unique_lock lock(m_mutex);
        if (!m_last_error.empty() && !m_display_frame_ready) {
            return SetError(error, m_last_error);
        }

        const double desired_absolute_seconds = currentDesiredAbsoluteLocked();
        const double backward_threshold = std::max(0.05, m_frame_duration_seconds * 2.0);
        if (m_display_frame_ready &&
            desired_absolute_seconds + backward_threshold < m_display_frame.absolute_seconds) {
            clearDisplayFrameLocked();
            requestSeekLocked(desired_absolute_seconds);
        }

        const double forward_resync_threshold =
            std::max(1.0, m_frame_duration_seconds * static_cast<double>(kDecodedFrameQueueCapacity) * 2.0);
        if (!m_display_frame_ready ||
            desired_absolute_seconds > latestBufferedAbsoluteLocked() + forward_resync_threshold) {
            requestSeekLocked(desired_absolute_seconds);
        }

        while (!m_pending_frames.empty() &&
               (!m_display_frame_ready ||
                m_pending_frames.front().absolute_seconds <=
                    desired_absolute_seconds + presentationSlackSeconds())) {
            promoteNextFrameLocked();
        }
        if (m_display_frame_ready) {
            m_condition.notify_all();
            return true;
        }

        const auto deadline = std::chrono::steady_clock::now() + kPrimeTimeout;
        while (true) {
            while (!m_pending_frames.empty() &&
                   (!m_display_frame_ready ||
                    m_pending_frames.front().absolute_seconds <=
                        desired_absolute_seconds + presentationSlackSeconds())) {
                promoteNextFrameLocked();
            }

            if (m_display_frame_ready ||
                displayFrameCoversDesiredLocked(desired_absolute_seconds)) {
                m_condition.notify_all();
                return true;
            }

            if (!m_last_error.empty() && !m_display_frame_ready) {
                return SetError(error, m_last_error);
            }

            if (std::chrono::steady_clock::now() >= deadline) {
                if (m_display_frame_ready) {
                    m_condition.notify_all();
                    return true;
                }
                return SetError(error, "video frame is not ready");
            }

            m_condition.notify_all();
            m_condition.wait_for(lock, kDecodePoll, [this]() {
                return m_stop_requested || !m_last_error.empty() || !m_pending_frames.empty();
            });
        }
    }

    [[nodiscard]] VideoTextureFrame currentFrame() const
    {
        std::lock_guard lock(m_mutex);
        if (!m_display_frame_ready) return {};
        return m_display_frame.frame;
    }

    [[nodiscard]] double durationSeconds() const
    {
        std::lock_guard lock(m_mutex);
        return m_duration_seconds;
    }

    [[nodiscard]] double playbackSeconds() const
    {
        std::lock_guard lock(m_mutex);
        return currentDesiredSecondsLocked();
    }

    [[nodiscard]] uint64_t loopCount() const
    {
        std::lock_guard lock(m_mutex);
        return m_loop_count;
    }

private:
    static constexpr size_t kDecodedFrameQueueCapacity = 8;

    struct DecodedFrameSlot {
        VideoTextureFrame frame {};
        double            pts_seconds { 0.0 };
        double            absolute_seconds { 0.0 };
        uint64_t          loop_index { 0 };
        bool              ready { false };
    };

    bool openDecoder(std::string* error)
    {
        m_media_path = WriteVideoPayloadToTemp(m_debug_label, m_payload, error);
        if (m_media_path.empty()) return false;

        AVFormatContext* format_context = nullptr;
        if (const int result = avformat_open_input(&format_context, m_media_path.c_str(), nullptr, nullptr);
            result < 0) {
            return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
        }

        if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
        }

        const int video_stream_index =
            av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        if (video_stream_index < 0) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
        }

        AVStream* video_stream = format_context->streams[video_stream_index];
        if (video_stream == nullptr || video_stream->codecpar == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "FFmpeg video stream is missing codec parameters");
        }

        const AVCodec* codec = avcodec_find_decoder(video_stream->codecpar->codec_id);
        if (codec == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to find FFmpeg decoder for video stream");
        }

        AVCodecContext* codec_context = avcodec_alloc_context3(codec);
        if (codec_context == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to allocate FFmpeg decoder context");
        }

        if (const int result = avcodec_parameters_to_context(codec_context, video_stream->codecpar);
            result < 0) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return SetError(error, "failed to copy FFmpeg codec parameters: " + AvErrorString(result));
        }

#if defined(__APPLE__)
        m_hw_pixel_format = AV_PIX_FMT_NONE;
        for (int index = 0;; ++index) {
            const AVCodecHWConfig* config = avcodec_get_hw_config(codec, index);
            if (config == nullptr) break;
            if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 &&
                config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
                m_hw_pixel_format = config->pix_fmt;
                break;
            }
        }
        if (m_hw_pixel_format == AV_PIX_FMT_NONE) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return SetError(error, "FFmpeg decoder does not advertise VideoToolbox hardware decode");
        }

        codec_context->get_format = SelectAppleHardwareFormat;
        codec_context->opaque = &m_hw_pixel_format;
        if (!CreateVideoToolboxDeviceContext(&m_hw_device_context, error)) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return false;
        }
        codec_context->hw_device_ctx = av_buffer_ref(m_hw_device_context);
        if (codec_context->hw_device_ctx == nullptr) {
            av_buffer_unref(&m_hw_device_context);
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return SetError(error, "failed to retain FFmpeg VideoToolbox device context");
        }
#endif

        if (const int result = avcodec_open2(codec_context, codec, nullptr); result < 0) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            av_buffer_unref(&m_hw_device_context);
            return SetError(error, "failed to open FFmpeg decoder: " + AvErrorString(result));
        }

        AVPacket* packet = av_packet_alloc();
        AVFrame*  frame = av_frame_alloc();
        if (packet == nullptr || frame == nullptr) {
            av_packet_free(&packet);
            av_frame_free(&frame);
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            av_buffer_unref(&m_hw_device_context);
            return SetError(error, "failed to allocate FFmpeg packet/frame buffers");
        }

        m_format_context = format_context;
        m_codec_context = codec_context;
        m_video_stream = video_stream;
        m_video_stream_index = video_stream_index;
        m_packet = packet;
        m_frame = frame;
        m_duration_seconds = ProbeDurationSeconds(format_context, video_stream);
        m_frame_duration_seconds = ProbeFrameDurationSeconds(video_stream);
        return true;
    }

    void closeDecoder()
    {
        if (m_packet != nullptr) av_packet_free(&m_packet);
        if (m_frame != nullptr) av_frame_free(&m_frame);
        if (m_codec_context != nullptr) avcodec_free_context(&m_codec_context);
        if (m_format_context != nullptr) avformat_close_input(&m_format_context);
        if (m_hw_device_context != nullptr) av_buffer_unref(&m_hw_device_context);
        m_video_stream = nullptr;
        m_video_stream_index = -1;
    }

    void stop()
    {
        {
            std::lock_guard lock(m_mutex);
            if (!m_running && !m_decode_thread.joinable()) return;
            m_stop_requested = true;
            m_running = false;
            m_condition.notify_all();
        }
        if (m_decode_thread.joinable()) m_decode_thread.join();
    }

    void releaseFrameSlot(DecodedFrameSlot* slot)
    {
        if (slot == nullptr) return;
        ReleaseAppleVideoFrame(&slot->frame);
        slot->ready = false;
        slot->pts_seconds = 0.0;
        slot->absolute_seconds = 0.0;
        slot->loop_index = 0;
        slot->frame = {};
    }

    void clearPendingFramesLocked()
    {
        for (auto& slot : m_pending_frames) {
            releaseFrameSlot(&slot);
        }
        m_pending_frames.clear();
    }

    void clearDisplayFrameLocked()
    {
        if (!m_display_frame_ready) return;
        releaseFrameSlot(&m_display_frame);
        m_display_frame_ready = false;
    }

    void clearFrames()
    {
        std::lock_guard lock(m_mutex);
        clearPendingFramesLocked();
        clearDisplayFrameLocked();
    }

    [[nodiscard]] double currentDesiredAbsoluteLocked() const
    {
        return std::max(0.0, m_scene_absolute_seconds);
    }

    [[nodiscard]] double currentDesiredSecondsLocked() const
    {
        if (!m_clock_initialized) return 0.0;
        return WrapSeconds(currentDesiredAbsoluteLocked(), m_duration_seconds);
    }

    [[nodiscard]] double presentationSlackSeconds() const
    {
        return std::min(0.001, m_frame_duration_seconds * 0.1);
    }

    [[nodiscard]] double latestBufferedAbsoluteLocked() const
    {
        if (!m_pending_frames.empty()) return m_pending_frames.back().absolute_seconds;
        if (m_display_frame_ready) return m_display_frame.absolute_seconds;
        return -std::numeric_limits<double>::infinity();
    }

    void requestSeekLocked(double absolute_seconds)
    {
        m_requested_seek_absolute_seconds = std::max(0.0, absolute_seconds);
        m_seek_requested = true;
        ++m_seek_ticket;
        clearPendingFramesLocked();
    }

    [[nodiscard]] bool displayFrameCoversDesiredLocked(double desired_absolute_seconds) const
    {
        if (!m_display_frame_ready) return false;
        if (desired_absolute_seconds + presentationSlackSeconds() < m_display_frame.absolute_seconds) {
            return false;
        }

        double display_end_absolute_seconds =
            m_display_frame.absolute_seconds + m_frame_duration_seconds;
        if (!m_pending_frames.empty() &&
            m_pending_frames.front().absolute_seconds > m_display_frame.absolute_seconds) {
            display_end_absolute_seconds = m_pending_frames.front().absolute_seconds;
        }

        return desired_absolute_seconds <
            display_end_absolute_seconds + presentationSlackSeconds();
    }

    bool promoteNextFrameLocked()
    {
        if (m_pending_frames.empty()) return false;

        auto next_frame = std::move(m_pending_frames.front());
        m_pending_frames.pop_front();
        if (m_display_frame_ready) {
            if (next_frame.loop_index > m_display_frame.loop_index) {
                m_loop_count += next_frame.loop_index - m_display_frame.loop_index;
            }
            releaseFrameSlot(&m_display_frame);
        }

        m_display_frame = std::move(next_frame);
        m_display_frame_ready = true;
        return true;
    }

    bool seekDecoderToAbsolute(double absolute_seconds, std::string* error)
    {
        const double clamped_absolute_seconds = std::max(0.0, absolute_seconds);
        const double wrapped_seconds = WrapSeconds(clamped_absolute_seconds, m_duration_seconds);
        if (!seekToSeconds(wrapped_seconds, error)) return false;

        if (m_duration_seconds > 0.0) {
            m_decode_loop_index = static_cast<uint64_t>(
                std::floor(clamped_absolute_seconds / m_duration_seconds));
        } else {
            m_decode_loop_index = 0;
        }
        return true;
    }

    bool seekToSeconds(double seconds, std::string* error)
    {
        if (m_format_context == nullptr || m_codec_context == nullptr || m_video_stream == nullptr) {
            return SetError(error, "FFmpeg decoder is not initialized");
        }

        const int64_t target_timestamp = av_rescale_q(
            static_cast<int64_t>(seconds * static_cast<double>(AV_TIME_BASE)),
            AVRational { 1, AV_TIME_BASE },
            m_video_stream->time_base);
        if (const int result = av_seek_frame(
                m_format_context,
                m_video_stream_index,
                std::max<int64_t>(0, target_timestamp),
                AVSEEK_FLAG_BACKWARD);
            result < 0) {
            return SetError(error, "failed to seek FFmpeg video stream: " + AvErrorString(result));
        }

        avcodec_flush_buffers(m_codec_context);
        av_frame_unref(m_frame);
        av_packet_unref(m_packet);
        return true;
    }

    bool decodeNextFrame(double minimum_absolute_seconds,
                         DecodedFrameSlot* out,
                         std::string* error)
    {
        if (out == nullptr) return SetError(error, "decoded frame output must not be null");
        const bool enforce_minimum =
            std::isfinite(minimum_absolute_seconds) && minimum_absolute_seconds > 0.0;

        while (true) {
            const int read_result = av_read_frame(m_format_context, m_packet);
            if (read_result == AVERROR_EOF) {
                if (!seekToSeconds(0.0, error)) return false;
                ++m_decode_loop_index;
                continue;
            }
            if (read_result < 0) {
                return SetError(error, "failed to read FFmpeg packet: " + AvErrorString(read_result));
            }

            if (m_packet->stream_index != m_video_stream_index) {
                av_packet_unref(m_packet);
                continue;
            }

            const int send_result = avcodec_send_packet(m_codec_context, m_packet);
            av_packet_unref(m_packet);
            if (send_result < 0 && send_result != AVERROR(EAGAIN)) {
                return SetError(error, "failed to submit FFmpeg packet to decoder: " + AvErrorString(send_result));
            }

            while (true) {
                const int receive_result = avcodec_receive_frame(m_codec_context, m_frame);
                if (receive_result == AVERROR(EAGAIN)) break;
                if (receive_result == AVERROR_EOF) {
                    if (!seekToSeconds(0.0, error)) return false;
                    ++m_decode_loop_index;
                    break;
                }
                if (receive_result < 0) {
                    return SetError(
                        error,
                        "failed to receive FFmpeg decoded frame: " + AvErrorString(receive_result));
                }

                const double frame_pts_seconds =
                    FramePtsSeconds(
                        m_frame,
                        m_video_stream->time_base,
                        WrapSeconds(minimum_absolute_seconds, m_duration_seconds));
                const double frame_absolute_seconds =
                    (m_duration_seconds > 0.0
                         ? static_cast<double>(m_decode_loop_index) * m_duration_seconds
                         : 0.0) + frame_pts_seconds;
                if (enforce_minimum &&
                    frame_absolute_seconds + m_frame_duration_seconds < minimum_absolute_seconds) {
                    av_frame_unref(m_frame);
                    continue;
                }

                VideoTextureFrame frame {};
                if (!ExtractAppleVideoFrame(m_frame, &frame, error)) {
                    av_frame_unref(m_frame);
                    return false;
                }

                frame.pts_seconds = frame_absolute_seconds;
                out->frame = frame;
                out->pts_seconds = frame_absolute_seconds;
                out->absolute_seconds = frame_absolute_seconds;
                out->loop_index = m_decode_loop_index;
                out->ready = true;
                av_frame_unref(m_frame);
                return true;
            }
        }
    }

    void queueDecodedFrame(DecodedFrameSlot frame_slot, uint64_t seek_ticket)
    {
        std::lock_guard lock(m_mutex);
        if (m_stop_requested || seek_ticket != m_seek_ticket) {
            releaseFrameSlot(&frame_slot);
            return;
        }

        frame_slot.frame.generation = m_next_generation++;
        m_pending_frames.push_back(std::move(frame_slot));
        if (!m_display_frame_ready) {
            promoteNextFrameLocked();
        }
        m_condition.notify_all();
    }

    void fail(std::string error)
    {
        std::lock_guard lock(m_mutex);
        if (m_last_error.empty()) m_last_error = std::move(error);
        m_running = false;
        m_condition.notify_all();
    }

    void decodeLoop()
    {
        while (true) {
            double minimum_absolute_seconds = -std::numeric_limits<double>::infinity();
            bool   perform_seek = false;
            double seek_absolute_seconds = 0.0;
            uint64_t decode_seek_ticket = 0;

            {
                std::unique_lock lock(m_mutex);
                m_condition.wait(lock, [this]() {
                    return m_stop_requested ||
                        m_seek_requested ||
                        m_pending_frames.size() < kDecodedFrameQueueCapacity ||
                        !m_display_frame_ready;
                });
                if (m_stop_requested) break;
                decode_seek_ticket = m_seek_ticket;
                if (m_seek_requested) {
                    perform_seek = true;
                    seek_absolute_seconds = m_requested_seek_absolute_seconds;
                    m_seek_requested = false;
                    minimum_absolute_seconds = seek_absolute_seconds;
                }
            }

            if (perform_seek) {
                std::string error;
                if (!seekDecoderToAbsolute(seek_absolute_seconds, &error)) {
                    fail(std::move(error));
                    break;
                }
            }

            DecodedFrameSlot frame_slot {};
            std::string      error;
            if (!decodeNextFrame(minimum_absolute_seconds, &frame_slot, &error)) {
                fail(std::move(error));
                break;
            }
            queueDecodedFrame(std::move(frame_slot), decode_seek_ticket);
        }
    }

private:
    std::string                      m_debug_label;
    std::vector<char>                m_payload;
    std::filesystem::path            m_media_path;
    std::string                      m_initial_error;
    mutable std::mutex               m_mutex;
    std::condition_variable          m_condition;
    VideoPlaybackState               m_playback_state {};
    double                           m_scene_absolute_seconds { 0.0 };
    std::chrono::steady_clock::time_point m_clock_base_time {};
    double                           m_clock_base_seconds { 0.0 };
    bool                             m_clock_initialized { false };
    double                           m_duration_seconds { 0.0 };
    double                           m_frame_duration_seconds { 1.0 / 60.0 };
    uint64_t                         m_loop_count { 0 };
    uint64_t                         m_next_generation { 1 };
    std::deque<DecodedFrameSlot>     m_pending_frames;
    DecodedFrameSlot                 m_display_frame {};
    bool                             m_display_frame_ready { false };
    bool                             m_seek_requested { false };
    double                           m_requested_seek_absolute_seconds { 0.0 };
    uint64_t                         m_seek_ticket { 0 };
    uint64_t                         m_decode_loop_index { 0 };
    bool                             m_running { false };
    bool                             m_stop_requested { false };
    bool                             m_primed { false };
    std::thread                      m_decode_thread;
    std::string                      m_last_error;
    AVFormatContext*                 m_format_context { nullptr };
    AVCodecContext*                  m_codec_context { nullptr };
    AVBufferRef*                     m_hw_device_context { nullptr };
    AVStream*                        m_video_stream { nullptr };
    int                              m_video_stream_index { -1 };
    AVPacket*                        m_packet { nullptr };
    AVFrame*                         m_frame { nullptr };
    AVPixelFormat                    m_hw_pixel_format { AV_PIX_FMT_NONE };
};

FfmpegVideoTextureSource::FfmpegVideoTextureSource(const Image& image)
    : m_impl(std::make_unique<Impl>(image))
{
}

FfmpegVideoTextureSource::~FfmpegVideoTextureSource() = default;

bool FfmpegVideoTextureSource::prime(std::string* error)
{
    return m_impl->prime(error);
}

bool FfmpegVideoTextureSource::syncPlayback(const VideoPlaybackState& state, std::string* error)
{
    return m_impl->syncPlayback(state, error);
}

bool FfmpegVideoTextureSource::refreshFrame(std::string* error)
{
    return m_impl->refreshFrame(error);
}

VideoTextureFrame FfmpegVideoTextureSource::currentFrame() const
{
    return m_impl->currentFrame();
}

double FfmpegVideoTextureSource::durationSeconds() const
{
    return m_impl->durationSeconds();
}

double FfmpegVideoTextureSource::playbackSeconds() const
{
    return m_impl->playbackSeconds();
}

uint64_t FfmpegVideoTextureSource::loopCount() const
{
    return m_impl->loopCount();
}

std::shared_ptr<VideoTextureSource> CreateVideoTextureSource(const Image& image,
                                                             std::string* error)
{
    if (!image.header.isVideo) {
        SetError(error, "image is not marked as a video texture");
        return nullptr;
    }

    return std::make_shared<FfmpegVideoTextureSource>(image);
}

bool ProbeVideoFileDimensions(std::string_view media_path,
                              uint32_t*        width,
                              uint32_t*        height,
                              std::string*     error)
{
    if (media_path.empty()) return SetError(error, "video media path must not be empty");

    AVFormatContext* format_context = nullptr;
    if (const int result = avformat_open_input(&format_context,
                                               std::string(media_path).c_str(),
                                               nullptr,
                                               nullptr);
        result < 0) {
        return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
    }

    if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
    }

    const int video_stream_index =
        av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_index < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
    }

    AVStream* stream = format_context->streams[video_stream_index];
    const bool ok = ProbeStreamDimensions(stream, width, height, error);
    avformat_close_input(&format_context);
    return ok;
}

bool ProbeVideoFileMetadata(std::string_view media_path,
                            VideoMetadata*   out,
                            std::string*     error)
{
    if (out == nullptr) return SetError(error, "video metadata output must not be null");
    if (media_path.empty()) return SetError(error, "video media path must not be empty");

    AVFormatContext* format_context = nullptr;
    if (const int result = avformat_open_input(&format_context,
                                               std::string(media_path).c_str(),
                                               nullptr,
                                               nullptr);
        result < 0) {
        return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
    }

    if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
    }

    const int video_stream_index =
        av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_index < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
    }

    AVStream* stream = format_context->streams[video_stream_index];
    const bool ok = ProbeStreamDimensions(stream, &out->width, &out->height, error);
    if (ok) {
        out->duration_seconds = ProbeDurationSeconds(format_context, stream);
    }
    avformat_close_input(&format_context);
    return ok;
}

} // namespace wallpaper::video
