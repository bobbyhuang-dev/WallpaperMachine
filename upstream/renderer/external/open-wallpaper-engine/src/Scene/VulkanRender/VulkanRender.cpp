#include "VulkanRender.hpp"

#include "Utils/Logging.h"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "Interface/IShaderValueUpdater.h"

#include "Utils/Algorism.h"

#include <glslang/Public/ShaderLang.h>

#include "Vulkan/Device.hpp"
#include "Vulkan/TextureCache.hpp"
#include "Vulkan/Swapchain.hpp"
#include "Vulkan/Util.hpp"
#include "Vulkan/VulkanExSwapchain.hpp"

#include "VulkanPass.hpp"
#include "CustomShaderPass.hpp"
#include "PrePass.hpp"
#include "FinPass.hpp"
#include "Resource.hpp"
#include "SpecTexs.hpp"
#include "PassCommon.hpp"

#include "Core/ArrayHelper.hpp"

#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <exception>
#include <unistd.h>
#include <vector>

#if ENABLE_RENDERDOC_API
#    include "RenderDoc.h"
#endif

using namespace wallpaper::vulkan;

constexpr uint64_t vk_wait_time { 10u * 1000u * 1000000u };
constexpr uint32_t vk_command_num { 2 };

constexpr std::array base_inst_exts {
    Extension { false, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME },
};
std::vector<Extension> BaseDeviceExtensions() {
    std::vector<Extension> extensions {
        Extension { false, VK_EXT_MEMORY_BUDGET_EXTENSION_NAME },
        Extension { true, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME },
    };
#if defined(__APPLE__)
    extensions.push_back({ true, "VK_EXT_metal_objects" });
#endif
#if defined(__linux__)
    extensions.push_back({ true, VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME });
    extensions.push_back({ true, VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME });
    extensions.push_back({ true, VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME });
    extensions.push_back({ true, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME });
#endif
    return extensions;
}

namespace
{
const char* WallpaperScalingModeName(wallpaper::WallpaperScalingMode mode) {
    switch (mode) {
    case wallpaper::WallpaperScalingMode::NONE: return "none";
    case wallpaper::WallpaperScalingMode::STRETCH: return "stretch";
    case wallpaper::WallpaperScalingMode::FIT: return "fit";
    case wallpaper::WallpaperScalingMode::FILL: return "fill";
    }

    return "unknown";
}

double NormalizeScaleFactor(double scale_factor) {
    if (! std::isfinite(scale_factor) || scale_factor <= 0.0) return 1.0;
    return scale_factor;
}

} // namespace

struct VulkanRender::Impl {
    Impl()  = default;
    ~Impl() = default;

    bool init(RenderInitInfo);
    bool initDevice(const RenderInitInfo& info);
    bool initPresentation(const RenderInitInfo& info);
    bool releasePresentation();
    void destroy();

    bool drawFrame(Scene&);
    VkResult quiesceFrame(bool wait_for_presentation = false);
    VkResult resetRecordings();
    bool failFrame(VkResult result);

    bool CreateRenderingResource(RenderingResources&);
    void DestroyRenderingResource(RenderingResources&);

    bool clearLastRenderGraph();
    bool compileRenderGraph(Scene&, rg::RenderGraph&);
    void UpdateCameraFillMode(Scene&, wallpaper::FillMode);
    void SetWallpaperScalingMode(wallpaper::WallpaperScalingMode);
    void SetWallpaperScalingFactor(double);
    void SetWallpaperHorizontalFlip(bool);

    bool initRes();
    VkResult executePreparedPasses(RenderingResources&);
    bool drawFrameSwapchain();
    bool drawFrameOffscreen();
    void setRenderTargetSize(Scene&, rg::RenderGraph&);
    void updateScalingLayout(const Scene&, uint32_t output_width, uint32_t output_height);
    WallpaperScalingLayout computeScalingLayout(const Scene&, uint32_t output_width,
                                                uint32_t output_height) const;
    WallpaperCursorMapping CursorMapping(const Scene&) const;

    Instance                m_instance;
    std::unique_ptr<Device> m_device;

    std::unique_ptr<PrePass> m_prepass { nullptr };
    std::unique_ptr<FinPass> m_finpass { nullptr };
    CustomShaderPass* m_direct_present_pass { nullptr };

    std::unique_ptr<FinPass> m_testpass { nullptr };
    ReDrawCB                 m_redraw_cb;
    std::function<bool()> m_wants_poster;
    std::function<void(std::span<const uint8_t>, uint32_t, uint32_t, bool)> m_poster_ready;

    std::unique_ptr<StagingBuffer> m_vertex_buf { nullptr };
    std::unique_ptr<StagingBuffer> m_dyn_buf { nullptr };

    vvk::CommandBuffers m_cmds;
    vvk::CommandBuffer  m_upload_cmd;
    vvk::CommandBuffer  m_render_cmd;

    bool m_with_surface { false };
    bool m_inited { false };
    bool m_pass_loaded { false };
    bool m_frame_faulted { false };
    bool m_device_lost { false };
    bool m_draw_submitted { false };
    bool m_static_upload_submitted { false };
    bool m_draw_recording { false };
    bool m_static_upload_recording { false };
    bool m_destroying { false };
    VmaBufferParameters m_frame_poster;

    std::unique_ptr<VulkanExSwapchain>    m_ex_swapchain;
    RenderingResources                    m_rendering_resources;
    WallpaperScalingLayout                m_scaling_layout {};
    WallpaperScalingMode                  m_scaling_mode { WallpaperScalingMode::FIT };
    double                                m_scaling_factor { 1.0 };
    bool                                  m_horizontal_flip { false };
    double                                m_display_scale_factor { 1.0 };
    VkExtent2D                            m_requested_render_extent {};

