#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "WPSceneParser.hpp"
#include "SpecTexs.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/PassCommon.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <map>
#include <span>
#include <string>
#include <vector>
#include <array>

#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"

namespace
{
using wallpaper::Scene;
using wallpaper::SceneCamera;
using wallpaper::SceneImageEffect;
using wallpaper::SceneImageEffectLayer;
using wallpaper::SceneImageEffectNode;
using wallpaper::SceneMaterial;
using wallpaper::SceneMesh;
using wallpaper::SceneNode;
using wallpaper::SceneRenderTarget;
using wallpaper::SpecTex_Default;
using wallpaper::vulkan::CopyPass;
using wallpaper::vulkan::CustomShaderPass;

class MemoryFs final : public wallpaper::fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::string> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<wallpaper::fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        const auto& s = it->second;
        return std::make_shared<wallpaper::fs::MemBinaryStream>(
            std::vector<uint8_t>(s.begin(), s.end()));
    }

    std::shared_ptr<wallpaper::fs::IBinaryStreamW> OpenW(std::string_view) override {
        return nullptr;
    }

private:
    std::map<std::string, std::string> m_files;
};

class Bytes {
public:
    void Stamp(std::string_view prefix, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "%.4s%.4d", prefix.data(), version);
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(stamp), sizeof(stamp)));
    }
    void Str(std::string_view value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(value.data()), value.size()));
        U8(0);
    }
    void U8(uint8_t value) { RawValue(value); }
    void U16(uint16_t value) { RawValue(value); }
    void U32(uint32_t value) { RawValue(value); }
    void F32(float value) { RawValue(value); }
    void Raw(std::span<const uint8_t> bytes) {
        m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
    }
    std::string TakeString() {
        return std::string(reinterpret_cast<const char*>(m_bytes.data()), m_bytes.size());
    }

private:
    template<typename T>
    void RawValue(const T& value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(&value), sizeof(value)));
    }

    std::vector<uint8_t> m_bytes;
};

constexpr uint32_t kSkinUvFlag = 0x00800000u | 0x01000000u | 0x00000008u;

void WritePuppetVertex(Bytes& b, float x, float y, float u) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.F32(1.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
}

void WritePuppetMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(3u * 52u);
    WritePuppetVertex(b, 0.0f, 0.0f, 0.0f);
    WritePuppetVertex(b, 1.0f, 0.0f, 0.5f);
    WritePuppetVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

std::string BuildMaskedPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 23);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WritePuppetMesh(b, "mat/head.json", 10);
    b.U32(1);
    b.U32(7);
    b.U32(0);
    b.Str("masks/iris_mask");
    b.U32(0);
    b.U32(1);
    b.U32(0);
    b.U32(1);
    b.U32(0);
    return b.TakeString();
}

std::string PuppetMaterialJson(std::string_view                        shader,
                               std::initializer_list<std::string_view> textures) {
    std::string texture_json;
    for (const auto texture : textures) {
        if (! texture_json.empty()) texture_json += ",";
        texture_json += "\"" + std::string(texture) + "\"";
    }
    return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                       R"("depthtest":"disabled","depthwrite":"disabled","shader":")") +
           std::string(shader) + R"(","textures":[)" + texture_json + R"(]}]})";
}

std::string BasicSceneJson(std::string_view image) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"masked puppet image","image":")") +
           std::string(image) +
           R"(","origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";
}

struct GraphPassView {
    std::string             name;
    const CustomShaderPass* custom {};
    const CopyPass*         copy {};
};

std::shared_ptr<SceneMesh> makeMesh(std::string name, std::vector<std::string> textures = {}) {
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial material {};
    material.name     = std::move(name);
    material.textures = std::move(textures);
    mesh->AddMaterial(std::move(material));
    return mesh;
}

std::shared_ptr<SceneNode> makeNode(
    std::string name,
    std::vector<std::string> textures = {}) {
    auto node = std::make_shared<SceneNode>();
    node->SetName(name);
    node->AddMesh(makeMesh(std::move(name), std::move(textures)));
    return node;
}

std::vector<GraphPassView> graphPasses(const wallpaper::rg::RenderGraph& graph) {
    std::vector<GraphPassView> passes;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass_node = graph.getPassNode(id);
        assert(pass_node != nullptr);
        auto* pass = graph.getPass(id);
        assert(pass != nullptr);
        passes.push_back(GraphPassView {
            .name   = std::string(pass_node->name()),
            .custom = dynamic_cast<const CustomShaderPass*>(pass),
            .copy   = dynamic_cast<const CopyPass*>(pass),
        });
    }
    return passes;
}

const CustomShaderPass* findCustomPass(
    const std::vector<GraphPassView>& passes,
    const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.custom != nullptr && pass.name == name;
    });
    assert(it != passes.end());
    return it->custom;
}

const CustomShaderPass* findCustomPassByNodeName(
    const std::vector<GraphPassView>& passes,
    const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.custom != nullptr && pass.custom->desc().node != nullptr &&
            pass.custom->desc().node->Name() == name;
    });
    assert(it != passes.end());
    return it->custom;
}

const GraphPassView* findCustomPassViewByNodeName(
    const std::vector<GraphPassView>& passes,
    const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.custom != nullptr && pass.custom->desc().node != nullptr &&
            pass.custom->desc().node->Name() == name;
    });
    assert(it != passes.end());
    return &(*it);
}

size_t findPassIndex(const std::vector<GraphPassView>& passes, const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.name == name;
    });
    assert(it != passes.end());
    return static_cast<size_t>(std::distance(passes.begin(), it));
}

const GraphPassView* findCopyPass(
    const std::vector<GraphPassView>& passes,
    const std::string& src,
    const std::string& dst) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&src, &dst](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == src &&
            pass.copy->desc().dst == dst;
    });
    if (it == passes.end()) return nullptr;
    return &(*it);
}

