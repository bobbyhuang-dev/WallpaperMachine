#pragma once

#include "Video/VideoTextureSource.hpp"

#include <memory>

namespace wallpaper::video
{

class FfmpegVideoTextureSource final : public VideoTextureSource {
public:
    explicit FfmpegVideoTextureSource(const Image& image);
    ~FfmpegVideoTextureSource() override;

    bool prime(std::string* error) override;
    bool syncPlayback(const VideoPlaybackState& state, std::string* error) override;
    bool refreshFrame(std::string* error) override;
    [[nodiscard]] VideoTextureFrame currentFrame() const override;
    [[nodiscard]] double durationSeconds() const override;
    [[nodiscard]] double playbackSeconds() const override;
    [[nodiscard]] uint64_t loopCount() const override;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace wallpaper::video