    // Exported dma_fence sync_file fd for the most recently completed
    // offscreen frame. Written by drawFrameOffscreen(), consumed by
    // takeLastFrameSyncFd() (called from the host's redraw callback).
    // -1 means no frame has been exported yet. Ownership: the taker.
    std::atomic<int> m_last_sync_fd { -1 };

    std::vector<VulkanPass*> m_passes;
    CustomPassExecutionScratch m_pass_scratch;
};

VulkanRender::VulkanRender(): pImpl(std::make_unique<Impl>()) {}
VulkanRender::~VulkanRender() { destroy(); }

bool VulkanRender::inited() const { return pImpl->m_inited; }

int VulkanRender::takeLastFrameSyncFd() {
    return pImpl->m_last_sync_fd.exchange(-1, std::memory_order_acq_rel);
}

bool VulkanRender::init(RenderInitInfo info) { return pImpl->init(info); }
void VulkanRender::destroy() { pImpl->destroy(); }
bool VulkanRender::releaseSurface() { return pImpl->releasePresentation(); }
bool VulkanRender::resetSurface(const RenderInitInfo& info) {
    if (! pImpl->releasePresentation()) return false;
    return pImpl->initPresentation(info);
}
bool VulkanRender::drawFrame(Scene& scene) { return pImpl->drawFrame(scene); }
bool VulkanRender::clearLastRenderGraph() { return pImpl->clearLastRenderGraph(); }
bool VulkanRender::compileRenderGraph(Scene& scene, rg::RenderGraph& rg) {
    return pImpl->compileRenderGraph(scene, rg);
}
void VulkanRender::UpdateCameraFillMode(Scene& scene, wallpaper::FillMode fill) {
    pImpl->UpdateCameraFillMode(scene, fill);
};
void VulkanRender::SetWallpaperScalingMode(wallpaper::WallpaperScalingMode mode) {
    pImpl->SetWallpaperScalingMode(mode);
}
void VulkanRender::SetWallpaperScalingFactor(double factor) {
    pImpl->SetWallpaperScalingFactor(factor);
}
void VulkanRender::SetWallpaperHorizontalFlip(bool enabled) {
    pImpl->SetWallpaperHorizontalFlip(enabled);
}
wallpaper::WallpaperCursorMapping VulkanRender::CursorMapping(const Scene& scene) const {
    return pImpl->CursorMapping(scene);
}
void VulkanRender::SetVideoPlaybackPaused(bool paused) {
    if (pImpl->m_device != nullptr) {
        pImpl->m_device->tex_cache().SetVideoPlaybackPaused(paused);
    }
}
void VulkanRender::SetVideoPlaybackRate(float rate) {
    if (pImpl->m_device != nullptr) {
        pImpl->m_device->tex_cache().SetVideoPlaybackRate(rate);
    }
}

wallpaper::ExSwapchain* VulkanRender::exSwapchain() const { return pImpl->m_ex_swapchain.get(); };

bool VulkanRender::Impl::init(RenderInitInfo info) {
    if (m_inited) return ! m_frame_faulted && ! m_device_lost;
    if (m_device || m_instance.inst()) destroy();
    if (! initDevice(info)) return false;
    if (! initPresentation(info)) return false;
    m_inited = true;
    return true;
}

bool VulkanRender::Impl::initDevice(const RenderInitInfo& info) {
    m_redraw_cb = info.redraw_callback;

    std::vector<Extension> inst_exts { base_inst_exts.begin(), base_inst_exts.end() };

    if (! info.offscreen) {
        std::transform(info.surface_info.instanceExts.begin(),
                       info.surface_info.instanceExts.end(),
                       std::back_inserter(inst_exts),
                       [](const auto& s) {
                           return Extension { true, s.c_str() };
                       });
    }

    std::vector<InstanceLayer> inst_layers;
    if (info.enable_valid_layer) {
        inst_layers.push_back({ true, VALIDATION_LAYER_NAME });
        LOG_INFO("vulkan valid layer \"%s\" enabled", VALIDATION_LAYER_NAME.data());
    }

    if (! Instance::Create(m_instance, inst_exts, inst_layers)) {
        LOG_ERROR("init vulkan failed");
        return false;
    }
    return true;
}

