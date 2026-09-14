#include "Utils/Logging.h"
#include "WPPuppet.hpp"

#include <algorithm>
#include <cmath>

using namespace wallpaper;
using namespace Eigen;

static Quaterniond ToQuaternion(Vector3f euler) {
    const std::array<Vector3d, 3> axis { Vector3d::UnitX(), Vector3d::UnitY(), Vector3d::UnitZ() };
    return AngleAxis<double>(euler.z(), axis[2]) * AngleAxis<double>(euler.y(), axis[1]) *
           AngleAxis<double>(euler.x(), axis[0]);
};

static bool HasValidBindParentIndex(const WPPuppet::Bone& bone, uint index)
{
    return bone.bind_parent == WPPuppet::Bone::NO_PARENT || bone.bind_parent < index;
}

void WPPuppet::prepared() {
    for (uint i = 0; i < bones.size(); i++) {
        auto& b = bones[i];
        if (! HasValidBindParentIndex(b, i)) {
            // Local safety adapter: upstream asserts this invariant. Some
            // malformed workshop assets previously crashed here; keep the
            // puppet usable by rooting only the invalid bind branch.
            LOG_ERROR("puppet invalid bind parent index %u for bone %u", b.bind_parent, i);
            b.bind_parent = WPPuppet::Bone::NO_PARENT;
            b.parent      = WPPuppet::Bone::NO_PARENT;
            b.world_bind  = b.local_bind;
        } else {
            if (b.noBindParent()) {
                b.world_bind = b.local_bind;
                if (world_anchored_bones) {
                    b.world_bind.pretranslate(b.vertex_centroid_offset);
                }
            } else {
                b.world_bind = bones[b.bind_parent].world_bind * b.local_bind;
            }
        }

        b.inv_bind = b.world_bind.inverse();
    }
    for (auto& anim : anims) {
        anim.frame_time = 1.0f / anim.fps;
        anim.max_time   = anim.length / anim.fps;
        for (auto& track : anim.bone_tracks) {
            for (auto& f : track.frames) {
                f.quaternion = ToQuaternion(f.angle);
            }
        }
    }

    m_final_affines.resize(bones.size());
}

