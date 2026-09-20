#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneLayerReference.hpp"
#include "SpecTexs.hpp"
#include "WPSceneParser.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"

#include <algorithm>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace
{
using namespace wallpaper;

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::string> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        const auto& s = it->second;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(s.begin(), s.end()));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::string> m_files;
};

constexpr std::string_view kVert = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
constexpr std::string_view kFrag = R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)";

std::string SceneJson(std::string_view objects) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":64,"height":32}
      },
      "objects": )") + std::string(objects) + "}";
}

void MountFiles(fs::VFS& vfs, std::map<std::string, std::string> extra = {}) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid"]}]})" },
        { "/linked.json", R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/shaders/genericimage.vert", std::string(kVert) },
        { "/shaders/genericimage.frag", std::string(kFrag) },
        { "/materials/solid.tex", "" },
    };
    for (auto& [path, content] : extra) files[path] = std::move(content);
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

std::shared_ptr<Scene> ParseScene(fs::VFS& vfs, std::string_view objects,
                                  std::map<std::string, std::string> extra = {}) {
    MountFiles(vfs, std::move(extra));
    audio::SoundManager sound;
    WPSceneParser       parser;
    return parser.Parse("layer-texture", SceneJson(objects), vfs, sound);
}

const vulkan::CustomShaderPass* FindPassByNode(
    const rg::RenderGraph& graph, std::string_view name) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == name) {
            return pass;
        }
    }
    return nullptr;
}

size_t PassIndexByNode(const rg::RenderGraph& graph, std::string_view name) {
    size_t index = 0;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == name) {
            return index;
        }
        ++index;
    }
    return static_cast<size_t>(-1);
}

const vulkan::CopyPass* FindLinkCopy(const rg::RenderGraph& graph, std::string_view dst) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CopyPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().dst == dst) return pass;
    }
    return nullptr;
}

const vulkan::CustomShaderPass* FindPassByOutput(const rg::RenderGraph& graph,
                                                 std::string_view output) {
    const vulkan::CustomShaderPass* found = nullptr;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().output == output) found = pass;
    }
    return found;
}

} // namespace

TEST(LayerTextureReference, CompositeIdIsTheAuthoredSyntax) {
    LayerCompositeSlot slot = LayerCompositeSlot::None;
    const auto         id   = ParseImageLayerCompositeId("_rt_imageLayerComposite_14942_a", &slot);
    ASSERT_TRUE(id.has_value());
    EXPECT_EQ(*id, 14942);
    EXPECT_EQ(slot, LayerCompositeSlot::A);
    EXPECT_EQ(ParseImageLayerCompositeId("_rt_imageLayerComposite_14942_b", &slot).value_or(0),
              14942);
    EXPECT_EQ(slot, LayerCompositeSlot::B);
    EXPECT_TRUE(ParseImageLayerCompositeId("_rt_imageLayerComposite_159").has_value());
}

TEST(LayerTextureReference, ForwardReferenceResolvesById) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":160,"name":"consumer","image":"linked.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_159_a"]}]}]},
      {"id":159,"name":"source","image":"image.json"}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    auto       resolved =
        ResolveLayerTextureName("_rt_imageLayerComposite_159_a", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.source_id, 159);
    EXPECT_TRUE(resolved.error.empty());
    EXPECT_EQ(resolved.resolved, GenLinkTex(159));
}

TEST(LayerTextureReference, DuplicateNameIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"dup","image":"image.json"},
      {"id":2,"name":"dup","image":"image.json"}
    ])");
    const auto index    = BuildLayerObjectIndex(objects);
    auto       resolved = ResolveLayerTextureName("dup", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.error, kLayerTextureDuplicateName);
    EXPECT_NE(resolved.resolved, GenLinkTex(1));
}

TEST(LayerTextureReference, MissingTargetIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([{"id":1,"name":"only","image":"image.json"}])");
    const auto index   = BuildLayerObjectIndex(objects);
    auto       resolved =
        ResolveLayerTextureName("_rt_imageLayerComposite_99_a", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.error, kLayerTextureMissingTarget);
}

TEST(LayerTextureReference, CycleIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"a","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_2_a"]}]}]},
      {"id":2,"name":"b","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_1_a"]}]}]}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    const auto refs  = CollectLayerTextureRefs(objects, index, nullptr);
    EXPECT_EQ(ClassifyLayerTextureReferences(refs, index), kLayerTextureIllegalCycle);
}

TEST(LayerTextureReference, SelfBIsHistoryFeedback) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":7,"name":"self","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_7_b"]}]}]}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    const auto refs  = CollectLayerTextureRefs(objects, index, nullptr);
    EXPECT_EQ(ClassifyLayerTextureReferences(refs, index), kLayerTextureHistoryFeedback);
}

