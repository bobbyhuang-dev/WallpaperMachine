#include <cassert>
#include "SceneImageEffectLayer.h"
#include "SceneNode.h"

#include "SpecTexs.hpp"
#include "Core/StringHelper.hpp"

using namespace wallpaper;

SceneImageEffectLayer::SceneImageEffectLayer(SceneNode* node, float w, float h,
                                             std::string_view pingpong_a,
                                             std::string_view pingpong_b)
    : m_worldNode(node),
      m_pingpong_a(pingpong_a),
      m_pingpong_b(pingpong_b),
      m_final_mesh(std::make_unique<SceneMesh>()),
      m_final_node(std::make_unique<SceneNode>()) {};

void SceneImageEffectLayer::SetFinalMeshDynamic(bool dynamic) {
    auto replacement = std::make_unique<SceneMesh>(dynamic);
    replacement->ChangeMeshDataFrom(*m_final_mesh);
    if (m_final_mesh->Material() != nullptr) {
        replacement->AddMaterial(SceneMaterial(*m_final_mesh->Material()));
    }
    m_final_mesh = std::move(replacement);
}

void SceneImageEffectLayer::ResolveEffect(const SceneMesh& default_mesh,
                                          std::string_view effect_cam) {
    m_resolved_final_render_node = nullptr;
    std::string_view ppong_a = m_pingpong_a, ppong_b = m_pingpong_b;
    auto             swap_pp = [&ppong_a, &ppong_b]() {
        std::swap(ppong_a, ppong_b);
    };
    auto default_node = SceneNode();

    SceneImageEffectNode* last_output { nullptr };
    for (auto& eff : m_effects) {
        for (auto& cmd : eff->commands) {
            if (sstart_with(cmd.src, WE_EFFECT_PPONG_PREFIX_A)) cmd.src = ppong_a;

            if (sstart_with(cmd.dst, WE_EFFECT_PPONG_PREFIX_A)) cmd.dst = ppong_a;
        }
        for (auto it = eff->nodes.begin(); it != eff->nodes.end(); it++) {
            if (sstart_with(it->output, WE_EFFECT_PPONG_PREFIX_B) ||
                it->output == SpecTex_Default) {
                it->output  = ppong_b;
                last_output = &(*it);
            }

            assert(it->sceneNode->HasMaterial());

            auto& material = *(it->sceneNode->Mesh()->Material());
            {
                material.blenmode = BlendMode::Normal;
                it->sceneNode->SetCamera(effect_cam.data());
                it->sceneNode->CopyTrans(default_node);
                it->sceneNode->Mesh()->ChangeMeshDataFrom(default_mesh);
            }

            auto& texs = material.textures;
            std::replace_if(
                texs.begin(),
                texs.end(),
                [](auto& t) {
                    return sstart_with(t, WE_EFFECT_PPONG_PREFIX_A);
                },
                ppong_a);
        }
        swap_pp();
    }
    if (last_output != nullptr) {
        last_output->output = SpecTex_Default;
        m_resolved_final_render_node = last_output->sceneNode.get();
        if (last_output->sceneNode->Mesh() != nullptr &&
            last_output->sceneNode->Mesh()->Dynamic() != m_final_mesh->Dynamic()) {
            auto replacement = std::make_shared<SceneMesh>(m_final_mesh->Dynamic());
            if (last_output->sceneNode->Mesh()->Material() != nullptr) {
                replacement->AddMaterial(SceneMaterial(*last_output->sceneNode->Mesh()->Material()));
            }
            last_output->sceneNode->AddMesh(std::move(replacement));
        }
        auto& mesh          = *(last_output->sceneNode->Mesh());
        auto& material      = *mesh.Material();
        {
            material.blenmode = m_final_blend;
            last_output->sceneNode->SetCamera(std::string());
            last_output->sceneNode->CopyTrans(*m_final_node);
            mesh.ChangeMeshDataFrom(*m_final_mesh);
        }
    }
}
