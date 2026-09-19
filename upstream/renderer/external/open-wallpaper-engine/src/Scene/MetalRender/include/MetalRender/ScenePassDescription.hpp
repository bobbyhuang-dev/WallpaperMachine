#pragma once

#include "MetalRender/MetalBlend.hpp"
#include "MetalRender/MetalCapability.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace wallpaper
{
class Scene;
class SceneNode;

namespace rg
{
class RenderGraph;
}

namespace metal
{

/// Mirror of `MTLLoadAction`, for the same reason as `MetalBlendFactor`:
/// the description has to be buildable and testable without Metal.
enum class MetalLoadAction : uint32_t
{
    DontCare = 0,
    Load = 1,
    Clear = 2,
};

/// Mirror of the `MTLPixelFormat` values this backend can render into.
/// `Invalid` is zero so a forgotten assignment is visibly wrong.
enum class MetalPixelFormat : uint32_t
{
    Invalid = 0,
    RGBA8Unorm = 70,
    RGBA8Unorm_sRGB = 71,
    BGRA8Unorm = 80,
    BGRA8Unorm_sRGB = 81,
};

/// One step of the frame, in terms a backend can execute without knowing how
/// the scene was authored.
///
/// Deliberately small: it carries what a first Metal backend needs and nothing
/// else. The scene objects a draw needs every frame -- the node whose transform
/// and material constants move -- are referenced, not copied, because copying
/// them would freeze exactly the values that are supposed to change.
struct ScenePassDescription
{
    MetalPassKind kind { MetalPassKind::Unsupported };
    std::string   name;

    // ---- target
    /// Resolved render-target key. Empty for a pass that produces no pixels.
    std::string          target_key;
    uint32_t             target_width { 0 };
    uint32_t             target_height { 0 };
    MetalLoadAction      load_action { MetalLoadAction::DontCare };
    std::array<float, 4> clear_color { 0.0f, 0.0f, 0.0f, 0.0f };

    // ---- Copy
    std::string source_key;

    // ---- CustomShader
    SceneNode*               node { nullptr };
    SceneNode*               visibility_node { nullptr };
    uint32_t                 material_slot { 0 };
    std::size_t              submesh_index { 0 };
    std::string              camera_override;
    BlendMode                blend { BlendMode::Disable };
    bool                     write_alpha { true };
    /// One entry per material texture slot, in slot order. An empty string is
    /// a slot the material leaves unbound, which must stay an empty slot
    /// rather than collapsing and shifting every later binding.
    std::vector<std::string> texture_keys;
};

/// Identity of a pipeline state, so one is built per distinct combination and
/// never inside a frame.
///
/// Blend mode and target pixel format are part of the key because Metal bakes
/// both into the pipeline: two passes that share a shader but differ in either
/// need two pipelines, and reusing one would either blend wrongly or fail
/// validation against the attachment.
struct MetalPipelineKey
{
    /// Identity of the translated shader program, stable for the lifetime of
    /// the compiled graph.
    uint64_t         program_id { 0 };
    /// Identity of the vertex buffer layout the submesh presents.
    uint64_t         vertex_layout_id { 0 };
    MetalBlendState  blend {};
    MetalPixelFormat color_format { MetalPixelFormat::Invalid };
    uint32_t         sample_count { 1 };
    bool             write_alpha { true };

    friend bool operator==(const MetalPipelineKey&, const MetalPipelineKey&) = default;
};

struct MetalPipelineKeyHash
{
    std::size_t operator()(const MetalPipelineKey& key) const noexcept;
};

/// Lowers the render graph the compatibility backend consumes into the pass
/// list this backend executes. One graph, two backends: the ordering, the
/// load/store decisions and the per-target clear behaviour are the graph's, not
/// this function's.
///
/// Returns false and fills `error` on anything it does not recognise, which is
/// how an unsupported construct becomes a whole-scene fallback instead of a
/// silently skipped draw.
bool BuildScenePassDescriptions(Scene& scene, const rg::RenderGraph& graph,
                                std::vector<ScenePassDescription>& out, std::string* error);

} // namespace metal
} // namespace wallpaper
