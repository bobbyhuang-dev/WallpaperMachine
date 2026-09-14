#pragma once

#include <cstdint>
#include <vulkan/vulkan.h>

namespace wallpaper
{

enum class WallpaperScalingMode : std::uint8_t
{
    NONE = 0,
    STRETCH = 1,
    FIT = 2,
    FILL = 3,
};

struct PixelRect {
    int32_t x { 0 };
    int32_t y { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
};

struct WallpaperScalingLayout {
    double scene_width { 0.0 };
    double scene_height { 0.0 };
    double display_logical_width { 0.0 };
    double display_logical_height { 0.0 };
    double scale_x { 1.0 };
    double scale_y { 1.0 };
    PixelRect viewport_px {};
    PixelRect scissor_px {};
};

WallpaperScalingLayout ComputeWallpaperScalingLayout(
    WallpaperScalingMode mode,
    uint32_t scene_width,
    uint32_t scene_height,
    uint32_t display_logical_width,
    uint32_t display_logical_height,
    double display_scale_factor,
    double wallpaper_scale_factor);

VkViewport MakeWallpaperViewport(const WallpaperScalingLayout& layout);
VkRect2D   MakeWallpaperScissor(const WallpaperScalingLayout& layout);

} // namespace wallpaper