bool VulkanRender::Impl::initPresentation(const RenderInitInfo& info) {
    if (m_device_lost) return false;
    m_wants_poster = info.wants_poster;
    m_poster_ready = info.poster_ready;
    // Presentation-scoped bookkeeping: these fields are re-read on every
    // surface reconfigure, so they must live here (not in initDevice) to
    // reflect the new display's geometry / scale on each reset.
    m_display_scale_factor    = NormalizeScaleFactor(info.display_scale_factor);
    m_requested_render_extent = { info.render_width, info.render_height };
    VkExtent2D extent { info.width, info.height };
    if (extent.width * extent.height < 500 * 500) {
        LOG_ERROR("too small swapchain image size: %dx%d", extent.width, extent.height);
    } else {
        LOG_INFO("set swapchain image size: %dx%d", extent.width, extent.height);
    }
    LOG_INFO("wallpaper render init: output_px=%ux%u requested_render_px=%ux%u display_scale=%.3f",
             extent.width,
             extent.height,
             m_requested_render_extent.width,
             m_requested_render_extent.height,
             m_display_scale_factor);

    std::vector<Extension> device_exts = BaseDeviceExtensions();

    if (! info.offscreen) {
        device_exts.push_back({ true, VK_KHR_SWAPCHAIN_EXTENSION_NAME });
    } else {
#if defined(__linux__)
        device_exts.push_back({ true, VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME });
        device_exts.push_back({ true, VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME });
        device_exts.push_back({ true, VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME });
#else
        LOG_ERROR("offscreen external-memory rendering is only supported on Linux");
        return false;
#endif
    }

    if (! info.offscreen) {
        VkSurfaceKHR surface;
        VVK_CHECK_ACT(
            {
                LOG_ERROR("create vulkan surface failed");
                return false;
            },
            info.surface_info.createSurfaceOp(*m_instance.inst(), &surface));
        m_instance.setSurface(VkSurfaceKHR(surface));
        m_with_surface = true;
    }

    if (! m_device) {
        {
            auto surface   = *m_instance.surface();
            auto check_gpu = [&device_exts, surface](const vvk::PhysicalDevice& gpu) {
                return Device::CheckGPU(gpu, device_exts, surface);
            };
            if (! m_instance.ChoosePhysicalDevice(check_gpu, info.uuid)) return false;
        }

        {
            m_device = std::make_unique<Device>();
            if (! Device::Create(m_instance, device_exts, extent, *m_device)) {
                LOG_ERROR("init vulkan device failed");
                return false;
            }
        }
    } else {
        // Device already exists — just recreate the swapchain.
        m_device->set_out_extent(extent);
        if (m_with_surface) {
            if (! m_device->recreateSwapchain(*m_instance.surface(), extent)) {
                LOG_ERROR("recreate swapchain failed");
                return false;
            }
        }
    }

    if (info.offscreen) {
        m_ex_swapchain = CreateExSwapchain(*m_device,
                                           extent.width,
                                           extent.height,
                                           (info.offscreen_tiling == TexTiling::OPTIMAL
                                                ? VK_IMAGE_TILING_OPTIMAL
                                                : VK_IMAGE_TILING_LINEAR));
        m_with_surface = false;
    }

    if (! initRes()) return false;
    m_frame_faulted = false;
    return true;
}

VkResult VulkanRender::Impl::resetRecordings() {
    if (m_draw_recording && ! m_draw_submitted) {
        const auto result = m_render_cmd ? m_render_cmd.Reset() : VK_SUCCESS;
        if (result != VK_SUCCESS) return result;
        m_device->tex_cache().AbandonVideoFrameRecording();
        if (m_dyn_buf) m_dyn_buf->finishUpload(false);
        m_draw_recording = false;
        m_frame_poster = {};
    }
    if (m_static_upload_recording && ! m_static_upload_submitted) {
        const auto result = m_upload_cmd ? m_upload_cmd.Reset() : VK_SUCCESS;
        if (result != VK_SUCCESS) return result;
        if (m_vertex_buf) m_vertex_buf->finishUpload(false);
        m_static_upload_recording = false;
    }
    return VK_SUCCESS;
}

VkResult VulkanRender::Impl::quiesceFrame(bool wait_for_presentation) {
    if (! m_device || ! m_device->handle()) return VK_SUCCESS;
    const auto discard_commands = [&]() {
        m_rendering_resources.command = {};
        m_render_cmd = {};
        m_upload_cmd = {};
        m_cmds = {};
    };
    const auto discard_lost_device = [&]() {
        m_frame_faulted = true;
        m_device_lost = true;
        if (m_destroying) discard_commands();
        m_device->tex_cache().DiscardAfterDeviceLoss();
        if (m_vertex_buf) m_vertex_buf->finishUpload(false);
        if (m_dyn_buf) m_dyn_buf->finishUpload(false);
        m_draw_submitted = false;
        m_static_upload_submitted = false;
        m_draw_recording = false;
        m_static_upload_recording = false;
        m_frame_poster = {};
        return VK_ERROR_DEVICE_LOST;
    };
    if (m_device_lost) return discard_lost_device();
    if (wait_for_presentation || m_draw_submitted || m_static_upload_submitted || m_frame_faulted) {
        const auto result = m_device->handle().WaitIdle();
        if (result == VK_ERROR_DEVICE_LOST) return discard_lost_device();
        if (result != VK_SUCCESS) {
            LOG_ERROR("renderer quiescence failed: %s", vvk::ToString(result));
            m_frame_faulted = true;
            m_device->tex_cache().InvalidateVideoDestinationPool();
            return result;
        }
    }
    if (m_destroying) {
        discard_commands();
    } else {
        const auto result = resetRecordings();
        if (result == VK_ERROR_DEVICE_LOST) return discard_lost_device();
        if (result != VK_SUCCESS) {
            LOG_ERROR("discard renderer recording failed: %s", vvk::ToString(result));
            m_frame_faulted = true;
            m_device->tex_cache().InvalidateVideoDestinationPool();
            return result;
        }
    }
    if (m_draw_submitted) {
        m_device->tex_cache().CompleteVideoFrame();
        if (m_dyn_buf) m_dyn_buf->finishUpload(true);
    } else if (m_draw_recording) {
        m_device->tex_cache().AbandonVideoFrameRecording();
        if (m_dyn_buf) m_dyn_buf->finishUpload(false);
    }
    if (m_static_upload_submitted) {
        if (m_vertex_buf) m_vertex_buf->finishUpload(true);
    } else if (m_static_upload_recording) {
        if (m_vertex_buf) m_vertex_buf->finishUpload(false);
    }
    m_draw_submitted = false;
    m_static_upload_submitted = false;
    m_draw_recording = false;
    m_static_upload_recording = false;
    m_frame_poster = {};
    return VK_SUCCESS;
}

