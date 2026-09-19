#include "WPShaderParser.hpp"

#include "Fs/IBinaryStream.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"
#include <unordered_map>

#include "Vulkan/ShaderComp.hpp"

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>

using namespace wallpaper;

namespace
{
thread_local ShaderStartupMetrics g_shader_startup_metrics;
// Bounded per-thread cache; dependencies are revalidated on every hit, including
// misses. Switching projects or editing includes must never reuse stale code.
thread_local std::unordered_map<std::string, nlohmann::json> g_program_cache;

std::string ProgramCacheKey(const std::string& request) {
    const auto identity = std::string("owe-program-v1:") +
                          wallpaper::shader::RustShaderCacheIdentity() + ":" + request;
    return utils::genSha1(std::span<const char>(identity.data(), identity.size()));
}

// Re-encodes a compiled Metal stage into the same payload shape the Rust
// bridge returns, so cached programs restore through one parser.
nlohmann::json MetalStageMetaJson(const wallpaper::shader::RustShaderMetalStage& stage) {
    auto bindings = nlohmann::json::array();
    for (const auto& binding : stage.bindings) {
        const char* slot_kind = "buffer";
        switch (binding.slot_kind) {
        case wallpaper::shader::RustShaderMetalSlotKind::Buffer: slot_kind = "buffer"; break;
        case wallpaper::shader::RustShaderMetalSlotKind::Texture: slot_kind = "texture"; break;
        case wallpaper::shader::RustShaderMetalSlotKind::Sampler: slot_kind = "sampler"; break;
        }
        bindings.push_back({
            {"name", binding.name},
            {"set", binding.set},
            {"binding", binding.binding},
            {"slot_kind", slot_kind},
            {"slot", binding.slot},
        });
    }

    return {
        {"entry_point", stage.entry_point},
        {"language_version", stage.language_version},
        {"bindings", std::move(bindings)},
        {"conventions",
         {
             {"clip_space_y_flipped", stage.conventions.clip_space_y_flipped},
             {"clip_space_depth_remapped", stage.conventions.clip_space_depth_remapped},
             {"texture_origin_flipped", stage.conventions.texture_origin_flipped},
         }},
    };
}

bool RestoreProgram(const nlohmann::json& cached, const std::string& request,
                    const wallpaper::shader::RustShaderIncludeReader& reader,
                    wallpaper::shader::RustShaderTarget target,
                    wallpaper::shader::RustShaderOutput& output) {
    try {
        if (cached.at("request") != request ||
            cached.at("compiler") != wallpaper::shader::RustShaderCacheIdentity()) return false;
        for (const auto& [path, content] : cached.at("includes").items()) {
            const auto current = reader(path);
            if (current ? content != *current : !content.is_null()) return false;
        }
        const auto stage_count = nlohmann::json::parse(request).at("stages").size();
        wallpaper::shader::RustShaderOutput restored;
        if (target == wallpaper::shader::RustShaderTarget::MetalMsl) {
            const auto& metal = cached.at("metal");
            if (metal.size() != stage_count) return false;
            for (const auto& stage_json : metal) {
                const auto source = stage_json.at("source").get<std::string>();
                if (source.empty()) return false;
                wallpaper::shader::RustShaderMetalStage stage;
                wallpaper::shader::ApplyRustShaderMetalStageJson(
                    stage_json.at("meta").get<std::string>(),
                    source,
                    stage_json.at("kind").get<int>() == 0 ? ShaderType::VERTEX
                                                          : ShaderType::FRAGMENT,
                    stage);
                restored.metal_stages.push_back(std::move(stage));
            }
        } else {
            restored.codes = cached.at("codes").get<std::vector<ShaderCode>>();
            if (restored.codes.size() != stage_count) return false;
            for (const auto& code : restored.codes) {
                if (code.size() < 5 || code[0] != 0x07230203u) return false;
            }
        }
        restored.metadata_json = cached.at("metadata").get<std::string>();
        restored.reflection_json = cached.at("reflection").get<std::string>();
        restored.cache_key = cached.at("cache_key").get<std::string>();
        wallpaper::shader::ApplyRustShaderMetadataJson(restored.metadata_json, restored);
        wallpaper::shader::ApplyRustShaderReflectionJson(restored.reflection_json, restored);
        output = std::move(restored);
        return true;
    } catch (const nlohmann::json::exception&) {
        return false;
    } catch (const std::runtime_error&) {
        return false;
    }
}

void RememberProgram(const std::string& key, const nlohmann::json& program) {
    if (g_program_cache.size() >= 128) g_program_cache.clear();
    g_program_cache[key] = program;
}

constexpr std::string_view kShaderCacheDirectory { "spvs01" };
constexpr std::string_view kShaderCacheSuffix { "spvs" };

double MeasureElapsedMs(const std::chrono::steady_clock::time_point started)
{
    return std::chrono::duration<double, std::milli>(
               std::chrono::steady_clock::now() - started)
        .count();
}

std::string RustTextureFormat(TextureFormat format)
{
    switch (format) {
    case TextureFormat::R8: return "r8";
    case TextureFormat::RG8: return "rg8";
    case TextureFormat::RGBA8: return "rgba8";
    default: return "unknown";
    }
}

std::string GetShaderCachePath(std::string_view scene_id, std::string_view cache_key)
{
    return std::string("/cache/") + std::string(scene_id) + "/" +
           std::string(kShaderCacheDirectory) + "/" + std::string(cache_key) + "." +
           std::string(kShaderCacheSuffix);
}

bool WriteBytes(fs::IBinaryStreamW& file, const void* data, usize size)
{
    return size == 0 || file.Write(data, size) == 1;
}

bool WriteUint32LE(fs::IBinaryStreamW& file, uint32_t value)
{
    const unsigned char bytes[] {
        static_cast<unsigned char>(value & 0xffu),
        static_cast<unsigned char>((value >> 8u) & 0xffu),
        static_cast<unsigned char>((value >> 16u) & 0xffu),
        static_cast<unsigned char>((value >> 24u) & 0xffu),
    };
    return WriteBytes(file, bytes, sizeof(bytes));
}

bool SaveShaderCacheFile(std::span<const ShaderCode> codes, fs::IBinaryStreamW& file)
{
    char padding[256] {};

    if (! WriteBytes(file, "SPVS0001", 9)) return false;
    if (! WriteUint32LE(file, static_cast<uint32_t>(codes.size()))) return false;
    for (const auto& code : codes) {
        const auto size_bytes = static_cast<uint32_t>(code.size() * sizeof(uint32_t));
        if (! WriteUint32LE(file, size_bytes)) return false;
        if (! WriteBytes(file, code.data(), size_bytes)) return false;
    }
    return WriteBytes(file, padding, sizeof(padding));
}

} // namespace