void installDefaultTargets(Scene& scene, bool default_reuse = true) {
    scene.activeCamera = nullptr;
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width      = 1920,
        .height     = 1080,
        .allowReuse = default_reuse,
    };
    scene.cameras["effect"] = std::make_shared<SceneCamera>(1920, 1080, 0.01f, 100.0f);
}

void renderTargetAliasesResolveForOutputAndSampledSpecTextures() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_resolved"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargetAliases["_alias_target"] = "_rt_resolved";

    auto sampled = makeNode("sampled_writer");
    scene.sceneGraph->AppendChild(sampled);

    auto sampler = makeNode("alias_sampler", { "_alias_target" });
    scene.sceneGraph->AppendChild(sampler);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        sampled.get(),
        64.0f,
        64.0f,
        "_alias_target",
        "_rt_pingpong_b"));
    sampled->SetCamera("alias_camera");
    scene.cameras["alias_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* output_pass = findCustomPass(passes, "sampled_writer");
    assert(output_pass->desc().output == "_rt_resolved");

    const auto* sampled_pass = findCustomPass(passes, "alias_sampler");
    assert(sampled_pass->desc().textures.size() == 1);
    assert(sampled_pass->desc().textures[0] == "_rt_resolved");
}

void runtimeTextTextureNamesStayImported() {
    Scene scene;
    installDefaultTargets(scene);
    scene.textures["runtime/text/Clock"].url = "runtime/text/Clock";

    auto text = makeNode("text", { "runtime/text/Clock" });
    scene.sceneGraph->AppendChild(text);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* text_pass = findCustomPass(passes, "text");
    assert(text_pass->desc().textures.size() == 1);
    assert(text_pass->desc().textures[0] == "runtime/text/Clock");

    const auto order = graph->topologicalOrder();
    const auto reads = graph->getLastReadTexs({ order });
    bool found_imported_text_texture = false;
    for (const auto& pass_reads : reads) {
        for (const auto* texture : pass_reads) {
            if (texture != nullptr && texture->key() == "runtime/text/Clock") {
                found_imported_text_texture =
                    texture->type() == wallpaper::rg::TexNode::TexType::Imported;
            }
        }
    }
    assert(found_imported_text_texture);
}

void submeshMaterialSlotsEmitDistinctCustomPasses() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_submesh_slots"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto node = std::make_shared<SceneNode>();
    node->SetName("multi_slot_mesh");

    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial body {};
    body.name = "body";
    SceneMaterial eyes {};
    eyes.name = "eyes";
    mesh->AddMaterial(std::move(body));
    mesh->AddMaterial(std::move(eyes));

    mesh->Submeshes().emplace_back();
    mesh->Submeshes().emplace_back();
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[1].material_slot = 1;

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        node.get(),
        64.0f,
        64.0f,
        "_rt_submesh_slots",
        "_rt_unused"));
    node->SetCamera("submesh_slots_camera");
    scene.cameras["submesh_slots_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* body_pass = findCustomPass(passes, "body");
    const auto* eyes_pass = findCustomPass(passes, "eyes");

    assert(body_pass->desc().output == "_rt_submesh_slots");
    assert(eyes_pass->desc().output == "_rt_submesh_slots");
    assert(body_pass->desc().submesh_index == 0);
    assert(body_pass->desc().material_slot == 0);
    assert(eyes_pass->desc().submesh_index == 1);
    assert(eyes_pass->desc().material_slot == 1);
    assert(body_pass->desc().clear_on_first_use);
    assert(!body_pass->desc().preserve_target_contents);
    assert(!eyes_pass->desc().clear_on_first_use);
    assert(eyes_pass->desc().preserve_target_contents);
}

void submeshMaterialRoutingDoesNotRequireSlotZero() {
    Scene scene;
    installDefaultTargets(scene);

    auto node = std::make_shared<SceneNode>();
    node->SetName("slot_one_only_mesh");

    auto mesh = std::make_shared<SceneMesh>();
    mesh->MaterialSlots().push_back(nullptr);
    SceneMaterial slot_one {};
    slot_one.name = "slot_one";
    mesh->AddMaterial(std::move(slot_one));

    mesh->Submeshes().emplace_back();
    mesh->Submeshes().emplace_back();
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[1].material_slot = 1;

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    assert(std::none_of(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.custom != nullptr && pass.name.empty();
    }));

    const auto* slot_one_pass = findCustomPass(passes, "slot_one");
    assert(slot_one_pass->desc().output == SpecTex_Default);
    assert(slot_one_pass->desc().submesh_index == 1);
    assert(slot_one_pass->desc().material_slot == 1);
}

void submeshOutputOverrideRoutesOnlyThatPass() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_puppet_mask"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_puppet_layer"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto node = std::make_shared<SceneNode>();
    node->SetName("masked_puppet");

    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial mask {};
    mask.name = "mask_pass";
    SceneMaterial clipped {};
    clipped.name = "clipped_pass";
    clipped.textures.resize(9);
    clipped.textures[8] = "_rt_puppet_mask";
    mesh->AddMaterial(std::move(mask));
    mesh->AddMaterial(std::move(clipped));
    mesh->Submeshes().emplace_back();
    mesh->Submeshes().emplace_back();
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[0].output_override = "_rt_puppet_mask";
    mesh->Submeshes()[1].material_slot = 1;

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        node.get(),
        64.0f,
        64.0f,
        "_rt_puppet_layer",
        "_rt_unused"));
    node->SetCamera("mask_camera");
    scene.cameras["mask_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* mask_pass = findCustomPass(passes, "mask_pass");
    const auto* clipped_pass = findCustomPass(passes, "clipped_pass");
    assert(mask_pass->desc().output == "_rt_puppet_mask");
    assert(clipped_pass->desc().output == "_rt_puppet_layer");
    assert(clipped_pass->desc().textures.size() == 9);
    assert(clipped_pass->desc().textures[8] == "_rt_puppet_mask");
}

