#include "Scene/include/Scene/SceneUpdateDemand.hpp"

#include "VulkanRender/StaticSubgraphCache.hpp"

namespace wallpaper
{

uint32_t SceneDemandReasonsFromShaderInputs(uint32_t shader_reasons)
{
    // Maps the renderer's per-pass reflection vocabulary onto the scene-level
    // one. Two of the renderer's reasons are deliberately NOT carried over:
    //
    // - `PointerUniform`: a pointer-reactive scene is event-driven, not
    //   continuously changing. It sleeps until the pointer moves, and the
    //   pointer path wakes it.
    // - `RuntimeImage`: an image the runtime may swap is a change that arrives
    //   as an event, and the code that swaps it requests a frame.
    //
    // Both of those still make a render target ineligible for pixel reuse,
    // which is a different question answered elsewhere. Every other reason
    // means something advances on its own and the clock has to keep running.
    using vulkan::DynamicReason;
    uint32_t reasons = 0;
    if (shader_reasons & DynamicReason::TimeUniform) reasons |= SceneDemandReason::TimeUniform;
    if (shader_reasons & DynamicReason::AudioUniform) reasons |= SceneDemandReason::AudioResponse;
    if (shader_reasons & DynamicReason::BoneUniform) reasons |= SceneDemandReason::Puppet;
    if (shader_reasons & DynamicReason::VideoInput) reasons |= SceneDemandReason::Video;
    if (shader_reasons & DynamicReason::DynamicMesh) reasons |= SceneDemandReason::DynamicMesh;
    if (shader_reasons & DynamicReason::AnimatedSprite) reasons |= SceneDemandReason::AnimatedSprite;
    if (shader_reasons & DynamicReason::Feedback) reasons |= SceneDemandReason::Feedback;
    if (shader_reasons & DynamicReason::UnknownInput) reasons |= SceneDemandReason::UnknownInput;
    return reasons;
}

bool SceneShaderInputsUsePointer(uint32_t shader_reasons)
{
    return shader_reasons & vulkan::DynamicReason::PointerUniform;
}

} // namespace wallpaper
