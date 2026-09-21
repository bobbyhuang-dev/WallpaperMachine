#include "ParticleSystem.h"
#include "Interface/IParticleRawGener.h"
#include "Core/Literals.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "ParticleModify.h"
#include "Scene/SceneMesh.h"
#include "Core/Random.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cmath>

using namespace wallpaper;

void ParticleInstance::Refresh() {
    SetDeath(false);
    SetNoLiveParticle(false);
    GetBoundedData() = {};
    ParticlesVec().clear();
    TrailsVec().clear();
}

bool ParticleInstance::IsDeath() const { return m_is_death; }
void ParticleInstance::SetDeath(bool v) { m_is_death = v; };

bool ParticleInstance::IsNoLiveParticle() const { return m_no_live_particle; };
void ParticleInstance::SetNoLiveParticle(bool v) { m_no_live_particle = v; };

std::span<const Particle> ParticleInstance::Particles() const { return m_particles; };
std::vector<Particle>&    ParticleInstance::ParticlesVec() { return m_particles; };

std::span<const ParticleTrailHistory> ParticleInstance::Trails() const { return m_trails; };
std::vector<ParticleTrailHistory>&    ParticleInstance::TrailsVec() { return m_trails; };

ParticleInstance::BoundedData& ParticleInstance::GetBoundedData() { return m_bounded_data; }

ParticleSubSystem::ParticleSubSystem(ParticleSystem& p, std::shared_ptr<SceneMesh> sm,
                                     uint32_t maxcount, double rate, u32 maxcount_instance,
                                     double probability, SpawnType type,
                                     ParticleRawGenSpecOp specOp)
    : m_sys(p),
      m_mesh(sm),
      m_maxcount(maxcount),
      m_rate(rate),
      m_genSpecOp(specOp),
      m_time(0),
      m_maxcount_instance(maxcount_instance),
      m_probability(probability),
      m_spawn_type(type) {};

ParticleSubSystem::~ParticleSubSystem() = default;

void ParticleSubSystem::AddEmitter(ParticleEmittOp&& em) { m_emiters.emplace_back(em); }

void ParticleSubSystem::AddInitializer(ParticleInitOp&& ini) { m_initializers.emplace_back(ini); }

void ParticleSubSystem::AddOperator(ParticleOperatorOp&& op) { m_operators.emplace_back(op); }

std::span<const ParticleControlpoint> ParticleSubSystem::Controlpoints() const {
    return m_controlpoints;
}
std::span<ParticleControlpoint> ParticleSubSystem::Controlpoints() { return m_controlpoints; };

void ParticleSubSystem::SetOwnerNode(std::weak_ptr<SceneNode> node) {
    m_owner_node = std::move(node);
}

void ParticleSubSystem::SetRateMultiplier(std::function<double()> rate_multiplier) {
    m_rate_multiplier = std::move(rate_multiplier);
}

void ParticleSubSystem::SetRopeSubdivision(u32 subdivision) {
    m_rope_subdivision = std::max<u32>(1, subdivision);
}

void ParticleSubSystem::SetRopeUv(float scale, bool scrolling, bool smoothing) {
    m_uv_scale     = RopeUvScaleOrOne(scale);
    m_uv_scrolling = scrolling;
    m_uv_smoothing = smoothing;
    if (m_trail.enabled() && m_mesh != nullptr && m_mesh->Material() != nullptr) {
        auto& constValues = m_mesh->Material()->customShader.constValues;
        auto  it          = constValues.find("g_RenderVar0");
        if (it != constValues.end() && it->second.size() >= 4) {
            it->second[3] =
                EncodeRopeTrailLength(static_cast<float>(m_trail.samples), m_uv_scale);
        }
    }
    if (m_mesh != nullptr) m_mesh->SetDirty();
}

void ParticleSubSystem::SetTrail(ParticleTrailConfig config) {
    m_trail       = config;
    m_trail_timer = 0.0;
}

float ParticleSubSystem::TrailPeriodFraction() const {
    if (! m_trail.enabled()) return 0;
    return static_cast<float>(std::clamp(m_trail_timer / m_trail.period, 0.0, 1.0));
}

ParticleSubSystem::SpawnType ParticleSubSystem::Type() const { return m_spawn_type; }

u32 ParticleSubSystem::MaxInstanceCount() const { return m_maxcount_instance; };

namespace
{
float InverseScaleOrIdentity(float scale) {
    if (! std::isfinite(scale) || scale <= 1.0e-6f) return 1.0f;
    return 1.0f / scale;
}
} // namespace