void generatedPuppetMaskSubmeshesRoutePrepassAndMainClip() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_puppet_mask"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
        .forceClear = true,
    };

    auto node = std::make_shared<SceneNode>();
    node->SetName("generated_masked_puppet");

    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial base {};
    base.name = "base_unclipped";
    SceneMaterial prepass {};
    prepass.name = "generated_mask_prepass";
    SceneMaterial clipped {};
    clipped.name = "generated_clipped_main";
    clipped.textures.resize(9);
    clipped.textures[8] = "_rt_puppet_mask";
    mesh->AddMaterial(std::move(base));
    mesh->AddMaterial(std::move(prepass));
    mesh->AddMaterial(std::move(clipped));

    mesh->Submeshes().resize(3);
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[1].material_slot = 1;
    mesh->Submeshes()[1].output_override = "_rt_puppet_mask";
    mesh->Submeshes()[1].SetDrawRanges(std::array<SceneMesh::DrawRange, 1> {
        SceneMesh::DrawRange { .indexOffset = 0, .indexCount = 3 },
    });
    mesh->Submeshes()[2].material_slot = 2;
    mesh->Submeshes()[2].SetDrawRanges(std::array<SceneMesh::DrawRange, 1> {
        SceneMesh::DrawRange { .indexOffset = 3, .indexCount = 3 },
    });

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* prepass_pass = findCustomPass(passes, "generated_mask_prepass");
    const auto* clipped_pass = findCustomPass(passes, "generated_clipped_main");
    assert(prepass_pass->desc().output == "_rt_puppet_mask");
    assert(prepass_pass->desc().submesh_index == 1);
    assert(prepass_pass->desc().material_slot == 1);
    assert(clipped_pass->desc().output == SpecTex_Default);
    assert(clipped_pass->desc().submesh_index == 2);
    assert(clipped_pass->desc().material_slot == 2);
    assert(clipped_pass->desc().textures.size() == 9);
    assert(clipped_pass->desc().textures[8] == "_rt_puppet_mask");
    assert(clipped_pass->desc().preserve_target_contents);
}

void parsedMaskedPuppetMaterialSlotsReachRenderGraph() {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/puppet_image.json",
          R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})" },
        { "/puppet.mdl", BuildMaskedPuppetMdlFixture() },
        { "/mat/base.json", PuppetMaterialJson("baseimage", { "base.tex" }) },
        { "/mat/head.json", PuppetMaterialJson("puppetmain", { "head.tex" }) },
        { "/shaders/baseimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/baseimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/puppetmain.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/puppetmain.frag",
          R"(uniform sampler2D g_Texture0;
#if CLIPPINGTARGET
uniform sampler2D g_Texture8;
#endif
varying vec2 v_TexCoord;
void main() {
  vec4 color = texture(g_Texture0, v_TexCoord);
#if CLIPPINGTARGET
  color *= texture(g_Texture8, v_TexCoord);
#endif
  gl_FragColor = color;
}
)" },
        { "/shaders/clippingmaskimage4.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/clippingmaskimage4.frag",
          R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * texture(g_Texture1, v_TexCoord);
}
)" },
        { "/materials/base.tex.tex", "" },
        { "/materials/head.tex.tex", "" },
        { "/materials/masks/iris_mask.tex", "" },
    };
    assert(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager;
    wallpaper::WPSceneParser       parser;
    auto parsed = parser.Parse(
        "parsed-masked-puppet", BasicSceneJson("puppet_image.json"), vfs, sound_manager);
    assert(parsed != nullptr);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* base_pass = findCustomPass(passes, "puppetmain");
    const auto* prepass_pass = findCustomPass(passes, "clippingmaskimage4");
    const auto clipped_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.custom != nullptr && pass.name == "puppetmain" &&
            pass.custom->desc().material_slot == 2;
    });
    assert(clipped_it != passes.end());
    const auto* clipped_pass = clipped_it->custom;

    assert(base_pass->desc().submesh_index == 0);
    assert(base_pass->desc().material_slot == 0);
    assert(prepass_pass->desc().submesh_index == 1);
    assert(prepass_pass->desc().material_slot == 1);
    assert(prepass_pass->desc().output == "_rt_puppet_mask");
    assert(clipped_pass->desc().submesh_index == 2);
    assert(clipped_pass->desc().material_slot == 2);
    assert(clipped_pass->desc().textures.size() == 9);
    assert(clipped_pass->desc().textures[8] == "_rt_puppet_mask");
}

void skippedBasePassStillEmitsEffectPasses() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_fx_a"] = SceneRenderTarget { .width = 64, .height = 64 };
    scene.renderTargets["_rt_fx_b"] = SceneRenderTarget { .width = 64, .height = 64 };

    auto base = makeNode("skipped_base");
    base->SetSkipRenderPass(true);
    scene.sceneGraph->AppendChild(base);

    auto effect_node = makeNode("effect_after_skipped_base");
    auto effect      = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back(SceneImageEffectNode {
        .output    = "_rt_fx_b",
        .sceneNode = effect_node,
    });

    auto layer = std::make_shared<SceneImageEffectLayer>(
        base.get(),
        64.0f,
        64.0f,
        "_rt_fx_a",
        "_rt_fx_b");
    layer->AddEffect(effect);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(layer);
    base->SetCamera("effect_camera");
    scene.cameras["effect_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    assert(std::none_of(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.name == "skipped_base";
    }));
    assert(findCustomPass(passes, "effect_after_skipped_base") != nullptr);
}

