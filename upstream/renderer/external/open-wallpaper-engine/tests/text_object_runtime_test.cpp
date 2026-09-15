#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Interface/IImageParser.h"
#include "RenderGraph/RenderGraph.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include <chrono>
#include "Runtime/SceneRuntimeContext.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "WPShaderValueUpdater.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scripting/ScriptEngine.hpp"
#include "Project/ProjectProperties.hpp"
#include "SpecTexs.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "Text/SystemFontResolver.hpp"
#include "Text/TextLayer.hpp"
#include "Vulkan/Shader.hpp"
#include "Vulkan/ShaderComp.hpp"
#include "WPSceneParser.hpp"
#include "WPPkgFs.hpp"

#include <gtest/gtest.h>
#include <spirv_reflect.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace wallpaper
{
namespace vulkan
{
bool ReflectCustomShader(const SceneShader& shader, std::vector<Uni_ShaderSpv>& spvs,
                         ShaderReflected& ref);
} // namespace vulkan

namespace
{

// Opt-in local-asset diagnostic: parser, scripts and render graph only. No
// Vulkan device, window, audio device or desktop state is created.
TEST(TextObjectRuntime, LonelyCatHeadlessRegression) {
    const auto* project = std::getenv("WE_TEST_PROJECT");
    const auto* assets = std::getenv("WE_TEST_ASSETS");
    const auto* cache = std::getenv("WE_TEST_CACHE");
    if (!project || !assets || !cache) GTEST_SKIP() << "No local scene fixture requested";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", fs::CreatePhysicalFs(assets), "assets"));
    ASSERT_TRUE(vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs(
        (std::filesystem::path(project).parent_path() / "scene.pkg").string())));
    ASSERT_TRUE(vfs.Mount("/cache", fs::CreatePhysicalFs(cache, true), "cache"));
    ASSERT_TRUE(InstallVirtualAssets(vfs));
    ProjectProperties properties;
    std::string error;
    ASSERT_TRUE(ParseProjectProperties(project, &properties, &error)) << error;
    auto source = vfs.Open("/assets/scene.json");
    ASSERT_NE(source, nullptr);
    audio::SoundManager sound;
    WPSceneParser parser;
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    const auto started = std::chrono::steady_clock::now();
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "local-regression", .project_path = project,
        .project_properties = &properties, .pkg_version = 22,
    }, source->ReadAllStr(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int i = 0; i < 3; ++i) scene->runtime->Tick(1.0 / 60.0);
    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
    const auto metrics = WPShaderParser::GetStartupMetrics();
    std::printf("Headless parse %.1f ms; shader hits=%llu misses=%llu compile=%.1f ms\n",
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count(),
        static_cast<unsigned long long>(metrics.cache_hits),
        static_cast<unsigned long long>(metrics.cache_misses), metrics.compile_ms);
    EXPECT_GT(metrics.cache_hits, 0u);
    if (std::getenv("WE_TEST_EXPECT_WARM")) EXPECT_EQ(metrics.cache_misses, 0u);
    EXPECT_EQ(scene->runtime->NodeText("__we_text_312").size(), 5u);
    EXPECT_FALSE(scene->runtime->NodeText("__we_text_150").empty());
}

constexpr uint32_t kSpirvMagic = 0x07230203u;
constexpr int32_t  kTexFormatR8 = 9;

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

class TestTexBytes {
public:
    void Stamp(char kind, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "TEX%c%04d", kind, version);
        Append(stamp, sizeof(stamp));
    }

    void I32(int32_t value) { Append(&value, sizeof(value)); }
    void U32(uint32_t value) { Append(&value, sizeof(value)); }

    std::string Take() {
        return std::string(reinterpret_cast<const char*>(m_bytes.data()), m_bytes.size());
    }

private:
    void Append(const void* data, std::size_t size) {
        const auto* p = static_cast<const uint8_t*>(data);
        m_bytes.insert(m_bytes.end(), p, p + size);
    }

    std::vector<uint8_t> m_bytes;
};

std::string BuildTextureHeaderFixture(int32_t format) {
    TestTexBytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(format);
    b.U32(0);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(0);
    return b.Take();
}

void MountAssets(fs::VFS& vfs, std::map<std::string, std::string> files = {}) {
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

bool MountPhysicalAssets(fs::VFS& vfs, const std::filesystem::path& assets_path) {
    auto physical_fs = fs::CreatePhysicalFs(assets_path.string());
    if (physical_fs == nullptr) return false;
    return vfs.Mount("/assets", std::move(physical_fs), "assets");
}

std::filesystem::path HomePath() {
    const char* home = std::getenv("HOME");
    return home != nullptr ? std::filesystem::path(home) : std::filesystem::path();
}

std::optional<std::string> ReadTextFile(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (! input.good()) return std::nullopt;
    std::string content((std::istreambuf_iterator<char>(input)),
                        std::istreambuf_iterator<char>());
    return content;
}

std::string MinimalSceneObjects(std::string objects_json) {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": )" +
           objects_json + "\n}";
}

SceneNode* FindRootChild(Scene& scene, std::string_view name) {
    if (scene.sceneGraph == nullptr) return nullptr;
    const auto& children = scene.sceneGraph->GetChildren();
    const auto  it       = std::find_if(children.begin(), children.end(), [name](const auto& node) {
        return node != nullptr && node->Name() == name;
    });
    return it == children.end() ? nullptr : it->get();
}

struct MeshBounds {
    float min_x { 0.0f };
    float max_x { 0.0f };
    float min_y { 0.0f };
    float max_y { 0.0f };

    Eigen::Vector2f Size() const { return Eigen::Vector2f(max_x - min_x, max_y - min_y); }
};

MeshBounds MeshLocalBounds(const SceneMesh& mesh) {
    const auto& vertices = mesh.GetVertexArray(0);
    const auto  stride   = vertices.OneSize();
    const auto* data     = vertices.Data();
    if (data == nullptr || vertices.VertexCount() == 0 || stride < 2u) {
        return {};
    }

    MeshBounds bounds {
        .min_x = data[0],
        .max_x = data[0],
        .min_y = data[1],
        .max_y = data[1],
    };
    for (std::size_t index = 1; index < vertices.VertexCount(); ++index) {
        const float x = data[index * stride + 0u];
        const float y = data[index * stride + 1u];
        bounds.min_x  = std::min(bounds.min_x, x);
        bounds.max_x  = std::max(bounds.max_x, x);
        bounds.min_y  = std::min(bounds.min_y, y);
        bounds.max_y  = std::max(bounds.max_y, y);
    }
    return bounds;
}

Eigen::Vector2f MeshSize(const SceneMesh& mesh) {
    return MeshLocalBounds(mesh).Size();
}

Eigen::Vector2f MeshCenter(const SceneMesh& mesh) {
    const auto bounds = MeshLocalBounds(mesh);
    return Eigen::Vector2f((bounds.min_x + bounds.max_x) * 0.5f,
                           (bounds.min_y + bounds.max_y) * 0.5f);
}

struct TexCoordBounds {
    float min_u { 0.0f };
    float max_u { 0.0f };
    float min_v { 0.0f };
    float max_v { 0.0f };
};

TexCoordBounds MeshTexCoordBounds(const SceneMesh& mesh) {
    const auto& vertices = mesh.GetVertexArray(0);
    const auto  stride   = vertices.OneSize();
    const auto* data     = vertices.Data();
    if (data == nullptr || vertices.VertexCount() == 0) {
        return {};
    }

    const auto offsets = vertices.GetAttrOffsetMap();
    const auto offset_iterator = offsets.find(WE_IN_TEXCOORD.data());
    if (offset_iterator == offsets.end()) return {};
    const auto tex_offset = offset_iterator->second.offset / sizeof(float);

    TexCoordBounds bounds {
        .min_u = data[tex_offset + 0u],
        .max_u = data[tex_offset + 0u],
        .min_v = data[tex_offset + 1u],
        .max_v = data[tex_offset + 1u],
    };
    for (std::size_t index = 1; index < vertices.VertexCount(); ++index) {
        const auto base = index * stride + tex_offset;
        const float u  = data[base + 0u];
        const float v  = data[base + 1u];
        bounds.min_u   = std::min(bounds.min_u, u);
        bounds.max_u   = std::max(bounds.max_u, u);
        bounds.min_v   = std::min(bounds.min_v, v);
        bounds.max_v   = std::max(bounds.max_v, v);
    }
    return bounds;
}

void ExpectTextEffectFboCoversFinalMesh(const SceneRenderTarget& fbo,
                                        const SceneMesh& final_mesh,
                                        int32_t target_width,
                                        int32_t target_height) {
    const auto final_mesh_size = MeshSize(final_mesh);
    const auto uv_bounds       = MeshTexCoordBounds(final_mesh);
    const auto effective_width =
        static_cast<float>(fbo.width) * (uv_bounds.max_u - uv_bounds.min_u);
    const auto effective_height =
        static_cast<float>(fbo.height) * (uv_bounds.max_v - uv_bounds.min_v);
    constexpr float kUvResolutionTolerance = 1.0e-3f;
    EXPECT_GE(effective_width + kUvResolutionTolerance,
              std::min(static_cast<float>(target_width), std::ceil(final_mesh_size.x())));
    EXPECT_GE(effective_height + kUvResolutionTolerance,
              std::min(static_cast<float>(target_height), std::ceil(final_mesh_size.y())));
}

bool ShaderUsesUniformMember(const ShaderCode& spirv, std::string_view member_name) {
    spv_reflect::ShaderModule module(spirv, SPV_REFLECT_MODULE_FLAG_NO_COPY);

    uint32_t binding_count = 0;
    if (module.EnumerateDescriptorBindings(&binding_count, nullptr) != SPV_REFLECT_RESULT_SUCCESS) {
        return false;
    }

    std::vector<SpvReflectDescriptorBinding*> bindings(binding_count);
    if (module.EnumerateDescriptorBindings(&binding_count, bindings.data()) !=
        SPV_REFLECT_RESULT_SUCCESS) {
        return false;
    }

    for (const auto* binding : bindings) {
        if (binding == nullptr || ! binding->accessed ||
            binding->descriptor_type != SPV_REFLECT_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            continue;
        }
        const auto& block = binding->block;
        for (uint32_t index = 0; index < block.member_count; ++index) {
            const auto* name = block.members[index].name;
            if (name != nullptr && member_name == name) return true;
        }
    }
    return false;
}

bool ShaderUsesUniformMember(const SceneShader& shader, std::string_view member_name) {
    if (shader.rust_reflection_json.has_value()) {
        shader::RustShaderOutput output;
        try {
            shader::ApplyRustShaderReflectionJson(*shader.rust_reflection_json, output);
            for (const auto& block : output.reflection.blocks) {
                if (block.member_map.contains(std::string(member_name))) return true;
            }
            return false;
        } catch (const std::exception&) {
        }
    }

    for (const auto& code : shader.codes) {
        if (ShaderUsesUniformMember(code, member_name)) return true;
    }
    return false;
}

int VisibleAlphaPixels(const Image& image) {
    int visible_pixels = 0;
    if (image.slots.empty() || image.slots[0].mipmaps.empty()) return visible_pixels;

    const auto& mip = image.slots[0].mipmaps[0];
    if (mip.data == nullptr) return visible_pixels;
    for (int y = 0; y < mip.height; ++y) {
        for (int x = 0; x < mip.width; ++x) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            if (alpha > 0u) ++visible_pixels;
        }
    }
    return visible_pixels;
}

const vulkan::CustomShaderPass* FindCustomPassForNode(const rg::RenderGraph& graph,
                                                      const SceneNode*       node) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node == node) return pass;
    }
    return nullptr;
}

