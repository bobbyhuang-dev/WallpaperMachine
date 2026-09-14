#include "VulkanRender/PassBatch.hpp"

#include <cassert>
#include <cstdint>
#include <vector>

namespace
{
using wallpaper::vulkan::CustomPassBatchCandidate;
using wallpaper::vulkan::CustomPassBatchKind;
using wallpaper::vulkan::CustomPassBatchPlan;
using wallpaper::vulkan::PlanCustomPassBatches;
using wallpaper::vulkan::PlanCustomPassMsaaAttachments;

CustomPassBatchCandidate makeCandidate(uintptr_t image, uintptr_t view, uint32_t width,
                                       bool visible = true) {
    CustomPassBatchCandidate candidate {};
    candidate.batchable           = true;
    candidate.visible             = visible;
    candidate.render.image        = reinterpret_cast<VkImage>(image);
    candidate.render.view         = reinterpret_cast<VkImageView>(view);
    candidate.render.extent       = { width, 64, 1 };
    candidate.render.final_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    candidate.render.load_op      = VK_ATTACHMENT_LOAD_OP_LOAD;
    candidate.render.sample_count = VK_SAMPLE_COUNT_1_BIT;
    candidate.render.render_pass  = reinterpret_cast<VkRenderPass>(0x11);
    candidate.render.framebuffer  = reinterpret_cast<VkFramebuffer>(0x21);
    return candidate;
}

void adjacentVisibleCustomPassesShareOneBatch() {
    std::vector<CustomPassBatchCandidate> candidates {
        makeCandidate(0x100, 0x200, 64),
        makeCandidate(0x100, 0x200, 64),
        makeCandidate(0x100, 0x200, 64),
    };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 1);
    assert(plan.entries[0].kind == CustomPassBatchKind::RenderPass);
    assert(plan.entries[0].first == 0);
    assert(plan.entries[0].last == 3);
    assert(plan.entries[0].visible_draws == 3);
}

void nonCustomBoundarySplitsBatches() {
    std::vector<CustomPassBatchCandidate> candidates {
        makeCandidate(0x100, 0x200, 64),
        CustomPassBatchCandidate { .batchable = false },
        makeCandidate(0x100, 0x200, 64),
    };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 2);
    assert(plan.entries[0].first == 0);
    assert(plan.entries[0].last == 1);
    assert(plan.entries[1].first == 2);
    assert(plan.entries[1].last == 3);
}

void differentOutputsDoNotBatch() {
    std::vector<CustomPassBatchCandidate> candidates {
        makeCandidate(0x100, 0x200, 64),
        makeCandidate(0x101, 0x201, 64),
    };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 2);
    assert(plan.entries[0].visible_draws == 1);
    assert(plan.entries[1].visible_draws == 1);
}

void differentSampleCountsDoNotBatch() {
    auto single_sample = makeCandidate(0x100, 0x200, 64);
    auto four_sample   = makeCandidate(0x100, 0x200, 64);
    four_sample.render.sample_count = VK_SAMPLE_COUNT_4_BIT;

    std::vector<CustomPassBatchCandidate> candidates {
        single_sample,
        four_sample,
    };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 2);
    assert(plan.entries[0].visible_draws == 1);
    assert(plan.entries[1].visible_draws == 1);
}

void differentMsaaSidecarsDoNotBatch() {
    auto first                 = makeCandidate(0x100, 0x200, 64);
    first.render.sample_count  = VK_SAMPLE_COUNT_4_BIT;
    first.render.msaa_image    = reinterpret_cast<VkImage>(0x300);
    first.render.msaa_view     = reinterpret_cast<VkImageView>(0x400);
    auto second                = makeCandidate(0x100, 0x200, 64);
    second.render.sample_count = VK_SAMPLE_COUNT_4_BIT;
    second.render.msaa_image   = reinterpret_cast<VkImage>(0x301);
    second.render.msaa_view    = reinterpret_cast<VkImageView>(0x401);

    std::vector<CustomPassBatchCandidate> candidates {
        first,
        second,
    };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 2);
    assert(plan.entries[0].visible_draws == 1);
    assert(plan.entries[1].visible_draws == 1);
}