TEST(LayerTextureReference, FileNameIsNotALayerEvenWhenNamesMatch) {
    fs::VFS vfs;
    MountFiles(vfs);
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"solid","image":"image.json"}
    ])");
    const auto index    = BuildLayerObjectIndex(objects);
    auto       resolved = ResolveLayerTextureName("solid", index, &vfs);
    EXPECT_FALSE(resolved.is_layer);
    EXPECT_EQ(resolved.resolved, "solid");
}

TEST(LayerTextureReference, ParserKeepsInvisibleCompositeSource) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->layer_texture_error.empty());
    EXPECT_TRUE(parsed->layer_texture_sources.contains(159));
    SceneNode* source = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "source") source = child.get();
    }
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_TRUE(source->MustProduce());
}

TEST(LayerTextureReference, ProducerRunsBeforeConsumer) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]},
        {"id":159,"name":"source","image":"image.json","visible":false}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    parsed->renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
    parsed->cameras["effect"] = std::make_shared<SceneCamera>(64, 32, 0.01f, 100.0f);
    parsed->activeCamera      = nullptr;

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_FALSE(consumer->desc().textures.empty());
    EXPECT_EQ(consumer->desc().textures[0], GenLinkTex(159));

    const auto source_index   = PassIndexByNode(*graph, "source");
    const auto consumer_index = PassIndexByNode(*graph, "consumer");
    EXPECT_NE(source_index, static_cast<size_t>(-1));
    EXPECT_LT(source_index, consumer_index);

    const auto* link = FindLinkCopy(*graph, GenLinkTex(159));
    ASSERT_NE(link, nullptr);
    EXPECT_NE(link->desc().src, SpecTex_Default);
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(159));
}

TEST(LayerTextureReference, EffectChainSourceLinksFromCompositeNotDefault) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false,
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/copy.json"}]})" },
        { "/materials/copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]} )" }});
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->layer_texture_error.empty());
    EXPECT_TRUE(parsed->layer_texture_sources.contains(159));
    parsed->renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
    if (parsed->cameras.find("effect") == parsed->cameras.end()) {
        parsed->cameras["effect"] = std::make_shared<SceneCamera>(64, 32, 0.01f, 100.0f);
    }
    parsed->activeCamera = nullptr;

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_FALSE(consumer->desc().textures.empty());
    EXPECT_EQ(consumer->desc().textures[0], GenLinkTex(159));

    const auto* link = FindLinkCopy(*graph, GenLinkTex(159));
    ASSERT_NE(link, nullptr) << "the consumer never received a copy of the source composite";
    EXPECT_NE(link->desc().src, SpecTex_Default);
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(159));

    const auto* composite = FindPassByOutput(*graph, LayerCompositeTargetKey(159));
    ASSERT_NE(composite, nullptr);
    EXPECT_NE(composite->desc().output, SpecTex_Default);
}

TEST(LayerTextureReference, AnnotationDefaultBindsItsSlotWithoutClaimingTheAuthorBoundIt) {
    // A sampler annotation's `default` exists so an unbound slot still samples
    // something sane. Its `combo` answers a different question -- did the
    // material bind a texture here -- and answering yes from the default turns
    // the shader's optional feature on permanently. `rounded_mask` then reads
    // its corner radius out of a white default instead of `u_Radius` and masks
    // every layer it touches into a circle.
    constexpr std::string_view kMaskFrag = R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1; // {"combo":"MASKED","default":"solid"}
varying vec2 v_TexCoord;
void main() {
#if MASKED
  gl_FragColor = texture(g_Texture1, v_TexCoord);
#else
  gl_FragColor = texture(g_Texture0, v_TexCoord);
#endif
}
)";
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"masked","image":"masked.json"}
      ])",
      {{ "/masked.json", R"({"width":64,"height":32,"material":"masked_mat.json"})" },
       { "/masked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"masked","textures":["solid"]}]})" },
       { "/shaders/masked.vert", std::string(kVert) },
       { "/shaders/masked.frag", std::string(kMaskFrag) }});
    ASSERT_NE(parsed, nullptr);

    SceneNode* node = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "masked") node = child.get();
    }
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);

    // The authored binding is untouched.
    ASSERT_FALSE(material->textures.empty());
    EXPECT_EQ(material->textures[0], "solid");
    // The `#if MASKED` branch must not have been compiled in, so the pass
    // samples slot 0 the way the author wrote it.
    EXPECT_EQ(std::count(material->defines.begin(), material->defines.end(), "MASKED"), 0);
}
