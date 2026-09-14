#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace wallpaper::video
{

struct VideoMetadata
{
    uint32_t width { 0 };
    uint32_t height { 0 };
    double   duration_seconds { 0.0 };
};

bool ProbeVideoFileMetadata(std::string_view media_path,
                            VideoMetadata*   out,
                            std::string*     error);

} // namespace wallpaper::video
