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
    void releasePresentation(); // Task 2
    void destroy();

    void drawFrame(Scene&);

    bool CreateRenderingResource(RenderingResources&);
    void DestroyRenderingResource(RenderingResources&);

    void clearLastRenderGraph();
    void compileRenderGraph(Scene&, rg::RenderGraph&);
    void UpdateCameraFillMode(Scene&, wallpaper::FillMode);
    void SetWallpaperScalingMode(wallpaper::WallpaperScalingMode);
    void SetWallpaperScalingFactor(double);
    void SetWallpaperHorizontalFlip(bool);

    bool initRes();
    void executePreparedPasses(RenderingResources&);
    void drawFrameSwapchain();
    void drawFrameOffscreen();
    void setRenderTargetSize(Scene&, rg::RenderGraph&);
    void updateScalingLayout(const Scene&, uint32_t output_width, uint32_t output_height);

    Instance                m_instance;
    std::unique_ptr<Device> m_device;

    std::unique_ptr<PrePass> m_prepass { nullptr };
    std::unique_ptr<FinPass> m_finpass { nullptr };

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
};

VulkanRender::VulkanRender(): pImpl(std::make_unique<Impl>()) {}
VulkanRender::~VulkanRender() {};

bool VulkanRender::inited() const { return pImpl->m_inited; }

int VulkanRender::takeLastFrameSyncFd() {
    return pImpl->m_last_sync_fd.exchange(-1, std::memory_order_acq_rel);
}

bool VulkanRender::init(RenderInitInfo info) { return pImpl->init(info); }
void VulkanRender::destroy() { pImpl->destroy(); }
void VulkanRender::releaseSurface() { pImpl->releasePresentation(); }
bool VulkanRender::resetSurface(const RenderInitInfo& info) {
    pImpl->releasePresentation();
    return pImpl->initPresentation(info);
}
void VulkanRender::drawFrame(Scene& scene) { pImpl->drawFrame(scene); };
void VulkanRender::clearLastRenderGraph() { pImpl->clearLastRenderGraph(); };
void VulkanRender::compileRenderGraph(Scene& scene, rg::RenderGraph& rg) {
    pImpl->compileRenderGraph(scene, rg);
};
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
    if (m_inited) return true;
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
    return true;
}

void VulkanRender::Impl::releasePresentation() {
    if (!m_inited) return;

    if (m_device && m_device->handle()) {
        VVK_CHECK(m_device->handle().WaitIdle());
    }

    // Destroy compiled render graph passes (they reference swapchain images).
    for (auto& p : m_passes) {
        p->destory(*m_device, m_rendering_resources);
    }
    m_passes.clear();
    m_pass_loaded = false;

    // Destroy FinPass + PrePass.
    m_finpass.reset();
    m_prepass.reset();

    // Destroy the ex_swapchain (offscreen) or swapchain (surface mode).
    m_ex_swapchain.reset();
    if (m_device) {
        m_device->releaseSwapchain();
    }

    // Destroy the VkSurfaceKHR.
    m_instance.releaseSurface();
    m_with_surface = false;
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
        {
            auto& pool = m_device->cmd_pool();
            VVK_CHECK_BOOL_RE(pool.Allocate(vk_command_num, VK_COMMAND_BUFFER_LEVEL_PRIMARY, m_cmds));
            m_upload_cmd = vvk::CommandBuffer(m_cmds[0], m_device->handle().Dispatch());
            m_render_cmd = vvk::CommandBuffer(m_cmds[1], m_device->handle().Dispatch());
        }
        if (! CreateRenderingResource(m_rendering_resources)) return false;
    }

#if ENABLE_RENDERDOC_API
    load_renderdoc_api();
#endif
    return true;
}

