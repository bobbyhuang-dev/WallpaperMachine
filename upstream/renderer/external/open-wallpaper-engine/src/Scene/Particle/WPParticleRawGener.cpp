#include "WPParticleRawGener.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <vector>

#include <Eigen/Dense>

#include "Core/Literals.hpp"
#include "SpecTexs.hpp"
#include "ParticleModify.h"
#include "ParticleSystem.h"

#include "Utils/Logging.h"

using namespace wallpaper;
using namespace Eigen;

struct WPGOption {
    bool thick_format { false };
    bool geometry_shader { false };
};

namespace
{
inline void AssignVertexTimes(std::span<float> dst, std::span<const float> src, uint num) noexcept {
    const uint dst_one_size = dst.size() / num;
    for (uint i = 0; i < num; i++) {
        std::copy(src.begin(), src.end(), dst.begin() + i * dst_one_size);
    }
}

inline void AssignVertex(std::span<float> dst, std::span<const float> src, uint num) noexcept {
    const uint dst_one_size = dst.size() / num;
    const uint src_one_size = src.size() / num;
    for (uint i = 0; i < num; i++) {
        std::copy_n(src.begin() + i * src_one_size, src_one_size, dst.begin() + i * dst_one_size);
    }
}

inline usize GenParticleData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                             const ParticleRawGenSpecOp& specOp, WPGOption opt,
                             SceneVertexArray& sv,
                             ParticleRenderScale render_scale) noexcept {
    std::array<float, 32 * 4> storage;

    float* data = storage.data();

    const auto one_size   = sv.OneSize();
    const auto totle_size = 4 * one_size;
    usize      i { 0 };
    for (const auto& inst : instances) {
        if (inst->IsNoLiveParticle()) continue;

        for (const auto& p : inst->Particles()) {
            if (! ParticleModify::LifetimeOk(p)) {
                continue;
            }

            float lifetime = p.lifetime;
            specOp(p, { &lifetime });

            auto pos = inst->GetBoundedData().pos + p.position;
            // The generic particle ABI exposes one scalar ParticleSize in
            // a_TexCoordVec4.w, so nonuniform owner scale cannot be undone per
            // billboard axis without changing the shader/vertex contract.
            // Use the isotropic value derived from effective X/Y column norms;
            // inverse_x/y are carried for generators that can represent them.
            float size = (p.size / 2.0f) * render_scale.isotropic_inverse;

            usize offset = 0;

            // pos
            AssignVertexTimes(
                { data + offset, totle_size }, std::array { pos[0], pos[1], pos[2] }, 4);
            offset += 4;
            // TexCoordVec4
            float      rz = p.rotation[2];
            std::array t { 0.0f, 1.0f, rz, size, 1.0f, 1.0f, rz, size,
                           1.0f, 0.0f, rz, size, 0.0f, 0.0f, rz, size };
            AssignVertex({ data + offset, totle_size }, t, 4);
            offset += 4;

            // color
            AssignVertexTimes({ data + offset, totle_size },
                              std::array { p.color[0], p.color[1], p.color[2], p.alpha },
                              4);
            offset += 4;

            if (opt.thick_format) {
                AssignVertexTimes(
                    { data + offset, totle_size },
                    std::array { p.velocity[0], p.velocity[1], p.velocity[2], lifetime },
                    4);
                offset += 4;
            }
            // TexCoordC2
            AssignVertexTimes(
                { data + offset, totle_size }, std::array { p.rotation[0], p.rotation[1] }, 4);

            sv.SetVertexs((i++) * 4, { data, totle_size });
        }
    }
    return i;
}

struct RopePoint {
    Eigen::Vector3f position;
    Eigen::Vector3f color;
    float           alpha;
    float           half_size;
};

