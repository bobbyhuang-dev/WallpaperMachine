#pragma once

#include <span>
#include "Scene/Scene.h"
#include "Scene/SceneShader.h"
#include "Type.hpp"

namespace wallpaper
{
namespace fs
{
class VFS;
}
using Combos = Map<std::string, std::string>;

// ui material name to gl uniform name
using WPAliasValueDict = Map<std::string, std::string>;

using WPDefaultTexs = std::vector<std::pair<i32, std::string>>;

struct WPShaderInfo {
    Combos           combos;
    ShaderValueMap   svs;
    ShaderValueMap   baseConstSvs;
    WPAliasValueDict alias;
    WPDefaultTexs    defTexs;
};

struct WPPreprocessorInfo {
    Map<std::string, std::string> input; // name to line
    Map<std::string, std::string> output;

    Set<uint> active_tex_slots;
};

struct WPShaderTexInfo {
    bool                present { false };
    bool                enabled { false };
    TextureFormat       format { TextureFormat::RGBA8 };
    std::array<bool, 3> composEnabled { false, false, false };
};

struct WPShaderUnit {
    ShaderType         stage;
    std::string        src;
    WPPreprocessorInfo preprocess_info;
};

struct ShaderStartupMetrics {
    uint64_t cache_hits { 0 };
    uint64_t cache_misses { 0 };
    double   include_expand_ms { 0.0 };
    double   metadata_extract_ms { 0.0 };
    double   preprocess_ms { 0.0 };
    double   legalize_ms { 0.0 };
    double   final_assembly_ms { 0.0 };
    double   compile_ms { 0.0 };
    double   cache_read_ms { 0.0 };
    double   cache_write_ms { 0.0 };
};

class WPShaderParser {
public:
    static constexpr uint32_t kShaderPipelineRevision = 2;

    static void InitGlslang();
    static void FinalGlslang();

    static void                 ResetStartupMetrics();
    static ShaderStartupMetrics GetStartupMetrics();
    static void ClearProgramCache();

    static bool CompileToSpvRust(std::string_view scene_id, std::string_view shader_name,
                                  std::span<WPShaderUnit>, std::vector<ShaderCode>& spvs,
                                  fs::VFS&, WPShaderInfo*, std::span<const WPShaderTexInfo>,
                                  std::string* reflection_json = nullptr);
};
} // namespace wallpaper
