#pragma once

#include "RenderGraph/RenderGraph.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "SceneWallpaperSurface.hpp"
#include "Swapchain/ExSwapchain.hpp"
#include "Type.hpp"

#include <cstdio>
#include <memory>

namespace wallpaper
{
class Scene;

namespace vulkan
{
class FinPass;

class VulkanRender {
public:
    VulkanRender();
    ~VulkanRender();

    bool init(RenderInitInfo);

    void destroy();

    /// Pauses rendering and releases presentation-scoped resources:
    /// VkSurfaceKHR, swapchain, FinPass/PrePass, and the presentation passes.
    /// The Vulkan instance, logical device, queues, and device-scoped
    /// buffers remain alive. Must be followed by `resetSurface` or `destroy`
    /// before another frame is drawn.
    void releaseSurface();

    /// Rebuild the surface, swapchain, and presentation passes from a new
    /// RenderInitInfo. The scene, staging buffers, and command buffers are
    /// preserved. Returns false if surface/swapchain creation fails.
    bool resetSurface(const RenderInitInfo& info);

    void drawFrame(Scene&);

    void clearLastRenderGraph();
    void compileRenderGraph(Scene&, rg::RenderGraph&);
    void UpdateCameraFillMode(Scene&, wallpaper::FillMode);
    void SetWallpaperScalingMode(wallpaper::WallpaperScalingMode);
    void SetWallpaperScalingFactor(double);
    void SetWallpaperHorizontalFlip(bool enabled);
    void SetVideoPlaybackPaused(bool paused);
    void SetVideoPlaybackRate(float rate);

    ExSwapchain* exSwapchain() const;
    bool inited() const;

    // Transfer ownership of the most recent frame's exported dma_fence
    // sync_file fd. Returns -1 if no frame has been rendered since the
    // last call (or export failed). Caller owns the returned fd and
    // must close() it. Thread-safe.
    int takeLastFrameSyncFd();

private:
    struct Impl;
    std::unique_ptr<Impl> pImpl;
};
} // namespace vulkan
} // namespace wallpaper