bool VulkanRender::Impl::failFrame(VkResult result) {
    LOG_ERROR("renderer frame stopped: %s", vvk::ToString(result));
    m_frame_faulted = true;
    m_device->tex_cache().InvalidateVideoDestinationPool();
    if (result == VK_ERROR_DEVICE_LOST) m_device_lost = true;
    if (m_device_lost || m_draw_submitted || m_static_upload_submitted) {
        const auto idle_result = quiesceFrame();
        if (idle_result != VK_SUCCESS && idle_result != VK_ERROR_DEVICE_LOST)
            LOG_ERROR("renderer retains unfinished frame resources");
    } else {
        const auto reset_result = resetRecordings();
        if (reset_result == VK_ERROR_DEVICE_LOST) {
            m_device_lost = true;
            const auto lost_result = quiesceFrame();
            if (lost_result != VK_ERROR_DEVICE_LOST)
                LOG_ERROR("renderer device-loss cleanup failed");
        } else if (reset_result != VK_SUCCESS) {
            LOG_ERROR("renderer retains failed command recording: %s", vvk::ToString(reset_result));
        }
    }
    return false;
}

bool VulkanRender::Impl::releasePresentation() {
    if (quiesceFrame(true) != VK_SUCCESS) return false;
    m_direct_present_pass = nullptr;
    if (m_device && m_device->handle()) {
        std::string error;
        if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
            LOG_ERROR("cannot release presentation uploads: %s", error.c_str());
            return failFrame(VK_ERROR_UNKNOWN);
        }
        for (auto* command : { &m_render_cmd, &m_upload_cmd }) {
            if (*command) {
                const auto result = command->Reset();
                if (result != VK_SUCCESS) return failFrame(result);
            }
        }
        for (auto* pass : m_passes) {
            if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
        }
        m_passes.clear();
        m_pass_scratch.passes.clear();
        m_pass_scratch.candidates.clear();
        m_pass_scratch.plan.entries.clear();
        if (! m_device->tex_cache().Clear(&error)) {
            LOG_ERROR("cannot clear presentation cache: %s", error.c_str());
            return failFrame(VK_ERROR_UNKNOWN);
        }
    }
    m_pass_loaded = false;
    DestroyRenderingResource(m_rendering_resources);
    m_finpass.reset();
    m_prepass.reset();
    m_ex_swapchain.reset();
    if (m_device) m_device->releaseSwapchain();
    m_instance.releaseSurface();
    m_with_surface = false;
    return true;
}