void composeBaseRunsBeforeChildrenAndEffectsAfterChildren() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_compose_a"] = SceneRenderTarget { .width = 64, .height = 64 };
    scene.renderTargets["_rt_compose_b"] = SceneRenderTarget { .width = 64, .height = 64 };

    auto compose = makeNode("compose_base");
    scene.sceneGraph->AppendChild(compose);

    auto child = makeNode("compose_child");
    compose->AppendChild(child);

    auto effect_node = makeNode("compose_effect", { "_rt_compose_a" });
    auto effect      = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back(SceneImageEffectNode {
        .output    = "_rt_compose_b",
        .sceneNode = effect_node,
    });

    auto layer = std::make_shared<SceneImageEffectLayer>(
        compose.get(),
        64.0f,
        64.0f,
        "_rt_compose_a",
        "_rt_compose_b");
    layer->AddEffect(effect);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchNode(compose);
    camera->AttatchImgEffect(layer);
    camera->SetComposeLayer(true);
    compose->SetCamera("compose_camera");
    scene.cameras["compose_camera"] = camera;
    scene.activeCamera              = camera.get();

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto base_index   = findPassIndex(passes, "compose_base");
    const auto child_index  = findPassIndex(passes, "compose_child");
    const auto effect_index = findPassIndex(passes, "compose_effect");

    assert(base_index < child_index);
    assert(child_index < effect_index);
}

void parsedContainerDeclarationOrderControlsRenderPassOrder() {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    assert(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager;
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":200,"name":"early container","origin":[10,0,0],"visible":true},
        {"id":201,"name":"middle sibling","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":202,"parent":200,"name":"late child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("rendergraph-declaration-order", scene_json, vfs, sound_manager);
    assert(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* child_view = findCustomPassViewByNodeName(passes, "late child");
    const auto* sibling_view = findCustomPassViewByNodeName(passes, "middle sibling");
    const auto child_index =
        static_cast<size_t>(std::distance(passes.data(), child_view));
    const auto sibling_index =
        static_cast<size_t>(std::distance(passes.data(), sibling_view));
    assert(child_index < sibling_index);
}

void parsedForwardParentDeclarationOrderControlsRenderPassOrder() {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    assert(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager;
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":302,"parent":300,"name":"early child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":301,"name":"middle root","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":300,"name":"late parent","origin":[10,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("rendergraph-forward-parent-order", scene_json, vfs, sound_manager);
    assert(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* child_view = findCustomPassViewByNodeName(passes, "early child");
    const auto* root_view  = findCustomPassViewByNodeName(passes, "middle root");
    const auto child_index =
        static_cast<size_t>(std::distance(passes.data(), child_view));
    const auto root_index =
        static_cast<size_t>(std::distance(passes.data(), root_view));
    assert(root_index < child_index);
}

void reusableNonDefaultTargetClearsOnlyOnFirstWriter() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_reusable"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto first = makeNode("first_reusable_writer");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_reusable_writer");
    scene.sceneGraph->AppendChild(second);

    auto first_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    first_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        first.get(),
        64.0f,
        64.0f,
        "_rt_reusable",
        "_rt_unused_a"));
    first->SetCamera("first_camera");
    scene.cameras["first_camera"] = first_camera;

    auto second_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    second_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        second.get(),
        64.0f,
        64.0f,
        "_rt_reusable",
        "_rt_unused_b"));
    second->SetCamera("second_camera");
    scene.cameras["second_camera"] = second_camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_reusable_writer");
    const auto* second_pass = findCustomPass(passes, "second_reusable_writer");

    assert(first_pass->desc().output == "_rt_reusable");
    assert(first_pass->desc().clear_on_first_use);
    assert(!first_pass->desc().preserve_target_contents);

    assert(second_pass->desc().output == "_rt_reusable");
    assert(!second_pass->desc().clear_on_first_use);
    assert(second_pass->desc().preserve_target_contents);
}

void forceClearReusableTargetClearsEveryWriter() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_force_clear"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
        .forceClear = true,
    };

    auto first = makeNode("first_force_clear_writer");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_force_clear_writer");
    scene.sceneGraph->AppendChild(second);

    auto first_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    first_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        first.get(),
        64.0f,
        64.0f,
        "_rt_force_clear",
        "_rt_unused_a"));
    first->SetCamera("first_force_clear_camera");
    scene.cameras["first_force_clear_camera"] = first_camera;

    auto second_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    second_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        second.get(),
        64.0f,
        64.0f,
        "_rt_force_clear",
        "_rt_unused_b"));
    second->SetCamera("second_force_clear_camera");
    scene.cameras["second_force_clear_camera"] = second_camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_force_clear_writer");
    const auto* second_pass = findCustomPass(passes, "second_force_clear_writer");

    assert(first_pass->desc().output == "_rt_force_clear");
    assert(first_pass->desc().clear_on_first_use);
    assert(!first_pass->desc().preserve_target_contents);

    assert(second_pass->desc().output == "_rt_force_clear");
    assert(second_pass->desc().clear_on_first_use);
    assert(!second_pass->desc().preserve_target_contents);
}

void forceClearDoesNotChangeDefaultOutputPreservation() {
    Scene scene;
    installDefaultTargets(scene);
    scene.clearEnabled = false;
    scene.renderTargets[std::string(SpecTex_Default)].forceClear = true;

    auto first = makeNode("first_default_force_clear_guard");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_default_force_clear_guard");
    scene.sceneGraph->AppendChild(second);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_default_force_clear_guard");
    const auto* second_pass = findCustomPass(passes, "second_default_force_clear_guard");

    assert(first_pass->desc().output == SpecTex_Default);
    assert(!first_pass->desc().clear_on_first_use);
    assert(!first_pass->desc().preserve_target_contents);

    assert(second_pass->desc().output == SpecTex_Default);
    assert(!second_pass->desc().clear_on_first_use);
    assert(second_pass->desc().preserve_target_contents);
}