ParticleRenderScale ParticleSubSystem::RenderScale() const {
    auto owner = m_owner_node.lock();
    if (! owner) {
        ParticleRenderScale scale {};
        scale.rope_subdivision = m_rope_subdivision;
        scale.trail_fraction   = TrailPeriodFraction();
        scale.uv_scale         = m_uv_scale;
        scale.uv_scrolling     = m_uv_scrolling;
        scale.uv_smoothing     = m_uv_smoothing;
        return scale;
    }

    owner->UpdateTrans();
    const auto& transform = owner->RenderTrans();
    const float scale_x = static_cast<float>(transform.block<3, 1>(0, 0).norm());
    const float scale_y = static_cast<float>(transform.block<3, 1>(0, 1).norm());

    return {
        .inverse_x         = InverseScaleOrIdentity(scale_x),
        .inverse_y         = InverseScaleOrIdentity(scale_y),
        .isotropic_inverse = InverseScaleOrIdentity((scale_x + scale_y) * 0.5f),
        .rope_subdivision  = m_rope_subdivision,
        .trail_fraction    = TrailPeriodFraction(),
        .uv_scale          = m_uv_scale,
        .uv_scrolling      = m_uv_scrolling,
        .uv_smoothing      = m_uv_smoothing,
    };
}

void ParticleSubSystem::UpdateMouseControlpoints() {
    if (std::none_of(m_controlpoints.begin(), m_controlpoints.end(),
                     [](const auto& cp) { return cp.link_mouse; })) {
        return;
    }
    // The presentation's own answer when there is one. Stretching the
    // window-normalized pointer across the whole canvas is only right when the
    // window shows the whole canvas: a cropped wallpaper agrees at the centre
    // and is wrong by half the cropped-away span at either edge.
    const auto& scene_pointer = m_sys.scene.pointerScenePosition;
    const auto  pointer       = m_sys.scene.pointerPosition;
    const Eigen::Vector3d mouse_world {
        scene_pointer.has_value()
            ? static_cast<double>((*scene_pointer)[0])
            : static_cast<double>(pointer[0]) * static_cast<double>(m_sys.scene.ortho[0]),
        scene_pointer.has_value()
            ? static_cast<double>((*scene_pointer)[1])
            : (1.0 - static_cast<double>(pointer[1])) * static_cast<double>(m_sys.scene.ortho[1]),
        0.0,
    };
    Eigen::Vector3d mouse_local = mouse_world;
    if (auto owner = m_owner_node.lock()) {
        owner->UpdateTrans();
        const Eigen::Vector4d local =
            owner->ModelTrans().inverse() * Eigen::Vector4d(mouse_world.x(), mouse_world.y(), 0.0, 1.0);
        mouse_local = local.head<3>();
    }
    for (auto& cp : m_controlpoints) {
        if (cp.link_mouse) cp.offset = cp.base_offset + mouse_local;
    }
}

void ParticleSubSystem::AddChild(std::unique_ptr<ParticleSubSystem>&& child) {
    m_children.emplace_back(std::move(child));
}

ParticleInstance* ParticleSubSystem::QueryNewInstance() {
    if (Random::get(0.0, 1.0) <= m_probability) {
        for (auto& inst : m_instances) {
            if (inst->IsDeath() && inst->IsNoLiveParticle()) {
                inst->Refresh();
                return inst.get();
            }
        }
        if (m_instances.size() < m_maxcount_instance) {
            m_instances.emplace_back(std::make_unique<ParticleInstance>());
            return m_instances.back().get();
        }
    }
    return nullptr;
}

