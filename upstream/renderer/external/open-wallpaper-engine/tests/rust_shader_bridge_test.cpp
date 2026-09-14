#include "Shader/RustShaderBridge.hpp"

#include "Fs/VFS.h"
#include "Scene/VulkanRender/CustomShaderPass.hpp"

#include <gtest/gtest.h>

#include <array>
#include <stdexcept>

using wallpaper::ShaderType;
using wallpaper::shader::RustShaderRequest;
using wallpaper::shader::RustShaderStageSource;
using wallpaper::shader::RustShaderTextureInfo;

namespace
{

constexpr uint32_t SPIRV_MAGIC = 0x07230203u;

RustShaderRequest TinyRequest()
{
    RustShaderRequest request;
    request.shader_name   = "bridge/tiny";
    request.scene_id      = "3611439897";
    request.cache_enabled = true;
    request.stages = {
        RustShaderStageSource {
            .kind   = ShaderType::VERTEX,
            .source = "attribute vec2 a_Position;\n"
                      "void main() { gl_Position = vec4(a_Position, 0.0, 1.0); }\n",
        },
        RustShaderStageSource {
            .kind   = ShaderType::FRAGMENT,
            .source = "void main() { gl_FragColor = vec4(1.0); }\n",
        },
    };
    request.combos["BLENDMODE"] = "0";
    request.textures.push_back(RustShaderTextureInfo {
        .slot       = 0,
        .present    = true,
        .enabled    = true,
        .format     = "rgba8",
        .components = { true, false, false },
    });
    return request;
}

std::array<wallpaper::WPShaderUnit, 2> ParserBridgeUnits()
{
    return {
        wallpaper::WPShaderUnit {
            .stage           = ShaderType::VERTEX,
            .src             = "attribute vec2 a_Position;\n"
                               "varying vec2 v_Uv;\n"
                               "void main() {\n"
                               "  v_Uv = a_Position * 0.5 + vec2(0.5);\n"
                               "  gl_Position = vec4(a_Position, 0.0, 1.0);\n"
                               "}\n",
            .preprocess_info = {},
        },
        wallpaper::WPShaderUnit {
            .stage           = ShaderType::FRAGMENT,
            .src             = "varying vec2 v_Uv;\n"
                               "uniform sampler2D g_Texture0; // {\"material\":\"albedo\",\"combo\":\"HAS_TEXTURE\",\"default\":\"materials/default.png\"}\n"
                               "uniform float g_Brightness; // {\"material\":\"brightness\",\"default\":1.25}\n"
                               "void main() {\n"
                               "  gl_FragColor = texture2D(g_Texture0, v_Uv) * g_Brightness;\n"
                               "}\n",
            .preprocess_info = {},
        },
    };
}

nlohmann::json RequestJsonWithInclude(std::string include_path)
{
    auto json = wallpaper::shader::BuildRustShaderRequestJson(TinyRequest());
    json["stages"][0]["source"] =
        "#include \"" + include_path + "\"\n"
        "attribute vec2 a_Position;\n"
        "void main() { gl_Position = vec4(a_Position, 0.0, 1.0); }\n";
    return json;
}

} // namespace

TEST(RustShaderBridge, BuildsSerdeTaggedRequestJsonWithEnabledCachePolicy)
{
    const auto json = wallpaper::shader::BuildRustShaderRequestJson(TinyRequest());

    ASSERT_EQ(json.at("shader_name"), "bridge/tiny");
    ASSERT_EQ(json.at("target"), "vulkan_spirv");
    ASSERT_EQ(json.at("cache_policy"), (nlohmann::json {
                                             { "mode", "enabled" },
                                             { "scene_id", "3611439897" },
                                         }));
    ASSERT_EQ(json.at("stages").at(0).at("kind"), "vertex");
    ASSERT_EQ(json.at("stages").at(1).at("kind"), "fragment");
    ASSERT_EQ(json.at("combos").at(0), (nlohmann::json {
                                            { "name", "BLENDMODE" },
                                            { "value", "0" },
                                        }));
    ASSERT_TRUE(json.at("textures").at(0).at("present"));
    ASSERT_EQ(json.at("textures").at(0).at("components"), (nlohmann::json {
                                                               { "compo1", true },
                                                               { "compo2", false },
                                                               { "compo3", false },
                                                           }));
    ASSERT_TRUE(json.at("properties").is_array());
}