void VulkanRender::Impl::destroy() {
    if (! m_inited) return;
    if (m_device && m_device->handle()) {
        VVK_CHECK(m_device->handle().WaitIdle());

        // res
        for (auto& p : m_passes) {
            p->destory(*m_device, m_rendering_resources);
        }
        m_vertex_buf->destroy();
        m_dyn_buf->destroy();

        m_device->Destroy();
    }
    m_instance.Destroy();
}

bool VulkanRender::Impl::CreateRenderingResource(RenderingResources& rr) {
    rr.command = m_render_cmd;
    VVK_CHECK_BOOL_RE(m_device->handle().CreateFence(
        VkFenceCreateInfo {
            .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = nullptr,
            .flags = VK_FENCE_CREATE_SIGNALED_BIT,
        },
        rr.fence_frame));

    rr.fence_frame.Reset();

    if (m_with_surface) {
        VkSemaphoreCreateInfo ci { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                                   .pNext = nullptr };
        VVK_CHECK_BOOL_RE(m_device->handle().CreateSemaphore(ci, rr.sem_swap_finish));
        VVK_CHECK_BOOL_RE(m_device->handle().CreateSemaphore(ci, rr.sem_swap_wait_image));
    }

    // Exportable SYNC_FD semaphore used by the waywallen-renderer host
    // to ship a dma_fence sync_file to display clients on each
    // FrameReady event. Created in both offscreen and surface modes —
    // only the offscreen drawFrame path currently signals it, but
    // having it always present keeps the lifetime simple.
    {
        VkExportSemaphoreCreateInfo export_info {
            .sType       = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
            .pNext       = nullptr,
            .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT_KHR,
        };
        VkSemaphoreCreateInfo ci {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &export_info,
            .flags = 0,
        };
        VVK_CHECK_BOOL_RE(m_device->handle().CreateSemaphore(ci, rr.sem_export));
    }

    rr.vertex_buf = m_vertex_buf.get();
    rr.dyn_buf    = m_dyn_buf.get();
    return true;
}

void VulkanRender::Impl::DestroyRenderingResource(RenderingResources& rr) {}

// VulkanExSwapchain* VulkanRender::exSwapchain() const { return m_ex_swapchain.get(); }

void VulkanRender::Impl::drawFrame(Scene& scene) {
    if (! (m_inited && m_pass_loaded)) return;

    m_device->tex_cache().CollectCompletedUploads();

    const auto output_extent = m_device->out_extent();
    updateScalingLayout(
        scene, std::max(1u, output_extent.width), std::max(1u, output_extent.height));
    m_rendering_resources.wallpaper_viewport = MakeWallpaperViewport(m_scaling_layout);
    m_rendering_resources.wallpaper_scissor  = MakeWallpaperScissor(m_scaling_layout);
    m_rendering_resources.wallpaper_horizontal_flip = m_horizontal_flip;

    // LOG_INFO("used ram: %fm", (m_device->GetUsage()/1024.0f)/1024.0f);

#if ENABLE_RENDERDOC_API
    if (rdoc_api)
        rdoc_api->StartFrameCapture(
            RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE((VkInstance)m_instance.inst()), NULL);
#endif

    if (m_instance.offscreen()) {
        drawFrameOffscreen();
    } else {
        drawFrameSwapchain();
    }

    if (m_redraw_cb) m_redraw_cb();

#if ENABLE_RENDERDOC_API
    if (rdoc_api)
        rdoc_api->EndFrameCapture(
            RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE((VkInstance)m_instance.inst()), NULL);
#endif
}

