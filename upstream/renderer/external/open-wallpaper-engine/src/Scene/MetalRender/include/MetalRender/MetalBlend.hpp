#pragma once

#include "Type.hpp"

#include <cstdint>

namespace wallpaper::metal
{

/// Mirror of `MTLBlendFactor`, so blend mapping can be written and tested
/// without a Metal device or an Objective-C translation unit. `MetalRender.mm`
/// static-asserts every enumerator against the real framework value, which is
/// what keeps this mirror honest.
enum class MetalBlendFactor : uint32_t
{
    Zero = 0,
    One = 1,
    SourceColor = 2,
    OneMinusSourceColor = 3,
    SourceAlpha = 4,
    OneMinusSourceAlpha = 5,
    DestinationColor = 6,
    OneMinusDestinationColor = 7,
    DestinationAlpha = 8,
    OneMinusDestinationAlpha = 9,
};

/// Mirror of `MTLBlendOperation`.
enum class MetalBlendOperation : uint32_t
{
    Add = 0,
    Subtract = 1,
    ReverseSubtract = 2,
    Min = 3,
    Max = 4,
};

/// Mirror of `MTLCullMode`.
enum class MetalCullMode : uint32_t
{
    None = 0,
    Front = 1,
    Back = 2,
};

/// The cull mode every scene pass is drawn with.
///
/// It must be `None`, and for two reasons that both matter. The compatibility
/// backend rasterizes with `VK_CULL_MODE_NONE`, so anything else would draw a
/// different picture. And any clip-space transform folded into the projection
/// also reverses triangle winding, so a cull mode tuned for one winding would
/// make geometry vanish the moment that fold stops being the identity. Named
/// here rather than written at the call site so the invariant can be asserted.
inline constexpr MetalCullMode kSceneCullMode = MetalCullMode::None;

/// The colour-attachment blend state for one authored blend mode.
struct MetalBlendState
{
    bool                blending_enabled { false };
    MetalBlendOperation rgb_operation { MetalBlendOperation::Add };
    MetalBlendOperation alpha_operation { MetalBlendOperation::Add };
    MetalBlendFactor    source_rgb { MetalBlendFactor::One };
    MetalBlendFactor    destination_rgb { MetalBlendFactor::Zero };
    MetalBlendFactor    source_alpha { MetalBlendFactor::One };
    MetalBlendFactor    destination_alpha { MetalBlendFactor::Zero };
    /// Authored `alphatocoverage` asks for coverage from alpha in addition to
    /// the blend factors, so it is carried alongside rather than folded in.
    bool                alpha_to_coverage { false };

    friend bool operator==(const MetalBlendState&, const MetalBlendState&) = default;
};

/// Translates an authored blend mode to Metal state, matching
/// `vulkan::SetBlend` factor for factor.
///
/// `BlendMode::Normal` is ONE / ZERO, an opaque replace. It is not Porter-Duff
/// source-over despite the name, and turning it into source-over would change
/// every scene that uses it.
[[nodiscard]] MetalBlendState ToMetalBlendState(BlendMode mode);

} // namespace wallpaper::metal
