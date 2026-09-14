#include "SceneToRenderGraph.hpp"

#include "Scene/Scene.h"
#include "RenderGraph/RenderGraph.hpp"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"
#include "Core/MapSet.hpp"

#include "Vulkan/SampleCount.hpp"
#include "VulkanRender/AllPasses.hpp"

#include <cstdlib>
#include <sstream>
#include <type_traits>
#include <variant>

using namespace wallpaper;
namespace wallpaper::rg
{

void doCopy(RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc, TexNode* in, TexNode* out) {
    builder.read(in);
    builder.write(out);

    desc.src = in->key();
    desc.dst = out->key();
}
void addCopyPass(RenderGraph& rgraph, TexNode* in, TexNode* out) {
    rgraph.addPass<vulkan::CopyPass>(
        "copy",
        PassNode::Type::Copy,
        [&in, &out](RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc) {
            doCopy(builder, desc, in, out);
        });
}

void addCopyPass(RenderGraph& rgraph, const TexNode::Desc& in, const TexNode::Desc& out) {
    rgraph.addPass<vulkan::CopyPass>(
        "copy",
        PassNode::Type::Copy,
        [&in, &out](RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc) {
            auto* in_node  = builder.createTexNode(in);
            auto* out_node = builder.createTexNode(out, true);
            doCopy(builder, desc, in_node, out_node);
        });
}

TexNode* addCopyPass(RenderGraph& rgraph, TexNode* in, TexNode::Desc* out_desc = nullptr) {
    TexNode* copy { nullptr };
    rgraph.addPass<vulkan::CopyPass>(
        "copy",
        PassNode::Type::Copy,
        [&copy, in, out_desc](RenderGraphBuilder& builder, vulkan::CopyPass::Desc& pdesc) {
            auto desc = out_desc == nullptr ? in->genDesc() : *out_desc;
            if (out_desc == nullptr) {
                desc.key += "_" + std::to_string(in->version()) + "_copy";
                desc.name += "_" + std::to_string(in->version()) + "_copy";
            }
            copy = builder.createTexNode(desc, true);
            doCopy(builder, pdesc, in, copy);
        });
    return copy;
}

static TexNode::Desc createTexDesc(std::string path) {
    return TexNode::Desc { .name = path,
                           .key  = path,
                           .type = IsSpecTex(path) ? TexNode::TexType::Temp
                                                   : TexNode::TexType::Imported };
}
} // namespace wallpaper::rg

static bool EnvFlagEnabled(const char* name)
{
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') return false;
    const std::string_view view(value);
    return view != "0" && view != "false" && view != "FALSE";
}

static bool EnvMatches(const char* name, std::string_view expected)
{
    const char* value = std::getenv(name);
    return value != nullptr && expected == value;
}

static bool IsComposeEffectCamera(
    Scene& scene,
    const std::shared_ptr<SceneCamera>& camera,
    const SceneNode* owner)
{
    if (camera == nullptr || scene.activeCamera == nullptr) return false;
    if (!camera->HasImgEffect() || !camera->IsComposeLayer()) return false;

    const auto effect_anchor = camera->GetAttachedNode();
    if (effect_anchor == nullptr) return false;
    if (owner != nullptr && effect_anchor.get() == owner) return true;

    const auto active_anchor = scene.activeCamera->GetAttachedNode();
    return active_anchor != nullptr && effect_anchor.get() == active_anchor.get();
}

static bool IsComposeEffectNode(Scene& scene, const SceneNode* node)
{
    if (node == nullptr || node->Camera().empty()) return false;
    auto camera_iterator = scene.cameras.find(node->Camera());
    if (camera_iterator == scene.cameras.end() || camera_iterator->second == nullptr) return false;
    return IsComposeEffectCamera(scene, camera_iterator->second, node);
}

static std::string ActiveCameraName(Scene& scene)
{
    for (const auto& [name, camera] : scene.cameras) {
        if (camera != nullptr && camera.get() == scene.activeCamera) return name;
    }
    return {};
}