void PumpTextUntilClean(SceneRuntimeContext& runtime, int max_attempts = 200) {
    for (int attempt = 0; attempt < max_attempts; ++attempt) {
        runtime.PumpTextLayerCache();
        bool any_dirty = false;
        for (std::string_view name : { "caption", "clock", "Clock" }) {
            any_dirty = any_dirty || runtime.NodeTextDirty(name);
        }
        if (! any_dirty) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

bool ReflectShaderDescriptors(const SceneShader& shader, vulkan::ShaderReflected& reflected) {
    std::vector<vulkan::Uni_ShaderSpv> spvs;
    return vulkan::ReflectCustomShader(shader, spvs, reflected);
}

SceneShader CompileTextShaderForSpirvReflection(fs::VFS& vfs) {
    (void)vfs;
    std::string vertex_src =
        "#version 450\n"
        "layout(location = 0) in vec3 a_Position;\n"
        "layout(binding = 1) uniform GlobalUniforms {\n"
        "  mat4 g_ModelViewProjectionMatrix;\n"
        "};\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "}\n";
    std::string fragment_src = "#version 450\n"
                               "layout(binding = 0) uniform sampler2D g_Texture0;\n"
                               "layout(location = 0) out vec4 glOutColor;\n"
                               "void main() {\n"
                               "  glOutColor = texture(g_Texture0, vec2(0.5));\n"
                               "}\n";

    std::vector<vulkan::ShaderCompUnit> units {
        vulkan::ShaderCompUnit {
            .stage = EShLangVertex,
            .src   = std::move(vertex_src),
        },
        vulkan::ShaderCompUnit {
            .stage = EShLangFragment,
            .src   = std::move(fragment_src),
        },
    };

    vulkan::ShaderCompOpt opt;
    opt.client_ver             = glslang::EShTargetVulkan_1_1;
    opt.auto_map_bindings      = true;
    opt.auto_map_locations     = true;
    opt.relaxed_errors_glsl    = true;
    opt.relaxed_rules_vulkan   = true;
    opt.suppress_warnings_glsl = true;

    WPShaderParser::InitGlslang();
    std::vector<vulkan::Uni_ShaderSpv> compiled;
    const bool ok = vulkan::CompileAndLinkShaderUnits(units, opt, compiled);
    WPShaderParser::FinalGlslang();
    if (! ok || compiled.size() != 2u) return {};

    SceneShader shader;
    shader.name = "text";
    shader.codes.reserve(compiled.size());
    for (auto& spv : compiled) {
        shader.codes.emplace_back(std::move(spv->spirv));
    }
    return shader;
}

std::optional<VkDescriptorSetLayoutBinding>
ShaderDescriptorBinding(const std::vector<ShaderCode>& spirv, std::string_view name) {
    std::vector<vulkan::Uni_ShaderSpv> spvs;
    vulkan::ShaderReflected            reflected;
    if (! vulkan::GenReflect(spirv, spvs, reflected)) return std::nullopt;

    const auto iterator = reflected.binding_map.find(std::string(name));
    if (iterator == reflected.binding_map.end()) return std::nullopt;

    return iterator->second;
}

std::optional<VkDescriptorSetLayoutBinding>
ShaderDescriptorBinding(const SceneShader& shader, std::string_view name) {
    vulkan::ShaderReflected reflected;
    if (! ReflectShaderDescriptors(shader, reflected)) {
        return std::nullopt;
    }

    const auto iterator = reflected.binding_map.find(std::string(name));
    if (iterator == reflected.binding_map.end()) return std::nullopt;

    return iterator->second;
}

std::vector<VkDescriptorSetLayoutBinding>
ShaderDescriptorBindings(const std::vector<ShaderCode>& spirv) {
    std::vector<vulkan::Uni_ShaderSpv> spvs;
    vulkan::ShaderReflected            reflected;
    if (! vulkan::GenReflect(spirv, spvs, reflected)) return {};

    std::vector<VkDescriptorSetLayoutBinding> bindings;
    bindings.reserve(reflected.binding_map.size());
    for (const auto& [name, binding] : reflected.binding_map) {
        (void)name;
        bindings.push_back(binding);
    }
    return bindings;
}

std::vector<VkDescriptorSetLayoutBinding>
ShaderDescriptorBindings(const SceneShader& shader) {
    vulkan::ShaderReflected reflected;
    if (! ReflectShaderDescriptors(shader, reflected)) {
        return {};
    }

    std::vector<VkDescriptorSetLayoutBinding> bindings;
    bindings.reserve(reflected.binding_map.size());
    for (const auto& [name, binding] : reflected.binding_map) {
        (void)name;
        bindings.push_back(binding);
    }
    return bindings;
}

} // namespace

TEST(TextObjectRuntime, ParserCreatesRuntimeTextNodeAndState) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-object",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": {"value": "hello"},
            "font": {"value": "Arial"},
            "pointsize": 20,
            "padding": 4,
            "origin": [100, 50, 0],
            "horizontalalign": "right",
            "verticalalign": "bottom",
            "alignment": "left",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->runtime->HasNodeNamed("caption"));
    EXPECT_EQ(scene->runtime->NodeText("caption"), "hello");

    const auto size = scene->runtime->NodeSize("caption");
    EXPECT_GT(size.x(), 8.0f);
    EXPECT_GT(size.y(), 8.0f);

    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    EXPECT_NE(node->Mesh(), nullptr);
    EXPECT_LT(node->Translate().x(), 100.0f);
    EXPECT_GT(node->Translate().y(), 50.0f);
}

TEST(TextObjectRuntime, ParserCreatesRenderableTextMaterialAndTexture) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-renderable-material",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "I I",
            "font": "Arial",
            "pointsize": 20,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);

    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    EXPECT_EQ(material->name, "text");
    ASSERT_EQ(material->textures.size(), 1u);
    EXPECT_FALSE(material->textures.front().empty());
    EXPECT_FALSE(IsSpecTex(material->textures.front()));
    EXPECT_TRUE(scene->textures.contains(material->textures.front()));
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    const auto& mip = image->slots[0].mipmaps[0];
    ASSERT_NE(mip.data, nullptr);
    ASSERT_GT(mip.width, 1);
    ASSERT_GT(mip.height, 1);
    bool has_visible_alpha            = false;
    bool has_transparent_space_column = false;
    for (int y = 1; y < mip.height - 1; ++y) {
        for (int x = 1; x < mip.width - 1; ++x) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            has_visible_alpha = has_visible_alpha || alpha > 0u;
        }
    }
    const int min_space_x = mip.width / 4;
    const int max_space_x = (mip.width * 3) / 4;
    for (int x = min_space_x; x < max_space_x && ! has_transparent_space_column; ++x) {
        bool column_clear = true;
        for (int y = 1; y < mip.height - 1; ++y) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            if (alpha != 0u) {
                column_clear = false;
                break;
            }
        }
        has_transparent_space_column = column_clear;
    }
    EXPECT_TRUE(has_visible_alpha);
    EXPECT_TRUE(has_transparent_space_column);
    ASSERT_NE(material->customShader.shader, nullptr);
    ASSERT_EQ(material->customShader.shader->codes.size(), 2u);
    for (const auto& code : material->customShader.shader->codes) {
        ASSERT_FALSE(code.empty());
        EXPECT_EQ(code.front(), kSpirvMagic);
    }
    EXPECT_TRUE(ShaderUsesUniformMember(*material->customShader.shader,
                                        "g_ModelViewProjectionMatrix"));
    const auto texture_binding =
        ShaderDescriptorBinding(*material->customShader.shader, "g_Texture0");
    ASSERT_TRUE(texture_binding.has_value());
    const bool has_rust_reflection = material->customShader.shader->rust_reflection_json.has_value();
    EXPECT_EQ(texture_binding->descriptorType,
              has_rust_reflection ? VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
                                  : VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
    const auto descriptor_bindings = ShaderDescriptorBindings(*material->customShader.shader);
    ASSERT_FALSE(descriptor_bindings.empty());
    bool has_uniform_buffer_descriptor = false;
    bool has_sampler_descriptor        = ! has_rust_reflection;
    for (const auto& binding : descriptor_bindings) {
        if (binding.descriptorType == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            has_uniform_buffer_descriptor = true;
            EXPECT_NE(binding.binding, texture_binding->binding);
        }
        if (binding.descriptorType == VK_DESCRIPTOR_TYPE_SAMPLER) {
            has_sampler_descriptor = true;
            EXPECT_NE(binding.binding, texture_binding->binding);
        }
    }
    EXPECT_TRUE(has_uniform_buffer_descriptor);
    EXPECT_TRUE(has_sampler_descriptor);
    EXPECT_EQ(material->blenmode, BlendMode::Translucent);
}

TEST(TextObjectRuntime, ParserRoutesTextObjectEffectsThroughImageEffectLayer) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "passes": [
                          { "material": "materials/effects/gradient.json" }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null],
                          "constantshadervalues": {
                            "gradient": "0.1 0.2 0.3"
                          }
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "uniform float g_Time;\n"
                      "uniform vec3 u_Gradient; // {\"material\":\"gradient\",\"default\":\"1 1 1\"}\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { vec4 albedo = texture(g_Texture0, v_TexCoord); gl_FragColor = vec4(u_Gradient * abs(cos(g_Time)), albedo.a); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "hello",
              "font": "Arial",
              "pointsize": 20,
              "origin": "0 0 0",
              "size": "200 40",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true,
                  "passes": [
                    {
                      "constantshadervalues": {
                        "gradient": "0.25 0.5 0.75"
                      }
                    }
                  ]
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    ASSERT_TRUE(scene->cameras.contains(text->Camera()));
    ASSERT_TRUE(scene->cameras.at(text->Camera())->HasImgEffect());

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);

    auto* effect_node = scene->cameras.at(text->Camera())
                            ->GetImgEffect()
                            ->GetEffect(0)
                            ->nodes.front()
                            .sceneNode.get();
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(effect_node, [](std::string_view name) {
        return name == "g_Time";
    });

    scene->PassFrameTime(0.5);
    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    updater->UpdateUniforms(effect_node, sprites, [&](std::string_view name, ShaderValue value) {
        updates.emplace(std::string(name), std::move(value));
    });
    ASSERT_TRUE(updates.contains("g_Time"));
    EXPECT_FLOAT_EQ(updates.at("g_Time")[0], 0.5f);
}

