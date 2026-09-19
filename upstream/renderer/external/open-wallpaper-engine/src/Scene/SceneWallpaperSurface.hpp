#pragma once
#include "SceneWallpaper.hpp"

#include <functional>
#include <string_view>
#include <vulkan/vulkan.h>
#include <cstdint>
#include <span>

namespace wallpaper
{
using ReDrawCB = std::function<void()>;

struct VulkanSurfaceInfo {
    std::function<VkResult(VkInstance, VkSurfaceKHR*)> createSurfaceOp;
    std::vector<std::string>                           instanceExts;
};

struct RenderInitInfo {
    bool enable_valid_layer { false };
    bool offscreen { false };

    std::span<const std::uint8_t> uuid;
    TexTiling                     offscreen_tiling { TexTiling::OPTIMAL };
    VulkanSurfaceInfo             surface_info;

    /// The `CAMetalLayer` this surface presents to, when there is one.
    ///
    /// `surface_info.createSurfaceOp` already closes over it, but a closure
    /// cannot be handed to a backend that does not create a `VkSurfaceKHR`.
    /// Carrying the handle alongside lets the native Metal backend adopt the
    /// same layer without a second plumbing path, and keeps the invariant that
    /// exactly one backend ever owns it. Null off Apple platforms and in
    /// offscreen mode.
    void* metal_layer { nullptr };

    uint16_t width { 1920 };
    uint16_t height { 1080 };
    uint16_t render_width { 0 };
    uint16_t render_height { 0 };
    double   display_scale_factor { 1.0 };
    ReDrawCB redraw_callback;

    // Optional, demand-driven export of the final presented pixels. The host
    // uses this for a native desktop poster, not for screen/window capture.
    std::function<bool()> wants_poster;
    std::function<void(std::span<const uint8_t>, uint32_t, uint32_t, bool)> poster_ready;
};

} // namespace wallpaper