inline Eigen::Vector3f CatmullRom(const Eigen::Vector3f& p0, const Eigen::Vector3f& p1,
                                  const Eigen::Vector3f& p2, const Eigen::Vector3f& p3, float t) {
    const float t2 = t * t;
    const float t3 = t2 * t;
    return 0.5f * (2.0f * p1 + (-p0 + p2) * t + (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t2 +
                   (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t3);
}

inline void WriteRopeQuad(SceneVertexArray& sv, usize quad_index, bool thick, const RopePoint& a,
                          const RopePoint& b, const Eigen::Vector3f& tangent_a,
                          const Eigen::Vector3f& tangent_b, float trail_length,
                          float trail_position) {
    const usize               one_size = sv.OneSize();
    std::array<float, 32 * 4> buffer {};
    // Shader start tangent = (end - start) + (start - cp0); end tangent =
    // (end - start) - (end - cp1). These cps make those equal tangent_a / tangent_b.
    const Vector3f            cp0 = b.position - tangent_a;
    const Vector3f            cp1 = a.position + tangent_b;
    constexpr float           uv[4][2] { { 0.0f, 1.0f }, { 1.0f, 1.0f }, { 1.0f, 0.0f }, { 0.0f, 0.0f } };

    for (usize v = 0; v < 4; ++v) {
        float* d = buffer.data() + v * one_size;
        d[0]     = a.position[0];
        d[1]     = a.position[1];
        d[2]     = a.position[2];
        d[3]     = a.half_size;
        d[4]     = b.position[0];
        d[5]     = b.position[1];
        d[6]     = b.position[2];
        d[7]     = trail_length;
        d[8]     = cp0[0];
        d[9]     = cp0[1];
        d[10]    = cp0[2];
        d[11]    = trail_position;
        if (thick) {
            d[12] = cp1[0];
            d[13] = cp1[1];
            d[14] = cp1[2];
            d[15] = b.half_size;
            d[16] = b.color[0];
            d[17] = b.color[1];
            d[18] = b.color[2];
            d[19] = b.alpha;
            d[20] = uv[v][0];
            d[21] = uv[v][1];
            d[22] = 0.0f;
            d[23] = 0.0f;
            d[24] = a.color[0];
            d[25] = a.color[1];
            d[26] = a.color[2];
            d[27] = a.alpha;
        } else {
            d[12] = cp1[0];
            d[13] = cp1[1];
            d[14] = cp1[2];
            d[15] = 0.0f;
            d[16] = uv[v][0];
            d[17] = uv[v][1];
            d[18] = 0.0f;
            d[19] = 0.0f;
            d[20] = a.color[0];
            d[21] = a.color[1];
            d[22] = a.color[2];
            d[23] = a.alpha;
        }
    }
    sv.SetVertexs(quad_index * 4, { buffer.data(), one_size * 4 });
}

inline void EmitRopeStrip(SceneVertexArray& sv, bool thick, std::span<const RopePoint> points,
                          float trail_length, usize& quad, usize quad_capacity) {
    const usize n = points.size();
    if (n < 2) return;

    auto tangent_at = [&](usize i) -> Vector3f {
        if (i == 0) return points[1].position - points[0].position;
        if (i + 1 == n) return points[i].position - points[i - 1].position;
        return points[i + 1].position - points[i - 1].position;
    };

    for (usize m = 0; m + 1 < n; ++m) {
        const RopePoint& a     = points[m];
        const RopePoint& b     = points[m + 1];
        const Vector3f   delta = b.position - a.position;
        if (delta.norm() < 1e-6f) continue;

        Vector3f ta = tangent_at(m);
        Vector3f tb = tangent_at(m + 1);
        if (ta.norm() < 1e-6f) ta = delta;
        if (tb.norm() < 1e-6f) tb = delta;

        if (quad >= quad_capacity) {
            LOG_ERROR("rope geometry exceeds mesh capacity: %zu quads, capacity %zu", quad,
                      quad_capacity);
            return;
        }
        WriteRopeQuad(sv, quad, thick, a, b, ta, tb, trail_length, static_cast<float>(m));
        ++quad;
    }
}

inline usize GenRopeData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                         WPGOption opt, SceneVertexArray& sv, ParticleRenderScale render_scale) {
    std::vector<RopePoint> live;
    std::vector<RopePoint> rope;
    const usize            quad_capacity = sv.CapacitySize() / (sv.OneSize() * 4);
    usize                  quad { 0 };
    const bool             thick = opt.thick_format;

    for (const auto& inst : instances) {
        if (inst->IsNoLiveParticle()) continue;

        live.clear();
        const Vector3f origin = inst->GetBoundedData().pos;
        for (const auto& p : inst->Particles()) {
            if (! ParticleModify::LifetimeOk(p)) continue;
            live.push_back(RopePoint { origin + p.position, p.color, p.alpha,
                                       (p.size / 2.0f) * render_scale.isotropic_inverse });
        }
        if (live.size() < 2) continue;

        const uint32_t s = std::max<uint32_t>(1, render_scale.rope_subdivision);
        if (s == 1) {
            EmitRopeStrip(sv, thick, live, static_cast<float>(live.size()), quad, quad_capacity);
        } else {
            const usize n = live.size();
            rope.clear();
            rope.reserve((n - 1) * s + 1);
            for (usize j = 0; j + 1 < n; ++j) {
                const RopePoint& p0 = live[j == 0 ? 0 : j - 1];
                const RopePoint& p1 = live[j];
                const RopePoint& p2 = live[j + 1];
                const RopePoint& p3 = live[j + 2 >= n ? n - 1 : j + 2];
                for (uint32_t q = 0; q < s; ++q) {
                    const float t = static_cast<float>(q) / static_cast<float>(s);
                    rope.push_back(RopePoint {
                        CatmullRom(p0.position, p1.position, p2.position, p3.position, t),
                        p1.color + (p2.color - p1.color) * t, p1.alpha + (p2.alpha - p1.alpha) * t,
                        p1.half_size + (p2.half_size - p1.half_size) * t });
                }
            }
            rope.push_back(live.back());
            EmitRopeStrip(sv, thick, rope, static_cast<float>(rope.size()), quad, quad_capacity);
        }
        if (quad >= quad_capacity) return quad;
    }
    return quad;
}

inline usize GenRopeTrailData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                              WPGOption opt, SceneVertexArray& sv,
                              ParticleRenderScale render_scale) {
    std::vector<RopePoint> points;
    const usize            quad_capacity = sv.CapacitySize() / (sv.OneSize() * 4);
    usize                  quad { 0 };
    const bool             thick = opt.thick_format;

    for (const auto& inst : instances) {
        if (inst->IsNoLiveParticle()) continue;

        const auto     trails = inst->Trails();
        const Vector3f origin = inst->GetBoundedData().pos;
        usize          i { 0 };
        for (const auto& p : inst->Particles()) {
            if (! ParticleModify::LifetimeOk(p) || i >= trails.size() || trails[i].Count() == 0) {
                ++i;
                continue;
            }

            const uint32_t h         = trails[i].Count();
            const float    half_size = (p.size / 2.0f) * render_scale.isotropic_inverse;
            points.clear();
            points.push_back(RopePoint { origin + p.position, p.color, p.alpha, half_size });
            for (uint32_t j = 1; j <= h; ++j) {
                points.push_back(
                    RopePoint { trails[i].At(j - 1).position, p.color, p.alpha, half_size });
            }
            if (h == trails[i].Capacity() && h >= 2) {
                const float t = std::clamp(render_scale.trail_fraction, 0.0f, 1.0f);
                RopePoint&  last = points.back();
                const RopePoint& previous = points[points.size() - 2];
                last.position = last.position + (previous.position - last.position) * t;
            }
            EmitRopeStrip(sv, thick, points, static_cast<float>(h), quad, quad_capacity);
            if (quad >= quad_capacity) return quad;
            ++i;
        }
    }
    return quad;
}

