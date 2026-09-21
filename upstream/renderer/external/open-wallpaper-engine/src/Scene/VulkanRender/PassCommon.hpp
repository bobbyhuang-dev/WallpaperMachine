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
#include "Utils/Algorism.h"

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

/// The smallest internal render scale that still leaves a usable image. Below
/// this the raster is coarse enough that the upscale at present dominates
/// whatever is saved, and the min-dimension clamp starts distorting small
/// targets rather than scaling them.
inline constexpr double kMinRenderScale = 0.25;

/// Scene-wide internal render scale, clamped to (0, 1].
///
/// Returns 1.0 for the engine's own plain-video scene: there the only content
/// is a decoded frame that already has its own resolution, so scaling the
/// target it is copied into would downsample and then upsample the same pixels
/// for no useful reduction in work. Those wallpapers report the control as not
/// applicable rather than pretending to honour it.
inline double ResolveSceneRenderScale(const wallpaper::Scene& scene) {
    if (scene.single_video_source) return 1.0;
    const double scale = scene.render_scale;
    if (! std::isfinite(scale) || scale >= 1.0) return 1.0;
    return std::max(kMinRenderScale, scale);
}

/// Latches the authored size of a target the first time it is resolved, then
/// derives the physical size from that latched value. Deriving from the
/// authored size rather than the current one is what keeps 100% -> 50% -> 100%
/// exact instead of drifting by a rounding step each way.
inline void ResolveRenderScaledSize(SceneRenderTarget& target, double render_scale) {
    if (target.authored_width <= 0 || target.authored_height <= 0) {
        target.authored_width  = target.width;
        target.authored_height = target.height;
    }
    if (target.media_sized) {
        target.width  = target.authored_width;
        target.height = target.authored_height;
        return;
    }
    target.width =
        ResolveScreenBoundRenderTargetDimension(target.authored_width, render_scale);
    target.height =
        ResolveScreenBoundRenderTargetDimension(target.authored_height, render_scale);
}