void WPShaderParser::InitGlslang() {
    ClearProgramCache();
    ResetStartupMetrics();
    glslang::InitializeProcess();
}
void WPShaderParser::FinalGlslang() {
    const auto metrics = GetStartupMetrics();
    LOG_INFO("scene shader cache: hits=%llu compiled=%llu compile_ms=%.1f cache_read_ms=%.1f",
             static_cast<unsigned long long>(metrics.cache_hits),
             static_cast<unsigned long long>(metrics.cache_misses),
             metrics.compile_ms, metrics.cache_read_ms);
    ClearProgramCache();
    glslang::FinalizeProcess();
}

void WPShaderParser::ResetStartupMetrics() { g_shader_startup_metrics = {}; }
ShaderStartupMetrics WPShaderParser::GetStartupMetrics() { return g_shader_startup_metrics; }
void WPShaderParser::ClearProgramCache() { g_program_cache.clear(); }

namespace
{

// Shared Rust-pipeline compile path for every output target. Include
// resolution, combo defaults, program caching and reflection are target
// independent; only the compiled payload in `output` differs.
// Where one compile reads its includes from and what it is allowed to cache.
//
// A parse has the project mounted and caches to it. A variant compiled later
// has neither: it replays the includes the ordinary translation of the same
// program recorded, and writes nothing. Both go through the identical compile
// below, so the second is not a different translation with different rules.
struct RustCompileEnv {
    fs::VFS*                  vfs { nullptr };
    const WPShaderIncludeMap* includes { nullptr };
    WPShaderIncludeMap*       used_includes { nullptr };
};

bool CompileProgramRust(std::string_view scene_id, std::string_view shader_name,
                        std::span<WPShaderUnit> units, wallpaper::shader::RustShaderTarget target,
                        wallpaper::shader::RustShaderOutput& output, const RustCompileEnv& env,
                        WPShaderInfo* shader_info, std::span<const WPShaderTexInfo> texs,
                        std::string* reflection_json,
                        std::optional<uint32_t> nv12_plane_slot = std::nullopt) {
    if (shader_info == nullptr) return false;

    wallpaper::shader::RustShaderRequest request {
        .shader_name   = std::string(shader_name),
        .scene_id      = std::string(scene_id),
        .target        = target,
        .cache_enabled = env.vfs != nullptr && env.vfs->IsMounted("cache"),
    };
    request.combos = shader_info->combos;
    request.stages.reserve(units.size());
    for (const auto& unit : units) {
        request.stages.push_back(wallpaper::shader::RustShaderStageSource {
            .kind   = unit.stage,
            .source = unit.src,
        });
    }
    request.textures.reserve(texs.size());
    for (usize slot = 0; slot < texs.size(); ++slot) {
        request.textures.push_back(wallpaper::shader::RustShaderTextureInfo {
            .slot       = static_cast<uint32_t>(slot),
            .present    = texs[slot].present,
            .enabled    = texs[slot].enabled,
            .format     = RustTextureFormat(texs[slot].format),
            .components = texs[slot].composEnabled,
            .video_planes =
                nv12_plane_slot.has_value() && *nv12_plane_slot == static_cast<uint32_t>(slot)
                    ? wallpaper::shader::RustShaderVideoPlanes::Nv12Biplanar
                    : wallpaper::shader::RustShaderVideoPlanes::None,
        });
    }

    const auto read_include = [&env](std::string_view path) -> std::optional<std::string> {
        if (env.includes != nullptr) {
            const auto found = env.includes->find(std::string(path));
            return found == env.includes->end() ? std::nullopt : found->second;
        }
        if (env.vfs == nullptr) return std::nullopt;

        std::string asset_path = "/assets/shaders/" + std::string(path);
        if (auto stream = env.vfs->Open(asset_path); stream != nullptr) return stream->ReadAllStr();

        std::string direct_path(path);
        if (auto stream = env.vfs->Open(direct_path); stream != nullptr) return stream->ReadAllStr();

        return std::nullopt;
    };
    // Recorded on every read, hit or miss, so a caller that wants to translate
    // this same program again later gets the complete set either way. A cache
    // hit reads them too -- that is how it revalidates -- so nothing is lost by
    // not compiling.
    const auto include_reader = [&](std::string_view path) -> std::optional<std::string> {
        auto content = read_include(path);
        if (env.used_includes != nullptr) {
            env.used_includes->insert_or_assign(std::string(path), content);
        }
        return content;
    };
    const auto request_json = wallpaper::shader::BuildRustShaderRequestJson(request).dump();
    const auto program_key = ProgramCacheKey(request_json);
    const auto program_path = std::string("/cache/") + std::string(scene_id) +
                              "/programs01/" + program_key + ".json";
    const auto cache_read_started = std::chrono::steady_clock::now();
    bool hit = false;
    if (request.cache_enabled) {
        if (const auto it = g_program_cache.find(program_key); it != g_program_cache.end()) {
            hit = RestoreProgram(it->second, request_json, include_reader, target, output);
        }
        if (!hit && env.vfs != nullptr) {
            if (auto file = env.vfs->Open(program_path); file != nullptr && file->Size() > 0 && file->Size() <= 16 * 1024 * 1024) {
                const auto cached = nlohmann::json::parse(file->ReadAllStr(), nullptr, false);
                hit = RestoreProgram(cached, request_json, include_reader, target, output);
                if (hit) RememberProgram(program_key, cached);
            }
        }
    }
    g_shader_startup_metrics.cache_read_ms += MeasureElapsedMs(cache_read_started);
    nlohmann::json program;
    if (hit) {
        ++g_shader_startup_metrics.cache_hits;
    } else {
        ++g_shader_startup_metrics.cache_misses;
        auto includes = nlohmann::json::object();
        const auto tracking_reader = [&](std::string_view path) -> std::optional<std::string> {
            const auto content = include_reader(path);
            includes[std::string(path)] = content ? nlohmann::json(*content) : nlohmann::json(nullptr);
            return content;
        };
        const auto compile_started = std::chrono::steady_clock::now();
        if (!wallpaper::shader::CompileRustShaderProgram(request, output, tracking_reader)) {
            g_shader_startup_metrics.compile_ms += MeasureElapsedMs(compile_started);
            const auto error = wallpaper::shader::LastRustShaderError();
            LOG_ERROR("Rust shader compile failed for '%s': %s",
                      std::string(shader_name).c_str(), error.c_str());
            return false;
        }
        g_shader_startup_metrics.compile_ms += MeasureElapsedMs(compile_started);
        if (request.cache_enabled) {
            program = {
                {"request", request_json}, {"compiler", wallpaper::shader::RustShaderCacheIdentity()},
                {"includes", std::move(includes)},
                {"metadata", output.metadata_json}, {"reflection", output.reflection_json},
                {"cache_key", output.cache_key},
            };
            if (target == wallpaper::shader::RustShaderTarget::MetalMsl) {
                auto metal = nlohmann::json::array();
                for (const auto& stage : output.metal_stages) {
                    metal.push_back({
                        {"kind", stage.kind == ShaderType::VERTEX ? 0 : 1},
                        {"source", stage.source},
                        {"meta", MetalStageMetaJson(stage).dump()},
                    });
                }
                program["metal"] = std::move(metal);
            } else {
                program["codes"] = output.codes;
            }
            RememberProgram(program_key, program);
        }
    }

    const auto cache_write_started = std::chrono::steady_clock::now();
    if (!hit && request.cache_enabled && env.vfs != nullptr && ! output.cache_key.empty()) {
        if (auto file = env.vfs->OpenW(program_path); file != nullptr) {
            const auto bytes = program.dump();
            WriteBytes(*file, bytes.data(), bytes.size());
        }
        // The `spvs01` container stores SPIR-V words; the Metal payload lives
        // only in the program JSON above.
        if (target == wallpaper::shader::RustShaderTarget::VulkanSpirv) {
            if (auto cache_file = env.vfs->OpenW(GetShaderCachePath(scene_id, output.cache_key)); cache_file) {
                if (! SaveShaderCacheFile(output.codes, *cache_file)) {
                    LOG_ERROR("Rust shader cache write failed for '%s'",
                              std::string(shader_name).c_str());
                }
            }
        }
    }
    g_shader_startup_metrics.cache_write_ms += MeasureElapsedMs(cache_write_started);

    shader_info->combos.insert(output.shader_info.combos.begin(), output.shader_info.combos.end());
    shader_info->svs.insert(output.shader_info.svs.begin(), output.shader_info.svs.end());
    shader_info->alias.insert(output.shader_info.alias.begin(), output.shader_info.alias.end());
    shader_info->defTexs.insert(
        shader_info->defTexs.end(), output.shader_info.defTexs.begin(), output.shader_info.defTexs.end());
    if (reflection_json != nullptr) {
        *reflection_json = output.reflection_json;
    }

    for (auto& unit : units) {
        if (unit.stage == ShaderType::VERTEX) {
            unit.preprocess_info = output.vertex_preprocessor_info;
        } else if (unit.stage == ShaderType::FRAGMENT) {
            unit.preprocess_info = output.fragment_preprocessor_info;
        }
    }

    return true;
}

} // namespace