TEST(TextObjectRuntime, RuntimeTextEffectTargetsResizeWithTextRasterSize) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-resize",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "a",
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    const auto initial_pingpong_width = pingpong->width;
    const auto initial_camera_width   = camera->Width();
    auto* fbo = scene->FindRenderTarget(
        effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    const auto initial_fbo_width = fbo->width;
    const auto initial_text_mesh_size = MeshSize(*text->Mesh());
    const auto initial_final_mesh_size = MeshSize(effect_layer->FinalMesh());

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    EXPECT_TRUE(resolved_final->Mesh()->Dynamic());

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "a much longer caption for effects"));
    PumpTextUntilClean(*scene->runtime);

    pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    EXPECT_EQ(pingpong->width, initial_pingpong_width);
    EXPECT_EQ(camera->Width(), initial_camera_width);
    EXPECT_EQ(static_cast<int>(camera->Width()), pingpong->width);
    EXPECT_EQ(static_cast<int>(camera->Height()), pingpong->height);
    const auto resized_text_mesh_size = MeshSize(*text->Mesh());
    const auto resized_final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_EQ(fbo->width, initial_fbo_width);
    EXPECT_GT(resized_text_mesh_size.x(), initial_text_mesh_size.x());
    EXPECT_GT(resized_final_mesh_size.x(), initial_final_mesh_size.x());
    EXPECT_NEAR(resized_final_mesh_size.x(), resized_text_mesh_size.x(), 1.0f);
    EXPECT_NEAR(resized_final_mesh_size.y(), resized_text_mesh_size.y(), 1.0f);
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_GE(uv_bounds.min_u, 0.0f);
    EXPECT_LE(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);

    ASSERT_EQ(resolved_final, effect_layer->ResolvedFinalRenderNode());
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    EXPECT_TRUE(resolved_final->Mesh()->Dynamic());
    const auto resolved_final_mesh_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_size.x(), resized_text_mesh_size.x(), 1.0f);
    EXPECT_NEAR(resolved_final_mesh_size.y(), resized_text_mesh_size.y(), 1.0f);
    const auto resolved_uv_bounds = MeshTexCoordBounds(*resolved_final->Mesh());
    EXPECT_GE(resolved_uv_bounds.min_u, 0.0f);
    EXPECT_LE(resolved_uv_bounds.max_u, 1.0f);
    EXPECT_GE(resolved_uv_bounds.min_v, 0.0f);
    EXPECT_LE(resolved_uv_bounds.max_v, 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, ParserTextEffectFinalUvsUseRoundedRenderTargetExtent) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "passes": [
                          { "material": "materials/effects/gradient.json" }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-rounded-uvs",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "a",
              "font": "Arial",
              "pointsize": 20.125,
              "padding": 0,
              "origin": "0 0 0",
              "size": [93.6, 41.6],
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    const auto uv_bounds       = MeshTexCoordBounds(effect_layer->FinalMesh());
    const auto expected_u_span = final_mesh_size.x() / static_cast<float>(camera->Width());
    const auto expected_v_span = final_mesh_size.y() / static_cast<float>(camera->Height());
    EXPECT_NEAR(uv_bounds.max_u - uv_bounds.min_u, expected_u_span, 1.0e-5f);
    EXPECT_NEAR(uv_bounds.max_v - uv_bounds.min_v, expected_v_span, 1.0e-5f);
    EXPECT_LT(uv_bounds.max_u - uv_bounds.min_u, 1.0f);
    EXPECT_LT(uv_bounds.max_v - uv_bounds.min_v, 1.0f);
}

TEST(TextObjectRuntime, OversizedTextEffectClipsFinalMeshToBoundedTarget) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-oversized-cap",
          .project_properties = &properties,
    };
    const std::string oversized_text(260, 'W');

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": ")JSON" + oversized_text +
                                                  R"JSON(",
              "font": "Arial",
              "pointsize": 40,
              "padding": 0,
              "origin": "0 0 0",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_NE(text->Mesh(), nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    const auto state = scene->runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    ASSERT_GT(state->raster_size.x(), 4096.0f);
    EXPECT_LE(camera->Width(), 4096.0);
    EXPECT_LE(camera->Height(), 4096.0);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    EXPECT_LE(pingpong->width, 4096);
    EXPECT_LE(pingpong->height, 4096);
    auto* fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);

    const auto text_mesh_size = MeshSize(*text->Mesh());
    EXPECT_GT(text_mesh_size.x(), static_cast<float>(pingpong->width));
    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_NEAR(final_mesh_size.x(), static_cast<float>(pingpong->width), 1.0f);
    EXPECT_LE(final_mesh_size.y(), static_cast<float>(pingpong->height));
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_FLOAT_EQ(uv_bounds.min_u, 0.0f);
    EXPECT_FLOAT_EQ(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    const auto resolved_final_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_size.x(), static_cast<float>(pingpong->width), 1.0f);
    const auto resolved_uv_bounds = MeshTexCoordBounds(*resolved_final->Mesh());
    EXPECT_FLOAT_EQ(resolved_uv_bounds.min_u, 0.0f);
    EXPECT_FLOAT_EQ(resolved_uv_bounds.max_u, 1.0f);
    EXPECT_GE(resolved_uv_bounds.min_v, 0.0f);
    EXPECT_LE(resolved_uv_bounds.max_v, 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, SceneScriptTextEffectMutationKeepsFinalUvsInCapacity) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "passes": [
                          { "material": "materials/effects/gradient.json" }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-script-mutation",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": {
                "text": "a",
                "script": "engine.on('cursorDown', function() { thisLayer.text = 'a much longer caption for effects'; })"
              },
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    scene->runtime->DispatchCursorDown();
    PumpTextUntilClean(*scene->runtime);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "a much longer caption for effects");
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_GE(uv_bounds.min_u, 0.0f);
    EXPECT_LE(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, ExplicitAlignedTextEffectTracksMeasuredRenderFrameWhenRasterExpands) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "explicit-text-effect-raster-camera",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": {
                "value": "a",
                "script": "export function update(value) { return 'a much longer caption for explicit effects'; }"
              },
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "size": [120, 50],
              "horizontalalign": "right",
              "verticalalign": "bottom",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_NE(text->Mesh(), nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    EXPECT_EQ(scene->runtime->NodeText("caption"),
              "a much longer caption for explicit effects");
    EXPECT_NEAR(text->Translate().x(), -60.0f, 1.0e-4f);
    EXPECT_NEAR(text->Translate().y(), 25.0f, 1.0e-4f);
    EXPECT_NEAR(text->Translate().x(), -60.0f, 1.0e-4f);
    EXPECT_NEAR(text->Translate().y(), 25.0f, 1.0e-4f);

    const auto state = scene->runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    const auto logical_size = scene->runtime->NodeSize("caption");
    EXPECT_FLOAT_EQ(logical_size.x(), 120.0f);
    EXPECT_FLOAT_EQ(logical_size.y(), 50.0f);
    EXPECT_GT(state->raster_size.x(), logical_size.x());
    const auto render_frame = TextLayerRenderFrameForRasterSize(*state, state->raster_size);

    const auto text_mesh_size = MeshSize(*text->Mesh());
    EXPECT_NEAR(text_mesh_size.x(), render_frame.size.x(), 1.0f);
    EXPECT_NEAR(text_mesh_size.y(), render_frame.size.y(), 1.0f);
    const auto text_mesh_center = MeshCenter(*text->Mesh());
    EXPECT_NEAR(text_mesh_center.x(), render_frame.center.x(), 1.0e-4f);
    EXPECT_NEAR(text_mesh_center.y(), render_frame.center.y(), 1.0e-4f);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    auto* fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    EXPECT_GE(pingpong->width, static_cast<int32_t>(std::lround(render_frame.size.x())));
    EXPECT_GE(pingpong->height, static_cast<int32_t>(std::lround(render_frame.size.y())));
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Width())), pingpong->width);
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Height())), pingpong->height);

    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_NEAR(final_mesh_size.x(), render_frame.size.x(), 1.0f);
    EXPECT_NEAR(final_mesh_size.y(), render_frame.size.y(), 1.0f);
    const auto final_mesh_center = MeshCenter(effect_layer->FinalMesh());
    EXPECT_NEAR(final_mesh_center.x(), render_frame.center.x(), 1.0e-4f);
    EXPECT_NEAR(final_mesh_center.y(), render_frame.center.y(), 1.0e-4f);
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_GE(uv_bounds.min_u, 0.0f);
    EXPECT_LE(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    const auto resolved_final_mesh_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_size.x(), render_frame.size.x(), 1.0f);
    EXPECT_NEAR(resolved_final_mesh_size.y(), render_frame.size.y(), 1.0f);
    const auto resolved_final_mesh_center = MeshCenter(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_center.x(), render_frame.center.x(), 1.0e-4f);
    EXPECT_NEAR(resolved_final_mesh_center.y(), render_frame.center.y(), 1.0e-4f);

    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
    PumpTextUntilClean(*scene->runtime);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, ExplicitAlignedTextEffectCoversMeasuredRasterWithoutScaling) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "explicit-text-effect-measured-raster",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "Saturday Saturday Saturday",
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "size": [120, 50],
              "horizontalalign": "right",
              "verticalalign": "bottom",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_NE(text->Mesh(), nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    const auto state = scene->runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    const auto logical_size = scene->runtime->NodeSize("caption");
    EXPECT_FLOAT_EQ(logical_size.x(), 120.0f);
    EXPECT_FLOAT_EQ(logical_size.y(), 50.0f);
    ASSERT_GT(state->raster_size.x(), logical_size.x());

    const auto text_mesh_size = MeshSize(*text->Mesh());
    EXPECT_NEAR(text_mesh_size.x(), state->raster_size.x(), 1.0f);
    EXPECT_NEAR(text_mesh_size.y(), state->raster_size.y(), 1.0f);
    const auto text_mesh_center = MeshCenter(*text->Mesh());
    EXPECT_LT(text_mesh_center.x(), 0.0f);
    EXPECT_GT(text_mesh_center.y(), 0.0f);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    auto* fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    EXPECT_GE(pingpong->width, static_cast<int32_t>(std::ceil(state->raster_size.x())));
    EXPECT_GE(pingpong->height, static_cast<int32_t>(std::ceil(state->raster_size.y())));
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Width())), pingpong->width);
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Height())), pingpong->height);
    EXPECT_NEAR(camera->GetPosition().x(), text_mesh_center.x(), 1.0e-4);
    EXPECT_NEAR(camera->GetPosition().y(), text_mesh_center.y(), 1.0e-4);

    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_NEAR(final_mesh_size.x(), state->raster_size.x(), 1.0f);
    EXPECT_NEAR(final_mesh_size.y(), state->raster_size.y(), 1.0f);
    EXPECT_NEAR(MeshCenter(effect_layer->FinalMesh()).x(), text_mesh_center.x(), 1.0e-4f);
    EXPECT_NEAR(MeshCenter(effect_layer->FinalMesh()).y(), text_mesh_center.y(), 1.0e-4f);

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    const auto resolved_final_mesh_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_size.x(), state->raster_size.x(), 1.0f);
    EXPECT_NEAR(resolved_final_mesh_size.y(), state->raster_size.y(), 1.0f);
    EXPECT_NEAR(MeshCenter(*resolved_final->Mesh()).x(), text_mesh_center.x(), 1.0e-4f);
    EXPECT_NEAR(MeshCenter(*resolved_final->Mesh()).y(), text_mesh_center.y(), 1.0e-4f);

    EXPECT_NEAR(text->Translate().x(), -60.0f, 1.0e-4f);
    EXPECT_NEAR(text->Translate().y(), 25.0f, 1.0e-4f);
}

TEST(TextObjectRuntime, ParserStabilizesCascadingRustShaderDefaultTextureMetadata) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
                    { "/mat.json",
                      R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                      R"("depthtest":"disabled","depthwrite":"disabled",)"
                      R"("shader":"defaulttexture","textures":[""]}]})" },
                    { "/shaders/defaulttexture.vert",
                      R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
                    { "/shaders/defaulttexture.frag",
                      R"(
uniform sampler2D g_Texture0; // {"material":"albedo","default":"fallback-r8.tex"}
#ifndef TEX0FORMAT
// [COMBO] {"combo":"FIRST_PASS_ONLY","default":1}
#endif
#if FIRST_PASS_ONLY
uniform float g_StaleFirstPassMarker; // {"default":1.0}
#endif
#if TEX0FORMAT == 9
uniform sampler2D g_Texture1; // {"material":"second","default":"second-r8.tex"}
#endif
#if TEX1FORMAT == 9
uniform float g_CascadedDefaultObserved; // {"default":1.0}
#endif
varying vec2 v_TexCoord;
void main() {
  vec4 texel = texture(g_Texture0, v_TexCoord);
#if TEX1FORMAT == 9
  texel += texture(g_Texture1, v_TexCoord) * 0.001;
  texel.r += g_CascadedDefaultObserved * 0.001;
#endif
  gl_FragColor = texel;
}
)" },
                    { "/materials/fallback-r8.tex.tex", BuildTextureHeaderFixture(kTexFormatR8) },
                    { "/materials/second-r8.tex.tex", BuildTextureHeaderFixture(kTexFormatR8) },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "rust-default-texture-material",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "defaulted image",
            "image": "image.json",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "defaulted image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 2u);
    EXPECT_EQ(material->textures[0], "fallback-r8.tex");
    EXPECT_EQ(material->textures[1], "second-r8.tex");
    EXPECT_TRUE(scene->textures.contains("fallback-r8.tex"));
    EXPECT_TRUE(scene->textures.contains("second-r8.tex"));
    ASSERT_NE(material->customShader.shader, nullptr);
    EXPECT_TRUE(ShaderUsesUniformMember(*material->customShader.shader,
                                        "g_CascadedDefaultObserved"));
    EXPECT_FALSE(ShaderUsesUniformMember(*material->customShader.shader,
                                         "g_StaleFirstPassMarker"));
}