void renderTargetSampleCountPropagatesToCustomPassDesc() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_scaffold"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };

    auto writer = makeNode("msaa_scaffold_writer");
    scene.sceneGraph->AppendChild(writer);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        writer.get(),
        64.0f,
        64.0f,
        "_rt_msaa_scaffold",
        "_rt_unused"));
    writer->SetCamera("msaa_scaffold_camera");
    scene.cameras["msaa_scaffold_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* pass = findCustomPass(passes, "msaa_scaffold_writer");
    assert(pass->desc().output == "_rt_msaa_scaffold");
    assert(pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);
}

void copyWrittenMsaaTargetsPreserveWithSingleSamplePasses() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_after_copy"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };

    auto writer = makeNode("msaa_after_copy_writer");
    auto post   = std::make_shared<wallpaper::ScenePostProcess>();
    post->name  = "msaa_after_copy_post";
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = std::string(SpecTex_Default),
        .dst = "_rt_msaa_after_copy",
    });
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = writer,
        .output = "_rt_msaa_after_copy",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* pass = findCustomPass(passes, "msaa_after_copy_writer");
    assert(pass->desc().output == "_rt_msaa_after_copy");
    assert(pass->desc().preserve_target_contents);
    assert(pass->desc().sample_count == VK_SAMPLE_COUNT_1_BIT);
}

void separateMsaaRenderTargetWritersPreserveWithMsaaSampleCount() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_multi_writer"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };

    auto first = makeNode("first_msaa_multi_writer");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_msaa_multi_writer");
    scene.sceneGraph->AppendChild(second);

    auto first_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    first_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        first.get(),
        64.0f,
        64.0f,
        "_rt_msaa_multi_writer",
        "_rt_unused_a"));
    first->SetCamera("first_msaa_multi_writer_camera");
    scene.cameras["first_msaa_multi_writer_camera"] = first_camera;

    auto second_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    second_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        second.get(),
        64.0f,
        64.0f,
        "_rt_msaa_multi_writer",
        "_rt_unused_b"));
    second->SetCamera("second_msaa_multi_writer_camera");
    scene.cameras["second_msaa_multi_writer_camera"] = second_camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_msaa_multi_writer");
    const auto* second_pass = findCustomPass(passes, "second_msaa_multi_writer");

    assert(first_pass->desc().output == "_rt_msaa_multi_writer");
    assert(first_pass->desc().clear_on_first_use);
    assert(!first_pass->desc().preserve_target_contents);
    assert(first_pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);

    assert(second_pass->desc().output == "_rt_msaa_multi_writer");
    assert(!second_pass->desc().clear_on_first_use);
    assert(second_pass->desc().preserve_target_contents);
    assert(second_pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);
}

void videoTextureSamplingIsPreservedInMsaaScenePass() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_video"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };
    scene.textures["video://clip"] = wallpaper::SceneTexture {
        .url     = "video://clip",
        .isVideo = true,
    };

    auto writer = makeNode("msaa_video_sampler", { "video://clip" });
    scene.sceneGraph->AppendChild(writer);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        writer.get(),
        64.0f,
        64.0f,
        "_rt_msaa_video",
        "_rt_unused"));
    writer->SetCamera("msaa_video_camera");
    scene.cameras["msaa_video_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* pass = findCustomPass(passes, "msaa_video_sampler");
    assert(pass->desc().output == "_rt_msaa_video");
    assert(pass->desc().textures.size() == 1);
    assert(pass->desc().textures[0] == "video://clip");
    assert(pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);
}

void defaultOutputUsesSceneClearEnabledWhileNonDefaultWritesAlpha() {
    Scene scene;
    installDefaultTargets(scene);
    scene.clearEnabled = false;
    scene.renderTargets["_rt_alpha"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto default_node = makeNode("default_writer");
    scene.sceneGraph->AppendChild(default_node);

    auto offscreen_node = makeNode("alpha_writer");
    scene.sceneGraph->AppendChild(offscreen_node);
    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        offscreen_node.get(),
        64.0f,
        64.0f,
        "_rt_alpha",
        "_rt_unused"));
    offscreen_node->SetCamera("alpha_camera");
    scene.cameras["alpha_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* default_pass = findCustomPass(passes, "default_writer");
    assert(default_pass->desc().output == SpecTex_Default);
    assert(!default_pass->desc().clear_on_first_use);
    assert(!default_pass->desc().write_alpha);

    const auto* offscreen_pass = findCustomPass(passes, "alpha_writer");
    assert(offscreen_pass->desc().output == "_rt_alpha");
    assert(offscreen_pass->desc().clear_on_first_use);
    assert(offscreen_pass->desc().write_alpha);

    Scene clear_scene;
    installDefaultTargets(clear_scene);
    clear_scene.clearEnabled = true;

    auto clear_node = makeNode("default_clear_writer");
    clear_scene.sceneGraph->AppendChild(clear_node);

    const auto clear_graph  = wallpaper::sceneToRenderGraph(clear_scene);
    const auto clear_passes = graphPasses(*clear_graph);

    const auto* clear_pass = findCustomPass(clear_passes, "default_clear_writer");
    assert(clear_pass->desc().output == SpecTex_Default);
    assert(clear_pass->desc().clear_on_first_use);
    assert(!clear_pass->desc().write_alpha);
}