bool VulkanRender::Impl::initRes() {
    // Presentation-scoped: always recreated.
    m_prepass = std::make_unique<PrePass>(PrePass::Desc {});
    m_finpass = std::make_unique<FinPass>(FinPass::Desc {});
    if (m_with_surface) {
        m_finpass->setPresentFormat(m_device->swapchain().format());
        m_finpass->setPresentQueueIndex(m_device->present_queue().family_index);
        m_finpass->setPresentLayout(VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
    } else {
        m_finpass->setPresentFormat(m_ex_swapchain->format());
        m_finpass->setPresentLayout(VK_IMAGE_LAYOUT_GENERAL);
        m_finpass->setPresentQueueIndex(VK_QUEUE_FAMILY_EXTERNAL);
    }

    // Device-scoped: only allocated on first call.
    if (!m_vertex_buf) {
        m_vertex_buf = std::make_unique<StagingBuffer>(*m_device,
                                                       2 * 1024 * 1024,
                                                       VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                                                           VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        m_dyn_buf    = std::make_unique<StagingBuffer>(*m_device,
                                                    2 * 1024 * 1024,
                                                    VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                                                        VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
                                                        VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        if (! m_vertex_buf->allocate()) return false;
        if (! m_dyn_buf->allocate()) return false;
    }
    if (m_cmds.data() == nullptr) {
        const auto result = m_device->cmd_pool().Allocate(
            vk_command_num, VK_COMMAND_BUFFER_LEVEL_PRIMARY, m_cmds);
        if (result != VK_SUCCESS) return failFrame(result);
        m_upload_cmd = vvk::CommandBuffer(m_cmds[0], m_device->handle().Dispatch());
        m_render_cmd = vvk::CommandBuffer(m_cmds[1], m_device->handle().Dispatch());
    }
    if (! CreateRenderingResource(m_rendering_resources)) return false;

#if ENABLE_RENDERDOC_API
    load_renderdoc_api();
#endif
    return true;
}

void VulkanRender::Impl::destroy() {
    m_destroying = true;
    m_direct_present_pass = nullptr;
    const auto result = quiesceFrame(true);
    if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST) {
        LOG_ERROR("cannot destroy renderer resources before GPU completion");
        std::terminate();
    }
    if (m_device && m_device->handle()) {
        if (! m_device_lost) {
            std::string error;
            if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
                LOG_ERROR("texture upload retirement failed during renderer destruction: %s",
                          error.c_str());
                // The cache destructor checks its remaining slots against device idle.
            }
        }
        for (auto* pass : m_passes) {
            if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
        }
    }
    m_passes.clear();
    m_pass_scratch.passes.clear();
    m_pass_scratch.candidates.clear();
    m_pass_scratch.plan.entries.clear();
    m_prepass.reset();
    m_finpass.reset();
    m_testpass.reset();
    m_ex_swapchain.reset();
    DestroyRenderingResource(m_rendering_resources);
    m_render_cmd = {};
    m_upload_cmd = {};
    m_cmds = {};
    m_frame_poster = {};
    m_vertex_buf.reset();
    m_dyn_buf.reset();
    m_device.reset();
    m_instance.Destroy();
    const int fd = m_last_sync_fd.exchange(-1, std::memory_order_acq_rel);
    if (fd >= 0) ::close(fd);
    m_pass_loaded = false;
    m_inited = false;
    m_with_surface = false;
    m_frame_faulted = false;
    m_device_lost = false;
    m_destroying = false;
}

bool VulkanRender::Impl::CreateRenderingResource(RenderingResources& rr) {
    rr.command = m_render_cmd;
    rr.vertex_buf = m_vertex_buf.get();
    rr.dyn_buf = m_dyn_buf.get();
    const auto fence_result = m_device->handle().CreateFence(
        VkFenceCreateInfo { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO },
        rr.fence_frame);
    if (fence_result != VK_SUCCESS) return failFrame(fence_result);
    VkSemaphoreCreateInfo semaphore { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    if (m_with_surface) {
        auto result = m_device->handle().CreateSemaphore(semaphore, rr.sem_swap_finish);
        if (result != VK_SUCCESS) return failFrame(result);
        result = m_device->handle().CreateSemaphore(semaphore, rr.sem_swap_wait_image);
        if (result != VK_SUCCESS) return failFrame(result);
    }
    // Only offscreen Linux rendering exports SYNC_FD.
    VkExportSemaphoreCreateInfo export_info {
        .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT_KHR,
    };
    if (! m_with_surface) semaphore.pNext = &export_info;
    const auto export_result = m_device->handle().CreateSemaphore(semaphore, rr.sem_export);
    if (export_result != VK_SUCCESS) return failFrame(export_result);
    return true;
}

void VulkanRender::Impl::DestroyRenderingResource(RenderingResources& rr) {
    rr.command = {};
    rr.fence_frame.reset();
    rr.sem_swap_wait_image.reset();
    rr.sem_swap_finish.reset();
    rr.sem_export.reset();
    rr.vertex_buf = nullptr;
    rr.dyn_buf = nullptr;
}

// VulkanExSwapchain* VulkanRender::exSwapchain() const { return m_ex_swapchain.get(); }

bool VulkanRender::Impl::drawFrame(Scene& scene) {
    if (! m_inited || ! m_pass_loaded || m_frame_faulted || m_device_lost) return false;
    if (quiesceFrame() != VK_SUCCESS) return false;

    m_device->tex_cache().CollectCompletedUploads();

    const auto output_extent = m_device->out_extent();
    updateScalingLayout(
        scene, std::max(1u, output_extent.width), std::max(1u, output_extent.height));
    m_rendering_resources.wallpaper_viewport = MakeWallpaperViewport(m_scaling_layout);
    m_rendering_resources.wallpaper_scissor  = MakeWallpaperScissor(m_scaling_layout);
    m_rendering_resources.wallpaper_horizontal_flip = m_horizontal_flip;

    std::string error;
    if (! m_device->tex_cache().BeginVideoFrameRecording(&error)) {
        LOG_ERROR("cannot begin video frame recording: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    m_draw_recording = true;
    if (! UpdatePreparedPasses(*m_device, m_rendering_resources, m_passes))
        return failFrame(VK_ERROR_UNKNOWN);

#if ENABLE_RENDERDOC_API
    if (rdoc_api)
        rdoc_api->StartFrameCapture(
            RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE((VkInstance)m_instance.inst()), NULL);
#endif

    const bool rendered = m_instance.offscreen() ? drawFrameOffscreen() : drawFrameSwapchain();
    if (rendered && m_redraw_cb) m_redraw_cb();

#if ENABLE_RENDERDOC_API
    if (rdoc_api)
        rdoc_api->EndFrameCapture(
            RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE((VkInstance)m_instance.inst()), NULL);
#endif
    return rendered;
}

VkResult VulkanRender::Impl::executePreparedPasses(RenderingResources& rr) {
    return ExecutePreparedPasses(*m_device, rr, m_passes, m_pass_scratch);
}

bool VulkanRender::Impl::drawFrameSwapchain() {

    RenderingResources& rr = m_rendering_resources;
    uint32_t image_index   = 0;
    const auto acquire_result = m_device->handle().AcquireNextImageKHR(
        *m_device->swapchain().handle(), vk_wait_time, *rr.sem_swap_wait_image, {}, &image_index);
    if (acquire_result != VK_SUCCESS && acquire_result != VK_SUBOPTIMAL_KHR)
        return failFrame(acquire_result);
    const auto& image = m_device->swapchain().images()[image_index];

    m_finpass->setPresent(image);

    // Read back only on a host request, after the final scaling/cropping pass.
    // Never inspect another window or the desktop compositor's contents.
    auto& poster = m_frame_poster;
    const auto format = m_device->swapchain().format();
    const bool bgra = format == VK_FORMAT_B8G8R8A8_UNORM || format == VK_FORMAT_B8G8R8A8_SRGB;
    const bool rgba = format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_R8G8B8A8_SRGB;
    const size_t poster_size = size_t(image.extent.width) * image.extent.height * 4;
    const bool export_poster = m_poster_ready && m_wants_poster && (bgra || rgba) &&
        m_device->swapchain().supportsReadback() &&
        m_device->graphics_queue().family_index == m_device->present_queue().family_index &&
        poster_size <= 128u * 1024u * 1024u && m_wants_poster();
    if (export_poster && ! CreateReadbackBuffer(m_device->vma_allocator(), poster_size, poster))
        return failFrame(VK_ERROR_OUT_OF_DEVICE_MEMORY);

    const auto begin_result = rr.command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (begin_result != VK_SUCCESS) return failFrame(begin_result);
    if (! m_dyn_buf->recordUpload(rr.command)) return failFrame(VK_ERROR_UNKNOWN);
    VkResult execute_result = VK_SUCCESS;
    if (m_direct_present_pass != nullptr &&
        m_direct_present_pass->canPresentDirectly(
            rr, { image.extent.width, image.extent.height }, format)) {
        execute_result = m_direct_present_pass->executePresentation(*m_device, rr, image, format);
        if (execute_result == VK_SUCCESS) {
            VkImageMemoryBarrier barrier {
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                .dstAccessMask = 0,
                .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = image.handle,
                .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
            };
            rr.command.PipelineBarrier(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                       VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, barrier);
        }
    } else {
        execute_result = executePreparedPasses(rr);
    }
    if (execute_result != VK_SUCCESS) return failFrame(execute_result);
    if (export_poster) {
        VkImageMemoryBarrier barrier {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = image.handle,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                   VK_PIPELINE_STAGE_TRANSFER_BIT, 0, barrier);
        VkBufferImageCopy region {
            .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
            .imageExtent = image.extent,
        };
        rr.command.CopyImageToBuffer(image.handle, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                     *poster.handle, spanone { region });
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = 0;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                                   VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, barrier);
        VkBufferMemoryBarrier host_barrier {
            .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = *poster.handle,
            .offset = 0,
            .size = VK_WHOLE_SIZE,
        };
        rr.command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                                   VK_PIPELINE_STAGE_HOST_BIT, 0, host_barrier);
    }
    const auto end_result = rr.command.End();
    if (end_result != VK_SUCCESS) return failFrame(end_result);

    VkPipelineStageFlags wait_dst_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo         sub_info {
                .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .pNext                = nullptr,
                .waitSemaphoreCount   = 1,
                .pWaitSemaphores      = rr.sem_swap_wait_image.address(),
                .pWaitDstStageMask    = &wait_dst_stage,
                .commandBufferCount   = 1,
                .pCommandBuffers      = rr.command.address(),
                .signalSemaphoreCount = 1,
                .pSignalSemaphores    = rr.sem_swap_finish.address(),
    };

    const auto submit_result = m_device->graphics_queue().handle.Submit(sub_info, *rr.fence_frame);
    if (submit_result != VK_SUCCESS) return failFrame(submit_result);
    m_draw_submitted = true;
    m_device->tex_cache().MarkVideoFrameSubmitted();
    VkPresentInfoKHR present_info {
        .sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext              = nullptr,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores    = rr.sem_swap_finish.address(),
        .swapchainCount     = 1,
        .pSwapchains        = m_device->swapchain().handle().address(),
        .pImageIndices      = &image_index,
    };
    // Even an out-of-date surface must finish the submitted copy before its
    // temporary readback buffer is destroyed.
    const auto present_result = m_device->present_queue().handle.Present(present_info);
    const auto wait_result = rr.fence_frame.Wait(vk_wait_time);
    if (wait_result != VK_SUCCESS) return failFrame(wait_result);
    m_device->tex_cache().CompleteVideoFrame();
    m_dyn_buf->finishUpload(true);
    m_draw_submitted = false;
    m_draw_recording = false;
    if (present_result != VK_SUCCESS && present_result != VK_SUBOPTIMAL_KHR)
        return failFrame(present_result);
    const auto reset_result = rr.fence_frame.Reset();
    if (reset_result != VK_SUCCESS) return failFrame(reset_result);
    if (export_poster) {
        void* bytes = nullptr;
        const auto map_result = poster.handle.MapMemory(&bytes);
        if (map_result != VK_SUCCESS) return failFrame(map_result);
        const auto invalidate_result = vmaInvalidateAllocation(
            m_device->vma_allocator(), poster.handle.Allocation(), 0, VK_WHOLE_SIZE);
        if (invalidate_result == VK_SUCCESS) {
            m_poster_ready({ static_cast<const uint8_t*>(bytes), poster_size },
                           image.extent.width, image.extent.height, bgra);
        }
        poster.handle.UnMapMemory();
        if (invalidate_result != VK_SUCCESS) return failFrame(invalidate_result);
    }
    m_frame_poster = {};
    return true;
}
bool VulkanRender::Impl::drawFrameOffscreen() {
    RenderingResources& rr    = m_rendering_resources;
    ImageParameters     image = m_ex_swapchain->GetInprogressImage();

    m_finpass->setPresent(image);

    const auto begin_result = rr.command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (begin_result != VK_SUCCESS) return failFrame(begin_result);
    if (! m_dyn_buf->recordUpload(rr.command)) return failFrame(VK_ERROR_UNKNOWN);
    const auto execute_result = executePreparedPasses(rr);
    if (execute_result != VK_SUCCESS) return failFrame(execute_result);

    const auto end_result = rr.command.End();
    if (end_result != VK_SUCCESS) return failFrame(end_result);

    VkSubmitInfo sub_info {
        .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext                = nullptr,
        .commandBufferCount   = 1,
        .pCommandBuffers      = rr.command.address(),
        .signalSemaphoreCount = 1,
        .pSignalSemaphores    = rr.sem_export.address(),
    };
    const auto submit_result = m_device->graphics_queue().handle.Submit(sub_info, *rr.fence_frame);
    if (submit_result != VK_SUCCESS) return failFrame(submit_result);
    m_draw_submitted = true;
    m_device->tex_cache().MarkVideoFrameSubmitted();
    const auto wait_result = rr.fence_frame.Wait(vk_wait_time);
    if (wait_result != VK_SUCCESS) return failFrame(wait_result);
    m_device->tex_cache().CompleteVideoFrame();
    m_dyn_buf->finishUpload(true);
    m_draw_submitted = false;
    m_draw_recording = false;
    const auto reset_result = rr.fence_frame.Reset();
    if (reset_result != VK_SUCCESS) return failFrame(reset_result);

    // Export the signaled semaphore as a dma_fence sync_file fd. The
    // export resets the semaphore's payload, so the next submit can
    // signal it again. Stored in an atomic slot that the host reads in
    // send_frame_ready_locked via takeLastFrameSyncFd().
    {
        int                     fd = -1;
        VkSemaphoreGetFdInfoKHR gi {
            .sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .pNext      = nullptr,
            .semaphore  = *rr.sem_export,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT_KHR,
        };
        const auto export_result = m_device->handle().GetSemaphoreFdKHR(gi, &fd);
        if (export_result != VK_SUCCESS) return failFrame(export_result);
        if (fd < 0) return failFrame(VK_ERROR_INVALID_EXTERNAL_HANDLE);
        int old = m_last_sync_fd.exchange(fd, std::memory_order_acq_rel);
        if (old >= 0) ::close(old);
    }

    m_ex_swapchain->renderFrame();
    return true;
}

void VulkanRender::Impl::setRenderTargetSize(Scene& scene, rg::RenderGraph& rg) {
    auto&      ext           = m_device->out_extent();
    const auto source_extent = ResolveScreenBoundRenderTargetSizes(scene, ext);
    for (auto& item : scene.renderTargets) {
        auto& rt = item.second;
        if (rt.bind.screen || ! rt.bind.enable) continue;
        auto bind_rt = scene.renderTargets.find(rt.bind.name);
        if (rt.bind.name.empty() || bind_rt == scene.renderTargets.end()) {
            LOG_ERROR("unknonw render target bind: %s", rt.bind.name.c_str());
            continue;
        }
        rt.width  = (i32)(rt.bind.scale * bind_rt->second.width);
        rt.height = (i32)(rt.bind.scale * bind_rt->second.height);
    }
    for (auto& item : scene.renderTargets) {
        auto& rt = item.second;
        if (! item.first.empty() && (rt.width * rt.height <= 4)) {
            LOG_ERROR("wrong size for render target: %s", item.first.c_str());
        } else if (rt.has_mipmap) {
            rt.mipmap_level =
                std::max(3u,
                         static_cast<uint>(std::floor(std::log2(std::min(rt.width, rt.height))))) -
                2u;
        }
    }
    scene.shaderValueUpdater->SetScreenSize(static_cast<i32>(source_extent.width),
                                            static_cast<i32>(source_extent.height));
}

wallpaper::WallpaperScalingLayout
VulkanRender::Impl::computeScalingLayout(const Scene& scene, uint32_t output_width,
                                         uint32_t output_height) const {
    const double scale_factor  = NormalizeScaleFactor(m_display_scale_factor);
    const auto   source_extent = ResolveSceneSourceExtent(
        scene, { std::max(1u, output_width), std::max(1u, output_height) });
    const uint32_t logical_width = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(output_width) / scale_factor)));
    const uint32_t logical_height = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(output_height) / scale_factor)));

    return ComputeWallpaperScalingLayout(m_scaling_mode,
                                         source_extent.width,
                                         source_extent.height,
                                         logical_width,
                                         logical_height,
                                         scale_factor,
                                         m_scaling_factor);
}

