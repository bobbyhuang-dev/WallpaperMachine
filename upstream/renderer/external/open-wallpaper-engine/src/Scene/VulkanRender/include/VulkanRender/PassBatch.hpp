#pragma once

#ifndef VK_NO_PROTOTYPES
#    define VK_NO_PROTOTYPES
#endif
#include <vulkan/vulkan.h>

#include <algorithm>
#include <array>
#include <span>
#include <vector>

namespace wallpaper
{
class Scene;
namespace vulkan
{

struct CustomPassRenderInfo {
    VkImage            image {};
    VkImageView        view {};
    VkImage            msaa_image {};
    VkImageView        msaa_view {};
    VkImage            depth_image {};
    VkImageView        depth_view {};
    bool               with_depth { false };
    VkExtent3D         extent {};
    VkImageLayout      final_layout { VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkAttachmentLoadOp load_op { VK_ATTACHMENT_LOAD_OP_DONT_CARE };
    VkSampleCountFlagBits sample_count { VK_SAMPLE_COUNT_1_BIT };
    VkRenderPass       render_pass {};
    VkFramebuffer      framebuffer {};
    VkClearValue       clear_value {};
};

struct CustomPassBatchCandidate {
    bool                 batchable { false };
    bool                 visible { false };
    bool                 clear_only { false };
    CustomPassRenderInfo render {};
};

enum class CustomPassBatchKind
{
    RenderPass,
    ClearImage,
};

struct CustomPassBatchEntry {
    CustomPassBatchKind  kind { CustomPassBatchKind::RenderPass };
    size_t               first { 0 };
    size_t               last { 0 };
    uint32_t             visible_draws { 0 };
    bool                 clear_on_begin { false };
    CustomPassRenderInfo render {};
};

struct CustomPassBatchPlan {
    std::vector<CustomPassBatchEntry> entries;
};

class Device;
class VulkanPass;
class CustomShaderPass;
struct RenderingResources;

struct CustomPassExecutionScratch {
    std::vector<CustomShaderPass*> passes;
    std::vector<CustomPassBatchCandidate> candidates;
    CustomPassBatchPlan plan;
};

bool UpdatePreparedPasses(const Device&, RenderingResources&, std::span<VulkanPass* const>);
VkResult ExecutePreparedPasses(const Device&, RenderingResources&, std::span<VulkanPass* const>,
                              CustomPassExecutionScratch&);
CustomShaderPass* FindDirectPresentationPass(Scene&, std::span<VulkanPass* const> graph_passes);

struct CustomPassMsaaAttachmentPlan {
    bool                  needs_resolve_attachment { false };
    bool                  has_depth { false };
    uint32_t              attachment_count { 1 };
    VkSampleCountFlagBits color_samples { VK_SAMPLE_COUNT_1_BIT };
    VkSampleCountFlagBits resolve_samples { VK_SAMPLE_COUNT_1_BIT };
    uint32_t              clear_value_count { 1 };
    VkImageUsageFlags     color_usage { VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
};

inline CustomPassMsaaAttachmentPlan
PlanCustomPassMsaaAttachments(VkSampleCountFlagBits color_samples) {
    if (color_samples == VK_SAMPLE_COUNT_1_BIT) return {};

    return CustomPassMsaaAttachmentPlan {
        .needs_resolve_attachment = true,
        .attachment_count         = 2,
        .color_samples            = color_samples,
        .resolve_samples          = VK_SAMPLE_COUNT_1_BIT,
        .clear_value_count        = 2,
        .color_usage              = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                       VK_IMAGE_USAGE_TRANSFER_DST_BIT,
    };
}

inline CustomPassMsaaAttachmentPlan
PlanCustomPassAttachments(VkSampleCountFlagBits color_samples, bool with_depth) {
    auto plan = PlanCustomPassMsaaAttachments(color_samples);
    if (with_depth) {
        plan.has_depth = true;
        plan.attachment_count += 1;
        plan.clear_value_count += 1;
    }
    return plan;
}

inline uint32_t
CustomPassBeginRenderPassClearValueCount(const CustomPassRenderInfo& render) {
    return PlanCustomPassAttachments(render.sample_count, render.with_depth).clear_value_count;
}

inline void FillCustomPassClearValues(const CustomPassRenderInfo& render,
                                      std::array<VkClearValue, 3>& out) {
    out = {};
    out[0] = render.clear_value;
    if (! render.with_depth) return;
    const auto count = CustomPassBeginRenderPassClearValueCount(render);
    if (count == 0) return;
    out[count - 1].depthStencil = { 1.0f, 0 };
}

struct CustomPassFramebufferAttachmentViewList {
    std::array<VkImageView, 3> views {};
    uint32_t                   count { 0 };