void postProcessesAppendPassesAndCopiesAfterSceneGraph() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_post_pass"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_post_copy"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto scene_node = makeNode("main_scene_writer");
    scene.sceneGraph->AppendChild(scene_node);

    auto post_node = makeNode("post_process_writer", { SpecTex_Default.data() });
    auto post      = std::make_shared<wallpaper::ScenePostProcess>();
    post->name     = "test_post_process";
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = post_node,
        .output = "_rt_post_pass",
    });
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = "_rt_post_pass",
        .dst = "_rt_post_copy",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto scene_index = findPassIndex(passes, "main_scene_writer");
    const auto post_index  = findPassIndex(passes, "post_process_writer");
    const auto copy_it     = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == "_rt_post_pass"
            && pass.copy->desc().dst == "_rt_post_copy";
    });
    assert(copy_it != passes.end());
    const auto copy_index = static_cast<size_t>(std::distance(passes.begin(), copy_it));

    assert(scene_index < post_index);
    assert(post_index < copy_index);

    const auto* post_pass = findCustomPass(passes, "post_process_writer");
    assert(post_pass->desc().output == "_rt_post_pass");
    assert(copy_it->copy->desc().src == "_rt_post_pass");
    assert(copy_it->copy->desc().dst == "_rt_post_copy");
}

void nullPostProcessPassNodesAreSkipped() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_after_null_pass"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_after_null_copy"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto post_node = makeNode("post_after_null_pass");
    auto post      = std::make_shared<wallpaper::ScenePostProcess>();
    post->name     = "null_pass_guard";
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = nullptr,
        .output = "_rt_ignored_null_pass",
    });
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = post_node,
        .output = "_rt_after_null_pass",
    });
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = "_rt_after_null_pass",
        .dst = "_rt_after_null_copy",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* post_pass = findCustomPass(passes, "post_after_null_pass");
    assert(post_pass->desc().output == "_rt_after_null_pass");
    assert(std::any_of(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == "_rt_after_null_pass"
            && pass.copy->desc().dst == "_rt_after_null_copy";
    }));
}

void postProcessCopyStepsResolveRenderTargetAliases() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_alias_resolved_src"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_alias_resolved_dst"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargetAliases["_alias_post_src"] = "_rt_alias_resolved_src";
    scene.renderTargetAliases["_alias_post_dst"] = "_rt_alias_resolved_dst";

    auto post_node = makeNode("alias_post_writer");
    auto post      = std::make_shared<wallpaper::ScenePostProcess>();
    post->name     = "alias_post_process";
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = post_node,
        .output = "_alias_post_src",
    });
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = "_alias_post_src",
        .dst = "_alias_post_dst",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* post_pass = findCustomPass(passes, "alias_post_writer");
    assert(post_pass->desc().output == "_rt_alias_resolved_src");

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == "_rt_alias_resolved_src"
            && pass.copy->desc().dst == "_rt_alias_resolved_dst";
    });
    assert(copy_it != passes.end());

    const auto post_index = findPassIndex(passes, "alias_post_writer");
    const auto copy_index = static_cast<size_t>(std::distance(passes.begin(), copy_it));
    assert(post_index < copy_index);
}

void linkedImageCompositeTexturesResolveToSourceLayerOutput() {
    Scene scene;
    installDefaultTargets(scene);

    auto source = makeNode("source_layer");
    source->ID() = 159;
    scene.sceneGraph->AppendChild(source);

    auto consumer = makeNode("consumer_layer", { wallpaper::GenLinkTex(159) });
    consumer->ID() = 160;
    scene.sceneGraph->AppendChild(consumer);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPass(passes, "consumer_layer");
    assert(consumer_pass->desc().textures.size() == 1);
    assert(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(159));

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().dst == wallpaper::GenLinkTex(159);
    });
    assert(copy_it != passes.end());
}

void parsedInvisibleDependencySourceResolvesLinkedRenderTexture() {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/linked.json",
          R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/linked_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    assert(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager;
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":159,"name":"dependency source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":160,"name":"consumer","image":"linked.json","dependencies":[159],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("linked-invisible-dependency", scene_json, vfs, sound_manager);
    assert(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPassByNodeName(passes, "consumer");
    assert(consumer_pass->desc().textures.size() == 1);
    assert(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(159));

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().dst == wallpaper::GenLinkTex(159);
    });
    assert(copy_it != passes.end());
}

void parsedZeroHeightDependencyEffectUsesNonZeroRenderTargets() {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/models/util/solidlayer.json",
          R"({"material":"materials/util/solidlayer.json"})" },
        { "/materials/util/solidlayer.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid.tex"]}]})" },
        { "/effects/audio_buffer_accumulation/effect.json",
          R"({"name":"Audio Buffer Accumulation","fbos":[{"name":"_rt_FullCompoBuffer1","scale":1},{"name":"_rt_FullCompoBuffer2","scale":1},{"name":"_rt_TinyScaledBuffer","scale":512}],"passes":[{"material":"materials/effects/accumulate.json","target":"_rt_FullCompoBuffer2","bind":[{"name":"previous","index":0},{"name":"_rt_FullCompoBuffer1","index":1}]},{"command":"copy","source":"_rt_FullCompoBuffer2","target":"_rt_FullCompoBuffer1"},{"material":"materials/effects/combine.json","bind":[{"name":"_rt_FullCompoBuffer2","index":0}]}]})" },
        { "/materials/effects/accumulate.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null,null]}]})" },
        { "/materials/effects/combine.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/linked.json",
          R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/linked_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_915"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/solid.tex.tex", "" },
    };
    assert(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager;
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":915,"name":"zero height dependency source","image":"models/util/solidlayer.json",
         "origin":[0,0,0],"scale":[0,0,0],"size":[64,0],"visible":false,
         "effects":[{"file":"effects/audio_buffer_accumulation/effect.json","id":917,"visible":true}]},
        {"id":916,"name":"consumer","image":"linked.json","dependencies":[915],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("zero-height-dependency-effect", scene_json, vfs, sound_manager);
    assert(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPassByNodeName(passes, "consumer");
    assert(consumer_pass->desc().textures.size() == 1);
    assert(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(915));

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().dst == wallpaper::GenLinkTex(915);
    });
    assert(copy_it != passes.end());

    const std::string full_compo_prefix =
        std::string(wallpaper::WE_FULL_COMPO_BUFFER_PREFIX);
    const std::string effect_pingpong_prefix =
        std::string(wallpaper::WE_EFFECT_PPONG_PREFIX);
    for (const auto& [name, target] : parsed->renderTargets) {
        const bool relevant =
            name.rfind(full_compo_prefix, 0) == 0 || name.rfind(effect_pingpong_prefix, 0) == 0 ||
            name.find("_rt_TinyScaledBuffer") != std::string::npos;
        if (!relevant) continue;
        assert(target.width * target.height > 4);
        assert(target.width >= 4);
        assert(target.height >= 4);
        if (name.find("_rt_TinyScaledBuffer") == std::string::npos) {
            assert(target.width == 64);
            assert(target.height == 360);
        }
    }
}