void VulkanRender::Impl::executePreparedPasses(RenderingResources& rr) {
    size_t i = 0;
    while (i < m_passes.size()) {
        auto* pass = m_passes[i];
        if (pass == nullptr || ! pass->prepared()) {
            ++i;
            continue;
        }

        auto* custom = dynamic_cast<CustomShaderPass*>(pass);
        if (custom == nullptr) {
            pass->execute(*m_device, rr);
            ++i;
            continue;
        }

        std::vector<CustomShaderPass*>        custom_passes;
        std::vector<CustomPassBatchCandidate> candidates;
        for (; i < m_passes.size(); ++i) {
            auto* run_pass = m_passes[i];
            if (run_pass == nullptr || ! run_pass->prepared()) break;
            auto* run_custom = dynamic_cast<CustomShaderPass*>(run_pass);
            if (run_custom == nullptr) break;

            custom_passes.push_back(run_custom);
            candidates.push_back(run_custom->preRecord(*m_device, rr));
        }

        const auto plan = PlanCustomPassBatches(candidates);
        for (const auto& entry : plan.entries) {
            const size_t first = entry.first;
            const size_t last  = entry.last;
            if (entry.kind == CustomPassBatchKind::ClearImage) {
                custom_passes[first]->recordClear(*m_device, rr);
                continue;
            }

            std::array<VkClearValue, 2> clear_values { entry.render.clear_value, VkClearValue {} };
            VkRenderPassBeginInfo pass_begin_info {
                .sType       = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .pNext       = nullptr,
                .renderPass  = entry.render.render_pass,
                .framebuffer = entry.render.framebuffer,
                .renderArea =
                    VkRect2D {
                        .offset = { 0, 0 },
                        .extent = { entry.render.extent.width, entry.render.extent.height },
                    },
                .clearValueCount = CustomPassBeginRenderPassClearValueCount(entry.render),
                .pClearValues    = clear_values.data(),
            };
            rr.command.BeginRenderPass(pass_begin_info, VK_SUBPASS_CONTENTS_INLINE);

            for (size_t local = first; local < last; ++local) {
                if (! candidates[local].visible) continue;
                custom_passes[local]->recordDraw(*m_device, rr);
            }

            rr.command.EndRenderPass();
        }
    }
}

void VulkanRender::Impl::drawFrameSwapchain() {
    static size_t resource_index = 0;

    RenderingResources& rr = m_rendering_resources;
    resource_index         = (resource_index + 1) % 3;
    uint32_t image_index   = 0;
    {
        VVK_CHECK_VOID_RE(m_device->handle().AcquireNextImageKHR(*m_device->swapchain().handle(),
                                                                 vk_wait_time,
                                                                 *rr.sem_swap_wait_image,
                                                                 {},
                                                                 &image_index));
    }
    const auto& image = m_device->swapchain().images()[image_index];

    m_finpass->setPresent(image);

    // Read back only on a host request, after the final scaling/cropping pass.
    // Never inspect another window or the desktop compositor's contents.
    VmaBufferParameters poster;
    const auto format = m_device->swapchain().format();
    const bool bgra = format == VK_FORMAT_B8G8R8A8_UNORM || format == VK_FORMAT_B8G8R8A8_SRGB;
    const bool rgba = format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_R8G8B8A8_SRGB;
    const size_t poster_size = size_t(image.extent.width) * image.extent.height * 4;
    const bool export_poster = m_poster_ready && m_wants_poster && (bgra || rgba) &&
        m_device->swapchain().supportsReadback() &&
        m_device->graphics_queue().family_index == m_device->present_queue().family_index &&
        poster_size <= 128u * 1024u * 1024u && m_wants_poster() &&
        CreateReadbackBuffer(m_device->vma_allocator(), poster_size, poster);

    (void)rr.command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    m_dyn_buf->recordUpload(rr.command);
    executePreparedPasses(rr);
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
    (void)rr.command.End();

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

    VVK_CHECK_VOID_RE(m_device->present_queue().handle.Submit(sub_info, *rr.fence_frame));
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
    VVK_CHECK(present_result);
    const auto wait_result = rr.fence_frame.Wait(vk_wait_time);
    if (wait_result != VK_SUCCESS) {
        VVK_CHECK(wait_result);
        VVK_CHECK(m_device->handle().WaitIdle());
        return;
    }
    VVK_CHECK_VOID_RE(rr.fence_frame.Reset());
    if (export_poster && (present_result == VK_SUCCESS || present_result == VK_SUBOPTIMAL_KHR)) {
        void* bytes = nullptr;
        if (poster.handle.MapMemory(&bytes) == VK_SUCCESS) {
            if (vmaInvalidateAllocation(m_device->vma_allocator(), poster.handle.Allocation(),
                                        0, VK_WHOLE_SIZE) == VK_SUCCESS) {
                m_poster_ready({ static_cast<const uint8_t*>(bytes), poster_size },
                               image.extent.width, image.extent.height, bgra);
            }
            poster.handle.UnMapMemory();
        }
    }
}
void VulkanRender::Impl::drawFrameOffscreen() {
    RenderingResources& rr    = m_rendering_resources;
    ImageParameters     image = m_ex_swapchain->GetInprogressImage();

    m_finpass->setPresent(image);

    (void)rr.command.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    m_dyn_buf->recordUpload(rr.command);
    executePreparedPasses(rr);

    (void)rr.command.End();

    VkSubmitInfo sub_info {
        .sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext                = nullptr,
        .commandBufferCount   = 1,
        .pCommandBuffers      = rr.command.address(),
        .signalSemaphoreCount = 1,
        .pSignalSemaphores    = rr.sem_export.address(),
    };
    VVK_CHECK_VOID_RE(m_device->graphics_queue().handle.Submit(sub_info, *rr.fence_frame));

    VVK_CHECK_VOID_RE(rr.fence_frame.Wait(vk_wait_time));
    VVK_CHECK_VOID_RE(rr.fence_frame.Reset());

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
        if (m_device->handle().GetSemaphoreFdKHR(gi, &fd) == VK_SUCCESS && fd >= 0) {
            int old = m_last_sync_fd.exchange(fd, std::memory_order_acq_rel);
            if (old >= 0) ::close(old);
        }
    }

    m_ex_swapchain->renderFrame();
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