TEST(RustShaderBridge, ParsesMetadataAndReflectionIntoCompatTypes)
{
    wallpaper::shader::RustShaderOutput output;

    wallpaper::shader::ApplyRustShaderMetadataJson(
        R"({
            "combos":[{"name":"HASALPHA","value":"1"}],
            "aliases":[{"material":"strength","uniform":"g_Strength"}],
            "default_uniforms":[{"name":"g_Strength","value":{"kind":"number","value":0.75}}],
            "default_textures":[{"slot":0,"path":"materials/default.png"}],
            "active_texture_slots":[0,2]
        })",
        output);
    wallpaper::shader::ApplyRustShaderReflectionJson(
        R"({
            "descriptor_bindings":[{
                "name":"GlobalUniforms",
                "set":0,
                "binding":0,
                "descriptor":"uniform_buffer",
                "stages":["vertex","fragment"],
                "count":1
            },{
                "name":"g_Texture0",
                "set":0,
                "binding":1,
                "descriptor":"sampled_image",
                "stages":["fragment"],
                "count":1
            },{
                "name":"_we_Sampler_g_Texture0",
                "set":0,
                "binding":2,
                "descriptor":"sampler",
                "stages":["fragment"],
                "count":1
            }],
            "uniform_blocks":[{
                "name":"GlobalUniforms",
                "set":0,
                "binding":0,
                "size":64,
                "members":[{
                    "name":"g_ModelViewProjectionMatrix",
                    "offset":0,
                    "size":64,
                    "element_count":16,
                    "array_count":0,
                    "array_stride":0
                }]
            }],
            "vertex_inputs":[{"name":"a_Position","location":0,"format":"r32g32_sfloat"}],
            "active_texture_slots":[0]
        })",
        output);

    ASSERT_EQ(output.shader_info.combos.at("HASALPHA"), "1");
    ASSERT_EQ(output.shader_info.alias.at("strength"), "g_Strength");
    ASSERT_EQ(output.shader_info.svs.at("g_Strength").size(), 1u);
    ASSERT_EQ(output.shader_info.defTexs.at(0).second, "materials/default.png");
    ASSERT_TRUE(output.fragment_preprocessor_info.active_tex_slots.contains(2));

    ASSERT_EQ(output.reflection.binding_map.at("GlobalUniforms").binding, 0u);
    ASSERT_EQ(output.reflection.binding_map.at("g_Texture0").binding, 1u);
    ASSERT_EQ(output.reflection.binding_map.at("g_Texture0").descriptorType,
              VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
    ASSERT_EQ(output.reflection.binding_map.at("_we_Sampler_g_Texture0").binding, 2u);
    ASSERT_EQ(output.reflection.binding_map.at("_we_Sampler_g_Texture0").descriptorType,
              VK_DESCRIPTOR_TYPE_SAMPLER);
    ASSERT_EQ(output.reflection.blocks.at(0).member_map.at("g_ModelViewProjectionMatrix").size, 64u);
    ASSERT_EQ(output.reflection.input_location_map.at("a_Position").location, 0u);
}

