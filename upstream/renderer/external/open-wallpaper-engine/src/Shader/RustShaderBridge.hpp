#pragma once

#include "Scene/Parse/WPShaderParser.hpp"
#include "Vulkan/Shader.hpp"

#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

namespace wallpaper::shader
{

struct RustShaderStageSource {
    ShaderType  kind;
    std::string source;
};

struct RustShaderTextureInfo {
    uint32_t            slot { 0 };
    bool                present { true };
    bool                enabled { false };
    std::string         format { "rgba8" };
    std::array<bool, 3> components { false, false, false };
};

struct RustShaderPropertyValue {
    std::string        kind;
    nlohmann::json     value;
};

struct RustShaderProperty {
    std::string             name;
    RustShaderPropertyValue value;
};

struct RustShaderRequest {
    std::string                         shader_name;
    std::string                         scene_id;
    bool                                cache_enabled { false };
    std::vector<RustShaderStageSource>  stages;
    Combos                              combos;
    std::vector<RustShaderTextureInfo>  textures;
    std::vector<RustShaderProperty>     properties;
};

struct RustShaderOutput {
    std::vector<ShaderCode> codes;
    WPShaderInfo           shader_info;
    WPPreprocessorInfo     vertex_preprocessor_info;
    WPPreprocessorInfo     fragment_preprocessor_info;
    vulkan::ShaderReflected reflection;
    std::string             metadata_json;
    std::string             reflection_json;
    std::string             diagnostics_json;
    std::string             cache_key;
};

using RustShaderIncludeReader = std::function<std::optional<std::string>(std::string_view)>;

nlohmann::json BuildRustShaderRequestJson(const RustShaderRequest& request);
void ApplyRustShaderMetadataJson(std::string_view metadata_json, RustShaderOutput& output);
void ApplyRustShaderReflectionJson(std::string_view reflection_json, RustShaderOutput& output);

bool CompileRustShaderProgram(
    const RustShaderRequest& request,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader = {});

std::string LastRustShaderError();
std::string RustShaderCacheIdentity();

#ifdef WESCENE_BUILD_TESTS
bool CompileRustShaderProgramWithBridgeJson(
    const nlohmann::json& request_json,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader = {});
#endif

} // namespace wallpaper::shader