void VulkanRender::Impl::updateScalingLayout(const Scene& scene, uint32_t output_width,
                                             uint32_t output_height) {
    const double scale_factor  = NormalizeScaleFactor(m_display_scale_factor);
    const auto   source_extent = ResolveSceneSourceExtent(
        scene, { std::max(1u, output_width), std::max(1u, output_height) });
    const uint32_t logical_width = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(output_width) / scale_factor)));
    const uint32_t logical_height = std::max(
        1u, static_cast<uint32_t>(std::lround(static_cast<double>(output_height) / scale_factor)));

    m_scaling_layout = ComputeWallpaperScalingLayout(m_scaling_mode,
                                                     source_extent.width,
                                                     source_extent.height,
                                                     logical_width,
                                                     logical_height,
                                                     scale_factor,
                                                     m_scaling_factor);
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

void VulkanRender::Impl::clearLastRenderGraph() {
    for (auto& p : m_passes) {
        p->destory(*m_device, m_rendering_resources);
    }
    m_passes.clear();
    m_device->tex_cache().Clear();

    m_vertex_buf->destroy();
    m_dyn_buf->destroy();

    m_vertex_buf->allocate();
    m_dyn_buf->allocate();
}

void VulkanRender::Impl::compileRenderGraph(Scene& scene, rg::RenderGraph& rg) {
    if (! m_inited) return;
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

    VVK_CHECK_VOID_RE(m_upload_cmd.Begin(VkCommandBufferBeginInfo {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = nullptr,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    }));
    m_vertex_buf->recordUpload(m_upload_cmd);
    VVK_CHECK_VOID_RE(m_upload_cmd.End());
    {
        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = m_upload_cmd.address(),
        };
        VVK_CHECK_VOID_RE(m_device->graphics_queue().handle.Submit(sub_info, {}));
        VVK_CHECK_VOID_RE(m_device->handle().WaitIdle());
    }
    m_pass_loaded = true;
};