TEST(TextObjectRuntime, MalformedRustReflectionJsonFallsBackToSpirvReflect) {
    fs::VFS vfs;
    MountAssets(vfs);

    SceneShader malformed_reflection_shader = CompileTextShaderForSpirvReflection(vfs);
    ASSERT_FALSE(malformed_reflection_shader.codes.empty());
    malformed_reflection_shader.rust_reflection_json = "{ malformed rust reflection json";

    EXPECT_TRUE(ShaderUsesUniformMember(malformed_reflection_shader,
                                        "g_ModelViewProjectionMatrix"));

    const auto texture_binding =
        ShaderDescriptorBinding(malformed_reflection_shader, "g_Texture0");
    ASSERT_TRUE(texture_binding.has_value());
    EXPECT_EQ(texture_binding->descriptorType, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);

    const auto descriptor_bindings = ShaderDescriptorBindings(malformed_reflection_shader);
    ASSERT_FALSE(descriptor_bindings.empty());
    bool has_uniform_buffer_descriptor = false;
    for (const auto& binding : descriptor_bindings) {
        if (binding.descriptorType == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            has_uniform_buffer_descriptor = true;
            EXPECT_NE(binding.binding, texture_binding->binding);
        }
    }
    EXPECT_TRUE(has_uniform_buffer_descriptor);

    SceneShader empty_reflection_shader = malformed_reflection_shader;
    empty_reflection_shader.rust_reflection_json = "{}";
    const auto fallback_texture_binding =
        ShaderDescriptorBinding(empty_reflection_shader, "g_Texture0");
    ASSERT_TRUE(fallback_texture_binding.has_value());
    EXPECT_EQ(fallback_texture_binding->descriptorType,
              VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
}

TEST(TextObjectRuntime, ExplicitTextObjectSizeIsMinimumRuntimeTextureDimensions) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-explicit-size-texture",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "clock",
            "text": "12:34",
            "font": "Arial",
            "pointsize": 20,
            "size": [320, 90],
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "clock");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);

    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    EXPECT_EQ(image->header.width, 320);
    EXPECT_EQ(image->header.height, 90);

    ASSERT_TRUE(scene->runtime->SetNodeText("clock", "12:34:56 PM UTC"));
    PumpTextUntilClean(*scene->runtime);

    auto updated = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(updated, nullptr);
    EXPECT_GT(updated->header.width, 320);
    EXPECT_EQ(updated->header.height, 90);
    const auto runtime_size = scene->runtime->NodeSize("clock");
    EXPECT_FLOAT_EQ(runtime_size.x(), 320.0f);
    EXPECT_FLOAT_EQ(runtime_size.y(), 90.0f);
    const auto mesh_size = MeshSize(*node->Mesh());
    EXPECT_GT(mesh_size.x(), runtime_size.x());
    EXPECT_NEAR(mesh_size.y(), runtime_size.y(), 1.0f);
}

TEST(TextObjectRuntime, ExplicitTextObjectSizeRemainsLogicalFrameWhenRasterExpands) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-explicit-layout-frame",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "Saturday",
            "font": "Arial",
            "pointsize": 20,
            "size": [180, 60],
            "origin": [300, 100, 0],
            "scale": [2, 3, 1],
            "horizontalalign": "right",
            "verticalalign": "bottom",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);

    const auto logical_size = scene->runtime->NodeSize("caption");
    EXPECT_FLOAT_EQ(logical_size.x(), 180.0f);
    EXPECT_FLOAT_EQ(logical_size.y(), 60.0f);
    EXPECT_NEAR(node->Translate().x(), 300.0f - 180.0f, 1.0e-4f);
    EXPECT_NEAR(node->Translate().y(), 100.0f + 90.0f, 1.0e-4f);

    const auto initial_mesh_size = MeshSize(*node->Mesh());
    EXPECT_GT(initial_mesh_size.x(), logical_size.x());
    EXPECT_GT(initial_mesh_size.y(), logical_size.y());
    const auto initial_mesh_bounds = MeshLocalBounds(*node->Mesh());
    EXPECT_NEAR(initial_mesh_bounds.max_x, logical_size.x() * 0.5f, 1.0e-4f);
    EXPECT_NEAR(initial_mesh_bounds.min_y, -logical_size.y() * 0.5f, 1.0e-4f);

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "Saturday Saturday Saturday"));
    PumpTextUntilClean(*scene->runtime);
    const auto resized_logical_size = scene->runtime->NodeSize("caption");
    EXPECT_FLOAT_EQ(resized_logical_size.x(), 180.0f);
    EXPECT_FLOAT_EQ(resized_logical_size.y(), 60.0f);
    EXPECT_NEAR(node->Translate().x(), 300.0f - 180.0f, 1.0e-4f);
    EXPECT_NEAR(node->Translate().y(), 100.0f + 90.0f, 1.0e-4f);

    const auto resized_mesh_size = MeshSize(*node->Mesh());
    EXPECT_GT(resized_mesh_size.x(), initial_mesh_size.x());
    EXPECT_NEAR(resized_mesh_size.y(), initial_mesh_size.y(), 1.0f);
    const auto resized_mesh_bounds = MeshLocalBounds(*node->Mesh());
    EXPECT_NEAR(resized_mesh_bounds.max_x, logical_size.x() * 0.5f, 1.0e-4f);
    EXPECT_NEAR(resized_mesh_bounds.min_y, -logical_size.y() * 0.5f, 1.0e-4f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, TextStyleColorAlphaAndBrightnessTintRuntimeTexture) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-style-tint",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "IIII",
            "font": "Arial",
            "pointsize": 20,
            "color": [0.25, 0.5, 0.75],
            "brightness": 0.5,
            "alpha": 0.25,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);

    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    const auto& mip = image->slots[0].mipmaps[0];
    ASSERT_NE(mip.data, nullptr);

    bool saw_tinted_pixel         = false;
    bool saw_straight_alpha_pixel = false;
    int  max_alpha                = 0;
    for (int y = 0; y < mip.height; ++y) {
        for (int x = 0; x < mip.width; ++x) {
            const auto offset =
                (static_cast<std::size_t>(y) * mip.width + static_cast<std::size_t>(x)) * 4u;
            const auto alpha = mip.data.get()[offset + 3u];
            max_alpha        = std::max(max_alpha, static_cast<int>(alpha));
            if (alpha == 0u || saw_tinted_pixel) continue;

            EXPECT_LT(mip.data.get()[offset + 0u], mip.data.get()[offset + 1u]);
            EXPECT_LT(mip.data.get()[offset + 1u], mip.data.get()[offset + 2u]);
            saw_tinted_pixel = true;
        }
    }
    for (int y = 0; y < mip.height && ! saw_straight_alpha_pixel; ++y) {
        for (int x = 0; x < mip.width; ++x) {
            const auto offset =
                (static_cast<std::size_t>(y) * mip.width + static_cast<std::size_t>(x)) * 4u;
            const auto alpha = mip.data.get()[offset + 3u];
            if (alpha < 48u) continue;

            EXPECT_GE(mip.data.get()[offset + 0u], 24u);
            EXPECT_GE(mip.data.get()[offset + 1u], 48u);
            EXPECT_GE(mip.data.get()[offset + 2u], 72u);
            saw_straight_alpha_pixel = true;
            break;
        }
    }
    EXPECT_TRUE(saw_tinted_pixel);
    EXPECT_TRUE(saw_straight_alpha_pixel);
    EXPECT_LE(max_alpha, 64);
}

TEST(TextObjectRuntime, RasterizedTextUsesFontPixelSizeAndAntialiasesEdges) {
    TextLayerState state {
        .text                   = "Hg",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 40.0f,
        .padding                = 4.0f,
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    constexpr uint32_t   width  = 420;
    constexpr uint32_t   height = 220;
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    int  min_y                  = static_cast<int>(height);
    int  max_y                  = -1;
    bool has_partial_alpha_edge = false;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(static_cast<std::size_t>(y) * width + x) * 4u + 3u];
            if (alpha == 0u) continue;
            min_y                  = std::min(min_y, static_cast<int>(y));
            max_y                  = std::max(max_y, static_cast<int>(y));
            has_partial_alpha_edge = has_partial_alpha_edge || (alpha > 0u && alpha < 255u);
        }
    }

    ASSERT_GE(max_y, min_y);
    EXPECT_GT(max_y - min_y + 1, 110);
    EXPECT_TRUE(has_partial_alpha_edge);
}

TEST(TextObjectRuntime, SansSerifAliasRasterizesClockDigits) {
    TextLayerState state {
        .text                   = "12:34",
        .font_key               = "systemfont_sansserif",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "sansserif",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_sansserif"),
        .point_size             = 33.0f,
        .padding                = 32.0f,
        .explicit_size          = Eigen::Vector2f(342.0f, 156.0f),
        .color                  = Eigen::Vector3f(1.0f, 0.81176f, 0.87059f),
        .horizontal_align       = "center",
        .vertical_align         = "center",
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    const auto     size   = TextLayerRasterSize(state);
    const uint32_t width  = static_cast<uint32_t>(std::ceil(size.x()));
    const uint32_t height = static_cast<uint32_t>(std::ceil(size.y()));
    ASSERT_GT(width, 0u);
    ASSERT_GT(height, 0u);

    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    int visible_pixels = 0;
    int max_alpha      = 0;
    for (std::size_t offset = 3; offset < rgba.size(); offset += 4u) {
        const auto alpha = rgba[offset];
        if (alpha == 0u) continue;
        ++visible_pixels;
        max_alpha = std::max(max_alpha, static_cast<int>(alpha));
    }

    EXPECT_GT(visible_pixels, 200);
    EXPECT_GT(max_alpha, 128);
}

TEST(TextObjectRuntime, ParserResolvesFamilyFontsForFreeTypeRasterization) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-family-freetype",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "Hg",
            "font": "Helvetica",
            "pointsize": 40,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    const auto state = scene->runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->resolved_font_kind, "family");
#ifdef __APPLE__
    EXPECT_FALSE(state->resolved_font_path.empty());
