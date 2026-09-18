#pragma once

#include "Video/VideoTextureSource.hpp"

#include <filesystem>
#include <memory>
#include <string>
#include <string_view>

namespace wallpaper
{
struct Image;

namespace video
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
    [[nodiscard]] double frameDurationSeconds() const override;
    [[nodiscard]] VideoSourceStats sourceStats() const override;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

/// Builds the texture image for a pure-video wallpaper project.
///
/// `file_name` is the project manifest's media entry, resolved against
/// `project_directory`. The media file is not read: the returned image only
/// records where it lives, and the decoder opens it in place. Symlinks are
/// resolved before the containment test, so an entry that leaves the project
/// directory is rejected instead of followed. Returns nullptr and fills
/// `error` when the entry is empty, missing, empty on disk, outside the
/// project, or not decodable.
std::shared_ptr<Image> CreateVideoProjectImage(const std::filesystem::path& project_directory,
                                               std::string_view             file_name,
                                               std::string*                 error);

} // namespace video
} // namespace wallpaper