void singleSamplePassNeedsOnlyColorAttachment() {
    const auto plan = PlanCustomPassMsaaAttachments(VK_SAMPLE_COUNT_1_BIT);

    assert(! plan.needs_resolve_attachment);
    assert(plan.attachment_count == 1);
    assert(plan.color_samples == VK_SAMPLE_COUNT_1_BIT);
    assert(plan.resolve_samples == VK_SAMPLE_COUNT_1_BIT);
    assert(plan.clear_value_count == 1);
    assert(plan.color_usage == VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
}

void multiSamplePassPlansResolveAttachmentAndClearSlot() {
    const auto plan = PlanCustomPassMsaaAttachments(VK_SAMPLE_COUNT_4_BIT);

    assert(plan.needs_resolve_attachment);
    assert(plan.attachment_count == 2);
    assert(plan.color_samples == VK_SAMPLE_COUNT_4_BIT);
    assert(plan.resolve_samples == VK_SAMPLE_COUNT_1_BIT);
    assert(plan.clear_value_count == 2);
    assert((plan.color_usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) != 0);
    assert((plan.color_usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0);
}

void beginRenderPassClearValueCountFollowsAttachmentPlan() {
    auto single_sample = makeCandidate(0x100, 0x200, 64);
    single_sample.render.sample_count = VK_SAMPLE_COUNT_1_BIT;
    auto four_sample = makeCandidate(0x100, 0x200, 64);
    four_sample.render.sample_count = VK_SAMPLE_COUNT_4_BIT;

    assert(CustomPassBeginRenderPassClearValueCount(single_sample.render) == 1);
    assert(CustomPassBeginRenderPassClearValueCount(four_sample.render) == 2);
}

void framebufferAttachmentViewsFollowAttachmentPlan() {
    auto single_sample                 = makeCandidate(0x100, 0x200, 64);
    single_sample.render.sample_count  = VK_SAMPLE_COUNT_1_BIT;
    single_sample.render.msaa_view     = reinterpret_cast<VkImageView>(0x300);
    auto four_sample                   = makeCandidate(0x100, 0x200, 64);
    four_sample.render.sample_count    = VK_SAMPLE_COUNT_4_BIT;
    four_sample.render.msaa_view       = reinterpret_cast<VkImageView>(0x300);

    const auto single_views = CustomPassFramebufferAttachmentViews(single_sample.render);
    assert(single_views.size() == 1);
    assert(single_views[0] == single_sample.render.view);

    const auto four_views = CustomPassFramebufferAttachmentViews(four_sample.render);
    assert(four_views.size() == 2);
    assert(four_views[0] == four_sample.render.msaa_view);
    assert(four_views[1] == four_sample.render.view);
}

void invisibleClearOnlyPassFoldsIntoNextVisiblePass() {
    auto clear           = makeCandidate(0x100, 0x200, 64, false);
    clear.clear_only     = true;
    clear.render.load_op = VK_ATTACHMENT_LOAD_OP_CLEAR;

    std::vector<CustomPassBatchCandidate> candidates {
        clear,
        makeCandidate(0x100, 0x200, 64),
    };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 1);
    assert(plan.entries[0].kind == CustomPassBatchKind::RenderPass);
    assert(plan.entries[0].first == 0);
    assert(plan.entries[0].last == 2);
    assert(plan.entries[0].visible_draws == 1);
    assert(plan.entries[0].clear_on_begin);
}

void invisibleClearOnlyMsaaPassPlansSidecarClearImage() {
    auto clear                 = makeCandidate(0x100, 0x200, 64, false);
    clear.clear_only           = true;
    clear.render.load_op       = VK_ATTACHMENT_LOAD_OP_CLEAR;
    clear.render.sample_count  = VK_SAMPLE_COUNT_4_BIT;
    clear.render.msaa_image    = reinterpret_cast<VkImage>(0x300);
    clear.render.msaa_view     = reinterpret_cast<VkImageView>(0x400);

    std::vector<CustomPassBatchCandidate> candidates { clear };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 1);
    assert(plan.entries[0].kind == CustomPassBatchKind::ClearImage);
    assert(plan.entries[0].visible_draws == 0);
    assert(plan.entries[0].clear_on_begin);
    assert(plan.entries[0].render.image == clear.render.image);
    assert(plan.entries[0].render.view == clear.render.view);
    assert(plan.entries[0].render.msaa_image == clear.render.msaa_image);
    assert(plan.entries[0].render.msaa_view == clear.render.msaa_view);
    assert(plan.entries[0].render.sample_count == VK_SAMPLE_COUNT_4_BIT);
}

void invisibleClearOnlyMsaaPassFoldsIntoNextVisiblePassWithSameSidecar() {
    auto clear                 = makeCandidate(0x100, 0x200, 64, false);
    clear.clear_only           = true;
    clear.render.load_op       = VK_ATTACHMENT_LOAD_OP_CLEAR;
    clear.render.sample_count  = VK_SAMPLE_COUNT_4_BIT;
    clear.render.msaa_image    = reinterpret_cast<VkImage>(0x300);
    clear.render.msaa_view     = reinterpret_cast<VkImageView>(0x400);

    auto visible                = makeCandidate(0x100, 0x200, 64);
    visible.render.sample_count = VK_SAMPLE_COUNT_4_BIT;
    visible.render.msaa_image   = clear.render.msaa_image;
    visible.render.msaa_view    = clear.render.msaa_view;

    std::vector<CustomPassBatchCandidate> candidates {
        clear,
        visible,
    };

    const CustomPassBatchPlan plan = PlanCustomPassBatches(candidates);

    assert(plan.entries.size() == 1);
    assert(plan.entries[0].kind == CustomPassBatchKind::RenderPass);
    assert(plan.entries[0].first == 0);
    assert(plan.entries[0].last == 2);
    assert(plan.entries[0].visible_draws == 1);
    assert(plan.entries[0].clear_on_begin);
    assert(CustomPassBeginRenderPassClearValueCount(plan.entries[0].render) == 2);
    assert(plan.entries[0].render.msaa_image == clear.render.msaa_image);
    assert(plan.entries[0].render.msaa_view == clear.render.msaa_view);
    assert(plan.entries[0].render.sample_count == VK_SAMPLE_COUNT_4_BIT);
}
} // namespace

int main() {
    adjacentVisibleCustomPassesShareOneBatch();
    nonCustomBoundarySplitsBatches();
    differentOutputsDoNotBatch();
    differentSampleCountsDoNotBatch();
    differentMsaaSidecarsDoNotBatch();
    singleSamplePassNeedsOnlyColorAttachment();
    multiSamplePassPlansResolveAttachmentAndClearSlot();
    beginRenderPassClearValueCountFollowsAttachmentPlan();
    framebufferAttachmentViewsFollowAttachmentPlan();
    invisibleClearOnlyPassFoldsIntoNextVisiblePass();
    invisibleClearOnlyMsaaPassPlansSidecarClearImage();
    invisibleClearOnlyMsaaPassFoldsIntoNextVisiblePassWithSameSidecar();
    return 0;
}