bool WPShaderParser::CompileToSpvRust(std::string_view scene_id, std::string_view shader_name,
                                      std::span<WPShaderUnit> units,
                                      std::vector<ShaderCode>& codes, fs::VFS& vfs,
                                      WPShaderInfo* shader_info,
                                      std::span<const WPShaderTexInfo> texs,
                                      std::string* reflection_json) {
    wallpaper::shader::RustShaderOutput output;
    const RustCompileEnv env { .vfs = &vfs };
    if (! CompileProgramRust(scene_id, shader_name, units,
                             wallpaper::shader::RustShaderTarget::VulkanSpirv, output, env,
                             shader_info, texs, reflection_json)) {
        return false;
    }

    codes = std::move(output.codes);
    return true;
}

bool WPShaderParser::CompileToMslRust(std::string_view scene_id, std::string_view shader_name,
                                      std::span<WPShaderUnit> units,
                                      std::vector<wallpaper::shader::RustShaderMetalStage>& stages,
                                      fs::VFS& vfs, WPShaderInfo* shader_info,
                                      std::span<const WPShaderTexInfo> texs,
                                      std::string* reflection_json,
                                      std::optional<uint32_t> nv12_plane_slot,
                                      WPShaderIncludeMap* used_includes) {
    wallpaper::shader::RustShaderOutput output;
    const RustCompileEnv env { .vfs = &vfs, .used_includes = used_includes };
    if (! CompileProgramRust(scene_id, shader_name, units,
                             wallpaper::shader::RustShaderTarget::MetalMsl, output, env,
                             shader_info, texs, reflection_json, nv12_plane_slot)) {
        return false;
    }
    if (output.metal_stages.size() != units.size()) {
        LOG_ERROR("Rust shader returned %zu metal stages for %zu units in '%s'",
                  output.metal_stages.size(), units.size(), std::string(shader_name).c_str());
        return false;
    }

    stages = std::move(output.metal_stages);
    return true;
}