    uint32_t size() const { return count; }
    const VkImageView* data() const { return views.data(); }
    VkImageView operator[](uint32_t index) const { return views[index]; }
};

inline CustomPassFramebufferAttachmentViewList
CustomPassFramebufferAttachmentViews(const CustomPassRenderInfo& render) {
    const auto plan = PlanCustomPassAttachments(render.sample_count, render.with_depth);
    CustomPassFramebufferAttachmentViewList list;
    list.views[0] = plan.needs_resolve_attachment ? render.msaa_view : render.view;
    uint32_t count = 1;
    if (plan.needs_resolve_attachment) list.views[count++] = render.view;
    if (plan.has_depth) list.views[count++] = render.depth_view;
    list.count = count;
    return list;
}

inline bool CompatibleCustomPassAttachments(const CustomPassRenderInfo& a,
                                            const CustomPassRenderInfo& b) {
    if (a.image != b.image || a.view != b.view || a.extent.width != b.extent.width ||
        a.extent.height != b.extent.height || a.extent.depth != b.extent.depth ||
        a.final_layout != b.final_layout || a.sample_count != b.sample_count) {
        return false;
    }

    if (a.with_depth != b.with_depth || a.depth_image != b.depth_image ||
        a.depth_view != b.depth_view)
        return false;
    if (a.sample_count == VK_SAMPLE_COUNT_1_BIT) return true;
    return a.msaa_image == b.msaa_image && a.msaa_view == b.msaa_view;
}

inline void PlanCustomPassBatches(std::span<const CustomPassBatchCandidate> candidates,
                                  CustomPassBatchPlan& plan) {
    plan.entries.clear();
    plan.entries.reserve(candidates.size());

    for (size_t i = 0; i < candidates.size();) {
        const auto& first = candidates[i];
        if (! first.batchable) {
            ++i;
            continue;
        }

        if (! first.visible && ! first.clear_only) {
            ++i;
            continue;
        }

        CustomPassBatchEntry entry {};
        entry.first  = i;
        entry.last   = i + 1;
        entry.render = first.render;
        entry.clear_on_begin =
            first.clear_only || first.render.load_op == VK_ATTACHMENT_LOAD_OP_CLEAR;
        entry.visible_draws = first.visible ? 1u : 0u;

        if (! first.visible && first.clear_only) {
            entry.kind = CustomPassBatchKind::ClearImage;
        }

        for (size_t j = i + 1; j < candidates.size(); ++j) {
            const auto& candidate = candidates[j];
            if (! candidate.batchable ||
                ! CompatibleCustomPassAttachments(entry.render, candidate.render)) {
                break;
            }

            if (entry.visible_draws > 0 && candidate.clear_only && ! candidate.visible) {
                break;
            }

            if (entry.visible_draws > 0 && candidate.visible &&
                candidate.render.load_op == VK_ATTACHMENT_LOAD_OP_CLEAR) {
                break;
            }

            entry.last = j + 1;
            if (candidate.visible) {
                entry.kind = CustomPassBatchKind::RenderPass;
                ++entry.visible_draws;
            }
            if (candidate.clear_only || candidate.render.load_op == VK_ATTACHMENT_LOAD_OP_CLEAR) {
                entry.clear_on_begin = true;
                if (entry.visible_draws == 0) {
                    entry.render = candidate.render;
                }
            }
        }

        if (entry.visible_draws > 0) {
            entry.kind = CustomPassBatchKind::RenderPass;
        } else if (! first.clear_only) {
            ++i;
            continue;
        }

        plan.entries.push_back(entry);
        i = std::max(entry.last, i + 1);
    }
}

} // namespace vulkan
} // namespace wallpaper