static bool IsResolvedImageEffectFinalNode(
    Scene& scene,
    const SceneNode* effect_node,
    const SceneNode* owner)
{
    if (effect_node == nullptr || owner == nullptr || owner->Camera().empty()) return false;
    auto camera_iterator = scene.cameras.find(owner->Camera());
    if (camera_iterator == scene.cameras.end() || camera_iterator->second == nullptr) return false;
    if (!camera_iterator->second->HasImgEffect()) return false;
    return camera_iterator->second->GetImgEffect()->ResolvedFinalRenderNode() == effect_node;
}

static bool ShouldDebugSkipGraphPass(const SceneNode* node, std::string_view material_name)
{
    if (node != nullptr && EnvMatches("WE_DEBUG_SKIP_NODE", node->Name())) return true;
    if (EnvMatches("WE_DEBUG_SKIP_MATERIAL", material_name)) return true;
    if (material_name == "passthrough" && EnvFlagEnabled("WE_DEBUG_SKIP_PASSTHROUGH")) return true;
    return false;
}

struct ComposeTarget
{
    std::string target;
    std::string camera;
};

static ComposeTarget ResolveNearestComposeTarget(Scene& scene, SceneNode* node)
{
    for (auto* current = node; current != nullptr; current = current->Parent()) {
        if (current->Camera().empty()) continue;
        auto camera_iterator = scene.cameras.find(current->Camera());
        if (camera_iterator == scene.cameras.end() || camera_iterator->second == nullptr) continue;
        if (!IsComposeEffectCamera(scene, camera_iterator->second, current)) continue;
        return {
            .target = camera_iterator->second->GetImgEffect()->FirstTarget(),
            .camera = current->Camera(),
        };
    }
    return {};
}

enum class GraphPassMode
{
    All,
    BaseOnly,
    EffectsOnly,
};

static void TraverseNode(
    const std::function<void(SceneNode*)>& func,
    SceneNode* node) {
    if (node == nullptr) return;
    func(node);
    for (auto& child : node->GetChildren()) {
        TraverseNode(func, child.get());
    }
}

static void CheckAndSetSprite(Scene& scene, vulkan::CustomShaderPass::Desc& desc,
                              std::span<const std::string> texs) {
    for (usize i = 0; i < texs.size(); i++) {
        auto& tex = texs[i];
        if (! tex.empty() && ! IsSpecTex(tex) && scene.textures.count(tex) != 0) {
            const auto& stex = scene.textures.at(tex);
            if (stex.isSprite) {
                desc.sprites_map[i] = stex.spriteAnim;
            }
        }
    }
}

struct DelayLinkInfo {
    rg::NodeID id;
    rg::NodeID link_id;
    i32        tex_index;
};

struct ExtraInfo {
    Map<size_t, rg::TexNode*>  id_link_map {};
    Map<size_t, rg::TexNode*>  id_base_output_link_map {};
    Set<size_t>                ids_with_effect_graph {};
    std::vector<DelayLinkInfo> link_info {};
    rg::RenderGraph*           rgraph { nullptr };
    Scene*                     scene { nullptr };
    bool                       use_mipmap_framebuffer { false };
};

