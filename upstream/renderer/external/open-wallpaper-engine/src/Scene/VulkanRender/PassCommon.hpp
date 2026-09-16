#pragma once
#include "Vulkan/Instance.hpp"
#include "Vulkan/Device.hpp"
#include "Vulkan/Parameters.hpp"
#include "Resource.hpp"
#include "Vulkan/SampleCount.hpp"
#include "Type.hpp"
#include "Vulkan/TextureCache.hpp"
#include "SpecTexs.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneRenderTarget.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

namespace wallpaper
{
namespace vulkan
{
inline void RecordShaderReadBarrier(
    vvk::CommandBuffer& command, const ImageParameters& image,
    VkPipelineStageFlags destination_stages =
        VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT) {
    VkImageMemoryBarrier barrier {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT |
                         VK_ACCESS_SHADER_READ_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = image.layout,
        .newLayout = image.layout,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image.handle,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS,
                             0, VK_REMAINING_ARRAY_LAYERS },
    };
    command.PipelineBarrier(
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT |
            VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        destination_stages, 0, barrier);
}

struct CachedColorFramebuffer {
    VkImageView      view {};
    VkRenderPass     render_pass {};
    uint32_t         width { 0 };
    uint32_t         height { 0 };
    vvk::Framebuffer framebuffer;
};

inline VkResult GetOrCreateColorFramebuffer(
    const Device& device, VkRenderPass pass, const ImageParameters& image,
    std::vector<CachedColorFramebuffer>& cache, VkFramebuffer& out) {
    out = VK_NULL_HANDLE;
    if (pass == VK_NULL_HANDLE || image.view == VK_NULL_HANDLE || image.handle == VK_NULL_HANDLE ||
        image.extent.width == 0 || image.extent.height == 0 || image.extent.depth != 1)
        return VK_ERROR_INITIALIZATION_FAILED;
    for (const auto& cached : cache) {
        if (cached.view == image.view && cached.render_pass == pass &&
            cached.width == image.extent.width && cached.height == image.extent.height) {
            out = *cached.framebuffer;
            return VK_SUCCESS;
        }
    }
    CachedColorFramebuffer cached {
        .view = image.view,
        .render_pass = pass,
        .width = image.extent.width,
        .height = image.extent.height,
    };
    VkFramebufferCreateInfo info {
        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = pass,
        .attachmentCount = 1,
        .pAttachments = &image.view,
        .width = image.extent.width,
        .height = image.extent.height,
        .layers = 1,
    };
    const auto result = device.handle().CreateFramebuffer(info, cached.framebuffer);
    if (result != VK_SUCCESS) return result;
    try {
        cache.push_back(std::move(cached));
    } catch (const std::bad_alloc&) {
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    out = *cache.back().framebuffer;
    return VK_SUCCESS;
}

inline VkViewport ResolvePresentationViewport(const RenderingResources& rr, VkExtent2D extent) {
    if (rr.wallpaper_viewport.width > 0.0f && rr.wallpaper_viewport.height != 0.0f)
        return rr.wallpaper_viewport;
    return VkViewport {
        .x = 0.0f,
        .y = static_cast<float>(extent.height),
        .width = static_cast<float>(extent.width),
        .height = -static_cast<float>(extent.height),
        .minDepth = 0.0f,
        .maxDepth = 1.0f,
    };
}

inline VkRect2D ResolvePresentationScissor(const RenderingResources& rr, VkExtent2D extent) {
    if (rr.wallpaper_scissor.extent.width > 0 && rr.wallpaper_scissor.extent.height > 0)
        return rr.wallpaper_scissor;
    return VkRect2D { { 0, 0 }, extent };
}

inline void SetBlend(BlendMode bm, VkPipelineColorBlendAttachmentState& state) {
    state.blendEnable  = true;
    state.colorBlendOp = VK_BLEND_OP_ADD;
    state.alphaBlendOp = VK_BLEND_OP_ADD;
    switch (bm) {
    case BlendMode::Disable: state.blendEnable = false; break;
    case BlendMode::Normal:
        state.srcColorBlendFactor = VK_BLEND_FACTOR_ONE;
        state.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO;
        state.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        state.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
        break;
    case BlendMode::AlphaToCoverage:
        state.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        state.srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        break;
    case BlendMode::Translucent:
        state.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        // Source-over coverage is As + Ad * (1 - As), not As squared.
        // Squaring it exposes the background along otherwise opaque overlaps.
        state.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        state.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        break;
    case BlendMode::Additive:
        state.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstColorBlendFactor = VK_BLEND_FACTOR_ONE;
        state.srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        state.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        break;
    }
}
inline VkAttachmentLoadOp ResolveAttachmentLoadOp(bool preserve_target_contents,
                                                  bool clear_on_first_use) {
    if (clear_on_first_use) return VK_ATTACHMENT_LOAD_OP_CLEAR;
    if (preserve_target_contents) return VK_ATTACHMENT_LOAD_OP_LOAD;
    return VK_ATTACHMENT_LOAD_OP_DONT_CARE;
}

inline VkClearValue ResolveAttachmentClearValue(bool scene_output,
                                                const std::array<float, 3>& clear_color) {
    if (scene_output) {
        return VkClearValue { .color = { clear_color[0], clear_color[1], clear_color[2], 1.0f } };
    }
    return VkClearValue { .color = { 0.0f, 0.0f, 0.0f, 0.0f } };
}

inline VkSampleCountFlagBits
ResolveCustomPassRenderTargetSampleCount(std::uint32_t requested_sample_count,
                                         VkSampleCountFlags supported_color_samples) {
    return ResolveSampleCount(requested_sample_count, supported_color_samples);
}

inline constexpr i32 kMinRenderTargetDimension = 4;

inline i32 ResolveScreenBoundRenderTargetDimension(double source_dimension, double scale) {
    if (! std::isfinite(source_dimension) || source_dimension <= 0.0) {
        source_dimension = static_cast<double>(kMinRenderTargetDimension);
    }
    if (! std::isfinite(scale) || scale <= 0.0) {
        scale = 1.0;
    }
    return std::max(
        kMinRenderTargetDimension,
        static_cast<i32>(std::lround(scale * source_dimension)));
}

inline void ResolveScreenBoundRenderTargetSize(SceneRenderTarget&      target,
                                               const VkExtent2D&       source_extent) {
    target.width = ResolveScreenBoundRenderTargetDimension(
        static_cast<double>(source_extent.width), target.bind.scale);
    target.height = ResolveScreenBoundRenderTargetDimension(
        static_cast<double>(source_extent.height), target.bind.scale);
}

inline VkExtent2D ResolveSceneSourceExtent(const wallpaper::Scene& scene,
                                           const VkExtent2D&       fallback_extent) {
    auto spec_rt = scene.renderTargets.find(std::string(wallpaper::SpecTex_Default));
    if (spec_rt != scene.renderTargets.end()) {
        if (spec_rt->second.width > 0 && spec_rt->second.height > 0) {
            return {
                static_cast<uint32_t>(spec_rt->second.width),
                static_cast<uint32_t>(spec_rt->second.height),
            };
        }
    }

    const auto ortho_width  = static_cast<uint32_t>(std::max(0, scene.ortho[0]));
    const auto ortho_height = static_cast<uint32_t>(std::max(0, scene.ortho[1]));
    if (ortho_width > 2 && ortho_height > 2) return { ortho_width, ortho_height };

    return {
        std::max(1u, fallback_extent.width),
        std::max(1u, fallback_extent.height),
    };
}

inline VkExtent2D ResolveScreenBoundRenderTargetSizes(Scene&             scene,
                                                      const VkExtent2D&  fallback_extent) {
    const auto source_extent = ResolveSceneSourceExtent(scene, fallback_extent);
    for (auto& item : scene.renderTargets) {
        if (item.first == wallpaper::SpecTex_Default) continue;
        auto& target = item.second;
        if (target.bind.enable && target.bind.screen) {
            ResolveScreenBoundRenderTargetSize(target, source_extent);
        }
    }
    return source_extent;
}

inline void SetAttachmentLoadOp(BlendMode bm, VkAttachmentLoadOp& load_op) {
    switch (bm) {
    case BlendMode::Disable:
    case BlendMode::Normal:
    case BlendMode::AlphaToCoverage: load_op = VK_ATTACHMENT_LOAD_OP_DONT_CARE; break;
    case BlendMode::Additive:
    case BlendMode::Translucent: load_op = VK_ATTACHMENT_LOAD_OP_LOAD; break;
    }
}

inline TextureKey ToTexKey(wallpaper::SceneRenderTarget rt) {
    return TextureKey {
        .width        = rt.width,
        .height       = rt.height,
        .usage        = {},
        .format       = wallpaper::TextureFormat::RGBA8,
        .sample       = rt.sample,
        .mipmap_level = rt.mipmap_level,
        .sample_count = SampleCountFromValue(rt.sample_count),
    };
}

inline TextureKey ToTexKeyMsaa(wallpaper::SceneRenderTarget rt,
                               VkSampleCountFlagBits        sample_count) {
    auto key          = ToTexKey(rt);
    key.usage         = TexUsage::MSAA_COLOR;
    key.mipmap_level  = 1;
    key.sample_count  = sample_count;
    return key;
}
} // namespace vulkan
} // namespace wallpaper
