#pragma once
#include "VulkanPass.hpp"
#include <string>

#include "Vulkan/Device.hpp"
#include "Vulkan/StagingBuffer.hpp"
#include "Vulkan/GraphicsPipeline.hpp"

#include "Scene/Scene.h"
#include "SpecTexs.hpp"

#include <vector>

namespace wallpaper
{
namespace vulkan
{

class FinPass : public VulkanPass {
public:
    struct Desc {
        // in
        const std::string_view result { SpecTex_Default };
        VkFormat               present_format;
        VkImageLayout          present_layout;
        uint32_t               present_queue_index;

        // prepared
        ImageParameters vk_result;
        ImageParameters vk_present;
        VkImageLayout   render_layout;
        VkClearValue    clear_value;

        StagingBufferRef   vertex_buf;
        StagingBufferRef   flipped_vertex_buf;
        PipelineParameters pipeline;
    };

    FinPass(const Desc&);
    virtual ~FinPass();

    void setPresent(ImageParameters);
    void setPresentLayout(VkImageLayout);
    void setPresentFormat(VkFormat);
    void setPresentQueueIndex(uint32_t);

    void prepare(Scene&, const Device&, RenderingResources&) override;
    void execute(const Device&, RenderingResources&) override;
    void destory(const Device&, RenderingResources&) override;

#ifdef WESCENE_BUILD_TESTS
    PipelineParameters& pipelineForTests() { return m_desc.pipeline; }
    void                destroyForTests(RenderingResources& rr) { resetPreparedState(rr); }
#endif

private:
    void resetPreparedState(RenderingResources&);

    struct CachedFramebuffer {
        VkImageView      view {};
        VkRenderPass     render_pass {};
        uint32_t         width { 0 };
        uint32_t         height { 0 };
        vvk::Framebuffer framebuffer;
    };

    vvk::Framebuffer* framebufferForPresent(const Device&, RenderingResources&);

    Desc                           m_desc;
    std::vector<CachedFramebuffer> m_framebuffers;
};

} // namespace vulkan
} // namespace wallpaper