void VulkanRender::Impl::updateScalingLayout(const Scene& scene, uint32_t output_width,
                                             uint32_t output_height) {
    m_scaling_layout = computeScalingLayout(scene, output_width, output_height);
}

wallpaper::WallpaperCursorMapping VulkanRender::Impl::CursorMapping(const Scene& scene) const {
    if (! m_inited || m_device == nullptr) return {};
    const auto extent = m_device->out_extent();
    if (extent.width == 0 || extent.height == 0) return {};

    const auto camera = scene.cameras.find("global");
    if (camera == scene.cameras.end() || camera->second == nullptr) return {};

    const auto position = camera->second->GetPosition();
    return ComputeWallpaperCursorMapping(computeScalingLayout(scene, extent.width, extent.height),
                                         position.x(),
                                         position.y(),
                                         camera->second->Width(),
                                         camera->second->Height());
}

void VulkanRender::Impl::UpdateCameraFillMode(wallpaper::Scene&   scene,
                                              wallpaper::FillMode fillmode) {
    using namespace wallpaper;
    auto width  = m_device->out_extent().width;
    auto height = m_device->out_extent().height;

    if (width == 0) return;
    double sw = scene.ortho[0], sh = scene.ortho[1];
    double fboAspect = width / (double)height, sAspect = sw / sh;
    auto&  gCam    = *scene.cameras.at("global");
    auto&  gPerCam = *scene.cameras.at("global_perspective");
    // assum cam
    switch (fillmode) {
    case FillMode::STRETCH:
        gCam.SetWidth(sw);
        gCam.SetHeight(sh);
        gPerCam.SetAspect(sAspect);
        gPerCam.SetFov(algorism::CalculatePersperctiveFov(1000.0f, gCam.Height()));
        break;
    case FillMode::ASPECTFIT:
        if (fboAspect < sAspect) {
            // scale height
            gCam.SetWidth(sw);
            gCam.SetHeight(sw / fboAspect);
        } else {
            gCam.SetWidth(sh * fboAspect);
            gCam.SetHeight(sh);
        }
        gPerCam.SetAspect(fboAspect);
        gPerCam.SetFov(algorism::CalculatePersperctiveFov(1000.0f, gCam.Height()));
        break;
    case FillMode::ASPECTCROP:
    default:
        if (fboAspect > sAspect) {
            // scale height
            gCam.SetWidth(sw);
            gCam.SetHeight(sw / fboAspect);
        } else {
            gCam.SetWidth(sh * fboAspect);
            gCam.SetHeight(sh);
        }
        gPerCam.SetAspect(fboAspect);
        gPerCam.SetFov(algorism::CalculatePersperctiveFov(1000.0f, gCam.Height()));
        break;
    }
    gCam.Update();
    gPerCam.Update();
    scene.UpdateLinkedCamera("global");
}