inline void updateIndexArray(uint16_t index, size_t count, SceneIndexArray& iarray) noexcept {
    constexpr size_t single_size = 6;
    const uint16_t   cv          = index * 4;

    std::array<uint16_t, single_size> single;
    // 0 1 3
    // 1 2 3
    single[0] = cv;
    single[1] = cv + 1;
    single[2] = cv + 3;
    single[3] = cv + 1;
    single[4] = cv + 2;
    single[5] = cv + 3;
    // every particle
    for (uint16_t i = index; i < count; i++) {
        iarray.AssignHalf(i * single_size, single);
        for (auto& x : single) x += 4;
    }
}
} // namespace

void WPParticleRawGener::GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                                   SceneMesh& mesh, ParticleRawGenSpecOp& specOp,
                                   ParticleRenderScale render_scale) {
    auto& sv = mesh.GetVertexArray(0);
    auto& si = mesh.GetIndexArray(0);

    WPGOption opt;

    opt.thick_format = sv.GetOption(WE_CB_THICK_FORMAT);

    usize particle_num { 0 };
    const usize expected_rope = opt.thick_format ? 28u : 24u;

    if (sv.GetOption(WE_PRENDER_ROPE) && sv.OneSize() != expected_rope) {
        LOG_ERROR("rope vertex one_size %zu, expected %zu", sv.OneSize(), expected_rope);
    } else if (sv.GetOption(WE_PRENDER_ROPETRAIL)) {
        particle_num = GenRopeTrailData(instances, opt, sv, render_scale);
    } else if (sv.GetOption(WE_PRENDER_ROPE)) {
        particle_num = GenRopeData(instances, opt, sv, render_scale);
    } else {
        particle_num += GenParticleData(instances, specOp, opt, sv, render_scale);
    }

    u16 indexNum = (si.DataCount() * 2) / 6;
    if (particle_num > indexNum) {
        updateIndexArray(indexNum, particle_num, si);
    }
    si.SetRenderDataCount(particle_num * 6 / 2);
}