#endif
    const auto runtime_size = scene->runtime->NodeSize("caption");
    EXPECT_GT(runtime_size.x(), 130.0f);
    EXPECT_GT(runtime_size.y(), 120.0f);
    EXPECT_LT(runtime_size.x(), 280.0f);
    EXPECT_LT(runtime_size.y(), 220.0f);

    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& vertex_array = node->Mesh()->GetVertexArray(0);
    ASSERT_EQ(vertex_array.VertexCount(), 4u);
    const float* vertices = vertex_array.Data();
    ASSERT_NE(vertices, nullptr);
    const auto stride = vertex_array.OneSize();
    float      min_x  = vertices[0];
    float      max_x  = vertices[0];
    float      min_y  = vertices[1];
    float      max_y  = vertices[1];
    for (std::size_t index = 1; index < vertex_array.VertexCount(); ++index) {
        const float x = vertices[index * stride + 0u];
        const float y = vertices[index * stride + 1u];
        min_x         = std::min(min_x, x);
        max_x         = std::max(max_x, x);
        min_y         = std::min(min_y, y);
        max_y         = std::max(max_y, y);
    }
    EXPECT_NEAR(max_x - min_x, runtime_size.x(), 1.0f);
    EXPECT_NEAR(max_y - min_y, runtime_size.y(), 1.0f);

    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    const auto& mip = image->slots[0].mipmaps[0];
    ASSERT_NE(mip.data, nullptr);

    bool has_partial_alpha_edge = false;
    for (int y = 0; y < mip.height && ! has_partial_alpha_edge; ++y) {
        for (int x = 0; x < mip.width; ++x) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            if (alpha > 0u && alpha < 255u) {
                has_partial_alpha_edge = true;
                break;
            }
        }
    }
    EXPECT_TRUE(has_partial_alpha_edge);
}

TEST(TextObjectRuntime, FreeTypeEstimatedSizeContainsTallGlyphs) {
    TextLayerState state {
        .text                   = "Hg",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 40.0f,
        .padding                = 4.0f,
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    const auto size = TextLayerRasterSize(state);
    EXPECT_GT(size.x(), 130.0f);
    EXPECT_GT(size.y(), 120.0f);
    EXPECT_LT(size.x(), 280.0f);
    EXPECT_LT(size.y(), 220.0f);

    std::vector<uint8_t> rgba(static_cast<std::size_t>(std::ceil(size.x())) *
                                  static_cast<std::size_t>(std::ceil(size.y())) * 4u,
                              0u);
    RasterizeTextLayer(state,
                       static_cast<uint32_t>(std::ceil(size.x())),
                       static_cast<uint32_t>(std::ceil(size.y())),
                       rgba);

    bool has_visible_alpha = false;
    for (std::size_t offset = 3; offset < rgba.size(); offset += 4u) {
        if (rgba[offset] > 0u) {
            has_visible_alpha = true;
            break;
        }
    }
    EXPECT_TRUE(has_visible_alpha);
}

TEST(TextObjectRuntime, TextRasterExpandsBeyondExplicitBoxWhenNeeded) {
    TextLayerState state {
        .text                   = "Saturday",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 20.0f,
        .padding                = 0.0f,
        .explicit_size          = Eigen::Vector2f(180.0f, 60.0f),
        .horizontal_align       = "left",
        .vertical_align         = "top",
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    const auto size = TextLayerRasterSize(state);
    EXPECT_GT(size.x(), 220.0f);
    EXPECT_GT(size.y(), 70.0f);

    const uint32_t       width  = static_cast<uint32_t>(std::ceil(size.x()));
    const uint32_t       height = static_cast<uint32_t>(std::ceil(size.y()));
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    int min_x = static_cast<int>(width);
    int max_x = -1;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(static_cast<std::size_t>(y) * width + x) * 4u + 3u];
            if (alpha == 0u) continue;
            min_x = std::min(min_x, static_cast<int>(x));
            max_x = std::max(max_x, static_cast<int>(x));
        }
    }

    ASSERT_GE(max_x, min_x);
    EXPECT_LT(min_x, 8);
    EXPECT_GT(max_x, 220);
    EXPECT_LT(max_x, static_cast<int>(width));
}

TEST(TextObjectRuntime, DynamicTextTransformSettingsUpdateRuntimeNode) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "text_origin", RuntimeScalarValue::String("30 40 0") },
          { "text_scale", RuntimeScalarValue::Float(2.5f) },
    };
    SceneParseRequest request {
        .scene_id           = "text-dynamic-transform",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "clock",
            "font": "Arial",
            "pointsize": 20,
            "origin": {"value": "10 20 0", "user": "text_origin"},
            "scale": {"value": "1 1 1", "user": "text_scale"},
            "horizontalalign": "center",
            "verticalalign": "center",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    EXPECT_FLOAT_EQ(node->Translate().x(), 30.0f);
    EXPECT_FLOAT_EQ(node->Translate().y(), 40.0f);
    EXPECT_FLOAT_EQ(node->Scale().x(), 2.5f);
    EXPECT_FLOAT_EQ(node->Scale().y(), 2.5f);

    scene->runtime->ApplyProjectPropertyOverride({
        { "text_origin", RuntimeScalarValue::String("50 60 0") },
        { "text_scale", RuntimeScalarValue::Float(3.0f) },
    });
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(node->Translate().x(), 50.0f);
    EXPECT_FLOAT_EQ(node->Translate().y(), 60.0f);
    EXPECT_FLOAT_EQ(node->Scale().x(), 3.0f);
    EXPECT_FLOAT_EQ(node->Scale().y(), 3.0f);
}

TEST(TextObjectRuntime, DynamicTextTransformScriptsUseCanvasSize) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "x", RuntimeScalarValue::Float(0.8f) },
          { "y", RuntimeScalarValue::Float(0.25f) },
    };
    SceneParseRequest request {
        .scene_id           = "text-dynamic-transform-script",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"JSON({
          "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
          "general": {
            "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
            "clearcolor":[0,0,0], "cameraparallax":false,
            "cameraparallaxamount":0, "cameraparallaxdelay":0,
            "cameraparallaxmouseinfluence":0,
            "orthogonalprojection":{"width":1000,"height":500}
          },
          "objects": [
            {
              "id": 1,
              "name": "caption",
              "text": "clock",
              "font": "Arial",
              "pointsize": 20,
              "origin": {
                "value": "0 0 0",
                "scriptproperties": {
                  "x": {"user": "x", "value": 0.5},
                  "y": {"user": "y", "value": 0.5}
                },
                "script": "export var scriptProperties = createScriptProperties().addSlider({name:'x',value:0.5}).addSlider({name:'y',value:0.5}).finish(); export function update(value) { value.x = scriptProperties.x * engine.canvasSize.x; value.y = scriptProperties.y * engine.canvasSize.y; return value; }"
              },
              "horizontalalign": "center",
              "verticalalign": "center",
              "visible": true
            }
          ]
        })JSON",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(node->Translate().x(), 800.0f);
    EXPECT_FLOAT_EQ(node->Translate().y(), 125.0f);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, ParserUsesUniqueTextureKeysForDuplicateTextLayerNames) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "duplicate-text-names",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "duplicate",
            "text": "first",
            "font": "Arial",
            "pointsize": 20,
            "visible": true
          },
          {
            "id": 2,
            "name": "duplicate",
            "text": "second much wider",
            "font": "Arial",
            "pointsize": 20,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->sceneGraph, nullptr);
    auto* first  = FindRootChild(*scene, "__we_text_1");
    auto* second = FindRootChild(*scene, "__we_text_2");
    ASSERT_NE(first, nullptr);
    ASSERT_NE(second, nullptr);
    ASSERT_NE(first->Mesh(), nullptr);
    ASSERT_NE(second->Mesh(), nullptr);
    auto* first_material  = first->Mesh()->MaterialForSlot(0);
    auto* second_material = second->Mesh()->MaterialForSlot(0);
    ASSERT_NE(first_material, nullptr);
    ASSERT_NE(second_material, nullptr);
    ASSERT_EQ(first_material->textures.size(), 1u);
    ASSERT_EQ(second_material->textures.size(), 1u);

    EXPECT_NE(first_material->textures.front(), second_material->textures.front());
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_text_1"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_text_2"));
    EXPECT_EQ(scene->runtime->NodeText("__we_text_1"), "first");
    EXPECT_EQ(scene->runtime->NodeText("__we_text_2"), "second much wider");
}

TEST(TextObjectRuntime, ParserReadsSupportedTextFormsIntoRuntimeState) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-forms",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "plain", "text": "plain text", "font": "Arial", "visible": true},
          {"id": 2, "name": "nested", "text": {"text": "nested text"}, "font": {"value": "Arial"}, "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("plain"), "plain text");
    EXPECT_EQ(scene->runtime->NodeText("nested"), "nested text");
}

TEST(TextObjectRuntime, ParserResolvesFontFamiliesAssetsAndSystemFontAliases) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/fonts/asset.ttf", "fake-font-bytes" },
                    { "/fonts/prefixed.ttf", "fake-font-bytes" },
                });
    ASSERT_TRUE(vfs.Mount("/provided",
                          std::make_unique<MemoryFs>(std::map<std::string, std::string> {
                              { "/absolute.otf", "fake-font-bytes" },
                          })));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-fonts",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "family", "text": "a", "font": "Arial", "visible": true},
          {"id": 2, "name": "asset", "text": "a", "font": "fonts/asset.ttf", "visible": true},
          {"id": 3, "name": "system", "text": "a", "font": "systemfont_Helvetica", "visible": true},
          {"id": 4, "name": "provided", "text": "a", "font": "/provided/absolute.otf", "visible": true},
          {"id": 5, "name": "prefixed", "text": "a", "font": "assets/fonts/prefixed.ttf", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    auto family = scene->runtime->NodeTextState("family");
    ASSERT_TRUE(family.has_value());
    EXPECT_EQ(family->resolved_font_kind, "family");
    EXPECT_EQ(family->resolved_font_identity, "Arial");

    auto asset = scene->runtime->NodeTextState("asset");
    ASSERT_TRUE(asset.has_value());
    EXPECT_EQ(asset->resolved_font_kind, "asset");
    EXPECT_EQ(asset->resolved_font_path, "/assets/fonts/asset.ttf");
    EXPECT_EQ(std::string(asset->resolved_font_data.begin(), asset->resolved_font_data.end()),
              "fake-font-bytes");

    auto system = scene->runtime->NodeTextState("system");
    ASSERT_TRUE(system.has_value());
    EXPECT_EQ(system->resolved_font_kind, "system");
    EXPECT_EQ(system->resolved_font_identity, "Helvetica");

    auto provided = scene->runtime->NodeTextState("provided");
    ASSERT_TRUE(provided.has_value());
    EXPECT_EQ(provided->resolved_font_kind, "asset");
    EXPECT_EQ(provided->resolved_font_path, "/provided/absolute.otf");
    EXPECT_EQ(std::string(provided->resolved_font_data.begin(), provided->resolved_font_data.end()),
              "fake-font-bytes");

    auto prefixed = scene->runtime->NodeTextState("prefixed");
    ASSERT_TRUE(prefixed.has_value());
    EXPECT_EQ(prefixed->resolved_font_kind, "asset");
    EXPECT_EQ(prefixed->resolved_font_path, "/assets/fonts/prefixed.ttf");
}

TEST(TextObjectRuntime, TextLayerStateCopiesShareResolvedFontData) {
    TextLayerState state {
        .text               = "fps: 60",
        .resolved_font_data = std::vector<uint8_t>(1024, 42),
    };

    const auto copy = state;

    ASSERT_FALSE(state.resolved_font_data.empty());
    ASSERT_FALSE(copy.resolved_font_data.empty());
    EXPECT_EQ(copy.resolved_font_data.data(), state.resolved_font_data.data());
}

TEST(TextObjectRuntime, ParserMapsSystemFontAliasesToPlatformFontPath) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-system-font-path",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "system", "text": "a", "font": "systemfont_Helvetica", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    auto system = scene->runtime->NodeTextState("system");
    ASSERT_TRUE(system.has_value());
    EXPECT_EQ(system->resolved_font_kind, "system");
    EXPECT_EQ(system->resolved_font_identity, "Helvetica");