void VulkanRender::Impl::SetWallpaperScalingMode(wallpaper::WallpaperScalingMode mode) {
    m_scaling_mode = mode;
    LOG_INFO("wallpaper scaling mode: %s", WallpaperScalingModeName(m_scaling_mode));
}

void VulkanRender::Impl::SetWallpaperScalingFactor(double factor) {
    m_scaling_factor = NormalizeScaleFactor(factor);
    LOG_INFO("wallpaper scaling factor: %.3f", m_scaling_factor);
}

void VulkanRender::Impl::SetWallpaperHorizontalFlip(bool enabled) {
    m_horizontal_flip = enabled;
    LOG_INFO("wallpaper horizontal flip: %s", m_horizontal_flip ? "enabled" : "disabled");
}

bool VulkanRender::Impl::clearLastRenderGraph() {
    if (quiesceFrame() != VK_SUCCESS) return false;
    m_direct_present_pass = nullptr;
    if (! m_device || ! m_device->handle()) return m_passes.empty();
    std::string error;
    if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
        LOG_ERROR("cannot clear render graph uploads: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    for (auto* command : { &m_render_cmd, &m_upload_cmd }) {
        if (*command) {
            const auto result = command->Reset();
            if (result != VK_SUCCESS) return failFrame(result);
        }
    }
    for (auto* pass : m_passes) {
        if (pass != nullptr) pass->destory(*m_device, m_rendering_resources);
    }
    m_passes.clear();
    m_pass_scratch.passes.clear();
    m_pass_scratch.candidates.clear();
    m_pass_scratch.plan.entries.clear();
    m_pass_loaded = false;
    if (! m_device->tex_cache().Clear(&error)) {
        LOG_ERROR("cannot clear render graph cache: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    if (! m_vertex_buf || ! m_dyn_buf) return false;
    m_vertex_buf->destroy();
    m_dyn_buf->destroy();
    const bool vertex_allocated = m_vertex_buf->allocate();
    const bool dynamic_allocated = m_dyn_buf->allocate();
    return vertex_allocated && dynamic_allocated;
}

bool VulkanRender::Impl::compileRenderGraph(Scene& scene, rg::RenderGraph& rg) {
    if (! m_inited || m_device_lost || m_frame_faulted) return false;
    if (! m_passes.empty() && ! clearLastRenderGraph()) return false;
    m_direct_present_pass = nullptr;
    if (quiesceFrame() != VK_SUCCESS) return false;
    std::string error;
    if (! m_device->tex_cache().WaitForPendingUploads(&error)) {
        LOG_ERROR("cannot compile render graph with pending uploads: %s", error.c_str());
        return failFrame(VK_ERROR_UNKNOWN);
    }
    m_pass_scratch.passes.clear();
    m_pass_scratch.candidates.clear();
    m_pass_scratch.plan.entries.clear();
    m_pass_loaded = false;

    auto nodes             = rg.topologicalOrder();
    auto node_release_texs = rg.getLastReadTexs(nodes);

    m_passes.clear();
    m_passes.resize(nodes.size());

    std::transform(nodes.begin(),
                   nodes.end(),
                   node_release_texs.begin(),
                   m_passes.begin(),
                   [&rg](auto& id, auto& texs) {
                       auto* pass = rg.getPass(id);
                       assert(pass != nullptr);
                       VulkanPass* vpass = static_cast<VulkanPass*>(pass);
                       // LOG_INFO("----release tex");
                       for (auto& tex : texs) {
                           vpass->addReleaseTexs(spanone<const std::string_view> { tex->key() });
                           //    LOG_INFO("%s", tex->key().data());
                       }
                       return vpass;
                   });

    for (auto* pass : m_passes) {
        if (auto* custom = dynamic_cast<CustomShaderPass*>(pass))
            custom->desc().presentation_format = VK_FORMAT_UNDEFINED;
    }
    if (m_with_surface && ! m_instance.offscreen() &&
        m_device->graphics_queue().family_index == m_device->present_queue().family_index) {
        const auto format = m_device->swapchain().format();
        if (format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_B8G8R8A8_UNORM) {
            m_direct_present_pass = FindDirectPresentationPass(scene, m_passes);
            if (m_direct_present_pass != nullptr)
                m_direct_present_pass->desc().presentation_format = format;
        }
    }

    m_passes.insert(m_passes.begin(), m_prepass.get());
    m_passes.push_back(m_finpass.get());

    setRenderTargetSize(scene, rg);

    glslang::InitializeProcess();
    for (auto* p : m_passes) {
        if (! p->prepared()) {
            p->prepare(scene, *m_device, m_rendering_resources);
        }
    }
    glslang::FinalizeProcess();
    if (std::any_of(m_passes.begin(), m_passes.end(),
                    [](const auto* pass) { return pass == nullptr || ! pass->prepared(); }))
        return false;

    m_static_upload_recording = true;
    const auto begin_result = m_upload_cmd.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    if (begin_result != VK_SUCCESS) return failFrame(begin_result);
    if (! m_vertex_buf->recordUpload(m_upload_cmd)) return failFrame(VK_ERROR_UNKNOWN);
    const auto end_result = m_upload_cmd.End();
    if (end_result != VK_SUCCESS) return failFrame(end_result);
    {
        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = m_upload_cmd.address(),
        };
        const auto submit_result = m_device->graphics_queue().handle.Submit(sub_info, {});
        if (submit_result != VK_SUCCESS) return failFrame(submit_result);
        m_static_upload_submitted = true;
        const auto idle_result = quiesceFrame();
        if (idle_result != VK_SUCCESS) return false;
    }
    m_pass_loaded = true;
    return true;
};
