#include "Scene/SceneRenderTarget.h"
#include "Vulkan/GraphicsPipeline.hpp"
#include "Vulkan/SampleCount.hpp"
#include "Vulkan/TextureCache.hpp"
#include "VulkanRender/Resource.hpp"
#include "VulkanRender/FinPass.hpp"
#include "VulkanRender/PassCommon.hpp"

#include <cassert>

namespace
{
using wallpaper::SceneRenderTarget;
using wallpaper::TextureFilter;
using wallpaper::TextureFormat;
using wallpaper::TextureSample;
using wallpaper::TextureWrap;
using wallpaper::vulkan::ResolveSampleCount;
using wallpaper::vulkan::SampleCountValue;
using wallpaper::vulkan::ResolveCustomPassRenderTargetSampleCount;
using wallpaper::vulkan::TexUsage;
using wallpaper::vulkan::TextureKey;
using wallpaper::vulkan::ToTexKey;

TextureKey makeKey(VkSampleCountFlagBits sample_count) {
    return TextureKey {
        .width        = 64,
        .height       = 64,
        .usage        = TexUsage::COLOR,
        .format       = TextureFormat::RGBA8,
        .sample       = TextureSample {
                  .wrapS     = TextureWrap::CLAMP_TO_EDGE,
                  .wrapT     = TextureWrap::CLAMP_TO_EDGE,
                  .magFilter = TextureFilter::LINEAR,
                  .minFilter = TextureFilter::LINEAR,
              },
        .mipmap_level = 1,
        .sample_count = sample_count,
    };
}

TextureKey makeDepthKey(VkSampleCountFlagBits sample_count) {
    TextureKey key = makeKey(sample_count);
    key.usage      = TexUsage::DEPTH;
    return key;
}

void requestedZeroOrOneResolvesToOne() {
    const auto supported = VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_2_BIT |
                           VK_SAMPLE_COUNT_4_BIT | VK_SAMPLE_COUNT_8_BIT;

    assert(ResolveSampleCount(0, supported) == VK_SAMPLE_COUNT_1_BIT);
    assert(ResolveSampleCount(1, supported) == VK_SAMPLE_COUNT_1_BIT);
}

void requestedAboveSupportedFallsBackToHighestSupported() {
    const auto supported =
        VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_2_BIT | VK_SAMPLE_COUNT_4_BIT;

    assert(ResolveSampleCount(8, supported) == VK_SAMPLE_COUNT_4_BIT);
}

void unsupportedRequestsFallBackToOne() {
    assert(ResolveSampleCount(16, VK_SAMPLE_COUNT_1_BIT) == VK_SAMPLE_COUNT_1_BIT);
}

void sampleCountValueReturnsIntegerSamples() {
    assert(SampleCountValue(VK_SAMPLE_COUNT_1_BIT) == 1);
    assert(SampleCountValue(VK_SAMPLE_COUNT_4_BIT) == 4);
}

void textureKeyHashIncludesSampleCount() {
    const TextureKey single_sample = makeKey(VK_SAMPLE_COUNT_1_BIT);
    const TextureKey four_sample   = makeKey(VK_SAMPLE_COUNT_4_BIT);

    assert(TextureKey::HashValue(single_sample) != TextureKey::HashValue(four_sample));
}

void sceneRenderTargetSampleCountConvertsToTextureKey() {
    const SceneRenderTarget render_target {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };

    const TextureKey key = ToTexKey(render_target);

    assert(key.sample_count == VK_SAMPLE_COUNT_4_BIT);
}

void customPassRenderTargetSampleCountFallsBackToSupportedColorSamples() {
    const auto supported =
        VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_2_BIT | VK_SAMPLE_COUNT_4_BIT;

    assert(ResolveCustomPassRenderTargetSampleCount(8, supported) == VK_SAMPLE_COUNT_4_BIT);
}

void customPassRenderTargetSampleCountFallsBackToSingleSampleWhenUnsupported() {
    assert(ResolveCustomPassRenderTargetSampleCount(4, VK_SAMPLE_COUNT_1_BIT) ==
           VK_SAMPLE_COUNT_1_BIT);
}

void customPassRenderTargetSampleCountPreservesGraphFallbackToSingleSample() {
    const auto supported =
        VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_2_BIT | VK_SAMPLE_COUNT_4_BIT;

    assert(ResolveCustomPassRenderTargetSampleCount(1, supported) == VK_SAMPLE_COUNT_1_BIT);
}

void gpuAllocationSampleCountPlansRequestedSamplesForInternalColorTargets() {
    const TextureKey key = makeKey(VK_SAMPLE_COUNT_4_BIT);

    assert(wallpaper::vulkan::PlannedTextureSampleCountForGpuAllocation(key) ==
           VK_SAMPLE_COUNT_1_BIT);
}

void gpuAllocationSampleCountUsesRequestedSamplesForMsaaSidecars() {
    SceneRenderTarget render_target {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };
    const TextureKey key = wallpaper::vulkan::ToTexKeyMsaa(render_target, VK_SAMPLE_COUNT_4_BIT);

    assert(wallpaper::vulkan::PlannedTextureSampleCountForGpuAllocation(key) ==
           VK_SAMPLE_COUNT_4_BIT);
}

void gpuAllocationSampleCountKeepsDepthSingleSampleInThisSlice() {
    const TextureKey key = makeDepthKey(VK_SAMPLE_COUNT_4_BIT);

    assert(wallpaper::vulkan::PlannedTextureSampleCountForGpuAllocation(key) ==
           VK_SAMPLE_COUNT_1_BIT);
}

void graphicsPipelineStoresRequestedSampleCount() {
    wallpaper::vulkan::GraphicsPipeline pipeline;

    assert(pipeline.sampleCount() == VK_SAMPLE_COUNT_1_BIT);
    pipeline.setSampleCount(VK_SAMPLE_COUNT_4_BIT);
    assert(pipeline.sampleCount() == VK_SAMPLE_COUNT_4_BIT);
    assert(pipeline.multisample.rasterizationSamples == VK_SAMPLE_COUNT_4_BIT);
    pipeline.toDefault();
    assert(pipeline.sampleCount() == VK_SAMPLE_COUNT_1_BIT);
}

void pipelineParametersResetDropsDescriptorLayouts() {
    wallpaper::vulkan::PipelineParameters parameters;

    parameters.descriptor_layouts.emplace_back();
    assert(parameters.descriptor_layouts.size() == 1);

    wallpaper::vulkan::ResetPipelineParameters(parameters);

    assert(parameters.descriptor_layouts.empty());
    assert(! parameters.handle);
    assert(! parameters.layout);
    assert(! parameters.pass);
}

void finPassDestroyResetsPersistentPipelineState() {
    wallpaper::vulkan::FinPass pass(wallpaper::vulkan::FinPass::Desc {});
    pass.pipelineForTests().descriptor_layouts.emplace_back();
    assert(pass.pipelineForTests().descriptor_layouts.size() == 1);

    wallpaper::vulkan::RenderingResources resources {};
    pass.destroyForTests(resources);

    assert(pass.pipelineForTests().descriptor_layouts.empty());
}
} // namespace

int main() {
    requestedZeroOrOneResolvesToOne();
    requestedAboveSupportedFallsBackToHighestSupported();
    unsupportedRequestsFallBackToOne();
    sampleCountValueReturnsIntegerSamples();
    textureKeyHashIncludesSampleCount();
    sceneRenderTargetSampleCountConvertsToTextureKey();
    customPassRenderTargetSampleCountFallsBackToSupportedColorSamples();
    customPassRenderTargetSampleCountFallsBackToSingleSampleWhenUnsupported();
    customPassRenderTargetSampleCountPreservesGraphFallbackToSingleSample();
    gpuAllocationSampleCountPlansRequestedSamplesForInternalColorTargets();
    gpuAllocationSampleCountUsesRequestedSamplesForMsaaSidecars();
    gpuAllocationSampleCountKeepsDepthSingleSampleInThisSlice();
    graphicsPipelineStoresRequestedSampleCount();
    pipelineParametersResetDropsDescriptorLayouts();
    finPassDestroyResetsPersistentPipelineState();
    return 0;
}