#ifdef __APPLE__
    EXPECT_FALSE(system->resolved_font_path.empty());
#else
    EXPECT_TRUE(system->resolved_font_path.empty());
#endif
}

TEST(TextObjectRuntime, HiddenTextStillCreatesNodeAndRuntimeState) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "hidden-text",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "hiddenCaption", "text": "secret", "font": "Arial", "visible": false}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->runtime->HasNodeNamed("hiddenCaption"));
    EXPECT_EQ(scene->runtime->NodeText("hiddenCaption"), "secret");
    auto* node = FindRootChild(*scene, "hiddenCaption");
    ASSERT_NE(node, nullptr);
    EXPECT_FALSE(node->Visible());
}

TEST(TextObjectRuntime, TextVisibleScriptUpdatesVisibilityOnTick) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-visible-script",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "scripted",
            "font": "Arial",
            "visible": {
              "value": true,
              "script": "export function update(value) { return false; }"
            }
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, TextVisibleUserBindingFollowsProjectOverride) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "show_text", RuntimeScalarValue::Bool(true) },
    };
    SceneParseRequest request {
        .scene_id           = "text-visible-user",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "user",
            "font": "Arial",
            "visible": {"value": true, "user": "show_text"}
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    EXPECT_TRUE(node->Visible());

    scene->runtime->ApplyProjectPropertyOverride({
        { "show_text", RuntimeScalarValue::Bool(false) },
    });
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(node->Visible());
}

TEST(TextObjectRuntime, TextFieldScriptUpdatesRuntimeTextOnTick) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-field-script",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "before",
              "script": "export function update(value) { return value + ' after'; }"
            },
            "font": "Arial",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "before after");
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));

    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "before after");
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, StaticObjectTextDoesNotOverwriteRuntimeMutationOnTick) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-static-object-field",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": {"text": "before"},
            "font": "Arial",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "before");

    scene->runtime->SetNodeText("caption", "after");
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "after");
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, EventOnlyTextScriptDoesNotOverwriteRuntimeMutationOnTick) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-event-script-object-field",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "before",
              "script": "engine.on('custom', function() {})"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "before");

    scene->runtime->SetNodeText("caption", "after");
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "after");
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, EventOnlyTextScriptRegistersAsSceneScript) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-event-script-scene-script",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "before",
              "script": "engine.on('cursorDown', function() { thisLayer.text = 'clicked'; })"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "before");
    EXPECT_EQ(scene->runtime->sceneScriptCount(), 1u);

    scene->runtime->DispatchCursorDown(0);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "clicked");
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, TextParentReusesPlaceholderWhenChildAppearsFirst) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-placeholder",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 2, "name": "childText", "parent": 1, "text": "child", "font": "Arial", "visible": true},
          {"id": 1, "name": "parentText", "text": "parent", "font": "Arial", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* parent = FindRootChild(*scene, "parentText");
    ASSERT_NE(parent, nullptr);
    EXPECT_NE(parent->Mesh(), nullptr);
    ASSERT_EQ(parent->GetChildren().size(), 1u);
    EXPECT_EQ(parent->GetChildren().front()->Name(), "childText");
    EXPECT_EQ(parent->GetChildren().front()->Parent(), parent);
}

TEST(TextObjectRuntime, UnnamedTextPlaceholderDoesNotLeaveStaleRuntimeLayerKey) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "unnamed-text-placeholder",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 2, "name": "childText", "parent": 1, "text": "child", "font": "Arial", "visible": true},
          {"id": 1, "text": "parent", "font": "Arial", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("__we_layer_1"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_text_1"));
    EXPECT_EQ(scene->runtime->NodeText("__we_text_1"), "parent");
}

TEST(TextObjectRuntime, TextStateUsesRuntimeRgbaTextureBackend) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text       = "layout only",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });

    const auto state = runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->render_backend, "runtime-rgba-texture");
}

TEST(TextObjectRuntime, RuntimeTextMutationUpdatesPersistentTextAndSize) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text             = "a",
                                   .font_key         = "Arial",
                                   .point_size       = 10.0f,
                                   .padding          = 2.0f,
                                   .horizontal_align = "left",
                                   .vertical_align   = "top",
                                   .anchor           = "left top",
                               });

    const auto before       = runtime->NodeSize("caption");
    const auto before_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(before_state.has_value());
    EXPECT_FALSE(before_state->texture_cache_key.empty());
    EXPECT_EQ(before_state->cache_revision, 1u);
    ASSERT_TRUE(runtime->SetNodeText("caption", "longer text"));

    EXPECT_EQ(runtime->NodeText("caption"), "longer text");
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));

    PumpTextUntilClean(*runtime);

    const auto after = runtime->NodeSize("caption");
    EXPECT_GT(after.x(), before.x());
    EXPECT_FLOAT_EQ(after.y(), before.y());
    const auto dirty_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(dirty_state.has_value());
    EXPECT_EQ(dirty_state->cache_revision, before_state->cache_revision + 1u);
    EXPECT_FALSE(dirty_state->cache_dirty);
    EXPECT_FALSE(dirty_state->full_dirty);

    runtime->ClearNodeTextDirty("caption");
    const auto clean_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(clean_state.has_value());
    EXPECT_EQ(clean_state->text, "longer text");
    EXPECT_EQ(clean_state->cache_revision, dirty_state->cache_revision);
    EXPECT_FALSE(clean_state->cache_dirty);
    EXPECT_FALSE(clean_state->full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, UnchangedRuntimeTextMutationSkipsDirtyAndCacheRevision) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text             = "12:34",
                                   .font_key         = "systemfont_sansserif",
                                   .point_size       = 33.0f,
                                   .padding          = 32.0f,
                                   .explicit_size    = Eigen::Vector2f(342.0f, 156.0f),
                                   .horizontal_align = "center",
                                   .vertical_align   = "center",
                               });
    runtime->RegisterTextValue("caption", std::make_unique<DynamicValue>("12:34"));
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->ConsumeSceneGraphMutationFlag());

    const auto before_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(before_state.has_value());
    ASSERT_FALSE(before_state->cache_dirty);
    ASSERT_FALSE(before_state->full_dirty);

    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);

    const auto after_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(after_state.has_value());
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_EQ(after_state->cache_revision, before_state->cache_revision);
    EXPECT_FALSE(after_state->cache_dirty);
    EXPECT_FALSE(after_state->full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, ClockScriptUpdatesSameSizeTextOnceThenSkipsMeasurements) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-clock-script-same-size",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "Clock",
            "text": {
              "value": "06:15",
              "script": "export function update(value) { return '12:34'; }"
            },
            "font": "systemfont_sansserif",
            "pointsize": 33,
            "padding": 32,
            "size": "342 156",
            "horizontalalign": "center",
            "verticalalign": "center",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* runtime = scene->runtime.get();

    EXPECT_EQ(runtime->NodeText("Clock"), "12:34");
    runtime->ClearNodeTextDirty("Clock");
    ASSERT_FALSE(runtime->NodeTextDirty("Clock"));

    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(runtime->NodeText("Clock"), "12:34");
    const auto changed_state = runtime->NodeTextState("Clock");
    ASSERT_TRUE(changed_state.has_value());
    EXPECT_FALSE(runtime->NodeTextDirty("Clock"));
    EXPECT_FALSE(changed_state->cache_dirty);

    runtime->ClearNodeTextDirty("Clock");
    ASSERT_FALSE(runtime->NodeTextDirty("Clock"));
    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(runtime->NodeText("Clock"), "12:34");
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_FALSE(runtime->NodeTextDirty("Clock"));
}

TEST(TextObjectRuntime, ClockScriptTextResizeDoesNotMutateSceneGraph) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-clock-script-resize-no-graph-mutation",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "Clock",
            "text": {
              "value": "1",
              "script": "export function update(value) { return '888888888888'; }"
            },
            "font": "systemfont_sansserif",
            "pointsize": 33,
            "padding": 32,
            "horizontalalign": "center",
            "verticalalign": "center",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* runtime = scene->runtime.get();
    auto* clock   = FindRootChild(*scene, "Clock");
    ASSERT_NE(clock, nullptr);
    ASSERT_NE(clock->Mesh(), nullptr);
    ASSERT_TRUE(clock->Mesh()->Dynamic());
    ASSERT_FALSE(runtime->ConsumeSceneGraphMutationFlag());

    EXPECT_EQ(runtime->NodeText("Clock"), "888888888888");
    EXPECT_FALSE(runtime->NodeTextDirty("Clock"));
    const auto before_size      = runtime->NodeSize("Clock");
    const auto before_mesh_size = MeshSize(*clock->Mesh());

    runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(runtime->NodeText("Clock"), "888888888888");
    EXPECT_FALSE(runtime->NodeTextDirty("Clock"));
    EXPECT_FLOAT_EQ(runtime->NodeSize("Clock").x(), before_size.x());
    EXPECT_FLOAT_EQ(MeshSize(*clock->Mesh()).x(), before_mesh_size.x());
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, Workshop3409533530ClockParentKeepsVisibleRuntimeTexture) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    {
                        "/fonts/workshop/3261114750/SourceHanSansCN-Normal.otf",
                        "not-used-by-clock",
                    },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "clock", RuntimeScalarValue::Bool(true) },
          { "time", RuntimeScalarValue::Bool(true) },
          { "x", RuntimeScalarValue::Float(0.8f) },
          { "y", RuntimeScalarValue::Float(0.25f) },
          { "newproperty1", RuntimeScalarValue::String("1 0.8117647 0.8705882") },
          { "newproperty2", RuntimeScalarValue::Float(2.5f) },
    };
    SceneParseRequest request {
          .scene_id           = "workshop-3409533530-clock-repro",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"JSON({
          "camera": {"center":"0.00000 0.00000 -1.00000", "eye":"0.00000 0.00000 0.00000", "up":"0.00000 1.00000 0.00000"},
          "general": {
            "ambientcolor":"0.30000 0.30000 0.30000",
            "skylightcolor":"0.30000 0.30000 0.30000",
            "clearcolor":"0.70000 0.70000 0.70000",
            "clearenabled":true,
            "cameraparallax":false,
            "cameraparallaxamount":0,
            "cameraparallaxdelay":0,
            "cameraparallaxmouseinfluence":0,
            "orthogonalprojection":{"width":3840,"height":2160}
          },
          "objects": [
            {
              "id": 31,
              "name": "Clock",
              "text": {
                "value": "06:15",
                "scriptproperties": {
                  "delimiter": ":",
                  "showCD": false,
                  "showTime": false,
                  "use12hFormat": {"user": "show12h", "value": false}
                },
                "script": "export var scriptProperties = createScriptProperties().addCheckbox({name:'use12hFormat',value:false}).addText({name:'delimiter',value:':'}).addCheckbox({name:'showTime',value:false}).addCheckbox({name:'showCD',value:false}).finish(); export function update(value) { let time = new Date(); var hours = time.getHours(); if (scriptProperties.use12hFormat) { hours %= 12; if (hours == 0) hours = 12; } hours = ('00' + hours).slice(-2); let minutes = ('00' + time.getMinutes()).slice(-2); value = hours + scriptProperties.delimiter + minutes; if (scriptProperties.showTime) value = '\\0'; if (scriptProperties.showCD) value = '\\0'; return value; }"
              },
              "font": "systemfont_sansserif",
              "pointsize": 33.0,
              "padding": 32,
              "size": "342.00000 156.00000",
              "origin": {
                "value": "0.00000 0.00000 0.00000",
                "scriptproperties": {
                  "x": {"user": "x", "value": 1},
                  "y": {"user": "y", "value": 1}
                },
                "script": "export var scriptProperties = createScriptProperties().addSlider({name:'x',value:0.5}).addSlider({name:'y',value:0.5}).finish(); export function update(value) { value.x = scriptProperties.x * engine.canvasSize.x; value.y = scriptProperties.y * engine.canvasSize.y; return value; }"
              },
              "scale": {"user": "newproperty2", "value": "2.50000 2.50000 2.50000"},
              "visible": {"user": "clock", "value": true},
              "color": {"user": "newproperty1", "value": "1.00000 0.81176 0.87059"},
              "horizontalalign": "center",
              "verticalalign": "center",
              "anchor": "none"
            },
            {
              "id": 32,
              "name": "Date",
              "parent": 31,
              "text": "DATE",
              "font": "systemfont_sansserif",
              "pointsize": 20.0,
              "padding": 36,
              "size": "987.00000 125.00000",
              "origin": "283.14212 -113.36209 0.00000",
              "scale": "0.28000 0.28000 0.00000",
              "visible": {"user": "time", "value": true},
              "horizontalalign": "right",
              "verticalalign": "center",
              "anchor": "none"
            },
            {
              "id": 33,
              "name": "Dy",
              "parent": 31,
              "text": "PM",
              "font": "systemfont_sansserif",
              "pointsize": 32.0,
              "padding": 32,
              "size": "190.00000 200.00000",
              "origin": "230.29727 -31.03779 0.00000",
              "scale": "0.61854 0.56577 0.43846",
              "horizontalalign": "center",
              "verticalalign": "center",
              "anchor": "none"
            }
          ]
        })JSON",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* runtime = scene->runtime.get();

    auto* clock = FindRootChild(*scene, "Clock");
    ASSERT_NE(clock, nullptr);
    ASSERT_NE(clock->Mesh(), nullptr);
    ASSERT_EQ(clock->GetChildren().size(), 2u);
    EXPECT_EQ(clock->GetChildren().front()->Name(), "Date");
    EXPECT_EQ(clock->GetChildren().back()->Name(), "Dy");

    runtime->Tick(1.0 / 60.0);
    runtime->PumpTextLayerCache();

    EXPECT_TRUE(runtime->NodeVisible("Clock"));
    EXPECT_TRUE(clock->EffectiveVisible());
    EXPECT_NE(runtime->NodeText("Clock"), std::string("\0", 1));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);

    const auto translate = runtime->NodeTranslate("Clock");
    const auto scale     = runtime->NodeScale("Clock");
    EXPECT_NEAR(translate.x(), 3072.0f, 1.0e-3f);
    EXPECT_NEAR(translate.y(), 540.0f, 1.0e-3f);
    EXPECT_NEAR(scale.x(), 2.5f, 1.0e-3f);
    EXPECT_NEAR(scale.y(), 2.5f, 1.0e-3f);

    auto state = runtime->NodeTextState("Clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->resolved_font_kind, "system");
#ifdef __APPLE__
    EXPECT_FALSE(state->resolved_font_path.empty());
#endif

    auto* material = clock->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    EXPECT_GT(image->header.width, 300);
    EXPECT_GT(image->header.height, 140);
    EXPECT_GT(VisibleAlphaPixels(*image), 200);

    runtime->ClearNodeTextDirty("Clock");
    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
}