std::span<const Eigen::Affine3f> WPPuppet::genFrame(WPPuppetLayer& puppet_layer,
                                                    double         time) noexcept {
    double global_blend = puppet_layer.m_global_blend;

    puppet_layer.updateInterpolation(time);

    // TRS skinning is required: WE puppets animate scale (e.g. blink uses
    // frame.scale.y -> ~0). A pure-translation g_Bones would shift the whole
    // sprite as a unit; intra-sprite compression needs non-identity linear so
    // vertices within the sprite get differential treatment.
    for (uint i = 0; i < m_final_affines.size(); i++) {
        const auto& bone   = bones[i];
        auto&       affine = m_final_affines[i];

        // Local safety adapter: upstream asserts anim_parent ordering. Invalid
        // asset data can otherwise index outside m_final_affines and crash.
        const bool has_valid_anim_parent = ! bone.noAnimParent() && bone.anim_parent < i;
        if (!bone.noAnimParent() && !has_valid_anim_parent) {
            LOG_ERROR("puppet invalid anim parent index %u for bone %u", bone.anim_parent, i);
        }
        const Affine3f parent =
            has_valid_anim_parent ? m_final_affines[bone.anim_parent] : Affine3f::Identity();

        // Bind state. vco is a fixed render-time pivot offset for root sprite
        // bones and is added to trans after layer blending below.
        Vector3f    trans { bone.local_bind.translation() * global_blend };
        Vector3f    scale { Vector3f::Ones() * global_blend };
        Quaterniond quat { bone.local_bind.linear().cast<double>() };
        const Quaterniond ident { Quaterniond::Identity() };

        for (auto& layer : puppet_layer.m_layers) {
            auto& alayer = layer.anim_layer;
            if (layer.anim == nullptr || ! alayer.visible) continue;
            if (i >= layer.anim->bone_tracks.size()) continue;
            // Local safety adapter: upstream assumes valid MDLA tracks. Keep
            // empty or truncated tracks from dereferencing frame[0]/frame_b.
            if (layer.anim->bone_tracks[i].frames.empty()) continue;
            auto& info = layer.interp_info;
            if (static_cast<usize>(info.frame_a) >= layer.anim->bone_tracks[i].frames.size() ||
                static_cast<usize>(info.frame_b) >= layer.anim->bone_tracks[i].frames.size()) {
                continue;
            }

            const auto base_frame = (alayer.additive && layer.anim->mode == WPPuppet::PlayMode::Single)
                ? layer.anim->bone_tracks[i].frames.size() - 1
                : 0u;
            auto& frame_base = layer.anim->bone_tracks[i].frames[base_frame];
            auto& frame_a    = layer.anim->bone_tracks[i].frames[(usize)info.frame_a];
            auto& frame_b    = layer.anim->bone_tracks[i].frames[(usize)info.frame_b];

            double t = info.t;
            double one_t   = 1.0f - info.t;

            auto frame_a_quat_delta = frame_a.quaternion * frame_base.quaternion.conjugate();
            auto frame_b_quat_delta = frame_b.quaternion * frame_base.quaternion.conjugate();
            auto pos_a_delta   = frame_a.position - frame_base.position;
            auto pos_b_delta   = frame_b.position - frame_base.position;
            auto scale_a_delta = frame_a.scale - frame_base.scale;
            auto scale_b_delta = frame_b.scale - frame_base.scale;

            quat *= frame_a_quat_delta.slerp(t, frame_b_quat_delta)
                        .slerp(1.0 - alayer.blend, ident);
            if (alayer.additive) {
                trans += alayer.blend * (pos_a_delta * one_t + pos_b_delta * t);
                scale += alayer.blend * (scale_a_delta * one_t + scale_b_delta * t);
            } else {
                trans += (layer.blend * frame_base.position) +
                         (alayer.blend * (pos_a_delta * one_t + pos_b_delta * t));
                scale += (layer.blend * frame_base.scale) +
                         (alayer.blend * (scale_a_delta * one_t + scale_b_delta * t));
            }
        }
        if (bone.noBindParent() && world_anchored_bones) {
            trans += bone.vertex_centroid_offset;
        }
        affine = Affine3f::Identity();
        affine.pretranslate(trans);
        affine.rotate(quat.cast<float>());
        affine.scale(scale);
        affine = parent * affine;
    }

    for (uint i = 0; i < m_final_affines.size(); i++) {
        m_final_affines[i] *= bones[i].inv_bind.matrix();
    }
    return m_final_affines;
}

static constexpr void genInterpolationInfo(WPPuppet::Animation::InterpolationInfo& info,
                                           double& cur, u32 length, double frame_time,
                                           double max_time) {
    // Local safety adapter: upstream assumes positive animation timing. A
    // zero-length/zero-fps track should hold bind pose, not divide by zero.
    if (length == 0 || frame_time <= 0.0 || max_time <= 0.0) {
        info.frame_a = 0;
        info.frame_b = 0;
        info.t = 0.0;
        return;
    }
    cur          = std::fmod(cur, max_time);
    double _rate = cur / frame_time;

    // `length` is the number of intervals; tracks store length + 1 samples.
    // frame_b = frame_a + 1 is therefore in range for valid MDLA tracks.
    info.frame_a = ((uint)_rate) % length;
    info.frame_b = info.frame_a + 1;
    info.t       = _rate - (double)info.frame_a;
}