TEST(RustShaderBridge, CustomShaderTextureBindingPlanPreservesDescriptorTypesAndSamplers)
{
    wallpaper::vulkan::ShaderReflected reflected;
    reflected.binding_map["g_Texture0"] = VkDescriptorSetLayoutBinding {
        .binding         = 1,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    reflected.binding_map["_we_Sampler_g_Texture0"] = VkDescriptorSetLayoutBinding {
        .binding         = 2,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    reflected.binding_map["g_Texture1"] = VkDescriptorSetLayoutBinding {
        .binding         = 3,
        .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    const auto split =
        wallpaper::vulkan::detail::ReflectedTextureBinding(reflected, "g_Texture0");
    EXPECT_EQ(split.image_binding, 1);
    EXPECT_EQ(split.image_descriptor_type, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
    EXPECT_EQ(split.sampler_binding, 2);

    const auto combined =
        wallpaper::vulkan::detail::ReflectedTextureBinding(reflected, "g_Texture1");
    EXPECT_EQ(combined.image_binding, 3);
    EXPECT_EQ(combined.image_descriptor_type, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
    EXPECT_EQ(combined.sampler_binding, -1);
}

TEST(RustShaderBridge, CustomShaderDescriptorLayoutOnlyKeepsWritableBindings)
{
    wallpaper::vulkan::ShaderReflected reflected;
    reflected.blocks.push_back(wallpaper::vulkan::ShaderReflected::Block {
        .index      = 0,
        .size       = 64,
        .binding    = 0,
        .name       = "GlobalUniforms",
        .member_map = {},
    });
    reflected.binding_map["GlobalUniforms"] = VkDescriptorSetLayoutBinding {
        .binding         = 0,
        .descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    reflected.binding_map["g_Texture0"] = VkDescriptorSetLayoutBinding {
        .binding         = 1,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    reflected.binding_map["_we_Sampler_g_Texture0"] = VkDescriptorSetLayoutBinding {
        .binding         = 2,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    reflected.binding_map["g_Texture1"] = VkDescriptorSetLayoutBinding {
        .binding         = 3,
        .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    std::vector<wallpaper::vulkan::CustomShaderPass::Desc::TextureBinding> texture_bindings;
    std::vector<VkDescriptorSetLayoutBinding> layout_bindings;
    ASSERT_TRUE(wallpaper::vulkan::detail::PlanCustomShaderDescriptors(
        reflected, 2, texture_bindings, layout_bindings));

    ASSERT_EQ(layout_bindings.size(), 4u);
    EXPECT_EQ(layout_bindings.at(0).descriptorType, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
    EXPECT_EQ(layout_bindings.at(1).descriptorType, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
    EXPECT_EQ(layout_bindings.at(2).descriptorType, VK_DESCRIPTOR_TYPE_SAMPLER);
    EXPECT_EQ(layout_bindings.at(3).descriptorType, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);

    ASSERT_EQ(texture_bindings.size(), 2u);
    EXPECT_EQ(texture_bindings.at(0).image_descriptor_type, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
    EXPECT_EQ(texture_bindings.at(0).sampler_binding, 2);
    EXPECT_EQ(texture_bindings.at(1).image_descriptor_type,
              VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
    EXPECT_EQ(texture_bindings.at(1).sampler_binding, -1);
}

TEST(RustShaderBridge, CustomShaderDescriptorLayoutRejectsUnsupportedReflectedBindings)
{
    auto accepts = [](wallpaper::vulkan::ShaderReflected reflected) {
        std::vector<wallpaper::vulkan::CustomShaderPass::Desc::TextureBinding> texture_bindings;
        std::vector<VkDescriptorSetLayoutBinding> layout_bindings;
        return wallpaper::vulkan::detail::PlanCustomShaderDescriptors(
            reflected, 1, texture_bindings, layout_bindings);
    };

    wallpaper::vulkan::ShaderReflected counted_texture;
    counted_texture.binding_map["g_Texture0"] = VkDescriptorSetLayoutBinding {
        .binding         = 0,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = 2,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    EXPECT_FALSE(accepts(counted_texture));

    wallpaper::vulkan::ShaderReflected non_slot_texture;
    non_slot_texture.binding_map["maskSampler"] = VkDescriptorSetLayoutBinding {
        .binding         = 4,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    EXPECT_FALSE(accepts(non_slot_texture));

    wallpaper::vulkan::ShaderReflected orphan_sampler;
    orphan_sampler.binding_map["_we_Sampler_maskSampler"] = VkDescriptorSetLayoutBinding {
        .binding         = 5,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    EXPECT_FALSE(accepts(orphan_sampler));
}

TEST(RustShaderBridge, CustomShaderDescriptorLayoutRejectsActiveTextureOutsideMaterialSlots)
{
    wallpaper::vulkan::ShaderReflected reflected;
    reflected.binding_map["g_Texture2"] = VkDescriptorSetLayoutBinding {
        .binding         = 4,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    reflected.binding_map["_we_Sampler_g_Texture2"] = VkDescriptorSetLayoutBinding {
        .binding         = 5,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    std::vector<wallpaper::vulkan::CustomShaderPass::Desc::TextureBinding> texture_bindings;
    std::vector<VkDescriptorSetLayoutBinding> layout_bindings;
    EXPECT_FALSE(wallpaper::vulkan::detail::PlanCustomShaderDescriptors(
        reflected, 2, texture_bindings, layout_bindings));
}

TEST(RustShaderBridge, RustReflectionRejectsUnsupportedDescriptorSetsAndCounts)
{
    wallpaper::shader::RustShaderOutput output;

    EXPECT_THROW(wallpaper::shader::ApplyRustShaderReflectionJson(
                     R"({
                        "descriptor_bindings":[{
                            "name":"g_Texture0",
                            "set":1,
                            "binding":0,
                            "descriptor":"sampled_image",
                            "stages":["fragment"],
                            "count":1
                        }]
                    })",
                     output),
                 std::runtime_error);

    EXPECT_THROW(wallpaper::shader::ApplyRustShaderReflectionJson(
                     R"({
                        "descriptor_bindings":[{
                            "name":"g_Texture0",
                            "set":0,
                            "binding":0,
                            "descriptor":"sampled_image",
                            "stages":["fragment"],
                            "count":2
                        }]
                    })",
                     output),
                 std::runtime_error);
}

TEST(RustShaderBridge, CustomShaderUniformBlockRequiresMatchingDescriptorBinding)
{
    wallpaper::vulkan::ShaderReflected reflected;
    reflected.blocks.push_back(wallpaper::vulkan::ShaderReflected::Block {
        .index      = 0,
        .size       = 64,
        .binding    = 1,
        .name       = "GlobalUniforms",
        .member_map = {},
    });

    EXPECT_EQ(wallpaper::vulkan::detail::ReflectedUniformBlockBinding(reflected), nullptr);

    reflected.binding_map["GlobalUniforms"] = VkDescriptorSetLayoutBinding {
        .binding         = 1,
        .descriptorType  = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    EXPECT_EQ(wallpaper::vulkan::detail::ReflectedUniformBlockBinding(reflected), nullptr);

    reflected.binding_map["GlobalUniforms"] = VkDescriptorSetLayoutBinding {
        .binding         = 1,
        .descriptorType  = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    const auto* binding = wallpaper::vulkan::detail::ReflectedUniformBlockBinding(reflected);
    ASSERT_NE(binding, nullptr);
    EXPECT_EQ(binding->binding, 1u);
    EXPECT_EQ(binding->descriptorType, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
}

TEST(RustShaderBridge, CompilesTinyProgramAndExtractsSpirv)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;

    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(TinyRequest(), output));
    ASSERT_EQ(output.codes.size(), 2u);
    ASSERT_FALSE(output.codes.at(0).empty());
    ASSERT_FALSE(output.codes.at(1).empty());
    ASSERT_EQ(output.codes.at(0).front(), SPIRV_MAGIC);
    ASSERT_EQ(output.codes.at(1).front(), SPIRV_MAGIC);
    ASSERT_FALSE(output.metadata_json.empty());
    ASSERT_FALSE(output.reflection_json.empty());
#endif
}

TEST(RustShaderBridge, CompilesWithRegisteredLegalizerPolicies)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;

    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(TinyRequest(), output))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_FALSE(output.reflection_json.empty());
    ASSERT_EQ(output.codes.size(), 2u);
    ASSERT_TRUE(output.reflection.input_location_map.contains("a_Position"));
#endif
}

TEST(RustShaderBridge, RuntimeReflectionOmitsInactiveTextureDescriptors)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    auto request = TinyRequest();
    request.shader_name = "bridge/inactive-texture-descriptor";
    request.cache_enabled = false;
    request.stages.at(1).source =
        "varying vec2 v_Uv;\n"
        "uniform sampler2D g_Texture0;\n"
        "uniform sampler2D g_Texture1;\n"
        "void main() { gl_FragColor = texture2D(g_Texture0, v_Uv); }\n";
    request.textures.push_back(RustShaderTextureInfo {
        .slot       = 1,
        .present    = true,
        .enabled    = true,
        .format     = "rgba8",
        .components = { false, false, false },
    });

    wallpaper::shader::RustShaderOutput output;
    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(request, output))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_TRUE(output.reflection.binding_map.contains("g_Texture0"));
    ASSERT_TRUE(output.reflection.binding_map.contains("_we_Sampler_g_Texture0"));
    ASSERT_FALSE(output.reflection.binding_map.contains("g_Texture1"));
    ASSERT_FALSE(output.reflection.binding_map.contains("_we_Sampler_g_Texture1"));
#endif
}

TEST(RustShaderBridge, AbsentTextureSlotDoesNotEnableAnnotationCombo)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    auto request          = TinyRequest();
    request.shader_name   = "bridge/absent-texture-combo";
    request.cache_enabled = false;
    request.stages.at(1).source =
        "// [COMBO] {\"combo\":\"LIGHTING\",\"default\":1}\n"
        "varying vec2 v_Uv;\n"
        "uniform sampler2D g_Texture0;\n"
        "#if LIGHTING\n"
        "uniform sampler2D g_Texture1; // {\"combo\":\"NORMALMAP\"}\n"
        "#endif\n"
        "void main() {\n"
        "  vec4 color = texture2D(g_Texture0, v_Uv);\n"
        "#if LIGHTING && NORMALMAP\n"
        "  color += texture2D(g_Texture1, v_Uv);\n"
        "#endif\n"
        "  gl_FragColor = color;\n"
        "}\n";
    request.textures.push_back(RustShaderTextureInfo {
        .slot       = 1,
        .present    = false,
        .enabled    = false,
        .format     = "rgba8",
        .components = { false, false, false },
    });

    const auto request_json = wallpaper::shader::BuildRustShaderRequestJson(request);
    ASSERT_FALSE(request_json.at("textures").at(1).at("present").get<bool>());

    wallpaper::shader::RustShaderOutput output;
    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(request, output))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_EQ(output.shader_info.combos.at("NORMALMAP"), "0")
        << "request: " << request_json.dump()
        << "\nmetadata: " << output.metadata_json;
    ASSERT_TRUE(output.reflection.binding_map.contains("g_Texture0"));
    ASSERT_FALSE(output.reflection.binding_map.contains("g_Texture1"));
    ASSERT_FALSE(output.reflection.binding_map.contains("_we_Sampler_g_Texture1"));
#endif
}

TEST(RustShaderBridge, CompilesWithEmptyIncludeCallbackPayload)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;
    bool                               include_requested = false;

    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgramWithBridgeJson(
        RequestJsonWithInclude("empty.glsl"),
        output,
        [&include_requested](std::string_view path) -> std::optional<std::string> {
            include_requested = path == "empty.glsl";
            return std::string {};
        }));

    ASSERT_TRUE(include_requested);
    ASSERT_EQ(output.codes.size(), 2u);
#endif
}

TEST(RustShaderBridge, FailedCompileClearsPreviousOutput)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;
    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(TinyRequest(), output));
    ASSERT_FALSE(output.codes.empty());

    auto invalid = wallpaper::shader::BuildRustShaderRequestJson(TinyRequest());
    invalid["stages"] = nlohmann::json::array();

    ASSERT_FALSE(wallpaper::shader::CompileRustShaderProgramWithBridgeJson(invalid, output));
    ASSERT_TRUE(output.codes.empty());
    ASSERT_TRUE(output.metadata_json.empty());
    ASSERT_TRUE(output.reflection_json.empty());
#endif
}

TEST(RustShaderBridge, WPShaderParserCompileToSpvRustPopulatesMetadataReflectionAndPreprocessInfo)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::fs::VFS                 vfs;
    wallpaper::WPShaderInfo            shader_info;
    std::vector<wallpaper::ShaderCode> spvs;
    std::string                        reflection_json;
    std::vector<wallpaper::WPShaderTexInfo> textures {
        wallpaper::WPShaderTexInfo {
            .present       = true,
            .enabled       = true,
            .composEnabled = { false, false, false },
        },
    };
    auto units = ParserBridgeUnits();

    ASSERT_TRUE(wallpaper::WPShaderParser::CompileToSpvRust(
        "parser-bridge-scene",
        "tests/parser-bridge",
        units,
        spvs,
        vfs,
        &shader_info,
        textures,
        &reflection_json))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_EQ(spvs.size(), 2u);
    ASSERT_FALSE(spvs.at(0).empty());
    ASSERT_FALSE(spvs.at(1).empty());
    EXPECT_EQ(spvs.at(0).front(), SPIRV_MAGIC);
    EXPECT_EQ(spvs.at(1).front(), SPIRV_MAGIC);

    ASSERT_FALSE(reflection_json.empty());
    const auto reflection = nlohmann::json::parse(reflection_json);
    const auto descriptors = reflection.value("descriptor_bindings", nlohmann::json::array());
    EXPECT_FALSE(descriptors.empty());
    const auto texture_descriptor = std::find_if(
        descriptors.begin(), descriptors.end(), [](const nlohmann::json& descriptor) {
            return descriptor.value("name", "") == "g_Texture0";
        });
    ASSERT_NE(texture_descriptor, descriptors.end());
    EXPECT_EQ(texture_descriptor->value("descriptor", ""), "sampled_image");
    const auto sampler_descriptor = std::find_if(
        descriptors.begin(), descriptors.end(), [](const nlohmann::json& descriptor) {
            return descriptor.value("name", "") == "_we_Sampler_g_Texture0";
        });
    ASSERT_NE(sampler_descriptor, descriptors.end());
    EXPECT_EQ(sampler_descriptor->value("descriptor", ""), "sampler");
    EXPECT_FALSE(reflection.value("vertex_inputs", nlohmann::json::array()).empty());

    ASSERT_EQ(shader_info.defTexs.size(), 1u);
    EXPECT_EQ(shader_info.defTexs.at(0).first, 0);
    EXPECT_EQ(shader_info.defTexs.at(0).second, "materials/default.png");
    EXPECT_EQ(shader_info.combos.at("HAS_TEXTURE"), "1");
    EXPECT_EQ(shader_info.alias.at("albedo"), "g_Texture0");
    EXPECT_EQ(shader_info.alias.at("brightness"), "g_Brightness");
    ASSERT_EQ(shader_info.svs.at("g_Brightness").size(), 1u);
    EXPECT_FLOAT_EQ(shader_info.svs.at("g_Brightness")[0], 1.25f);

    EXPECT_TRUE(units.at(1).preprocess_info.active_tex_slots.contains(0));
#endif
}

TEST(RustShaderBridge, WPShaderParserCompileToSpvRustReportsGeneratedFragmentPath)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::fs::VFS                 vfs;
    wallpaper::WPShaderInfo            shader_info;
    std::vector<wallpaper::ShaderCode> spvs;
    std::string                        reflection_json;
    std::vector<wallpaper::WPShaderTexInfo> textures {
        wallpaper::WPShaderTexInfo {
            .enabled       = true,
            .composEnabled = { false, false, false },
        },
    };
    auto units = ParserBridgeUnits();
    units.at(1).src =
        "varying vec2 v_Uv;\n"
        "void main() {\n"
        "  gl_FragColor = missing_value;\n"
        "}\n";

    ASSERT_FALSE(wallpaper::WPShaderParser::CompileToSpvRust(
        "parser-bridge-scene",
        "tests/parser-bridge-invalid",
        units,
        spvs,
        vfs,
        &shader_info,
        textures,
        &reflection_json));

    const auto error = wallpaper::shader::LastRustShaderError();
    EXPECT_NE(error.find("generated/fragment.glsl"), std::string::npos) << error;
#endif
}