/// The author's canvas, in scene units. Never scaled: presentation layout and
/// cursor mapping are computed against this, so the internal raster size
/// cannot move the letterbox or offset the hit test.
inline VkExtent2D ResolveSceneSourceExtent(const wallpaper::Scene& scene,
                                           const VkExtent2D&       fallback_extent) {
    if (scene.scene_extent[0] > 0 && scene.scene_extent[1] > 0) {
        return {
            static_cast<uint32_t>(scene.scene_extent[0]),
            static_cast<uint32_t>(scene.scene_extent[1]),
        };
    }

    auto spec_rt = scene.renderTargets.find(std::string(wallpaper::SpecTex_Default));
    if (spec_rt != scene.renderTargets.end()) {
        const auto& rt      = spec_rt->second;
        const auto  width   = rt.authored_width > 0 ? rt.authored_width : rt.width;
        const auto  height  = rt.authored_height > 0 ? rt.authored_height : rt.height;
        if (width > 0 && height > 0) {
            return {
                static_cast<uint32_t>(width),
                static_cast<uint32_t>(height),
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

/// The authored canvas and the internal raster it is drawn at. Equal at render
/// scale 1.0.
struct SceneRasterExtents {
    VkExtent2D source {};
    VkExtent2D raster {};
};

/// Re-bakes `g_TextureNResolution` for every material slot that samples a
/// screen-bound render target.
///
/// Those constants are folded in while the scene is parsed, when a target that
/// follows the screen still has placeholder dimensions because the output size
/// is not known yet. Nothing refreshes them afterwards, so a shader that
/// divides by the resolution -- a separable blur steps by
/// `1 / g_Texture0Resolution.zw` -- was dividing by two. Every one of its taps
/// landed outside the texture and clamped to the edge, which turns a gentle
/// blur into a flat wash and is why an effect chain's background lost its
/// shape entirely.
inline void RefreshScreenBoundTextureResolutions(Scene& scene) {
    const auto refresh = [&scene](SceneNode* node) {
        if (node == nullptr || node->Mesh() == nullptr) return;
        auto* mesh = node->Mesh();
        for (uint32_t slot = 0; slot < mesh->MaterialSlots().size(); ++slot) {
            auto* material = mesh->MaterialForSlot(slot);
            if (material == nullptr) continue;
            for (std::size_t index = 0; index < material->textures.size(); ++index) {
                if (index >= wallpaper::WE_GLTEX_RESOLUTION_NAMES.size()) break;
                const auto& texture = material->textures[index];
                if (texture.empty()) continue;
                // The material keeps the authored name; the scene keys targets
                // by the resolved one.
                const auto* target =
                    scene.FindRenderTarget(scene.ResolveRenderTargetName(texture));
                if (target == nullptr) continue;
                if (! (target->bind.enable && target->bind.screen)) continue;
                const std::array<i32, 4> resolution { target->width, target->height,
                                                      target->width, target->height };
                material->customShader.constValues[std::string(
                    wallpaper::WE_GLTEX_RESOLUTION_NAMES[index])] = array_cast<float>(resolution);
            }
        }
    };
    const auto walk = [&refresh](auto&& self, SceneNode* node) -> void {
        if (node == nullptr) return;
        refresh(node);
        for (const auto& child : node->GetChildren()) self(self, child.get());
    };
    walk(walk, scene.sceneGraph.get());
    // An effect chain's nodes are not children of the layer they belong to, so
    // a plain graph walk misses exactly the passes this matters most for.
    for (auto& [name, camera] : scene.cameras) {
        (void)name;
        if (camera == nullptr || ! camera->HasImgEffect()) continue;
        auto& layer = *camera->GetImgEffect();
        for (std::size_t i = 0; i < layer.EffectCount(); ++i) {
            const auto& effect = layer.GetEffect(i);
            if (effect == nullptr) continue;
            for (const auto& effect_node : effect->nodes) refresh(effect_node.sceneNode.get());
        }
    }
}

inline SceneRasterExtents ResolveScreenBoundRenderTargetSizes(Scene&            scene,
                                                              const VkExtent2D& fallback_extent) {
    const auto source_extent = ResolveSceneSourceExtent(scene, fallback_extent);
    const auto render_scale  = ResolveSceneRenderScale(scene);
    const VkExtent2D raster_extent {
        static_cast<uint32_t>(
            ResolveScreenBoundRenderTargetDimension(source_extent.width, render_scale)),
        static_cast<uint32_t>(
            ResolveScreenBoundRenderTargetDimension(source_extent.height, render_scale)),
    };

    for (auto& item : scene.renderTargets) {
        auto& target = item.second;
        if (item.first == wallpaper::SpecTex_Default) {
            // The scene's own colour buffer and the source the final blit
            // samples. It is bound to the screen with scale 1.0, so the raster
            // extent is exactly its size.
            if (target.authored_width <= 0 || target.authored_height <= 0) {
                target.authored_width  = static_cast<i32>(source_extent.width);
                target.authored_height = static_cast<i32>(source_extent.height);
            }
            if (target.media_sized) {
                target.width  = target.authored_width;
                target.height = target.authored_height;
            } else {
                target.width  = static_cast<i32>(raster_extent.width);
                target.height = static_cast<i32>(raster_extent.height);
            }
            continue;
        }
        if (target.bind.enable && target.bind.screen) {
            if (target.authored_width <= 0 || target.authored_height <= 0) {
                target.authored_width = ResolveScreenBoundRenderTargetDimension(
                    source_extent.width, target.bind.scale);
                target.authored_height = ResolveScreenBoundRenderTargetDimension(
                    source_extent.height, target.bind.scale);
            }
            ResolveScreenBoundRenderTargetSize(target, raster_extent);
        }
    }
    RefreshScreenBoundTextureResolutions(scene);
    return { source_extent, raster_extent };
}

/// Fits the scene's authored canvas into an output of `width` x `height`.
///
/// Purely scene-side camera arithmetic with nothing Vulkan in it, so both
/// render backends call this one definition. Two copies of it would drift, and
/// the drift would show as the two backends framing the same wallpaper
/// differently.
inline void ApplyCameraFillMode(wallpaper::Scene& scene, wallpaper::FillMode fillmode,
                                uint32_t width, uint32_t height) {
    using namespace wallpaper;
    if (width == 0 || height == 0) return;
    const auto global = scene.cameras.find("global");
    const auto global_perspective = scene.cameras.find("global_perspective");
    if (global == scene.cameras.end() || global_perspective == scene.cameras.end()) return;
    if (global->second == nullptr || global_perspective->second == nullptr) return;

    double sw = scene.ortho[0], sh = scene.ortho[1];
    double fboAspect = width / (double)height, sAspect = sw / sh;
    auto&  gCam    = *global->second;
    auto&  gPerCam = *global_perspective->second;
    switch (fillmode) {
    case FillMode::STRETCH:
        gCam.SetWidth(sw);
        gCam.SetHeight(sh);
        gPerCam.SetAspect(sAspect);
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
        break;
    }
    if (! gPerCam.FovLocked()) {
        gPerCam.SetFov(algorism::CalculatePersperctiveFov(1000.0f, gCam.Height()));
    }
    gCam.Update();
    gPerCam.Update();
    scene.UpdateLinkedCamera("global");
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

inline TextureKey ToTexKeyDepth(wallpaper::SceneRenderTarget rt,
                                VkSampleCountFlagBits        sample_count) {
    auto key          = ToTexKey(rt);
    key.usage         = TexUsage::DEPTH;
    key.mipmap_level  = 1;
    key.sample_count  = sample_count;
    return key;
}
} // namespace vulkan
} // namespace wallpaper
