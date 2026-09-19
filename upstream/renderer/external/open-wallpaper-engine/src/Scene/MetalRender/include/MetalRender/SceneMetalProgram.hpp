#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace wallpaper
{

/// Metal argument-table namespace a shader resource is bound into.
///
/// Metal keeps buffers, textures and samplers in independent index spaces, so a
/// slot number only means something together with the space it belongs to.
enum class SceneMetalSlotKind : uint8_t
{
    Buffer = 0,
    Texture = 1,
    Sampler = 2,
};

enum class SceneMetalStageKind : uint8_t
{
    Vertex = 0,
    Fragment = 1,
};

/// One shader resource and the Metal argument-table slot it was translated to.
///
/// `name` is the original GLSL global name (`g_Texture0`), which is what the
/// reflection payload and the material's texture list use. It is deliberately
/// not the identifier that appears in the generated Metal source: the shader
/// backend appends a trailing underscore on collisions, so matching on source
/// text would silently miss exactly the shaders that collided.
struct SceneMetalBinding
{
    std::string        name;
    uint32_t           set { 0 };
    uint32_t           binding { 0 };
    SceneMetalSlotKind slot_kind { SceneMetalSlotKind::Buffer };
    uint32_t           slot { 0 };
};

struct SceneMetalStage
{
    SceneMetalStageKind            kind { SceneMetalStageKind::Vertex };
    std::string                    source;
    /// The generated entry-point function name. The shader backend renames
    /// entry points, so this is never assumed to be `main`.
    std::string                    entry_point;
    std::string                    language_version;
    std::vector<SceneMetalBinding> bindings;
};

/// Metal Shading Language translation of one material's shader program.
///
/// Attached to `SceneShader` by the parser, which is the only place that still
/// holds the final combos, the preprocessed units and the texture info the
/// SPIR-V compile settled on. A null `metal_program` on a shader therefore
/// means "translation was never attempted", which is a different answer from
/// "translation was attempted and failed" and has to stay distinguishable: the
/// first is what every scene looks like when the user has not selected the
/// native renderer, and reporting it as a translation failure would accuse the
/// author's shader of a fault it does not have.
struct SceneMetalProgram
{
    std::vector<SceneMetalStage> stages;
    /// The same reflection payload the SPIR-V path produces: uniform block
    /// layout, vertex inputs and active texture slots. Kept as the raw
    /// document so this type stays free of both Vulkan and JSON dependencies.
    std::string reflection_json;
    /// Non-empty when translation was attempted and failed. The scene still
    /// loads and still draws; only the native backend is refused.
    std::string error;

    [[nodiscard]] bool ok() const
    {
        return error.empty() && ! stages.empty() && ! reflection_json.empty();
    }
};

} // namespace wallpaper