static constexpr void genSingleInterpolationInfo(WPPuppet::Animation::InterpolationInfo& info,
                                                 double& cur, u32 length, double frame_time,
                                                 double max_time) {
    // Local safety adapter: upstream assumes positive animation timing. A
    // zero-length/zero-fps track should hold bind pose, not divide by zero.
    if (length == 0 || frame_time <= 0.0 || max_time <= 0.0) {
        info.frame_a = 0;
        info.frame_b = 0;
        info.t = 0.0;
        return;
    }
    if (cur >= max_time) {
        cur = max_time;
        info.frame_a = length;
        info.frame_b = length;
        info.t = 0.0;
        return;
    }
    if (cur < 0.0) cur = 0.0;
    double _rate = cur / frame_time;

    info.frame_a = (uint)_rate;
    info.frame_b = info.frame_a + 1;
    info.t       = _rate - (double)info.frame_a;
}

WPPuppet::Animation::InterpolationInfo
WPPuppet::Animation::getInterpolationInfo(double* cur_time) const {
    InterpolationInfo _info;
    auto&             _cur_time = *cur_time;

    if (mode == PlayMode::Loop) {
        genInterpolationInfo(_info, _cur_time, (u32)length, frame_time, max_time);
    } else if (mode == PlayMode::Single) {
        genSingleInterpolationInfo(_info, _cur_time, (u32)length, frame_time, max_time);
    } else if (mode == PlayMode::Mirror) {
        const auto _get_frame = [this](auto f) -> idx {
            return f <= length ? f : (2 * length - f);
        };
        genInterpolationInfo(_info, _cur_time, (u32)length * 2, frame_time, max_time * 2.0f);
        _info.frame_a = _get_frame(_info.frame_a);
        _info.frame_b = _get_frame(_info.frame_b);
    }

    return _info;
}

void WPPuppetLayer::prepared(std::span<AnimationLayer> alayers) {
    m_layers.resize(alayers.size());
    double& blend = m_global_blend;
    double& total_blend = m_total_blend;

    total_blend = 0.0;
    const auto& anims = m_puppet->anims;
    for (int i = 0; i < alayers.size(); i++) {
        if (! alayers[i].visible || alayers[i].additive) continue;
        bool exists = std::any_of(anims.begin(), anims.end(), [&](const auto& a) {
            return a.id == alayers[i].id;
        });
        if (exists) total_blend += alayers[i].blend;
    }

    std::transform(
        alayers.rbegin(), alayers.rend(), m_layers.rbegin(), [&blend, this](const auto& layer) {
            double      cur_blend { 0.0f };
            const auto& anims = m_puppet->anims;

            auto it = std::find_if(anims.begin(), anims.end(), [&layer](auto& a) {
                return layer.id == a.id;
            });
            bool ok = it != anims.end() && layer.visible;

            double &total_blend = m_total_blend;

            if (ok) {
                if (layer.additive) {
                    cur_blend = layer.blend;
                }
                else if (total_blend > 1.0)
                {
                    cur_blend = layer.blend / total_blend;
                    blend = 0.0;
                }
                else
                {
                    cur_blend = blend * layer.blend;
                    blend *= 1.0f - layer.blend;
                    blend = blend < 0.0f ? 0.0f : blend;
                }
            }

            return Layer {
                .anim_layer = layer,
                .blend      = cur_blend,
                .anim       = ok ? std::addressof(*it) : nullptr,
            };
        });
}

std::span<const Eigen::Affine3f> WPPuppetLayer::genFrame(double time) noexcept {
    return m_puppet->genFrame(*this, time);
}

void WPPuppetLayer::updateInterpolation(double time) noexcept {
    double delta = (m_last_elapsed < 0.0) ? 0.0 : (time - m_last_elapsed);
    bool advance = (m_last_elapsed < 0.0) || (delta > 0.0);
    if (advance) m_last_elapsed = time;
    for (auto& layer : m_layers) {
        if (layer) {
            if (advance) layer.anim_layer.cur_time += delta * layer.anim_layer.rate;
            layer.interp_info = layer.anim->getInterpolationInfo(&(layer.anim_layer.cur_time));
        }
    }
}

WPPuppetLayer::WPPuppetLayer(std::shared_ptr<WPPuppet> pup): m_puppet(pup) {}
WPPuppetLayer::WPPuppetLayer()  = default;
WPPuppetLayer::~WPPuppetLayer() = default;