TEST(TextObjectRuntime, Workshop3409533530FullSceneKeepsClockRenderPassAndTexture) {
    const auto home = HomePath();
    if (home.empty()) GTEST_SKIP() << "HOME is not set";

    const auto workshop_root =
        home / "Library/Application Support/Steam/steamapps/workshop/content/431960/3409533530";
    const auto project_json = ReadTextFile(workshop_root / "project.json");
    if (! project_json.has_value() || ! std::filesystem::exists(workshop_root / "scene.pkg")) {
        GTEST_SKIP() << "local workshop 3409533530 package is not available";
    }

    fs::VFS vfs;
    const auto common_assets =
        home / "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets";
    if (std::filesystem::exists(common_assets)) {
        ASSERT_TRUE(MountPhysicalAssets(vfs, common_assets));
    }
    ASSERT_TRUE(vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs((workshop_root / "scene.pkg").string())));
    auto scene_stream = vfs.Open("/assets/scene.json");
    ASSERT_NE(scene_stream, nullptr);
    const auto scene_json = scene_stream->ReadAllStr();

    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "clock", RuntimeScalarValue::Bool(true) },
          { "time", RuntimeScalarValue::Bool(true) },
          { "x", RuntimeScalarValue::Float(0.8f) },
          { "y", RuntimeScalarValue::Float(0.25f) },
          { "newproperty1", RuntimeScalarValue::String("1 0.8117647 0.8705882") },
          { "newproperty2", RuntimeScalarValue::Float(2.5f) },
    };
    SceneParseRequest request {
          .scene_id           = "workshop-3409533530-full-scene-clock-repro",
          .project_path       = (workshop_root / "project.json").string(),
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request, scene_json, vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    auto* clock = FindRootChild(*scene, "Clock");
    ASSERT_NE(clock, nullptr);
    ASSERT_NE(clock->Mesh(), nullptr);
    EXPECT_GE(clock->GetChildren().size(), 4u);

    auto* runtime = scene->runtime.get();
    runtime->Tick(1.0 / 60.0);
    runtime->PumpTextLayerCache();

    EXPECT_TRUE(runtime->NodeVisible("Clock"));
    EXPECT_TRUE(clock->EffectiveVisible());
    EXPECT_NE(runtime->NodeText("Clock"), std::string("\0", 1));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);

    auto* material = clock->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    EXPECT_EQ(material->textures.front(), TextTextureName("Clock"));
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    EXPECT_GT(VisibleAlphaPixels(*image), 200);

    const auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    const auto* clock_pass = FindCustomPassForNode(*graph, clock);
    ASSERT_NE(clock_pass, nullptr);
    ASSERT_EQ(clock_pass->desc().textures.size(), 1u);
    EXPECT_EQ(clock_pass->desc().textures.front(), TextTextureName("Clock"));
    EXPECT_EQ(clock_pass->desc().visibility_node, clock);
    EXPECT_EQ(clock_pass->desc().output, SpecTex_Default);
    EXPECT_NE(clock_pass->desc().uploaded_mesh_dirty_generation, clock->Mesh()->DirtyGeneration());

    runtime->ClearNodeTextDirty("Clock");
    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
}

TEST(TextObjectRuntime, DynamicTextPassStartsWithPendingInitialZeroGenerationUpload) {
    SceneMesh mesh(true);
    ASSERT_TRUE(mesh.Dynamic());
    ASSERT_EQ(mesh.DirtyGeneration(), 0u);

    vulkan::CustomShaderPass::Desc desc;
    vulkan::CustomShaderPass       pass(desc);

    EXPECT_NE(pass.desc().uploaded_mesh_dirty_generation, mesh.DirtyGeneration());
}

TEST(TextObjectRuntime, RuntimeTextMutationResizesRenderableMesh) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-runtime-mesh-resize",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "a", "font": "Arial", "pointsize": 10, "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_TRUE(node->Mesh()->Dynamic());

    auto mesh_width = [](const SceneMesh& mesh) {
        const auto& vertices = mesh.GetVertexArray(0);
        const auto  stride   = vertices.OneSize();
        const auto* data     = vertices.Data();
        float       min_x    = data[0];
        float       max_x    = data[0];
        for (std::size_t index = 1; index < vertices.VertexCount(); ++index) {
            const float x = data[index * stride];
            min_x         = std::min(min_x, x);
            max_x         = std::max(max_x, x);
        }
        return max_x - min_x;
    };

    const auto before_size  = scene->runtime->NodeSize("caption");
    const auto before_width = mesh_width(*node->Mesh());

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaaaaaa"));
    PumpTextUntilClean(*scene->runtime);

    const auto after_size  = scene->runtime->NodeSize("caption");
    const auto after_width = mesh_width(*node->Mesh());
    EXPECT_GT(after_size.x(), before_size.x());
    EXPECT_GT(after_width, before_width);
    EXPECT_NEAR(after_width, after_size.x(), 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, AlignedTextReanchorsWhenTextSizeChanges) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-reanchor",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "a", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "horizontalalign": "right", "verticalalign": "bottom", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    const auto before_translate = node->Translate();
    const auto before_size      = scene->runtime->NodeSize("caption");

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaaaaaa"));
    PumpTextUntilClean(*scene->runtime);

    const auto after_translate = node->Translate();
    const auto after_size      = scene->runtime->NodeSize("caption");
    EXPECT_GT(after_size.x(), before_size.x());
    EXPECT_LT(after_translate.x(), before_translate.x());
    EXPECT_FLOAT_EQ(after_translate.y(), before_translate.y());
    EXPECT_NEAR(after_translate.x(), 100.0f - after_size.x() * 0.5f, 1.0e-4f);
    EXPECT_NEAR(after_translate.y(), 50.0f + after_size.y() * 0.5f, 1.0e-4f);
}

TEST(TextObjectRuntime, ScaledTextAnchoringUsesRenderedSizeFromOriginalOrigin) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-scaled-reanchor",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "aa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "scale": [2, 3, 1], "horizontalalign": "right", "verticalalign": "bottom", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    const auto size = scene->runtime->NodeSize("caption");
    EXPECT_NEAR(node->Translate().x(), 100.0f - size.x(), 1.0e-4f);
    EXPECT_NEAR(node->Translate().y(), 50.0f + size.y() * 1.5f, 1.0e-4f);

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaa"));
    PumpTextUntilClean(*scene->runtime);
    const auto resized = scene->runtime->NodeSize("caption");
    EXPECT_NEAR(node->Translate().x(), 100.0f - resized.x(), 1.0e-4f);
    EXPECT_NEAR(node->Translate().y(), 50.0f + resized.y() * 1.5f, 1.0e-4f);
}