void linkedEffectSourceFallsBackToBaseTargetWhenEffectsFailToLoad() {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/source.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/failing/effect.json",
          R"({"name":"failing effect","passes":[{"material":"materials/missing.json"}]})" },
        { "/linked.json",
          R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/linked_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_915"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    assert(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager;
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":915,"name":"dependency source with failed effect","image":"source.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false,
         "effects":[{"file":"effects/failing/effect.json","id":917,"visible":true}]},
        {"id":916,"name":"consumer","image":"linked.json","dependencies":[915],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("failed-effect-linked-source", scene_json, vfs, sound_manager);
    assert(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPassByNodeName(passes, "consumer");
    assert(consumer_pass->desc().textures.size() == 1);
    assert(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(915));

    const auto* source_view = findCustomPassViewByNodeName(passes, "dependency source with failed effect");
    const auto* source_pass = source_view->custom;
    assert(source_pass->desc().output.rfind(wallpaper::WE_EFFECT_PPONG_PREFIX_A, 0) == 0);
    const auto* link_copy = findCopyPass(passes, source_pass->desc().output, wallpaper::GenLinkTex(915));
    assert(link_copy != nullptr);

    const auto source_index =
        static_cast<size_t>(std::distance(passes.data(), source_view));
    const auto copy_index =
        static_cast<size_t>(std::distance(passes.data(), link_copy));
    const auto* consumer_view = findCustomPassViewByNodeName(passes, "consumer");
    const auto consumer_index =
        static_cast<size_t>(std::distance(passes.data(), consumer_view));
    assert(source_index < copy_index);
    assert(copy_index < consumer_index);
}

void linkedEffectSourceDoesNotUseIntermediateTargetAsFallback() {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_source_base"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_intermediate_effect"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto source = makeNode("source_base");
    source->ID() = 915;
    scene.sceneGraph->AppendChild(source);

    auto effect_node = makeNode("source_intermediate_effect", { "_rt_source_base" });
    auto effect      = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back(SceneImageEffectNode {
        .output    = "_rt_intermediate_effect",
        .sceneNode = effect_node,
    });

    auto layer = std::make_shared<SceneImageEffectLayer>(
        source.get(),
        64.0f,
        64.0f,
        "_rt_source_base",
        "_rt_unused_pingpong");
    layer->AddEffect(effect);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(layer);
    source->SetCamera("source_effect_camera");
    scene.cameras["source_effect_camera"] = camera;

    auto consumer = makeNode("consumer_of_base", { wallpaper::GenLinkTex(915) });
    consumer->ID() = 916;
    scene.sceneGraph->AppendChild(consumer);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPass(passes, "consumer_of_base");
    assert(consumer_pass->desc().textures.size() == 1);
    assert(consumer_pass->desc().textures[0].empty());
    assert(findCopyPass(passes, "_rt_source_base", wallpaper::GenLinkTex(915)) == nullptr);
    assert(findCopyPass(passes, "_rt_intermediate_effect", wallpaper::GenLinkTex(915)) == nullptr);
}

void parsedFullscreenScaledFbosStayValidAfterScreenBindSizing() {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/fullscreen.json",
          R"({"fullscreen":true,"material":"materials/fullscreen.json"})" },
        { "/materials/fullscreen.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid.tex"]}]})" },
        { "/effects/fullscreen_scaled/effect.json",
          R"({"name":"Fullscreen Scaled FBO","fbos":[{"name":"_rt_TinyFullscreenBuffer","scale":512}],"passes":[{"material":"materials/effects/copy.json","target":"_rt_TinyFullscreenBuffer","bind":[{"name":"previous","index":0}]}]})" },
        { "/materials/effects/copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/solid.tex.tex", "" },
    };
    assert(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager;
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "zoom":4,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":930,"name":"fullscreen tiny fbo","image":"fullscreen.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/fullscreen_scaled/effect.json","id":931,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("fullscreen-scaled-fbo", scene_json, vfs, sound_manager);
    assert(parsed != nullptr);
    const auto tiny_it = std::find_if(
        parsed->renderTargets.begin(),
        parsed->renderTargets.end(),
        [](const auto& item) {
            return item.first.find("_rt_TinyFullscreenBuffer") != std::string::npos;
        });
    assert(tiny_it != parsed->renderTargets.end());

    const auto& target = tiny_it->second;
    assert(target.bind.enable);
    assert(target.bind.screen);
    const auto& default_target = parsed->renderTargets.at(std::string(SpecTex_Default));
    assert(default_target.width == 160);
    assert(default_target.height == 90);
    assert(std::abs(target.bind.scale - (1.0 / 512.0)) < 0.000001);

    auto runtime_target = target;
    Scene runtime_scene;
    runtime_scene.renderTargets[std::string(SpecTex_Default)] = default_target;
    runtime_scene.renderTargets["fullscreen_runtime_target"] = runtime_target;
    wallpaper::vulkan::ResolveScreenBoundRenderTargetSizes(
        runtime_scene,
        VkExtent2D {
            .width  = 999,
            .height = 999,
        });
    runtime_target = runtime_scene.renderTargets.at("fullscreen_runtime_target");
    assert(runtime_target.width >= 4);
    assert(runtime_target.height >= 4);
    assert(runtime_target.width * runtime_target.height > 4);
}