void ParticleSubSystem::Emitt() {
    double frameTime    = m_sys.scene.frameTime;
    const double rate_multiplier =
        m_rate_multiplier ? std::max(0.0, m_rate_multiplier()) : 1.0;
    double particleTime = frameTime * m_rate * rate_multiplier;
    m_time += particleTime;
    bool record_trail = false;
    if (m_trail.enabled()) {
        m_trail_timer += particleTime;
        if (m_trail_timer >= m_trail.period) {
            record_trail  = true;
            m_trail_timer = std::fmod(m_trail_timer, m_trail.period);
        }
    }
    UpdateMouseControlpoints();

    if (m_spawn_type == SpawnType::STATIC) {
        if (m_instances.empty()) m_instances.emplace_back(std::make_unique<ParticleInstance>());
    }

    auto spawn_inst = [](ParticleInstance& inst, ParticleSubSystem& child, isize idx) {
        ParticleInstance* n_inst = child.QueryNewInstance();
        if (n_inst != nullptr) {
            n_inst->GetBoundedData() = {
                .parent       = &inst,
                .particle_idx = idx,
            };
        }
    };

    for (auto& inst : m_instances) {
        assert(inst);

        auto& bounded_data = inst->GetBoundedData();

        bool type_has_death =
            m_spawn_type == SpawnType::EVENT_SPAWN || m_spawn_type == SpawnType::EVENT_FOLLOW;

        // bouded data and death
        if (bounded_data.parent != nullptr) {
            std::span particles = bounded_data.parent->Particles();
            if (bounded_data.particle_idx != -1 && bounded_data.particle_idx < particles.size()) {
                auto& p          = particles[bounded_data.particle_idx];
                bounded_data.pos = ParticleModify::GetPos(p);
                // only update pos once when event_death
                if (m_spawn_type == SpawnType::EVENT_DEATH) bounded_data.particle_idx = -1;

                // death if bounded particle death
                if (! inst->IsDeath() && type_has_death) {
                    bool cur_life_ok = ParticleModify::LifetimeOk(p);
                    inst->SetDeath(! cur_life_ok && bounded_data.pre_lifetime_ok);
                    bounded_data.pre_lifetime_ok = cur_life_ok;
                }
            }

            // death if parent death
            if (! inst->IsDeath() && type_has_death) {
                inst->SetDeath(bounded_data.parent->IsDeath());
            }
        }

        // clear when death if follow
        if (inst->IsDeath() && m_spawn_type == SpawnType::EVENT_FOLLOW) {
            inst->ParticlesVec().clear();
            inst->TrailsVec().clear();
        }

        if (! inst->IsDeath()) {
            for (auto& emittOp : m_emiters) {
                emittOp(inst->ParticlesVec(),
                        m_initializers,
                        m_maxcount,
                        particleTime,
                        m_controlpoints);
            }
        }

        auto& trails = inst->TrailsVec();
        if (m_trail.enabled()) {
            if (trails.size() < inst->ParticlesVec().size()) trails.resize(inst->ParticlesVec().size());
        }

        // event_death is always death after emitop
        if (m_spawn_type == SpawnType::EVENT_DEATH) inst->SetDeath(true);

        ParticleInfo info {
            .particles     = inst->ParticlesVec(),
            .controlpoints = m_controlpoints,
            .time          = m_time,
            .time_pass     = particleTime,
        };

        bool  has_live = false;
        isize i        = -1;
        for (auto& p : info.particles) {
            i++;

            if (ParticleModify::IsNew(p)) {
                // new spawn
                for (auto& child : m_children) {
                    if (child->Type() == SpawnType::EVENT_FOLLOW ||
                        child->Type() == SpawnType::EVENT_SPAWN)
                        spawn_inst(*inst, *child, i);
                }
                if (m_trail.enabled() && static_cast<std::size_t>(i) < trails.size()) {
                    trails[i].Reset(m_trail.samples);
                    trails[i].Push({ bounded_data.pos + p.position });
                }
            }

            ParticleModify::MarkOld(p);
            if (! ParticleModify::LifetimeOk(p)) {
                continue;
            }
            ParticleModify::Reset(p);
            ParticleModify::ChangeLifetime(p, -particleTime);

            if (! ParticleModify::LifetimeOk(p)) {
                // new dead
                for (auto& child : m_children) {
                    if (child->Type() == SpawnType::EVENT_DEATH) spawn_inst(*inst, *child, i);
                }
            } else {
                has_live = true;
            }
        }

        inst->SetNoLiveParticle(! has_live);

        std::for_each(m_operators.begin(), m_operators.end(), [&info](ParticleOperatorOp& op) {
            op(info);
        });

        for (auto& p : info.particles) {
            if (! ParticleModify::LifetimeOk(p)) continue;
            ParticleModify::MoveByTime(p, particleTime);
            ParticleModify::RotateByTime(p, particleTime);
        }

        if (record_trail) {
            isize slot = -1;
            for (auto& p : info.particles) {
                slot++;
                if (! ParticleModify::LifetimeOk(p)) continue;
                if (static_cast<std::size_t>(slot) < trails.size()) {
                    trails[slot].Push({ bounded_data.pos + p.position });
                }
            }
        }
    }

    m_mesh->SetDirty();

    m_sys.gener->GenGLData(m_instances, *m_mesh, m_genSpecOp, RenderScale());

    if (m_trail.enabled() && m_mesh->Material() != nullptr) {
        auto& constValues = m_mesh->Material()->customShader.constValues;
        auto  it          = constValues.find("g_RenderVar0");
        if (it != constValues.end() && it->second.size() >= 4) {
            it->second[2] = TrailPeriodFraction();
        }
    }

    for (auto& child : m_children) {
        child->Emitt();
    }
}

void ParticleSystem::Emitt() {
    for (auto& el : subsystems) {
        el->Emitt();
    }
}
