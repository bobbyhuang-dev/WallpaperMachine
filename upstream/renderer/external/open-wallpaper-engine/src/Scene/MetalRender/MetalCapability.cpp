#include "MetalRender/MetalCapability.hpp"

#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"

#include "CopyPass.hpp"
#include "CustomShaderPass.hpp"
#include "PrePass.hpp"
#include "RenderGraph/PassNode.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneImageEffectLayer.h"
#include "SpecTexs.hpp"
#include "Particle/ParticleSystem.h"

#include <algorithm>
#include <functional>
#include <unordered_set>
#include <variant>
#include <vector>

namespace wallpaper::metal
{
namespace
{

/// Uniform whose presence means the shader is driven by skeletal transforms.
/// Read from reflection, never from shader source text.
constexpr std::string_view kBonesUniform { "g_Bones" };

/// Whether the camera the scene actually renders through is a perspective one.
///
/// `Scene::activeCamera` is a raw pointer with no default, so it is validated
/// against the camera table before it is dereferenced. A scene built by hand --
/// in a test, or by a future caller -- must not make this read uninitialised
/// memory.
bool SceneUsesPerspective(const Scene& scene)
{
    for (const auto& [name, camera] : scene.cameras) {
        (void)name;
        if (camera == nullptr || camera.get() != scene.activeCamera) continue;
        return camera->IsPerspective();
    }
    return false;
}

const SceneCamera* FindCamera(const Scene& scene, const std::string& name)
{
    if (name.empty()) return nullptr;
    const auto found = scene.cameras.find(name);
    if (found == scene.cameras.end()) return nullptr;
    return found->second.get();
}

/// The scene nodes an image effect chain draws with, which are not children of
/// the layer they belong to and so are missed by a plain scene-graph walk. They
/// carry ordinary meshes, materials and translated shaders, and every structural
/// limit that applies to a layer applies to them too.
std::vector<SceneNode*> EffectNodes(const Scene& scene, const SceneNode* node)
{
    std::vector<SceneNode*> nodes;
    const auto* camera = FindCamera(scene, node->Camera());
    if (camera == nullptr || ! camera->HasImgEffect()) return nodes;
    auto& layer = *const_cast<SceneCamera*>(camera)->GetImgEffect();
    for (std::size_t i = 0; i < layer.EffectCount(); ++i) {
        const auto& effect = layer.GetEffect(i);
        if (effect == nullptr) continue;
        for (const auto& effect_node : effect->nodes) {
            if (effect_node.sceneNode != nullptr) nodes.push_back(effect_node.sceneNode.get());
        }
    }
    return nodes;
}

/// The nodes the scene's post-process chain draws with. Like effect nodes they
/// live outside the scene graph, and the render graph lowers them into ordinary
/// custom-shader passes, so they are checked as ordinary layers.
std::vector<SceneNode*> PostProcessNodes(const Scene& scene)
{
    std::vector<SceneNode*> nodes;
    for (const auto& post_process : scene.post_processes) {
        if (post_process == nullptr) continue;
        for (const auto& step : post_process->steps) {
            const auto* pass = std::get_if<ScenePostProcessPass>(&step);
            if (pass != nullptr && pass->node != nullptr) nodes.push_back(pass->node.get());
        }
    }
    return nodes;
}

/// Walks the scene graph, stopping at the first rejection.
std::string RejectNodes(const Scene& scene, const SceneNode* node)
{
    if (node == nullptr) return {};

    if (const auto* camera = FindCamera(scene, node->Camera()); camera != nullptr) {
        if (camera->IsPerspective()) return "the scene uses a perspective 3D camera";
    }

    if (auto* mesh = const_cast<SceneNode*>(node)->Mesh(); mesh != nullptr) {
        if (mesh->Dynamic()) {
            return "the scene rebuilds mesh geometry every frame";
        }
        if (mesh->Primitive() != MeshPrimitive::TRIANGLE) {
            return "the scene draws a primitive the native renderer does not support";
        }
        for (const auto& slot : mesh->MaterialSlots()) {
            if (slot == nullptr) continue;
            const auto& material = *slot;
            const auto* shader   = material.customShader.shader.get();
            if (shader == nullptr) return "a layer has no shader";
        }
    }

    // Link textures and a material that samples the target it draws into are
    // deliberately NOT rejected here. Both are ordinary same-frame inputs once
    // the render graph exists: the graph names the producing pass's output and
    // breaks a read-while-write with its own copy. Whether an input is genuine
    // cross-frame history is a question only the lowered graph can answer, and
    // `MetalGraphRejection` answers it there.

    for (auto* effect_node : EffectNodes(scene, node)) {
        auto reason = RejectNodes(scene, effect_node);
        if (! reason.empty()) return reason;
    }
    for (const auto& child : node->GetChildren()) {
        auto reason = RejectNodes(scene, child.get());
        if (! reason.empty()) return reason;
    }
    return {};
}

/// Shader-translation rejection, checked only after the structural ones.
std::string RejectShaders(const Scene& scene, const SceneNode* node, bool& saw_any_attempt)
{
    if (node == nullptr) return {};

    if (auto* mesh = const_cast<SceneNode*>(node)->Mesh(); mesh != nullptr) {
        for (const auto& slot : mesh->MaterialSlots()) {
            if (slot == nullptr) continue;
            const auto* shader = slot->customShader.shader.get();
            if (shader == nullptr) continue;
            const auto* program = shader->metal_program.get();
            if (program == nullptr) continue;
            saw_any_attempt = true;
            if (! program->ok()) {
                return "a shader could not be translated to Metal";
            }
            MetalShaderReflection reflection;
            std::string           error;
            if (! ParseMetalShaderReflection(program->reflection_json, reflection, &error)) {
                return "a shader could not be translated to Metal";
            }
            if (reflection.hasMember(kBonesUniform)) {
                return "the scene animates a puppet skeleton";
            }
        }
    }

    for (auto* effect_node : EffectNodes(scene, node)) {
        auto reason = RejectShaders(scene, effect_node, saw_any_attempt);
        if (! reason.empty()) return reason;
    }
    for (const auto& child : node->GetChildren()) {
        auto reason = RejectShaders(scene, child.get(), saw_any_attempt);
        if (! reason.empty()) return reason;
    }
    return {};
}

} // namespace

std::string SceneMetalStructuralRejection(const Scene& scene)
{
    if (scene.sceneGraph == nullptr) return "the scene has no drawable content";
    // Every scene owns a particle system object; only some have an emitter in
    // it, and it is the emitter that this backend cannot draw.
    if (scene.paritileSys != nullptr && scene.paritileSys->HasEmitters()) {
        return "the scene uses a particle emitter";
    }
    if (! scene.lights.empty()) return "the scene uses dynamic lighting";
    // A plain video wallpaper is not a scene this backend competes for: the
    // host has a dedicated path for it.
    if (scene.single_video_source) return "the wallpaper is a video";

    for (const auto& [name, texture] : scene.textures) {
        if (texture.isSprite) return "the scene uses an animated sprite sheet";
        if (texture.isVideo) {
            if (auto reason = MetalVideoTextureRejection(scene, name); ! reason.empty()) {
                return reason;
            }
        }
    }

    if (SceneUsesPerspective(scene)) return "the scene uses a perspective 3D camera";

    // Effect chains and post-processing are ordinary multi-pass work here, so
    // neither is rejected wholesale any more. What this backend can execute is
    // decided pass by pass once the render graph exists.
    if (auto reason = RejectNodes(scene, scene.sceneGraph.get()); ! reason.empty()) return reason;
    for (auto* node : PostProcessNodes(scene)) {
        if (auto reason = RejectNodes(scene, node); ! reason.empty()) return reason;
    }
    return {};
}

SceneBackendSelection EvaluateMetalSupport(const Scene& scene)
{
    if (auto reason = SceneMetalStructuralRejection(scene); ! reason.empty()) {
        return SceneBackendSelection { SceneBackend::LegacyVulkan, std::move(reason) };
    }

    bool saw_any_attempt = false;
    if (auto reason = RejectShaders(scene, scene.sceneGraph.get(), saw_any_attempt);
        ! reason.empty()) {
        return SceneBackendSelection { SceneBackend::LegacyVulkan, std::move(reason) };
    }
    for (auto* node : PostProcessNodes(scene)) {
        if (auto reason = RejectShaders(scene, node, saw_any_attempt); ! reason.empty()) {
            return SceneBackendSelection { SceneBackend::LegacyVulkan, std::move(reason) };
        }
    }

    // No shader carries a translation at all. That is not the author's fault
    // and must not be reported as one: it is what every scene looks like when
    // it was parsed while the compatibility renderer was selected, because the
    // second compile is only run when the native renderer is asked for.
    if (! saw_any_attempt) {
        return SceneBackendSelection {
            SceneBackend::LegacyVulkan,
            "the wallpaper was loaded before the native renderer was selected",
        };
    }

    return SceneBackendSelection { SceneBackend::NativeMetal, {} };
}

MetalPassKind ClassifyMetalPassKind(int pass_node_type)
{
    switch (pass_node_type) {
    case static_cast<int>(rg::PassNode::Type::CustomShader): return MetalPassKind::CustomShader;
    case static_cast<int>(rg::PassNode::Type::Copy): return MetalPassKind::Copy;
    case static_cast<int>(rg::PassNode::Type::Clear): return MetalPassKind::Clear;
    case static_cast<int>(rg::PassNode::Type::Virtual): return MetalPassKind::Virtual;
    default: return MetalPassKind::Unsupported;
    }
}

std::string MetalGraphRejection(const Scene& scene, const rg::RenderGraph& graph)
{
    constexpr std::string_view kUnrecognised =
        "the render graph contains a step the native renderer does not recognise";

    // One step per pass that produces pixels, in execution order. Built first so
    // the feedback question can look forward as well as back: whether an input
    // is this frame's work or last frame's leftovers depends on what happens
    // after the pass that reads it, not only before.
    struct GraphStep
    {
        std::string              writes;
        std::vector<std::string> reads;
    };
    std::vector<GraphStep> steps;

    for (const auto node_id : graph.topologicalOrder()) {
        const auto* pass_node = graph.getPassNode(node_id);
        auto*       pass      = graph.getPass(node_id);
        if (pass_node == nullptr || pass == nullptr) return std::string(kUnrecognised);

        GraphStep step;
        switch (ClassifyMetalPassKind(static_cast<int>(pass_node->type()))) {
        case MetalPassKind::Virtual: continue;
        case MetalPassKind::Unsupported: return std::string(kUnrecognised);
        case MetalPassKind::Clear: {
            const auto* clear = dynamic_cast<const vulkan::PrePass*>(pass);
            if (clear == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(clear->desc().result);
            break;
        }
        case MetalPassKind::Copy: {
            const auto* copy = dynamic_cast<const vulkan::CopyPass*>(pass);
            if (copy == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(copy->desc().dst);
            step.reads.push_back(scene.ResolveRenderTargetName(copy->desc().src));
            break;
        }
        case MetalPassKind::CustomShader: {
            const auto* custom = dynamic_cast<const vulkan::CustomShaderPass*>(pass);
            if (custom == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(custom->desc().output);
            for (const auto& texture : custom->desc().textures) {
                if (texture.empty()) continue;
                step.reads.push_back(scene.ResolveRenderTargetName(texture));
            }
            break;
        }
        }
        steps.push_back(std::move(step));
    }

    // Depth and multisampled attachments are the two target shapes this backend
    // has no allocation for. Checked against the targets the graph actually
    // names, so an unused declaration in the project file cannot reject a scene.
    const auto unrenderable = [&scene](const std::string& key) {
        const auto* target = scene.FindRenderTarget(key);
        return target != nullptr && (target->withDepth || target->sample_count > 1);
    };

    std::unordered_set<std::string> written;
    for (std::size_t i = 0; i < steps.size(); ++i) {
        if (unrenderable(steps[i].writes)) {
            return "an effect uses a render-target format the native renderer cannot create";
        }
        for (const auto& read : steps[i].reads) {
            if (unrenderable(read)) {
                return "an effect uses a render-target format the native renderer cannot create";
            }
            // The graph breaks a read-while-write by copying the target first,
            // so a pass still naming its own output has a cycle nothing broke.
            if (! read.empty() && read == steps[i].writes) {
                return "an effect reads the image it is drawing into";
            }
            if (! IsSpecTex(read)) continue;          // an imported image, not a target
            if (written.count(read) != 0) continue;   // produced earlier in this same frame
            const bool written_later =
                std::any_of(steps.begin() + static_cast<std::ptrdiff_t>(i) + 1, steps.end(),
                            [&read](const GraphStep& later) { return later.writes == read; });
            // Read before anything filled it, and filled afterwards: what this
            // pass samples is the previous frame's result.
            if (written_later) return "the scene uses a history feedback effect";
        }
        if (! steps[i].writes.empty()) written.insert(steps[i].writes);
    }
    return {};
}

} // namespace wallpaper::metal
