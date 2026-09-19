#pragma once

#include "MetalRender/MetalRender.hpp"
#include "Scene/include/Scene/SceneBackendSelection.hpp"
#include "VulkanRender/VulkanRender.hpp"

#include <memory>
#include <utility>

namespace wallpaper
{

/// Owns whichever renderer is drawing this surface, and never more than one.
///
/// The two backends present to the same `CAMetalLayer`, and a layer has exactly
/// one drawable producer: a Vulkan swapchain and a Metal drawable loop running
/// together would fight over it. This type exists so that invariant is
/// structural rather than a rule someone has to remember — holding one means
/// not holding the other, and switching releases before it acquires.
///
/// The two renderers share their method names deliberately, so this forwards
/// rather than defining a virtual interface. Adding virtuals to `VulkanRender`
/// would put a dispatch on the per-pass path of the backend that draws every
/// wallpaper today, to serve a backend that draws a subset.
class SceneRendererHandle : NoCopy, NoMove {
public:
    SceneRendererHandle(): m_vulkan(std::make_unique<vulkan::VulkanRender>()) {}

    [[nodiscard]] SceneBackend backend() const {
        return m_metal != nullptr ? SceneBackend::NativeMetal : SceneBackend::LegacyVulkan;
    }

    /// The Vulkan renderer, or null when Metal is driving this surface.
    ///
    /// Only for the two entry points Metal has no equivalent of. Everything
    /// else goes through the forwarders, so a caller cannot accidentally reach
    /// past the active backend.
    [[nodiscard]] vulkan::VulkanRender* vulkanOnly() const { return m_vulkan.get(); }

    /// Replaces the Vulkan renderer with a Metal one on the same layer.
    ///
    /// Destroys the Vulkan renderer first: the layer cannot carry a live
    /// swapchain and a Metal drawable at once, and a failure here must not
    /// leave both half-alive. On failure the Vulkan renderer is rebuilt and the
    /// caller re-initialises it, so the surface is never left with no backend.
    [[nodiscard]] bool adoptMetal(const metal::MetalRenderInitInfo& info, std::string& error) {
        if (m_metal != nullptr) return true;
        if (m_vulkan != nullptr) {
            m_vulkan->destroy();
            m_vulkan.reset();
        }
        auto candidate = std::make_unique<metal::MetalRender>();
        if (! candidate->init(info)) {
            error = candidate->lastError();
            candidate.reset();
            m_vulkan = std::make_unique<vulkan::VulkanRender>();
            return false;
        }
        m_metal = std::move(candidate);
        return true;
    }

    /// Returns to the Vulkan backend, destroying the Metal one first.
    void releaseMetal() {
        if (m_metal == nullptr) return;
        m_metal->destroy();
        m_metal.reset();
        m_vulkan = std::make_unique<vulkan::VulkanRender>();
    }

#define OWE_FORWARD(call)                                                                          \
    if (m_metal != nullptr) return m_metal->call;                                                  \
    return m_vulkan->call

    bool inited() const { OWE_FORWARD(inited()); }
    bool init(const RenderInitInfo& info) {
        // Only the Vulkan backend is created from a `RenderInitInfo`; the Metal
        // one is adopted later, once the scene is known to be supported.
        return m_vulkan != nullptr && m_vulkan->init(info);
    }
    void destroy() {
        if (m_metal != nullptr) {
            m_metal->destroy();
            return;
        }
        m_vulkan->destroy();
    }
    bool releaseSurface() { OWE_FORWARD(releaseSurface()); }
    /// Re-establishes the surface after a display reconfiguration.
    ///
    /// The layer is replaced by that reconfiguration, so the Metal backend has
    /// to be told about the new one too. Returns false when the active backend
    /// cannot take the new layer; the caller owns the fallback, because
    /// switching backends carries bookkeeping this type has no business doing
    /// silently.
    bool resetSurface(const RenderInitInfo& info) {
        if (m_metal != nullptr) {
            metal::MetalRenderInitInfo metal_info;
            metal_info.metal_layer          = info.metal_layer;
            metal_info.width                = info.width;
            metal_info.height               = info.height;
            metal_info.render_width         = info.render_width;
            metal_info.render_height        = info.render_height;
            metal_info.display_scale_factor = info.display_scale_factor;
            metal_info.redraw_callback      = info.redraw_callback;
            // Deliberately does NOT fall back here. Switching backends has
            // bookkeeping attached — remembering the failure against the scene,
            // publishing the new backend and its reason, re-applying counters
            // and pause — and a holder that switched silently would leave the
            // panel reporting a backend that is no longer drawing. The caller
            // owns that, through one routine.
            return m_metal->resetSurface(metal_info);
        }
        return m_vulkan != nullptr && m_vulkan->resetSurface(info);
    }

    /// Why the active backend last failed, for the fallback reason shown to
    /// the user. Empty when nothing failed.
    [[nodiscard]] std::string lastError() const {
        if (m_metal != nullptr) return m_metal->lastError();
        return std::string {};
    }
    bool clearLastRenderGraph() { OWE_FORWARD(clearLastRenderGraph()); }
    bool compileRenderGraph(Scene& scene, rg::RenderGraph& graph) {
        OWE_FORWARD(compileRenderGraph(scene, graph));
    }
    bool ApplyRenderScale(Scene& scene, rg::RenderGraph& graph, double scale) {
        OWE_FORWARD(ApplyRenderScale(scene, graph, scale));
    }
    bool   drawFrame(Scene& scene) { OWE_FORWARD(drawFrame(scene)); }
    void   UpdateCameraFillMode(Scene& scene, FillMode mode) {
        OWE_FORWARD(UpdateCameraFillMode(scene, mode));
    }
    void SetWallpaperScalingMode(WallpaperScalingMode mode) {
        OWE_FORWARD(SetWallpaperScalingMode(mode));
    }
    void SetWallpaperScalingFactor(double value) { OWE_FORWARD(SetWallpaperScalingFactor(value)); }
    void SetWallpaperHorizontalFlip(bool value) { OWE_FORWARD(SetWallpaperHorizontalFlip(value)); }
    void SetVideoPlaybackPaused(bool value) { OWE_FORWARD(SetVideoPlaybackPaused(value)); }
    void SetVideoPlaybackRate(float value) { OWE_FORWARD(SetVideoPlaybackRate(value)); }
    double ShortestVideoFramePeriod() const { OWE_FORWARD(ShortestVideoFramePeriod()); }
    uint32_t ShaderUpdateDemandReasons() const { OWE_FORWARD(ShaderUpdateDemandReasons()); }
    void     SetCounters(RendererCounters* counters) { OWE_FORWARD(SetCounters(counters)); }
    WallpaperCursorMapping CursorMapping(const Scene& scene) const {
        OWE_FORWARD(CursorMapping(scene));
    }

#undef OWE_FORWARD

private:
    std::unique_ptr<vulkan::VulkanRender> m_vulkan;
    std::unique_ptr<metal::MetalRender>   m_metal;
};

} // namespace wallpaper