static void AddCustomShaderGraphPass(
    rg::RenderGraph& rgraph,
    Scene& scene,
    ExtraInfo& extra,
    SceneNode* node,
    SceneNode* visibility_node,
    SceneMaterial& material,
    std::string_view output,
    std::string output_override,
    i32 imgId,
    std::string camera_override,
    std::size_t submesh_index,
    uint32_t material_slot,
    bool register_base_link_output = false) {
    rgraph.addPass<vulkan::CustomShaderPass>(
        material.name,
        rg::PassNode::Type::CustomShader,
        [&material,
         node,
         visibility_node,
         output,
         output_override,
         imgId,
         &rgraph,
         &scene,
         &extra,
         camera_override,
         submesh_index,
         material_slot,
         register_base_link_output](
            rg::RenderGraphBuilder& builder, vulkan::CustomShaderPass::Desc& pdesc) {
            const auto& pass = builder.workPassNode();
            const auto  pass_output = output_override.empty()
                ? std::string(output)
                : std::move(output_override);
            const auto  resolved_output = scene.ResolveRenderTargetName(pass_output);
            pdesc.node            = node;
            pdesc.visibility_node = visibility_node != nullptr ? visibility_node : node;
            pdesc.output          = resolved_output;
            pdesc.camera_override = camera_override;
            pdesc.submesh_index   = submesh_index;
            pdesc.material_slot   = material_slot;
            CheckAndSetSprite(scene, pdesc, material.textures);
            for (usize i = 0; i < material.textures.size(); i++) {
                const auto& texture_name = material.textures[i];
                const auto  url = IsSpecTex(texture_name)
                    ? scene.ResolveRenderTargetName(texture_name)
                    : texture_name;
                rg::TexNode* input { nullptr };
                if (url.empty()) {
                    pdesc.textures.emplace_back("");
                    continue;
                } else if (IsSpecLinkTex(url)) {
                    auto id = ParseLinkTex(url);
                    extra.link_info.push_back(
                        DelayLinkInfo { .id = pass.ID(), .link_id = id, .tex_index = (i32)i });
                    pdesc.textures.emplace_back("");
                    continue;
                } else {
                    rg::TexNode::Desc desc;
                    desc.key  = url;
                    desc.name = url;
                    desc.type = ! IsSpecTex(url) ? rg::TexNode::TexType::Imported
                                                 : rg::TexNode::TexType::Temp;
                    input     = builder.createTexNode(desc);
                    if (IsSpecTex(url)) builder.markVirtualWrite(input);
                    if (sstart_with(url, WE_MIP_MAPPED_FRAME_BUFFER))
                        extra.use_mipmap_framebuffer = true;
                }

                if (url == resolved_output) {
                    builder.markSelfWrite(input);
                    input = rg::addCopyPass(rgraph, input);
                }
                builder.read(input);
                pdesc.textures.emplace_back(input->key());
            }

            rg::TexNode* output_node { nullptr };
            output_node =
                builder.createTexNode(rg::TexNode::Desc { .name = resolved_output,
                                                          .key  = resolved_output,
                                                          .type = rg::TexNode::TexType::Temp },
                                      true);
            builder.write(output_node);
            if (resolved_output == SpecTex_Default) {
                extra.id_link_map[(usize)imgId] = output_node;
            } else if (register_base_link_output) {
                extra.id_base_output_link_map[(usize)imgId] = output_node;
            }
        });
}

