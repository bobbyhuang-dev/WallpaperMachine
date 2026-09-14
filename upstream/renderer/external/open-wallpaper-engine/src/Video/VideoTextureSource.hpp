#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

namespace wallpaper
{
struct Image;

namespace video
{
struct VideoMetadata;

struct VideoTextureFrame {
    uint32_t width { 0 };
    uint32_t height { 0 };
    void*    pixel_buffer { nullptr };
    void*    io_surface { nullptr };
    uint32_t pixel_format { 0 };
    uint32_t plane_count { 0 };
    double   pts_seconds { 0.0 };
    uint64_t generation { 0 };

    [[nodiscard]] bool valid() const
    {
        return (pixel_buffer != nullptr || io_surface != nullptr) && width > 0 && height > 0;
    }
};

struct VideoPlaybackState {
    bool   paused { false };
    float  rate { 1.0f };
    double scene_elapsed_seconds { 0.0 };
};

class VideoTextureSource {
public:
    virtual ~VideoTextureSource() = default;

    virtual bool prime(std::string* error) = 0;
    virtual bool syncPlayback(const VideoPlaybackState& state, std::string* error) = 0;
    virtual bool refreshFrame(std::string* error) = 0;
    [[nodiscard]] virtual VideoTextureFrame currentFrame() const = 0;
    [[nodiscard]] virtual double durationSeconds() const = 0;
    [[nodiscard]] virtual double playbackSeconds() const = 0;
    [[nodiscard]] virtual uint64_t loopCount() const = 0;
};

std::shared_ptr<VideoTextureSource> CreateVideoTextureSource(const Image& image,
                                                             std::string* error);
bool ProbeVideoFileDimensions(std::string_view media_path,
                              uint32_t*        width,
                              uint32_t*        height,
                              std::string*     error);
bool ProbeVideoFileMetadata(std::string_view media_path,
                            VideoMetadata*   out,
                            std::string*     error);

} // namespace video
} // namespace wallpaper
