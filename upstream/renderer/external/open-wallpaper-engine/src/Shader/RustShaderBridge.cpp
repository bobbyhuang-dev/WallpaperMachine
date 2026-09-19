#include "Shader/RustShaderBridge.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace wallpaper::shader
{
namespace
{

constexpr uint32_t SPIRV_MAGIC = 0x07230203u;
constexpr int RS_SHADER_TARGET_VULKAN_SPIRV = 0;
constexpr int RS_SHADER_TARGET_METAL_MSL    = 1;

struct RsShaderOwnedBytes {
    uint8_t* ptr;
    size_t   len;
    void (*free)(uint8_t*, size_t, void*);
    void* free_user_data;
};

struct RsShaderProgram;

using RsShaderIncludeCallback = RsShaderOwnedBytes (*)(const char*, void*);

#ifdef WESCENE_HAS_RUST_SHADER_FFI
extern "C"
{
int rs_shader_compile_program(
    const char* request_json,
    RsShaderIncludeCallback include_callback,
    void* include_user_data,
    RsShaderProgram** out_program);
size_t rs_shader_program_stage_count(const RsShaderProgram* program);
int rs_shader_program_stage_kind(const RsShaderProgram* program, size_t stage_index);
const uint32_t* rs_shader_program_stage_spv_words(
    const RsShaderProgram* program,
    size_t stage_index);
size_t rs_shader_program_stage_spv_word_count(const RsShaderProgram* program, size_t stage_index);
int rs_shader_program_stage_target(const RsShaderProgram* program, size_t stage_index);
const char* rs_shader_program_stage_msl_source(
    const RsShaderProgram* program,
    size_t stage_index);
const char* rs_shader_program_stage_metal_json(
    const RsShaderProgram* program,
    size_t stage_index);
const char* rs_shader_program_metadata_json(const RsShaderProgram* program);
const char* rs_shader_program_reflection_json(const RsShaderProgram* program);
const char* rs_shader_program_diagnostics_json(const RsShaderProgram* program);
const char* rs_shader_program_cache_key(const RsShaderProgram* program);
void rs_shader_program_free(RsShaderProgram* program);
const char* rs_shader_last_error();
const char* rs_shader_cache_identity();
}
#endif

struct ProgramHandle {
    RsShaderProgram* ptr { nullptr };

    ~ProgramHandle()
    {
#ifdef WESCENE_HAS_RUST_SHADER_FFI
        if (ptr != nullptr) {
            rs_shader_program_free(ptr);
        }
#endif
    }
};

const char* ToStageKind(ShaderType type)
{
    switch (type) {
    case ShaderType::VERTEX: return "vertex";
    case ShaderType::FRAGMENT: return "fragment";
    default: throw std::runtime_error("unsupported Rust shader stage");
    }
}

ShaderType FromRustStageKind(int kind)
{
    switch (kind) {
    case 0: return ShaderType::VERTEX;
    case 1: return ShaderType::FRAGMENT;
    default: throw std::runtime_error("Rust shader returned an invalid stage kind");
    }
}

const char* ToTargetName(RustShaderTarget target)
{
    switch (target) {
    case RustShaderTarget::VulkanSpirv: return "vulkan_spirv";
    case RustShaderTarget::MetalMsl: return "metal_msl";
    }
    throw std::runtime_error("unsupported Rust shader target");
}

int ToRustTarget(RustShaderTarget target)
{
    switch (target) {
    case RustShaderTarget::VulkanSpirv: return RS_SHADER_TARGET_VULKAN_SPIRV;
    case RustShaderTarget::MetalMsl: return RS_SHADER_TARGET_METAL_MSL;
    }
    throw std::runtime_error("unsupported Rust shader target");
}

RustShaderMetalSlotKind FromMetalSlotKind(std::string_view slot_kind)
{
    if (slot_kind == "buffer") {
        return RustShaderMetalSlotKind::Buffer;
    }
    if (slot_kind == "texture") {
        return RustShaderMetalSlotKind::Texture;
    }
    if (slot_kind == "sampler") {
        return RustShaderMetalSlotKind::Sampler;
    }
    throw std::runtime_error("Rust shader returned an unknown metal slot kind");
}

VkShaderStageFlags ToVkStageFlags(const nlohmann::json& stages)
{
    VkShaderStageFlags flags = 0;
    for (const auto& stage : stages) {
        const auto name = stage.get<std::string>();
        if (name == "vertex") {
            flags |= VK_SHADER_STAGE_VERTEX_BIT;
        } else if (name == "fragment") {
            flags |= VK_SHADER_STAGE_FRAGMENT_BIT;
        }
    }
    return flags;
}

VkDescriptorType ToVkDescriptorType(std::string_view descriptor)
{
    if (descriptor == "uniform_buffer") {
        return VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    }
    if (descriptor == "sampled_image") {
        return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    }
    if (descriptor == "combined_image_sampler") {
        return VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    }
    if (descriptor == "sampler") {
        return VK_DESCRIPTOR_TYPE_SAMPLER;
    }
    throw std::runtime_error("unsupported Rust descriptor kind");
}

VkFormat ToVkVertexFormat(std::string_view format)
{
    if (format == "r32_sfloat") {
        return VK_FORMAT_R32_SFLOAT;
    }
    if (format == "r32g32_sfloat") {
        return VK_FORMAT_R32G32_SFLOAT;
    }
    if (format == "r32g32b32_sfloat") {
        return VK_FORMAT_R32G32B32_SFLOAT;
    }
    if (format == "r32g32b32a32_sfloat") {
        return VK_FORMAT_R32G32B32A32_SFLOAT;
    }
    if (format == "r32_uint") {
        return VK_FORMAT_R32_UINT;
    }
    if (format == "r32g32_uint") {
        return VK_FORMAT_R32G32_UINT;
    }
    if (format == "r32g32b32_uint") {
        return VK_FORMAT_R32G32B32_UINT;
    }
    if (format == "r32g32b32a32_uint") {
        return VK_FORMAT_R32G32B32A32_UINT;
    }
    if (format == "r32_sint") {
        return VK_FORMAT_R32_SINT;
    }
    if (format == "r32g32_sint") {
        return VK_FORMAT_R32G32_SINT;
    }
    if (format == "r32g32b32_sint") {
        return VK_FORMAT_R32G32B32_SINT;
    }
    if (format == "r32g32b32a32_sint") {
        return VK_FORMAT_R32G32B32A32_SINT;
    }
    throw std::runtime_error("unsupported Rust vertex input format");
}

void FreeOwnedBytes(uint8_t* ptr, size_t, void*)
{
    std::free(ptr);
}

RsShaderOwnedBytes IncludeCallback(const char* path, void* user_data)
{
    if (path == nullptr || user_data == nullptr) {
        return {};
    }

    auto* include_reader = static_cast<const RustShaderIncludeReader*>(user_data);
    const auto bytes = (*include_reader)(path);
    if (! bytes.has_value()) {
        return {};
    }

    const auto allocation_size = std::max<std::size_t>(bytes->size(), 1);
    auto*      buffer = static_cast<uint8_t*>(std::malloc(allocation_size));
    if (buffer == nullptr) {
        return {};
    }
    if (! bytes->empty()) {
        std::memcpy(buffer, bytes->data(), bytes->size());
    }

    return RsShaderOwnedBytes {
        .ptr            = buffer,
        .len            = bytes->size(),
        .free           = FreeOwnedBytes,
        .free_user_data = nullptr,
    };
}

std::string BorrowedString(const char* value)
{
    return value == nullptr ? std::string {} : std::string { value };
}

void ApplyActiveTextureSlots(const nlohmann::json& json, WPPreprocessorInfo& info)
{
    for (const auto& slot : json.value("active_texture_slots", nlohmann::json::array())) {
        info.active_tex_slots.insert(slot.get<uint>());
    }
}

ShaderValue ToShaderValue(const nlohmann::json& value)
{
    const auto kind = value.value("kind", std::string {});
    if (kind == "number") {
        return ShaderValue { value.at("value").get<float>() };
    }
    if (kind == "bool") {
        return ShaderValue { value.at("value").get<bool>() ? 1.0f : 0.0f };
    }
    if (kind == "vec2" || kind == "vec3" || kind == "vec4" || kind == "matrix4") {
        const auto& array = value.at("value");
        std::vector<float> values;
        values.reserve(array.size());
        for (const auto& item : array) {
            values.push_back(item.get<float>());
        }
        return ShaderValue { values };
    }
    return ShaderValue {};
}

} // namespace

nlohmann::json BuildRustShaderRequestJson(const RustShaderRequest& request)
{
    nlohmann::json stages = nlohmann::json::array();
    for (const auto& stage : request.stages) {
        stages.push_back({
            { "kind", ToStageKind(stage.kind) },
            { "source", stage.source },
        });
    }

    nlohmann::json combos = nlohmann::json::array();
    for (const auto& [name, value] : request.combos) {
        combos.push_back({
            { "name", name },
            { "value", value },
        });
    }

    nlohmann::json textures = nlohmann::json::array();
    for (const auto& texture : request.textures) {
        nlohmann::json entry {
            { "slot", texture.slot },
            { "present", texture.present },
            { "enabled", texture.enabled },
            { "format", texture.format },
            {
                "components",
                {
                    { "compo1", texture.components[0] },
                    { "compo2", texture.components[1] },
                    { "compo3", texture.components[2] },
                },
            },
        };
        // Written only when a slot really is compiled as planes, so an
        // ordinary texture's request JSON -- and the program cache key derived
        // from it -- is byte for byte the one this bridge always produced.
        if (texture.video_planes == RustShaderVideoPlanes::Nv12Biplanar) {
            entry["video_planes"] = "nv12_biplanar";
        }
        textures.push_back(std::move(entry));
    }

    nlohmann::json properties = nlohmann::json::array();
    for (const auto& property : request.properties) {
        properties.push_back({
            { "name", property.name },
            {
                "value",
                {
                    { "kind", property.value.kind },
                    { "value", property.value.value },
                },
            },
        });
    }

    nlohmann::json cache_policy = { { "mode", request.cache_enabled ? "enabled" : "disabled" } };
    if (request.cache_enabled) {
        cache_policy["scene_id"] = request.scene_id;
    }

    return {
        { "shader_name", request.shader_name },
        { "target", ToTargetName(request.target) },
        { "cache_policy", std::move(cache_policy) },
        { "stages", std::move(stages) },
        { "combos", std::move(combos) },
        { "textures", std::move(textures) },
        { "properties", std::move(properties) },
    };
}

void ApplyRustShaderMetadataJson(std::string_view metadata_json, RustShaderOutput& output)
{
    const auto metadata = nlohmann::json::parse(metadata_json);

    for (const auto& combo : metadata.value("combos", nlohmann::json::array())) {
        output.shader_info.combos[combo.at("name").get<std::string>()] =
            combo.at("value").get<std::string>();
    }
    for (const auto& alias : metadata.value("aliases", nlohmann::json::array())) {
        output.shader_info.alias[alias.at("material").get<std::string>()] =
            alias.at("uniform").get<std::string>();
    }
    for (const auto& uniform : metadata.value("default_uniforms", nlohmann::json::array())) {
        output.shader_info.svs[uniform.at("name").get<std::string>()] =
            ToShaderValue(uniform.at("value"));
    }
    for (const auto& texture : metadata.value("default_textures", nlohmann::json::array())) {
        output.shader_info.defTexs.emplace_back(
            texture.at("slot").get<i32>(),
            texture.at("path").get<std::string>());
    }

    ApplyActiveTextureSlots(metadata, output.fragment_preprocessor_info);
}

void ApplyRustShaderReflectionJson(std::string_view reflection_json, RustShaderOutput& output)
{
    const auto reflection = nlohmann::json::parse(reflection_json);

    output.reflection.binding_map.clear();
    for (const auto& descriptor : reflection.value("descriptor_bindings", nlohmann::json::array())) {
        if (descriptor.value("set", 0u) != 0u) {
            throw std::runtime_error("Rust shader descriptors must use descriptor set 0");
        }
        if (descriptor.value("count", 1u) != 1u) {
            throw std::runtime_error("Rust shader descriptor arrays are not supported");
        }

        VkDescriptorSetLayoutBinding binding {};
        binding.binding         = descriptor.at("binding").get<uint32_t>();
        binding.descriptorType  = ToVkDescriptorType(descriptor.at("descriptor").get<std::string>());
        binding.descriptorCount = descriptor.value("count", 1u);
        binding.stageFlags      = ToVkStageFlags(descriptor.value("stages", nlohmann::json::array()));
        output.reflection.binding_map[descriptor.at("name").get<std::string>()] = binding;
    }

    output.reflection.blocks.clear();
    int block_index = 0;
    for (const auto& block_json : reflection.value("uniform_blocks", nlohmann::json::array())) {
        vulkan::ShaderReflected::Block block {
            .index      = block_index,
            .size       = block_json.at("size").get<uint>(),
            .binding    = block_json.value("binding", 0u),
            .name       = block_json.at("name").get<std::string>(),
            .member_map = {},
        };

        for (const auto& member : block_json.value("members", nlohmann::json::array())) {
            block.member_map[member.at("name").get<std::string>()] =
                vulkan::ShaderReflected::BlockedUniform {
                    .block_index  = block_index,
                    .offset       = member.at("offset").get<uint>(),
                    .size         = member.at("size").get<size_t>(),
                    .num          = member.value("element_count", 1u),
                    .array_count  = member.value("array_count", 0u),
                    .array_stride = member.value("array_stride", 0u),
                };
        }

        output.reflection.blocks.push_back(std::move(block));
        block_index++;
    }

    output.reflection.input_location_map.clear();
    for (const auto& input : reflection.value("vertex_inputs", nlohmann::json::array())) {
        output.reflection.input_location_map[input.at("name").get<std::string>()] =
            vulkan::ShaderReflected::Input {
                .location = input.at("location").get<uint>(),
                .format   = ToVkVertexFormat(input.at("format").get<std::string>()),
            };
    }

    ApplyActiveTextureSlots(reflection, output.fragment_preprocessor_info);
}

void ApplyRustShaderMetalStageJson(
    std::string_view metal_json,
    std::string_view msl_source,
    ShaderType kind,
    RustShaderMetalStage& stage)
{
    const auto metal = nlohmann::json::parse(metal_json);

    stage.kind        = kind;
    stage.source      = std::string(msl_source);
    stage.entry_point = metal.at("entry_point").get<std::string>();
    if (stage.entry_point.empty()) {
        throw std::runtime_error("Rust shader returned an empty metal entry point");
    }
    stage.language_version = metal.value("language_version", std::string {});

    stage.bindings.clear();
    for (const auto& binding : metal.value("bindings", nlohmann::json::array())) {
        stage.bindings.push_back(RustShaderMetalBinding {
            .name      = binding.at("name").get<std::string>(),
            .set       = binding.at("set").get<uint32_t>(),
            .binding   = binding.at("binding").get<uint32_t>(),
            .slot_kind = FromMetalSlotKind(binding.at("slot_kind").get<std::string>()),
            .slot      = binding.at("slot").get<uint32_t>(),
        });
    }

    const auto conventions = metal.value("conventions", nlohmann::json::object());
    stage.conventions      = RustShaderMetalConventions {
             .clip_space_y_flipped      = conventions.value("clip_space_y_flipped", false),
             .clip_space_depth_remapped = conventions.value("clip_space_depth_remapped", false),
             .texture_origin_flipped    = conventions.value("texture_origin_flipped", false),
    };
}

namespace
{

bool CompileRustShaderProgramJson(
    const std::string& request_json,
    RustShaderTarget target,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    (void)request_json;
    (void)target;
    (void)output;
    (void)include_reader;
    output = {};
    return false;
#else
    RustShaderOutput next_output;

    ProgramHandle program;
    const int status = rs_shader_compile_program(
        request_json.c_str(),
        include_reader ? IncludeCallback : nullptr,
        include_reader ? const_cast<RustShaderIncludeReader*>(&include_reader) : nullptr,
        &program.ptr);
    if (status != 0 || program.ptr == nullptr) {
        output = {};
        return false;
    }

    const int    expected_target = ToRustTarget(target);
    const size_t stage_count     = rs_shader_program_stage_count(program.ptr);
    if (target == RustShaderTarget::MetalMsl) {
        next_output.metal_stages.reserve(stage_count);
    } else {
        next_output.codes.reserve(stage_count);
    }

    for (size_t i = 0; i < stage_count; ++i) {
        const auto kind = FromRustStageKind(rs_shader_program_stage_kind(program.ptr, i));
        if (rs_shader_program_stage_target(program.ptr, i) != expected_target) {
            output = {};
            return false;
        }

        if (target == RustShaderTarget::MetalMsl) {
            const auto metal_json = BorrowedString(
                rs_shader_program_stage_metal_json(program.ptr, i));
            const auto msl_source = BorrowedString(
                rs_shader_program_stage_msl_source(program.ptr, i));
            if (msl_source.empty()) {
                output = {};
                return false;
            }
            RustShaderMetalStage metal_stage;
            ApplyRustShaderMetalStageJson(metal_json, msl_source, kind, metal_stage);
            next_output.metal_stages.push_back(std::move(metal_stage));
            continue;
        }

        const auto* words = rs_shader_program_stage_spv_words(program.ptr, i);
        const auto  count = rs_shader_program_stage_spv_word_count(program.ptr, i);
        if (words == nullptr || count == 0 || words[0] != SPIRV_MAGIC) {
            output = {};
            return false;
        }
        next_output.codes.emplace_back(words, words + count);
    }

    next_output.metadata_json    = BorrowedString(rs_shader_program_metadata_json(program.ptr));
    next_output.reflection_json  = BorrowedString(rs_shader_program_reflection_json(program.ptr));
    next_output.diagnostics_json = BorrowedString(rs_shader_program_diagnostics_json(program.ptr));
    next_output.cache_key        = BorrowedString(rs_shader_program_cache_key(program.ptr));
    // Reflection is target-independent: the Metal path consumes exactly the
    // same uniform-block layout, descriptor names and texture slots the Vulkan
    // path does.
    ApplyRustShaderMetadataJson(next_output.metadata_json, next_output);
    ApplyRustShaderReflectionJson(next_output.reflection_json, next_output);

    output = std::move(next_output);
    return true;
#endif
}

} // namespace

bool CompileRustShaderProgram(
    const RustShaderRequest& request,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
    return CompileRustShaderProgramJson(
        BuildRustShaderRequestJson(request).dump(),
        request.target,
        output,
        include_reader);
}

std::string RustShaderCacheIdentity()
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    return BorrowedString(rs_shader_cache_identity());
#else
    return "ffi-disabled";
#endif
}

std::string LastRustShaderError()
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    return "Rust shader FFI is disabled";
#else
    return BorrowedString(rs_shader_last_error());
#endif
}

#ifdef WESCENE_BUILD_TESTS
bool CompileRustShaderProgramWithBridgeJson(
    const nlohmann::json& request_json,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
    return CompileRustShaderProgramJson(
        request_json.dump(),
        request_json.value("target", std::string { "vulkan_spirv" }) == "metal_msl"
            ? RustShaderTarget::MetalMsl
            : RustShaderTarget::VulkanSpirv,
        output,
        include_reader);
}
#endif

} // namespace wallpaper::shader
