#pragma once
#include <cstdint>
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
};

class ParticleInstance;
class IParticleRawGener {
public:
    IParticleRawGener()          = default;
    virtual ~IParticleRawGener() = default;

    virtual void GenGLData(std::span<const std::unique_ptr<ParticleInstance>>, SceneMesh&,
                           ParticleRawGenSpecOp&, ParticleRenderScale render_scale) = 0;
};
} // namespace wallpaper
