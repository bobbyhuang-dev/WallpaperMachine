#pragma once
#include <cstdint>
#include <cmath>
#include <span>
#include <memory>
#include <functional>

#include "Particle/Particle.h"
#include "Scene/SceneMesh.h"

namespace wallpaper
{
struct ParticleRawGenSpec {
    float* lifetime;
};
using ParticleRawGenSpecOp = std::function<void(const Particle&, const ParticleRawGenSpec&)>;

struct ParticleRenderScale {
    float inverse_x { 1.0f };
    float inverse_y { 1.0f };
    float isotropic_inverse { 1.0f };
    /// How many straight pieces a rope renderer draws between two connected
    /// particles. One means a single piece per pair; a sprite renderer ignores
    /// it. Carried here because it is per-subsystem generator input exactly as
    /// the scale is, and the generator is shared by every subsystem.
    uint32_t rope_subdivision { 1 };
    /// Rope trails only: `ParticleSubSystem::TrailPeriodFraction()` for this
    /// tick, so the oldest piece of a full trail can shrink by exactly as much
    /// as the newest one has grown instead of vanishing in one step.
    float trail_fraction { 0.0f };
    /// Texture repeats along the whole rope/trail. The author shader has no
    /// uniform for this; it is encoded in the trail-length the generator writes.
    float uv_scale { 1.0f };
    /// When set, UV is measured against mesh/history capacity so a growing
    /// rope unrolls the texture instead of stretching it.
    bool uv_scrolling { false };
    /// When set, V along the strip is eased with smoothstep.
    bool uv_smoothing { false };
};

inline float RopeUvScaleOrOne(float scale) noexcept {
    return (std::isfinite(scale) && scale > 0.0f) ? scale : 1.0f;
}

/// Maps authored point-count `length` so the shader's (length-1) span is
/// `uv_scale` repeats. Identity when uv_scale is 1.
inline float EncodeRopeTrailLength(float authored_length, float uv_scale) noexcept {
    return (authored_length - 1.0f) / RopeUvScaleOrOne(uv_scale) + 1.0f;
}

class ParticleInstance;
class IParticleRawGener {
public:
    IParticleRawGener()          = default;
    virtual ~IParticleRawGener() = default;

    virtual void GenGLData(std::span<const std::unique_ptr<ParticleInstance>>, SceneMesh&,
                           ParticleRawGenSpecOp&, ParticleRenderScale render_scale) = 0;
};
} // namespace wallpaper
