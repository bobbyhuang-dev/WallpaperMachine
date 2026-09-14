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

bool RestoreProgram(const nlohmann::json& cached, const std::string& request,
                    const wallpaper::shader::RustShaderIncludeReader& reader,
                    wallpaper::shader::RustShaderOutput& output) {
    try {
        if (cached.at("request") != request ||
            cached.at("compiler") != wallpaper::shader::RustShaderCacheIdentity()) return false;
        for (const auto& [path, content] : cached.at("includes").items()) {
            const auto current = reader(path);
            if (current ? content != *current : !content.is_null()) return false;
        }
        wallpaper::shader::RustShaderOutput restored;
        restored.codes = cached.at("codes").get<std::vector<ShaderCode>>();
        if (restored.codes.size() != nlohmann::json::parse(request).at("stages").size()) return false;
        for (const auto& code : restored.codes) {
            if (code.size() < 5 || code[0] != 0x07230203u) return false;
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

bool WPShaderParser::CompileToSpvRust(std::string_view scene_id, std::string_view shader_name,
                                      std::span<WPShaderUnit> units,
                                      std::vector<ShaderCode>& codes, fs::VFS& vfs,
                                      WPShaderInfo* shader_info,
                                      std::span<const WPShaderTexInfo> texs,
                                      std::string* reflection_json) {
    if (shader_info == nullptr) return false;

    wallpaper::shader::RustShaderRequest request {
        .shader_name   = std::string(shader_name),
        .scene_id      = std::string(scene_id),
        .cache_enabled = vfs.IsMounted("cache"),
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
        });
    }

    wallpaper::shader::RustShaderOutput output;
    const auto include_reader = [&vfs](std::string_view path) -> std::optional<std::string> {
        std::string asset_path = "/assets/shaders/" + std::string(path);
        if (auto stream = vfs.Open(asset_path); stream != nullptr) return stream->ReadAllStr();

        std::string direct_path(path);
        if (auto stream = vfs.Open(direct_path); stream != nullptr) return stream->ReadAllStr();

        return std::nullopt;
    };
    const auto request_json = wallpaper::shader::BuildRustShaderRequestJson(request).dump();
    const auto program_key = ProgramCacheKey(request_json);
    const auto program_path = std::string("/cache/") + std::string(scene_id) +
                              "/programs01/" + program_key + ".json";
    const auto cache_read_started = std::chrono::steady_clock::now();
    bool hit = false;
    if (request.cache_enabled) {
        if (const auto it = g_program_cache.find(program_key); it != g_program_cache.end()) {
            hit = RestoreProgram(it->second, request_json, include_reader, output);
        }
        if (!hit) {
            if (auto file = vfs.Open(program_path); file != nullptr && file->Size() > 0 && file->Size() <= 16 * 1024 * 1024) {
                const auto cached = nlohmann::json::parse(file->ReadAllStr(), nullptr, false);
                hit = RestoreProgram(cached, request_json, include_reader, output);
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
                {"includes", std::move(includes)}, {"codes", output.codes},
                {"metadata", output.metadata_json}, {"reflection", output.reflection_json},
                {"cache_key", output.cache_key},
            };
            RememberProgram(program_key, program);
        }
    }

    codes = std::move(output.codes);
    const auto cache_write_started = std::chrono::steady_clock::now();
    if (!hit && request.cache_enabled && ! output.cache_key.empty()) {
        if (auto file = vfs.OpenW(program_path); file != nullptr) {
            const auto bytes = program.dump();
            WriteBytes(*file, bytes.data(), bytes.size());
        }
        if (auto cache_file = vfs.OpenW(GetShaderCachePath(scene_id, output.cache_key)); cache_file) {
            if (! SaveShaderCacheFile(codes, *cache_file)) {
                LOG_ERROR("Rust shader cache write failed for '%s'",
                          std::string(shader_name).c_str());
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
        *reflection_json = std::move(output.reflection_json);
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