static void ToGraphPass(
    SceneNode* node,
    std::string output,
    i32 imgId,
    ExtraInfo& extra,
    SceneNode* visibility_node = nullptr,
    GraphPassMode mode = GraphPassMode::All) {
    auto& rgraph = *extra.rgraph;
    auto& scene  = *extra.scene;

    auto loadEffect = [node, &rgraph, &scene, &extra](SceneImageEffectLayer* effs) {
        effs->ResolveEffect(scene.default_effect_mesh, "effect");

        for (usize i = 0; i < effs->EffectCount(); i++) {
            auto& eff     = effs->GetEffect(i);
            auto  cmdItor = eff->commands.begin();
            auto  cmdEnd  = eff->commands.end();
            int   nodePos = 0;
            for (auto& n : eff->nodes) {
                if (cmdItor != cmdEnd && nodePos == cmdItor->afterpos) {
                    rg::addCopyPass(
                        rgraph, rg::createTexDesc(cmdItor->src), rg::createTexDesc(cmdItor->dst));
                    cmdItor++;
                }
                auto& name = n.output;
                extra.ids_with_effect_graph.insert((usize)node->ID());
                ToGraphPass(n.sceneNode.get(), name, node->ID(), extra, node);
                nodePos++;
            }
        }
    };

    if (node->Mesh() == nullptr) return;
    auto* mesh = node->Mesh();

    SceneImageEffectLayer* imgeff = nullptr;
    if (! node->Camera().empty()) {
        auto& cam = scene.cameras.at(node->Camera());
        if (cam->HasImgEffect()) {
            imgeff = cam->GetImgEffect().get();
            output = imgeff->FirstTarget();
        }
    }

    std::string camera_override;
    if (mode == GraphPassMode::BaseOnly && IsComposeEffectNode(scene, node)) {
        camera_override = ActiveCameraName(scene);
    }
    const bool route_effect_final_to_compose =
        IsResolvedImageEffectFinalNode(scene, node, visibility_node);
    if (!output.empty() && (output == SpecTex_Default || route_effect_final_to_compose)) {
        SceneNode* compose_anchor = node->Parent();
        if (compose_anchor == nullptr && visibility_node != nullptr) {
            compose_anchor = visibility_node->Parent();
        }
        const auto compose_target = ResolveNearestComposeTarget(scene, compose_anchor);
        if (!compose_target.target.empty()) output = compose_target.target;
        if (!compose_target.camera.empty()) camera_override = compose_target.camera;
    }

    if (mode != GraphPassMode::EffectsOnly && !node->SkipRenderPass()) {
        const auto& submeshes = mesh->Submeshes();
        if (submeshes.size() > 1) {
            for (std::size_t submesh_index = 0; submesh_index < submeshes.size(); ++submesh_index) {
                const auto material_slot = submeshes[submesh_index].material_slot;
                auto* submesh_material = mesh->MaterialForSlot(material_slot);
                if (submesh_material == nullptr) continue;
                if (ShouldDebugSkipGraphPass(node, submesh_material->name)) continue;
                AddCustomShaderGraphPass(
                    rgraph,
                    scene,
                    extra,
                    node,
                    visibility_node,
                    *submesh_material,
                    output,
                    submeshes[submesh_index].output_override,
                    imgId,
                    camera_override,
                    submesh_index,
                    material_slot,
                    imgeff != nullptr);
            }
        } else {
            auto* material = mesh->MaterialForSlot(0);
            if (material == nullptr) return;
            if (!ShouldDebugSkipGraphPass(node, material->name)) {
                AddCustomShaderGraphPass(
                    rgraph,
                    scene,
                    extra,
                    node,
                    visibility_node,
                    *material,
                    output,
                    {},
                    imgId,
                    camera_override,
                    0,
                    0,
                    imgeff != nullptr);
            }
        }
    }

    // load effect
    if (mode != GraphPassMode::BaseOnly && imgeff != nullptr) loadEffect(imgeff);
}

