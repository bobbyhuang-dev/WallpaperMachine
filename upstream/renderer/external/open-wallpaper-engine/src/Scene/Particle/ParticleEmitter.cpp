#include "ParticleEmitter.h"
#include "ParticleModify.h"
#include "Utils/Algorism.h"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Core/Random.hpp"

#include <Eigen/src/Core/Matrix.h>
#include <random>
#include <array>
#include <tuple>
#include <cmath>

using namespace wallpaper;

typedef std::function<Particle()> GenParticleOp;
typedef std::function<Particle()> SpwanOp;

namespace
{

inline std::tuple<u32, bool> FindLastParticle(std::span<const Particle> ps, u32 last) {
    for (u32 i = last; i < ps.size(); i++) {
        if (! ParticleModify::LifetimeOk(ps[i])) return { i, true };
    }
    return { 0, false };
}

inline u32 GetEmitNum(double& timer, double speed) {
    if (speed <= 0.0) return 0;
    const double emitDur = 1.0 / speed;
    if (emitDur > timer) return 0;
    u32 num = static_cast<u32>((timer / emitDur) + 1.0e-9);
    timer -= static_cast<double>(num) * emitDur;
    if (timer < 1.0e-9) timer = 0;
    return num;
}

inline u32 Emitt(std::vector<Particle>& particles, u32 num, u32 maxcount, bool sort,
                 SpwanOp Spwan) {
    u32  lastPartcle = 0;
    bool has_dead    = true;
    u32  i           = 0;

    for (i = 0; i < num; i++) {
        if (has_dead) {
            auto [r1, r2] = FindLastParticle(particles, lastPartcle);
            lastPartcle   = r1;
            has_dead      = r2;
        }
        if (has_dead) {
            particles[lastPartcle] = Spwan();

        } else {
            if (maxcount == particles.size()) break;
            particles.push_back(Spwan());
        }
    }

    if (sort) {
        // old << new << dead
        std::stable_sort(particles.begin(), particles.end(), [](const auto& a, const auto& b) {
            bool l_a = ParticleModify::LifetimeOk(a);
            bool l_b = ParticleModify::LifetimeOk(b);

            return (l_a && ! l_b) ||
                   (l_a && l_b && ! ParticleModify::IsNew(a) && ParticleModify::IsNew(b));
        });
    }

    return i + 1;
}

inline Particle Spwan(GenParticleOp gen, std::vector<ParticleInitOp>& inis, double duration) {
    auto particle = gen();
    for (auto& el : inis) el(particle, duration);
    return particle;
}

inline void ApplySign(Eigen::Vector3d& p, int32_t x, int32_t y, int32_t z) noexcept {
    if (x != 0) {
        p.x() = std::abs(p.x()) * (float)x;
    }
    if (y != 0) {
        p.y() = std::abs(p.y()) * (float)y;
    }
    if (z != 0) {
        p.z() = std::abs(p.z()) * (float)z;
    }
}

inline Eigen::Vector3d ResolveEmitterOrigin(std::span<const ParticleControlpoint> cps, i32 cp_index,
                                            const std::array<float, 3>& authored) {
    Eigen::Vector3d origin {
        static_cast<double>(authored[0]),
        static_cast<double>(authored[1]),
        static_cast<double>(authored[2]),
    };
    if (cp_index >= 0 && static_cast<std::size_t>(cp_index) < cps.size()) {
        origin += cps[static_cast<std::size_t>(cp_index)].offset;
    }
    return origin;
}

inline float ResolveMultiplier(const std::shared_ptr<const float>& multiplier) {
    if (multiplier == nullptr) return 1.0f;
    return std::max(0.0f, *multiplier);
}
} // namespace

ParticleEmittOp ParticleBoxEmitterArgs::MakeEmittOp(ParticleBoxEmitterArgs a) {
    double timer { 0.0f };
    return [a, timer](std::vector<Particle>&       ps,
                      std::vector<ParticleInitOp>& inis,
                      u32                          maxcount,
                      double                       timepass,
                      std::span<const ParticleControlpoint>
                          controlpoints) mutable {
        timer += timepass;
        const Eigen::Vector3d origin = ResolveEmitterOrigin(controlpoints, a.controlpoint, a.orgin);
        auto                  GenBox = [&]() {
            Eigen::Vector3d pos;
            for (int32_t i = 0; i < 3; i++)
                pos[i] = algorism::lerp(Random::get(-1.0, 1.0), a.minDistance[i], a.maxDistance[i]);
            auto p = Particle();
            pos = pos.cwiseProduct(Eigen::Vector3f { a.directions.data() }.cast<double>());
            ParticleModify::MoveTo(p, pos);
            ParticleModify::ChangeVelocity(p,
                                           Random::get(a.minSpeed, a.maxSpeed) * pos.normalized());

            ParticleModify::Move(p, origin);
            return p;
        };
        const float count_multiplier = ResolveMultiplier(a.countMultiplier);
        u32 emit_num = GetEmitNum(timer, a.emitSpeed * count_multiplier);
        emit_num     = a.one_per_frame ? 1 : emit_num;
        emit_num     = a.instantaneous > 0 && ps.empty()
                       ? static_cast<u32>(std::ceil(static_cast<float>(a.instantaneous) *
                                                    count_multiplier))
                       : emit_num;
        Emitt(ps, emit_num, maxcount, a.sort, [&]() {
            return Spwan(GenBox, inis, a.emitSpeed > 0.0f ? 1.0f / a.emitSpeed : 0.0f);
        });
    };
}

ParticleEmittOp ParticleSphereEmitterArgs::MakeEmittOp(ParticleSphereEmitterArgs a) {
    using namespace Eigen;
    double timer { 0.0f };
    return [a, timer](std::vector<Particle>&       ps,
                      std::vector<ParticleInitOp>& inis,
                      u32                          maxcount,
                      double                       timepass,
                      std::span<const ParticleControlpoint>
                          controlpoints) mutable {
        timer += timepass;
        const Eigen::Vector3d origin = ResolveEmitterOrigin(controlpoints, a.controlpoint, a.orgin);
        auto                  GenSphere = [&]() {
            auto   p = Particle();
            double r = algorism::lerp(
                std::pow(Random::get(0.0, 1.0), 1.0 / 3.0), a.minDistance, a.maxDistance);
            Eigen::Vector3d sp = r * algorism::GenSphereSurfaceNormal(
                                         [](double u, double o) {
                                             return Random::get<std::normal_distribution<>>(u, o);
                                         },
                                         Eigen::Vector3f { a.directions.data() }.cast<double>());
            ApplySign(sp, a.sign[0], a.sign[1], a.sign[2]);

            ParticleModify::MoveTo(p, sp);
            ParticleModify::ChangeVelocity(p,
                                           Random::get(a.minSpeed, a.maxSpeed) * sp.normalized());

            ParticleModify::Move(p, origin);
            return p;
        };
        const float count_multiplier = ResolveMultiplier(a.countMultiplier);
        u32 emit_num = GetEmitNum(timer, a.emitSpeed * count_multiplier);
        emit_num     = a.one_per_frame ? 1 : emit_num;
        emit_num     = a.instantaneous > 0 && ps.empty()
                       ? static_cast<u32>(std::ceil(static_cast<float>(a.instantaneous) *
                                                    count_multiplier))
                       : emit_num;
        Emitt(ps, emit_num, maxcount, a.sort, [&]() {
            return Spwan(GenSphere, inis, a.emitSpeed > 0.0f ? 1.0f / a.emitSpeed : 0.0f);
        });
    };
}