bool WPShaderParser::CompileMslVariant(const SceneMetalVariantInputs&             inputs,
                                       std::vector<wallpaper::shader::RustShaderMetalStage>& stages,
                                       std::string* reflection_json, std::string* error) {
    // Copies of the caller's snapshot, never the snapshot itself: this compile
    // merges its own combos, default textures and preprocessor results into
    // whatever it is handed, and the snapshot has to stay exactly as captured
    // so a second attempt -- after a failure, or for another surface -- starts
    // from the same place.
    auto         units       = inputs.units;
    WPShaderInfo shader_info = inputs.shader_info;

    wallpaper::shader::RustShaderOutput output;
    const RustCompileEnv env { .includes = &inputs.includes };
    const auto           set_error = [error](std::string message) {
        if (error != nullptr) *error = std::move(message);
        return false;
    };

    try {
        if (! CompileProgramRust(inputs.scene_id, inputs.shader_name, units,
                                 wallpaper::shader::RustShaderTarget::MetalMsl, output, env,
                                 &shader_info, inputs.texinfos, reflection_json,
                                 inputs.nv12_plane_slot)) {
            auto message = wallpaper::shader::LastRustShaderError();
            if (message.empty()) message = "the shader cannot sample the video as planes";
            return set_error(std::move(message));
        }
    } catch (const std::exception& e) {
        return set_error(e.what());
    }
    if (output.metal_stages.size() != units.size()) {
        return set_error("the plane variant produced the wrong number of stages");
    }

    stages = std::move(output.metal_stages);
    return true;
}