std::unique_ptr<rg::RenderGraph> wallpaper::sceneToRenderGraph(Scene& scene) {
    std::unique_ptr<rg::RenderGraph> rgraph = std::make_unique<rg::RenderGraph>();
    ExtraInfo                        extra { .rgraph = rgraph.get(), .scene = &scene };
    std::function<void(SceneNode*)> build_graph = [&extra, &build_graph](SceneNode* node) {
        if (node == nullptr) return;

        const bool is_compose_effect_node = IsComposeEffectNode(*extra.scene, node);

        if (is_compose_effect_node) {
            if (!node->SkipRenderPass()) {
                ToGraphPass(
                    node,
                    std::string(SpecTex_Default),
                    node->ID(),
                    extra,
                    nullptr,
                    GraphPassMode::BaseOnly);
            }
        } else if (!node->SkipRenderPass()) {
            ToGraphPass(node, std::string(SpecTex_Default), node->ID(), extra);
        }

        for (auto& child : node->GetChildren()) {
            build_graph(child.get());
        }

        if (is_compose_effect_node) {
            ToGraphPass(
                node,
                std::string(SpecTex_Default),
                node->ID(),
                extra,
                nullptr,
                GraphPassMode::EffectsOnly);
        } else if (node->SkipRenderPass()) {
            ToGraphPass(node, std::string(SpecTex_Default), node->ID(), extra);
        }
    };
    build_graph(scene.sceneGraph.get());

    for (const auto& post_process : scene.post_processes) {
        if (post_process == nullptr) continue;
        for (const auto& step : post_process->steps) {
            std::visit(
                [&extra](const auto& post_step) {
                    using Step = std::decay_t<decltype(post_step)>;
                    if constexpr (std::is_same_v<Step, ScenePostProcessPass>) {
                        if (post_step.node == nullptr) return;
                        ToGraphPass(
                            post_step.node.get(),
                            post_step.output,
                            post_step.node->ID(),
                            extra);
                    } else if constexpr (std::is_same_v<Step, ScenePostProcessCopy>) {
                        const auto src = extra.scene->ResolveRenderTargetName(post_step.src);
                        const auto dst = extra.scene->ResolveRenderTargetName(post_step.dst);
                        rg::addCopyPass(
                            *extra.rgraph,
                            rg::createTexDesc(src),
                            rg::createTexDesc(dst));
                    }
                },
                step);
        }
    }

    for (auto& info : extra.link_info) {
        if (! exists(extra.id_link_map, info.link_id) &&
            ! exists(extra.ids_with_effect_graph, info.link_id) &&
            exists(extra.id_base_output_link_map, info.link_id)) {
            extra.id_link_map[info.link_id] = extra.id_base_output_link_map.at(info.link_id);
        }
        if (! exists(extra.id_link_map, info.link_id)) {
            LOG_ERROR("link tex %d not found", info.link_id);
            continue;
        }
        rgraph->afterBuild(
            info.id, [&rgraph, &extra, &info](rg::RenderGraphBuilder& builder, rg::Pass& rgpass) {
                auto& pass = static_cast<vulkan::CustomShaderPass&>(rgpass);

                auto* link_tex_node = extra.id_link_map.at(info.link_id);
                auto  copy_desc     = link_tex_node->genDesc();
                copy_desc.key       = GenLinkTex((idx)info.link_id);
                copy_desc.name      = copy_desc.key;

                auto new_in = rg::addCopyPass(*rgraph, link_tex_node, &copy_desc);
                builder.read(new_in);
                pass.setDescTex((u32)info.tex_index, new_in->key());
                return true;
            });
    }

    if (extra.use_mipmap_framebuffer) {
        rg::addCopyPass(*rgraph,
                        rg::TexNode::Desc { .name = SpecTex_Default.data(),
                                            .key  = SpecTex_Default.data(),
                                            .type = rg::TexNode::TexType::Temp },
                        rg::TexNode::Desc { .name = WE_MIP_MAPPED_FRAME_BUFFER.data(),
                                            .key  = WE_MIP_MAPPED_FRAME_BUFFER.data(),
                                            .type = rg::TexNode::TexType::Temp });
    }

    Set<std::string> written_targets {};
    Set<std::string> transfer_written_targets {};
    for (const auto node_id : rgraph->topologicalOrder()) {
        if (auto* copy_pass = dynamic_cast<vulkan::CopyPass*>(rgraph->getPass(node_id));
            copy_pass != nullptr) {
            const auto copy_dst = scene.ResolveRenderTargetName(copy_pass->desc().dst);
            if (!copy_dst.empty()) {
                written_targets.insert(copy_dst);
                transfer_written_targets.insert(copy_dst);
            }
            continue;
        }

        auto* custom_pass = dynamic_cast<vulkan::CustomShaderPass*>(rgraph->getPass(node_id));
        if (custom_pass == nullptr) continue;

        auto& desc = custom_pass->desc();
        desc.write_alpha = desc.output != SpecTex_Default;
        const auto render_target = scene.FindRenderTarget(desc.output);
        const bool force_clear =
            desc.output != SpecTex_Default && render_target != nullptr && render_target->forceClear;
        desc.sample_count = render_target != nullptr
                                ? vulkan::SampleCountFromValue(render_target->sample_count)
                                : VK_SAMPLE_COUNT_1_BIT;

        const bool first_writer =
            !desc.output.empty() && written_targets.insert(desc.output).second;
        if (!first_writer && !force_clear) {
            desc.clear_on_first_use = false;
            desc.preserve_target_contents = true;
            if (transfer_written_targets.find(desc.output) != transfer_written_targets.end()) {
                desc.sample_count = VK_SAMPLE_COUNT_1_BIT;
            }
            continue;
        }

        desc.preserve_target_contents = false;
        if (!desc.output.empty()) {
            transfer_written_targets.erase(desc.output);
        }
        if (desc.output == SpecTex_Default) {
            desc.clear_on_first_use = scene.clearEnabled;
            continue;
        }

        desc.clear_on_first_use = render_target != nullptr && (render_target->allowReuse || force_clear);
    }

    return rgraph;
}