void screenBoundSizingHonorsTinyAuthoredDefaultExtent() {
    Scene scene;
    scene.ortho[0] = 640;
    scene.ortho[1] = 360;
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width  = 1,
        .height = 90,
        .bind   = { .enable = true, .screen = true },
    };
    scene.renderTargets["screen_bound_tiny"] = SceneRenderTarget {
        .width = 2,
        .height = 2,
        .bind = {
            .enable = true,
            .screen = true,
            .scale = 1.0,
        },
    };

    const auto source_extent = wallpaper::vulkan::ResolveScreenBoundRenderTargetSizes(
        scene,
        VkExtent2D {
            .width  = 999,
            .height = 999,
        });

    assert(source_extent.width == 1);
    assert(source_extent.height == 90);
    const auto& target = scene.renderTargets.at("screen_bound_tiny");
    assert(target.width == 4);
    assert(target.height == 90);

    const auto second_source_extent = wallpaper::vulkan::ResolveScreenBoundRenderTargetSizes(
        scene,
        VkExtent2D {
            .width  = 999,
            .height = 999,
        });
    assert(second_source_extent.width == 1);
    assert(second_source_extent.height == 90);
    const auto& second_target = scene.renderTargets.at("screen_bound_tiny");
    assert(second_target.width == 4);
    assert(second_target.height == 90);
    const auto& default_target = scene.renderTargets.at(std::string(SpecTex_Default));
    assert(default_target.width == 1);
    assert(default_target.height == 90);
}

void textureDescriptorReadinessRejectsMissingImages() {
    wallpaper::vulkan::CustomShaderPass::Desc desc {};
    desc.textures = { "_rt_imageLayerComposite_159_a" };
    desc.vk_textures.resize(1);
    desc.vk_texture_bindings.push_back({
        .image_binding = 1,
        .image_descriptor_type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .sampler_binding = -1,
    });

    wallpaper::vulkan::CustomShaderPass pass(desc);
    pass.desc().vk_textures = desc.vk_textures;
    pass.desc().vk_texture_bindings = desc.vk_texture_bindings;
    assert(! pass.textureDescriptorsReady());
}

void textureDescriptorReadinessRejectsMissingSeparateSampler() {
    wallpaper::vulkan::CustomShaderPass::Desc desc {};
    desc.textures = { "image.png" };
    desc.vk_textures.resize(1);
    wallpaper::vulkan::ImageParameters image {};
    image.handle  = reinterpret_cast<VkImage>(1);
    image.view    = reinterpret_cast<VkImageView>(1);
    image.sampler = VK_NULL_HANDLE;
    image.layout  = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    desc.vk_textures[0].slots.push_back(image);
    desc.vk_texture_bindings.push_back({
        .image_binding = 1,
        .image_descriptor_type = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .sampler_binding = 2,
    });

    wallpaper::vulkan::CustomShaderPass pass(desc);
    pass.desc().vk_textures = desc.vk_textures;
    pass.desc().vk_texture_bindings = desc.vk_texture_bindings;
    assert(! pass.textureDescriptorsReady());
}
} // namespace

int main() {
    renderTargetAliasesResolveForOutputAndSampledSpecTextures();
    runtimeTextTextureNamesStayImported();
    submeshMaterialSlotsEmitDistinctCustomPasses();
    submeshMaterialRoutingDoesNotRequireSlotZero();
    submeshOutputOverrideRoutesOnlyThatPass();
    generatedPuppetMaskSubmeshesRoutePrepassAndMainClip();
    parsedMaskedPuppetMaterialSlotsReachRenderGraph();
    skippedBasePassStillEmitsEffectPasses();
    composeBaseRunsBeforeChildrenAndEffectsAfterChildren();
    parsedContainerDeclarationOrderControlsRenderPassOrder();
    parsedForwardParentDeclarationOrderControlsRenderPassOrder();
    reusableNonDefaultTargetClearsOnlyOnFirstWriter();
    forceClearReusableTargetClearsEveryWriter();
    forceClearDoesNotChangeDefaultOutputPreservation();
    renderTargetSampleCountPropagatesToCustomPassDesc();
    copyWrittenMsaaTargetsPreserveWithSingleSamplePasses();
    separateMsaaRenderTargetWritersPreserveWithMsaaSampleCount();
    videoTextureSamplingIsPreservedInMsaaScenePass();
    defaultOutputUsesSceneClearEnabledWhileNonDefaultWritesAlpha();
    postProcessesAppendPassesAndCopiesAfterSceneGraph();
    nullPostProcessPassNodesAreSkipped();
    postProcessCopyStepsResolveRenderTargetAliases();
    linkedImageCompositeTexturesResolveToSourceLayerOutput();
    parsedInvisibleDependencySourceResolvesLinkedRenderTexture();
    parsedZeroHeightDependencyEffectUsesNonZeroRenderTargets();
    linkedEffectSourceFallsBackToBaseTargetWhenEffectsFailToLoad();
    linkedEffectSourceDoesNotUseIntermediateTargetAsFallback();
    parsedFullscreenScaledFbosStayValidAfterScreenBindSizing();
    screenBoundSizingHonorsTinyAuthoredDefaultExtent();
    textureDescriptorReadinessRejectsMissingImages();
    textureDescriptorReadinessRejectsMissingSeparateSampler();
    return 0;
}
