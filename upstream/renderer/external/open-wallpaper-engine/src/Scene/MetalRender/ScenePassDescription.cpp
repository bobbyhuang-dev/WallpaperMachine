#include "MetalRender/ScenePassDescription.hpp"

#include "CopyPass.hpp"
#include "CustomShaderPass.hpp"
#include "PassCommon.hpp"
#include "PrePass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"

#include <functional>

namespace wallpaper::metal
{
namespace
{

uint64_t HashMix(uint64_t seed, uint64_t value)
{
    seed ^= value + 0x9e3779b97f4a7c15ULL + (seed << 6) + (seed >> 2);
    return seed;
}

MetalLoadAction ResolveLoadAction(bool preserve_target_contents, bool clear_on_first_use)
{
    if (clear_on_first_use) return MetalLoadAction::Clear;
    if (preserve_target_contents) return MetalLoadAction::Load;
    return MetalLoadAction::DontCare;
}

bool TargetExtent(const Scene& scene, const std::string& key, uint32_t& width, uint32_t& height)
{
    const auto* target = scene.FindRenderTarget(key);
    if (target == nullptr || target->width <= 0 || target->height <= 0) return false;
    width  = static_cast<uint32_t>(target->width);
    height = static_cast<uint32_t>(target->height);
    return true;
}

} // namespace

std::size_t MetalPipelineKeyHash::operator()(const MetalPipelineKey& key) const noexcept
{
    uint64_t hash = 0xcbf29ce484222325ULL;
    hash          = HashMix(hash, key.program_id);
    hash          = HashMix(hash, key.vertex_layout_id);
    hash          = HashMix(hash, static_cast<uint64_t>(key.color_format));
    hash          = HashMix(hash, key.sample_count);
    hash          = HashMix(hash, key.write_alpha ? 1u : 0u);
    hash          = HashMix(hash, key.blend.blending_enabled ? 1u : 0u);
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.rgb_operation));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.alpha_operation));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.source_rgb));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.destination_rgb));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.source_alpha));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.destination_alpha));
    hash          = HashMix(hash, key.blend.alpha_to_coverage ? 1u : 0u);
    return static_cast<std::size_t>(hash);
}

bool BuildScenePassDescriptions(Scene& scene, const rg::RenderGraph& graph,
                                std::vector<ScenePassDescription>& out, std::string* error)
{
    out.clear();
    const auto set_error = [error](std::string message) {
        if (error != nullptr) *error = std::move(message);
        return false;
    };

    for (const auto node_id : graph.topologicalOrder()) {
        const auto* pass_node = graph.getPassNode(node_id);
        auto*       pass      = graph.getPass(node_id);
        if (pass_node == nullptr || pass == nullptr) {
            return set_error("the render graph contains a step with no pass");
        }

        const auto kind = ClassifyMetalPassKind(static_cast<int>(pass_node->type()));
        switch (kind) {
        case MetalPassKind::Virtual:
            // Bookkeeping only: it records a writer so versioning works, and
            // produces no pixels. Skipped rather than rejected.
            continue;
        case MetalPassKind::Unsupported:
            return set_error("the render graph contains a step the native renderer does not "
                             "recognise");
        case MetalPassKind::Clear: {
            auto* pre = dynamic_cast<vulkan::PrePass*>(pass);
            if (pre == nullptr) return set_error("a clear step has an unexpected shape");
            ScenePassDescription desc;
            desc.kind        = MetalPassKind::Clear;
            desc.name        = std::string(pass_node->name());
            desc.target_key  = scene.ResolveRenderTargetName(pre->desc().result);
            desc.load_action = MetalLoadAction::Clear;
            if (pre->desc().transparent) {
                desc.clear_color = { 0.0f, 0.0f, 0.0f, 0.0f };
            } else {
                desc.clear_color = { scene.clearColor[0], scene.clearColor[1], scene.clearColor[2],
                                     1.0f };
            }
            if (! TargetExtent(scene, desc.target_key, desc.target_width, desc.target_height)) {
                return set_error("a clear step targets an image with no size");
            }
            out.push_back(std::move(desc));
            continue;
        }
        case MetalPassKind::Copy: {
            auto* copy = dynamic_cast<vulkan::CopyPass*>(pass);
            if (copy == nullptr) return set_error("a copy step has an unexpected shape");
            ScenePassDescription desc;
            desc.kind        = MetalPassKind::Copy;
            desc.name        = std::string(pass_node->name());
            desc.source_key  = scene.ResolveRenderTargetName(copy->desc().src);
            desc.target_key  = scene.ResolveRenderTargetName(copy->desc().dst);
            desc.load_action = MetalLoadAction::DontCare;
            if (! TargetExtent(scene, desc.target_key, desc.target_width, desc.target_height)) {
                return set_error("a copy step targets an image with no size");
            }
            out.push_back(std::move(desc));
            continue;
        }
        case MetalPassKind::CustomShader: {
            auto* custom = dynamic_cast<vulkan::CustomShaderPass*>(pass);
            if (custom == nullptr) return set_error("a draw step has an unexpected shape");
            const auto& src = custom->desc();
            if (src.node == nullptr || src.node->Mesh() == nullptr) {
                return set_error("a draw step has no mesh");
            }
            auto* mesh = src.node->Mesh();
            if (src.submesh_index >= mesh->Submeshes().size()) {
                return set_error("a draw step names a submesh that does not exist");
            }
            const auto* material = mesh->MaterialForSlot(src.material_slot);
            if (material == nullptr) return set_error("a draw step has no material");

            ScenePassDescription desc;
            desc.kind            = MetalPassKind::CustomShader;
            desc.name            = material->name;
            desc.node            = src.node;
            desc.visibility_node = src.visibility_node != nullptr ? src.visibility_node : src.node;
            desc.material_slot   = src.material_slot;
            desc.submesh_index   = src.submesh_index;
            desc.camera_override = src.camera_override;
            desc.blend           = material->blenmode;
            desc.write_alpha     = src.write_alpha;
            desc.target_key      = scene.ResolveRenderTargetName(src.output);
            desc.load_action = ResolveLoadAction(src.preserve_target_contents,
                                                 src.clear_on_first_use);
            // Only the scene's own colour buffer clears to the author's
            // background; every other target clears to nothing, so a layer
            // composited onto it is not composited onto a colour.
            if (desc.target_key == scene.ResolveRenderTargetName(SpecTex_Default)) {
                desc.clear_color = { scene.clearColor[0], scene.clearColor[1], scene.clearColor[2],
                                     1.0f };
            } else {
                desc.clear_color = { 0.0f, 0.0f, 0.0f, 0.0f };
            }
            if (! TargetExtent(scene, desc.target_key, desc.target_width, desc.target_height)) {
                return set_error("a draw step targets an image with no size");
            }
            desc.texture_keys.reserve(src.textures.size());
            for (const auto& texture : src.textures) {
                desc.texture_keys.push_back(texture.empty()
                                                ? std::string {}
                                                : scene.ResolveRenderTargetName(texture));
            }
            out.push_back(std::move(desc));
            continue;
        }
        }
        return set_error("the render graph contains a step the native renderer does not recognise");
    }

    if (out.empty()) return set_error("the render graph draws nothing");
    return true;
}

} // namespace wallpaper::metal