TEST(TextObjectRuntime, PumpTextLayerCacheClearsDirtyStateWithoutLosingText) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text       = "before",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });

    ASSERT_TRUE(runtime->SetNodeText("caption", "after"));
    ASSERT_TRUE(runtime->NodeTextDirty("caption"));
    PumpTextUntilClean(*runtime);

    const auto state = runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->text, "after");
    EXPECT_FALSE(state->cache_dirty);
    EXPECT_FALSE(state->full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, PumpTextLayerCacheDoesNotKeepDirtyWhenSceneCannotAcceptRuntimeTexture) {
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    scene.runtime->AttachScene(&scene);

    auto node = std::make_shared<SceneNode>();
    scene.runtime->RegisterNode("caption", node.get());
    scene.runtime->RegisterTextLayer("caption",
                                     TextLayerState {
                                         .text       = "before",
                                         .font_key   = "Arial",
                                         .point_size = 12.0f,
                                     });

    ASSERT_TRUE(scene.runtime->SetNodeText("caption", "after"));
    ASSERT_TRUE(scene.runtime->NodeTextDirty("caption"));

    PumpTextUntilClean(*scene.runtime);

    const auto state = scene.runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_FALSE(state->cache_dirty);
    EXPECT_FALSE(state->full_dirty);
    EXPECT_FALSE(scene.runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(scene.runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, PumpTextLayerCacheRerasterizesAttachedSceneTexture) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-rerasterize",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "a", "font": "Arial", "pointsize": 20, "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    const auto texture_name = material->textures.front();

    auto before = scene->imageParser->Parse(texture_name);
    ASSERT_NE(before, nullptr);
    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaa"));
    ASSERT_TRUE(scene->runtime->NodeTextDirty("caption"));

    PumpTextUntilClean(*scene->runtime);

    auto after = scene->imageParser->Parse(texture_name);
    ASSERT_NE(after, nullptr);
    EXPECT_NE(before->key, after->key);
    EXPECT_GT(after->header.width, before->header.width);
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, PumpTextLayerCacheSkipsHiddenTextUntilVisible) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "hidden-text-cache-pump",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "before",
            "font": "Arial",
            "pointsize": 20,
            "visible": false
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    const auto texture_name = material->textures.front();

    auto before = scene->imageParser->Parse(texture_name);
    ASSERT_NE(before, nullptr);
    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "after"));
    ASSERT_TRUE(scene->runtime->NodeTextDirty("caption"));

    scene->runtime->PumpTextLayerCache();

    auto hidden = scene->imageParser->Parse(texture_name);
    ASSERT_NE(hidden, nullptr);
    EXPECT_EQ(hidden->key, before->key);
    EXPECT_TRUE(scene->runtime->NodeTextDirty("caption"));

    scene->runtime->SetNodeVisible("caption", true);
    PumpTextUntilClean(*scene->runtime);

    auto visible = scene->imageParser->Parse(texture_name);
    ASSERT_NE(visible, nullptr);
    EXPECT_NE(visible->key, before->key);
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, RuntimeTextMutationDoesNotMeasureSynchronously) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text          = "fps: 59",
                                   .font_key      = "Arial",
                                   .point_size    = 20.0f,
                                   .padding       = 32.0f,
                                   .explicit_size = Eigen::Vector2f(264.0f, 109.0f),
                               });
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->NodeTextDirty("caption"));

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(runtime->SetNodeText("caption", "fps: 60"));

    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, RuntimeTextMutationDefersVisibleTextPreparation) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "visible-text-async-preparation",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "before",
            "font": "Arial",
            "pointsize": 28,
            "padding": 32,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    const auto texture_name = material->textures.front();

    auto before = scene->imageParser->Parse(texture_name);
    ASSERT_NE(before, nullptr);

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "after after after"));
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "after after after");
    EXPECT_TRUE(scene->runtime->NodeTextDirty("caption"));

    scene->runtime->PumpTextLayerCache();
    auto queued = scene->imageParser->Parse(texture_name);
    ASSERT_NE(queued, nullptr);
    EXPECT_EQ(queued->key, before->key);
    EXPECT_TRUE(scene->runtime->NodeTextDirty("caption"));

    std::shared_ptr<Image> updated;
    for (int attempt = 0; attempt < 200; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        scene->runtime->PumpTextLayerCache();
        updated = scene->imageParser->Parse(texture_name);
        ASSERT_NE(updated, nullptr);
        if (updated->key != before->key) break;
    }

    ASSERT_NE(updated, nullptr);
    EXPECT_NE(updated->key, before->key);
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, TextCacheKeysAreUniquePerLayerEvenWithSameFontAndSize) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto first  = std::make_shared<SceneNode>();
    auto second = std::make_shared<SceneNode>();
    runtime->RegisterNode("first", first.get());
    runtime->RegisterNode("second", second.get());
    runtime->RegisterTextLayer("first",
                               TextLayerState {
                                   .text       = "one",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });
    runtime->RegisterTextLayer("second",
                               TextLayerState {
                                   .text       = "two",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });

    const auto first_state  = runtime->NodeTextState("first");
    const auto second_state = runtime->NodeTextState("second");
    ASSERT_TRUE(first_state.has_value());
    ASSERT_TRUE(second_state.has_value());
    EXPECT_NE(first_state->texture_cache_key, second_state->texture_cache_key);
}

TEST(TextObjectRuntime, HorizontalAlignOverridesLegacyAlignment) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-align-horizontal",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "fallback", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "left", "visible": true},
          {"id": 2, "name": "override", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "left", "horizontalalign": "right", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* fallback = FindRootChild(*scene, "fallback");
    auto* override = FindRootChild(*scene, "override");
    ASSERT_NE(fallback, nullptr);
    ASSERT_NE(override, nullptr);
    EXPECT_GT(fallback->Translate().x(), 100.0f);
    EXPECT_LT(override->Translate().x(), 100.0f);
    EXPECT_FLOAT_EQ(fallback->Translate().y(), 50.0f);
    EXPECT_FLOAT_EQ(override->Translate().y(), 50.0f);
}

TEST(TextObjectRuntime, VerticalAlignOverridesLegacyAlignment) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-align-vertical",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "fallback", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "top", "visible": true},
          {"id": 2, "name": "override", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "top", "verticalalign": "bottom", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* fallback = FindRootChild(*scene, "fallback");
    auto* override = FindRootChild(*scene, "override");
    ASSERT_NE(fallback, nullptr);
    ASSERT_NE(override, nullptr);
    EXPECT_LT(fallback->Translate().y(), 50.0f);
    EXPECT_GT(override->Translate().y(), 50.0f);
    EXPECT_FLOAT_EQ(fallback->Translate().x(), 100.0f);
    EXPECT_FLOAT_EQ(override->Translate().x(), 100.0f);
}

TEST(TextObjectRuntime, ScriptThisLayerTextSetterMutatesRuntimeText) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text       = "before",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                                   .padding    = 0.0f,
                               });

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(),
                                                                       R"JS(
export function update(value) {
  thisLayer.text = "after";
  var indirect = thisScene.getLayer('caption');
  indirect.text = indirect.text + " indirect";
  return thisLayer.text === "after indirect" ? 1 : -1;
}
)JS",
                                                                       "caption",
                                                                       {},
                                                                       DynamicValue(0.0f),
                                                                       runtime->hostContext());
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 1.0f);
    EXPECT_EQ(runtime->NodeText("caption"), "after indirect");
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, FontFallbackHandlesFamiliesMissingFilesAndCorruptAssets) {
#ifdef __APPLE__
    const auto reference_path = ResolveSystemFontPath("systemfont_sansserif");
    ASSERT_FALSE(reference_path.empty());
    std::ifstream font_file(reference_path, std::ios::binary);
    const std::vector<uint8_t> valid_font((std::istreambuf_iterator<char>(font_file)), {});
    ASSERT_FALSE(valid_font.empty());
    for (const auto* family : {"systemfont_consolas", "systemfont_Segoe UI", "Arial",
                              "systemfont_serif", "systemfont_monospace", "missing-font-98765", ""}) {
        for (const auto* text : {"08:36", "Monday September", "Bonjour 你好"}) {
            TextLayerState reference {
                .text = text, .font_key = family,
                .resolved_font_path = ResolveSystemFontPath(family), .point_size = 20, .padding = 4,
            };
            if (reference.resolved_font_path.empty()) reference.resolved_font_path = reference_path;
            const auto raster = [](const TextLayerState& state) {
                const auto size = TextLayerRasterSize(state);
                const auto width = static_cast<uint32_t>(std::ceil(size.x()));
                const auto height = static_cast<uint32_t>(std::ceil(size.y()));
                std::vector<uint8_t> rgba(width * height * 4, 0);
                RasterizeTextLayer(state, width, height, rgba);
                return rgba;
            };
            const auto expected = raster(reference);
            for (int failure = 0; failure < 3; ++failure) {
                SCOPED_TRACE(::testing::Message() << family << ':' << text << ':' << failure);
                auto state = reference;
                state.resolved_font_path = failure == 0 ? "" : "/missing/workshop/font.ttf";
                if (failure == 2) state.resolved_font_data = std::vector<uint8_t>{1,2,3,4};
                EXPECT_EQ(TextLayerRasterSize(state), TextLayerRasterSize(reference));
                EXPECT_EQ(raster(state), expected);
            }
            // A valid embedded font wins even when the requested family is absent.
            auto embedded = reference;
            embedded.resolved_font_path = "/virtual/font.ttf";
            embedded.resolved_font_data = valid_font;
            auto installed = reference;
            installed.resolved_font_path = reference_path;
            EXPECT_EQ(raster(embedded), raster(installed));
        }
    }
#endif
}

TEST(TextObjectRuntime, MissingWindowsFontUsesRealGlyphsInsteadOfRectangles) {
#ifdef __APPLE__
    TextLayerState state {
        .text = "08:36",
        .font_key = "systemfont_consolas",
        .resolved_font_path = ResolveSystemFontPath("systemfont_consolas"),
        .point_size = 33.0f,
        .padding = 32.0f,
    };
    ASSERT_FALSE(state.resolved_font_path.empty());
    EXPECT_TRUE(std::filesystem::exists(state.resolved_font_path));
    EXPECT_FALSE(ResolveSystemFontPath("systemfont_missing-workshop-font-12345").empty());
    const auto size = TextLayerRasterSize(state);
    const auto width = static_cast<uint32_t>(std::ceil(size.x()));
    const auto height = static_cast<uint32_t>(std::ceil(size.y()));
    std::vector<uint8_t> rgba(width * height * 4, 0);
    RasterizeTextLayer(state, width, height, rgba);
    uint32_t min_y = height, max_y = 0;
    std::size_t antialiased = 0;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(y * width + x) * 4 + 3];
            if (alpha) { min_y = std::min(min_y, y); max_y = std::max(max_y, y); }
            if (alpha > 0 && alpha < 255) ++antialiased;
        }
    }
    EXPECT_GT(max_y - min_y, 60u); // Placeholder bars were only 30 px tall.
    EXPECT_GT(antialiased, 100u);
#endif
}

TEST(TextObjectRuntime, ResolvesWallpaperEngineSansSerifSystemFontAlias) {
#ifdef __APPLE__
    EXPECT_FALSE(ResolveSystemFontPath("systemfont_sansserif").empty());
#endif
}

TEST(TextObjectRuntime, FreeTypeRasterizationFallsBackForMissingPrimaryGlyph) {
#ifdef __APPLE__
    TextLayerState state {
        .text                   = "\xE4\xB8\xAD",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 40.0f,
        .padding                = 4.0f,
    };
    ASSERT_FALSE(state.resolved_font_path.empty());

    const auto size = TextLayerRasterSize(state);
    EXPECT_GT(size.x(), 40.0f);
    EXPECT_GT(size.y(), 40.0f);

    const auto           width  = static_cast<uint32_t>(std::ceil(size.x()));
    const auto           height = static_cast<uint32_t>(std::ceil(size.y()));
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    TextLayerState unsupported_state = state;
    unsupported_state.text           = "\xF4\x8F\xBF\xBF";
    const auto unsupported_size      = TextLayerRasterSize(unsupported_state);
    const auto unsupported_width     = static_cast<uint32_t>(std::ceil(unsupported_size.x()));
    const auto unsupported_height    = static_cast<uint32_t>(std::ceil(unsupported_size.y()));
    std::vector<uint8_t> unsupported_rgba(
        static_cast<std::size_t>(unsupported_width) * unsupported_height * 4u, 0u);
    RasterizeTextLayer(unsupported_state, unsupported_width, unsupported_height, unsupported_rgba);

    int min_x = static_cast<int>(width);
    int max_x = -1;
    int min_y = static_cast<int>(height);
    int max_y = -1;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(static_cast<std::size_t>(y) * width + x) * 4u + 3u];
            if (alpha == 0u) continue;
            min_x = std::min(min_x, static_cast<int>(x));
            max_x = std::max(max_x, static_cast<int>(x));
            min_y = std::min(min_y, static_cast<int>(y));
            max_y = std::max(max_y, static_cast<int>(y));
        }
    }

    ASSERT_GE(max_x, min_x);
    ASSERT_GE(max_y, min_y);
    EXPECT_GT(max_x - min_x + 1, 20);
    EXPECT_GT(max_y - min_y + 1, 20);
    EXPECT_NE(rgba, unsupported_rgba);
#endif
}

} // namespace wallpaper
