#include "MetalRender/MetalCapability.hpp"

#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/SceneMetalProgram.hpp"

#include "RenderGraph/PassNode.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Particle/ParticleSystem.h"

#include <functional>

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

/// Walks the scene graph, stopping at the first rejection.
std::string RejectNodes(const Scene& scene, const SceneNode* node)
{
    if (node == nullptr) return {};

    if (const auto* camera = FindCamera(scene, node->Camera()); camera != nullptr) {
        if (camera->IsPerspective()) return "the scene uses a perspective 3D camera";
        if (camera->HasImgEffect()) return "the scene uses an image effect chain";
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
            for (const auto& texture : material.textures) {
                if (texture.empty()) continue;
                if (IsSpecLinkTex(texture)) {
                    return "the scene links a layer's output into another layer";
                }
                // A material that samples the scene's own colour buffer while
                // drawing into it is feedback. The compatibility backend breaks
                // the cycle with an inserted copy; this one does not implement
                // that, so the whole scene falls back rather than sampling a
                // target mid-write.
                if (scene.ResolveRenderTargetName(texture) ==
                    scene.ResolveRenderTargetName(SpecTex_Default)) {
                    return "a layer samples the image it is drawing into";
                }
            }
        }
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
    if (! scene.post_processes.empty()) return "the scene uses a post-processing chain";
    if (scene.single_video_source) return "the wallpaper is a video";

    for (const auto& [name, texture] : scene.textures) {
        (void)name;
        if (texture.isVideo) return "the scene plays a video texture";
        if (texture.isSprite) return "the scene uses an animated sprite sheet";
    }

    if (SceneUsesPerspective(scene)) return "the scene uses a perspective 3D camera";

    for (const auto& [name, camera] : scene.cameras) {
        (void)name;
        if (camera == nullptr) continue;
        if (camera->HasImgEffect()) return "the scene uses an image effect chain";
    }

    return RejectNodes(scene, scene.sceneGraph.get());
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
    (void)scene;
    for (const auto node_id : graph.topologicalOrder()) {
        const auto* pass_node = graph.getPassNode(node_id);
        if (pass_node == nullptr) {
            return "the render graph contains a step the native renderer does not recognise";
        }
        if (ClassifyMetalPassKind(static_cast<int>(pass_node->type())) ==
            MetalPassKind::Unsupported) {
            return "the render graph contains a step the native renderer does not recognise";
        }
    }
    return {};
}

} // namespace wallpaper::metal
