#include "WPMdlParser.hpp"
#include "Fs/VFS.h"
#include "Fs/IBinaryStream.h"
#include "Fs/MemBinaryStream.h"
#include "WPCommon.hpp"
#include "Utils/Logging.h"
#include "Scene/SceneMesh.h"
#include "SpecTexs.hpp"
#include "wpscene/WPMaterial.h"
#include "WPShaderParser.hpp"

#include <cstring>
#include <cstdlib>
#include <functional>

using namespace wallpaper;

namespace
{
constexpr uint32_t kIndexTriangleBytes = 2 * 3;
constexpr uint32_t kSingleBoneFrameBytes = 4 * 9;
constexpr uint32_t kMaxMdlMeshes       = 64;
constexpr uint32_t kMaxMdlVertices     = 1'000'000;
constexpr uint32_t kMaxMdlTriangles    = 2'000'000;
constexpr uint32_t kMaxMdlParts        = 1'000'000;
constexpr uint32_t kMaxMdlMasks        = 16'384;
constexpr uint32_t kMaxMdlMaskParts    = 1'000'000;
constexpr uint32_t kMaxMdlaAnimations  = 4'096;
constexpr uint32_t kMaxMdlaBoneTracks  = 4'096;
constexpr uint32_t kMaxMdlaCurveFloats = 1'000'000;
constexpr uint32_t kMaxMdlaV4Events    = 65'536;
constexpr uint32_t kMaxMdlaEvents      = 65'536;
constexpr std::string_view kPuppetMaskRenderTarget = "_rt_puppet_mask";
constexpr uint32_t mdat_attachment_data_byte_length = 64;
constexpr uint32_t MDL_FLAG_NORMAL      = 0x00000002;
constexpr uint32_t MDL_FLAG_TANGENT     = 0x00000004;
constexpr uint32_t MDL_FLAG_UV          = 0x00000008;
constexpr uint32_t MDL_FLAG_UV2         = 0x00000020;
constexpr uint32_t MDL_FLAG_EXTRA4      = 0x00010000;
constexpr uint32_t MDL_FLAG_SKIN_BLEND  = 0x00800000;
constexpr uint32_t MDL_FLAG_SKIN_WEIGHT = 0x01000000;

WPPuppet::PlayMode ToPlayMode(std::string_view m) {
    if (m == "loop" || m.empty()) return WPPuppet::PlayMode::Loop;
    if (m == "mirror") return WPPuppet::PlayMode::Mirror;
    if (m == "single") return WPPuppet::PlayMode::Single;

    LOG_INFO("unknown puppet animation play mode \"%s\"", m.data());
    assert(m == "loop");
    return WPPuppet::PlayMode::Loop;
}

bool PeekBlockMagic(fs::MemBinaryStream& f, std::string_view expect4) {
    if (expect4.size() != 4) return false;
    const auto save = f.Tell();
    if (save + 4 > f.Size()) return false;
    char buf[4] {};
    f.Read(buf, 4);
    f.SeekSet(save);
    return std::memcmp(buf, expect4.data(), 4) == 0;
}

bool HasRemaining(const fs::MemBinaryStream& f, uint64_t bytes) {
    const auto pos  = f.Tell();
    const auto size = f.Size();
    return pos >= 0 && size >= pos && bytes <= static_cast<uint64_t>(size - pos);
}

bool ReadCStringBounded(fs::MemBinaryStream& f, std::string& out) {
    out.clear();
    while (HasRemaining(f, 1)) {
        const char c = static_cast<char>(f.ReadUint8());
        if (c == '\0') return true;
        out.push_back(c);
    }
    return false;
}

bool ReadCStringBefore(fs::MemBinaryStream& f, const idx end_offset, std::string& out) {
    out.clear();
    if (end_offset < 0 || end_offset > f.Size()) return false;
    while (f.Tell() < end_offset) {
        const char c = static_cast<char>(f.ReadUint8());
        if (c == '\0') return true;
        out.push_back(c);
    }
    return false;
}

bool ReadCStringInBlock(fs::MemBinaryStream& f, const idx end_offset, std::string& out) {
    return end_offset > 0 ? ReadCStringBefore(f, end_offset, out) : ReadCStringBounded(f, out);
}

bool FitsInBlock(const fs::MemBinaryStream& f, const uint64_t bytes, const idx end_offset) {
    if (! HasRemaining(f, bytes)) return false;
    return end_offset <= 0 || static_cast<uint64_t>(f.Tell()) + bytes <= static_cast<uint64_t>(end_offset);
}

uint64_t RemainingInBlock(const fs::MemBinaryStream& f, const idx end_offset) {
    if (end_offset < f.Tell()) return 0;
    const auto stream_remaining = f.Size() - f.Tell();
    const auto block_remaining  = end_offset - f.Tell();
    return static_cast<uint64_t>(std::min(stream_remaining, block_remaining));
}

bool SeekSetChecked(fs::MemBinaryStream& f, const uint32_t offset) {
    return offset <= static_cast<uint32_t>(f.Size()) && f.SeekSet(static_cast<idx>(offset));
}

std::string ConsumeBlockTag(fs::MemBinaryStream& f) {
    char buf[9] {};
    f.Read(buf, sizeof(buf));
    return std::string(buf, 8);
}

bool ParseVersionFromTag(std::string_view tag, std::string_view prefix, int32_t& version) {
    if (tag.size() < 8 || tag.substr(0, 4) != prefix) return false;
    char* end = nullptr;
    const auto text = std::string(tag.substr(4, 4));
    const long value = std::strtol(text.c_str(), &end, 10);
    if (end == text.c_str()) return false;
    version = static_cast<int32_t>(value);
    return true;
}

uint32_t ComputeVertexStride(uint32_t flag) {
    uint32_t stride = 12;
    if (flag & MDL_FLAG_NORMAL) stride += 12;
    if (flag & MDL_FLAG_TANGENT) stride += 16;
    if (flag & MDL_FLAG_EXTRA4) stride += 4;
    if (flag & MDL_FLAG_SKIN_BLEND) stride += 16;
    if (flag & MDL_FLAG_SKIN_WEIGHT) stride += 16;
    if (flag & (MDL_FLAG_UV | MDL_FLAG_UV2)) stride += 8;
    if (flag & MDL_FLAG_UV2) stride += 8;
    return stride;
}

bool ParseMesh(fs::MemBinaryStream& f, const WPMdl::Header& header, WPMdl::Mesh& mesh,
               std::string_view path) {
    if (! ReadCStringBounded(f, mesh.mat_json_file) || ! HasRemaining(f, 4)) {
        LOG_ERROR("truncated mdl mesh header in %s", std::string(path).c_str());
        return false;
    }
    mesh.flag_a        = f.ReadUint32();
    if (mesh.flag_a == 2) {
        if (! HasRemaining(f, 4)) return false;
        mesh.has_flag_a2_one = (f.ReadUint32() == 1);
    }

    if (header.mdlv >= 17) {
        if (! HasRemaining(f, 24)) return false;
        for (auto& v : mesh.aabb_min) v = f.ReadFloat();
        for (auto& v : mesh.aabb_max) v = f.ReadFloat();
        mesh.has_aabb = true;
    }

    if (! HasRemaining(f, header.mdlv > 14 ? 8 : 4)) return false;
    mesh.flag = header.mdlv > 14 ? f.ReadUint32() : header.mdl_flag;
    const uint32_t vertex_size = f.ReadUint32();
    const uint32_t stride      = ComputeVertexStride(mesh.flag);
    if (stride == 0 || vertex_size % stride != 0) {
        LOG_ERROR("unsupport mdl vertex size %d (flag=0x%X stride=%d) in %s",
                  vertex_size, mesh.flag, stride, std::string(path).c_str());
        return false;
    }

    const uint32_t vertex_num = vertex_size / stride;
    if (vertex_num > kMaxMdlVertices || ! HasRemaining(f, vertex_size)) {
        LOG_ERROR("mdlv%d vertex payload too large or truncated in %s",
                  header.mdlv, std::string(path).c_str());
        return false;
    }
    mesh.positions.resize(vertex_num);
    if (mesh.flag & MDL_FLAG_NORMAL) mesh.normals.resize(vertex_num);
    if (mesh.flag & MDL_FLAG_TANGENT) mesh.tangents.resize(vertex_num);
    if (mesh.flag & MDL_FLAG_EXTRA4) mesh.extra4.resize(vertex_num);
    if (mesh.flag & MDL_FLAG_SKIN_BLEND) mesh.blend_indices.resize(vertex_num);
    if (mesh.flag & MDL_FLAG_SKIN_WEIGHT) mesh.blend_weights.resize(vertex_num);
    if (mesh.flag & (MDL_FLAG_UV | MDL_FLAG_UV2)) mesh.texcoords.resize(vertex_num);
    if (mesh.flag & MDL_FLAG_UV2) mesh.texcoord2.resize(vertex_num);

    for (uint32_t i = 0; i < vertex_num; ++i) {
        for (auto& v : mesh.positions[i]) v = f.ReadFloat();
        if (mesh.flag & MDL_FLAG_NORMAL) {
            for (auto& v : mesh.normals[i]) v = f.ReadFloat();
        }
        if (mesh.flag & MDL_FLAG_TANGENT) {
            for (auto& v : mesh.tangents[i]) v = f.ReadFloat();
        }
        if (mesh.flag & MDL_FLAG_EXTRA4) {
            for (auto& v : mesh.extra4[i]) v = f.ReadUint8();
        }
        if (mesh.flag & MDL_FLAG_SKIN_BLEND) {
            for (auto& v : mesh.blend_indices[i]) v = f.ReadUint32();
        }
        if (mesh.flag & MDL_FLAG_SKIN_WEIGHT) {
            for (auto& v : mesh.blend_weights[i]) v = f.ReadFloat();
        }
        if (mesh.flag & (MDL_FLAG_UV | MDL_FLAG_UV2)) {
            for (auto& v : mesh.texcoords[i]) v = f.ReadFloat();
        }
        if (mesh.flag & MDL_FLAG_UV2) {
            for (auto& v : mesh.texcoord2[i]) v = f.ReadFloat();
        }
    }

    if (! HasRemaining(f, 4)) return false;
    const uint32_t indices_size = f.ReadUint32();
    if (indices_size % kIndexTriangleBytes != 0) {
        LOG_ERROR("unsupport mdl indices size %d in %s", indices_size, std::string(path).c_str());
        return false;
    }
    const uint32_t index_count = indices_size / kIndexTriangleBytes;
    if (index_count > kMaxMdlTriangles || ! HasRemaining(f, indices_size)) {
        LOG_ERROR("mdlv%d index payload too large or truncated in %s",
                  header.mdlv, std::string(path).c_str());
        return false;
    }
    mesh.indices.resize(index_count);
    for (auto& id : mesh.indices) {
        for (auto& v : id) v = f.ReadUint16();
    }

    if (header.mdlv >= 21) {
        if (! HasRemaining(f, 1)) return false;
        const uint8_t extras = f.ReadUint8();
        if (extras == 1) {
            if (! HasRemaining(f, 1)) return false;
            const uint8_t has_payload = f.ReadUint8();
            if (has_payload) {
                if (! HasRemaining(f, 7)) return false;
                (void)f.ReadUint16();
                (void)f.ReadUint8();
                const uint32_t payload_size = f.ReadUint32();
                if (vertex_num > UINT32_MAX / 12u || payload_size != vertex_num * 12u) {
                    LOG_ERROR("mdlv%d parts payload size %d != 12*%d",
                              header.mdlv, payload_size, vertex_num);
                    return false;
                }
                if (! HasRemaining(f, payload_size)) {
                    LOG_ERROR("mdlv%d parts payload truncated in %s",
                              header.mdlv, std::string(path).c_str());
                    return false;
                }
                mesh.part_uv2.resize(vertex_num);
                mesh.part_uv2_pad.resize(vertex_num);
                for (uint32_t i = 0; i < vertex_num; ++i) {
                    for (auto& v : mesh.part_uv2[i]) v = f.ReadFloat();
                    mesh.part_uv2_pad[i] = f.ReadUint32();
                }
            }
        } else if (extras != 0) {
            LOG_ERROR("mdlv%d unhandled parts extras %d", header.mdlv, extras);
            return false;
        }

        if (! HasRemaining(f, 1)) return false;
        const uint8_t has_parts = f.ReadUint8();
        if (has_parts) {
            if (! HasRemaining(f, 4)) return false;
            const uint32_t parts_bytes = f.ReadUint32();
            if (parts_bytes % 16 != 0) {
                LOG_ERROR("mdlv%d parts bytes %u not %% 16 in %s",
                          header.mdlv, parts_bytes, std::string(path).c_str());
                return false;
            }
            const uint32_t part_count = parts_bytes / 16;
            if (part_count > kMaxMdlParts || ! HasRemaining(f, parts_bytes)) {
                LOG_ERROR("mdlv%d parts list too large or truncated in %s",
                          header.mdlv, std::string(path).c_str());
                return false;
            }
            mesh.parts.resize(part_count);
            for (auto& part : mesh.parts) {
                part.id = f.ReadUint32();
                (void)f.ReadUint32();
                part.start = f.ReadUint32();
                part.size = f.ReadUint32();
            }
        }

        if (header.mdlv > 21) {
            if (! HasRemaining(f, 4)) return false;
            const uint32_t mask_count = f.ReadUint32();
            if (mask_count > kMaxMdlMasks) {
                LOG_ERROR("mdlv%d mask count too large in %s",
                          header.mdlv, std::string(path).c_str());
                return false;
            }
            mesh.masks.resize(mask_count);
            for (auto& mask : mesh.masks) {
                if (! HasRemaining(f, 8)) return false;
                mask.leading_a = f.ReadUint32();
                (void)f.ReadUint32();
                if (! ReadCStringBounded(f, mask.mat_json_file)) return false;
                if (! HasRemaining(f, 8)) return false;
                (void)f.ReadUint32();
                const uint32_t a_count = f.ReadUint32();
                if (a_count > kMaxMdlMaskParts ||
                    ! HasRemaining(f, static_cast<uint64_t>(a_count) * sizeof(uint32_t))) {
                    LOG_ERROR("mdlv%d mask part count invalid in %s",
                              header.mdlv, std::string(path).c_str());
                    return false;
                }
                mask.part_ids_a.resize(a_count);
                for (auto& part : mask.part_ids_a) part = f.ReadUint32();

                if (! HasRemaining(f, 4)) return false;
                const uint32_t b_count = f.ReadUint32();
                if (b_count > kMaxMdlMaskParts ||
                    ! HasRemaining(f, static_cast<uint64_t>(b_count) * sizeof(uint32_t))) {
                    LOG_ERROR("mdlv%d mask part count invalid in %s",
                              header.mdlv, std::string(path).c_str());
                    return false;
                }
                mask.part_ids_b.resize(b_count);
                for (auto& part : mask.part_ids_b) part = f.ReadUint32();
            }
        }
    }
    return true;
}

bool ParseMDAT(fs::MemBinaryStream& f, WPMdl& mdl, std::string_view path) {
    if (! HasRemaining(f, 6)) return false;
    const uint32_t end_offset = f.ReadUint32();
    if (end_offset > static_cast<uint32_t>(f.Size()) ||
        static_cast<uint32_t>(f.Tell()) > end_offset) {
        LOG_ERROR("invalid MDAT end offset %d in %s", end_offset, std::string(path).c_str());
        return false;
    }
    const uint16_t num_attachments = f.ReadUint16();
    if (! mdl.puppet) {
        return end_offset == 0 || SeekSetChecked(f, end_offset);
    }
    auto& attachments = mdl.puppet->attachments;
    attachments.resize(num_attachments);
    for (auto& att : attachments) {
        if (! HasRemaining(f, 2) || f.Tell() + 2 > end_offset) return false;
        att.bone_index = f.ReadUint16();
        if (! ReadCStringBefore(f, static_cast<idx>(end_offset), att.name)) return false;
        if (f.Tell() + mdat_attachment_data_byte_length > end_offset) return false;
        att.local_xform = Eigen::Affine3f::Identity();
        for (auto col : att.local_xform.matrix().colwise()) {
            for (auto& v : col) v = f.ReadFloat();
        }
    }
    if (end_offset > 0 && static_cast<uint32_t>(f.Tell()) != end_offset) {
        return SeekSetChecked(f, end_offset);
    }
    return true;
}

bool ParseAnimBoneCurves(fs::MemBinaryStream& f,
                         std::vector<WPPuppet::Animation::BoneFrameCurve>& out,
                         const uint32_t bone_count,
                         const idx end_offset,
                         std::string_view path) {
    if (! HasRemaining(f, 1) || f.Tell() + 1 > end_offset) return false;
    const uint8_t has_curves = f.ReadUint8();
    if (! has_curves) return true;

    out.resize(bone_count);
    for (auto& curve : out) {
        if (! HasRemaining(f, 8) || f.Tell() + 8 > end_offset) return false;
        const uint32_t zero_a = f.ReadUint32();
        if (zero_a != 0) {
            LOG_INFO("BoneFrameCurve zero_a expected 0, got %u in %s",
                     zero_a,
                     std::string(path).c_str());
        }
        const uint32_t byte_size = f.ReadUint32();
        if (byte_size % 4 != 0 || f.Tell() + byte_size > end_offset ||
            ! HasRemaining(f, byte_size)) {
            LOG_ERROR("BoneFrameCurve byte_size %u invalid in %s",
                      byte_size,
                      std::string(path).c_str());
            return false;
        }
        if (byte_size / 4 > kMaxMdlaCurveFloats) {
            LOG_ERROR("BoneFrameCurve float count %u invalid in %s",
                      byte_size / 4,
                      std::string(path).c_str());
            return false;
        }
        curve.values.resize(byte_size / 4);
        for (auto& v : curve.values) v = f.ReadFloat();
    }
    return true;
}

bool ParseAnimation(fs::MemBinaryStream& f, WPPuppet::Animation& anim, const int32_t mdla,
                    const idx end_offset, std::string_view path) {
    if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
    anim.id = f.ReadInt32();
    if (anim.id <= 0) {
        LOG_ERROR("wrong animation id %d in %s", anim.id, std::string(path).c_str());
        return false;
    }
    if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
    anim.unk_after_id = f.ReadUint32();

    if (! ReadCStringBefore(f, end_offset, anim.name)) return false;
    if (anim.name.empty() && ! ReadCStringBefore(f, end_offset, anim.name)) return false;

    std::string mode;
    if (! ReadCStringBefore(f, end_offset, mode)) return false;
    if (! HasRemaining(f, 12) || f.Tell() + 12 > end_offset) return false;
    anim.mode   = ToPlayMode(mode);
    anim.fps    = f.ReadFloat();
    anim.length = f.ReadInt32();
    (void)f.ReadInt32();

    if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
    const uint32_t b_num = f.ReadUint32();
    const uint64_t min_bone_track_bytes = static_cast<uint64_t>(b_num) * 8u;
    if (b_num > kMaxMdlaBoneTracks || min_bone_track_bytes > RemainingInBlock(f, end_offset)) {
        LOG_ERROR("MDLA bone track count %u invalid in %s",
                  b_num,
                  std::string(path).c_str());
        return false;
    }
    anim.bone_tracks.resize(b_num);
    for (uint32_t bone_index = 0; bone_index < b_num; ++bone_index) {
        auto& track = anim.bone_tracks[bone_index];
        track.bone_index = bone_index;
        if (! HasRemaining(f, 8) || f.Tell() + 8 > end_offset) return false;
        track.unk = f.ReadInt32();
        const uint32_t byte_size = f.ReadUint32();
        if (byte_size % kSingleBoneFrameBytes != 0 || f.Tell() + byte_size > end_offset ||
            ! HasRemaining(f, byte_size)) {
            LOG_ERROR("wrong bone frame size %u in %s",
                      byte_size,
                      std::string(path).c_str());
            return false;
        }
        track.frames.resize(byte_size / kSingleBoneFrameBytes);
        for (auto& frame : track.frames) {
            for (auto& v : frame.position) v = f.ReadFloat();
            for (auto& v : frame.angle) v = f.ReadFloat();
            for (auto& v : frame.scale) v = f.ReadFloat();
        }
    }

    if (mdla >= 3) {
        if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
        const uint32_t trans_flag = f.ReadUint32();
        if (trans_flag == 1) {
            auto& trans = anim.trans.emplace();
            if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
            const uint32_t extra_size = f.ReadUint32();
            if (extra_size > 0) {
                if (extra_size % 4 != 0 || f.Tell() + extra_size > end_offset ||
                    ! HasRemaining(f, extra_size)) {
                    LOG_ERROR("UnkAnimTrans extra_size %u invalid in %s",
                              extra_size,
                              std::string(path).c_str());
                    return false;
                }
                if (extra_size / 4 > kMaxMdlaCurveFloats) {
                    LOG_ERROR("UnkAnimTrans extra float count %u invalid in %s",
                              extra_size / 4,
                              std::string(path).c_str());
                    return false;
                }
                trans.extra_track.resize(extra_size / 4);
                for (auto& v : trans.extra_track) v = f.ReadFloat();
                if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
                const uint32_t extra_zero = f.ReadUint32();
                if (extra_zero != 0) {
                    LOG_INFO("UnkAnimTrans extra_zero expected 0, got %u in %s",
                             extra_zero,
                             std::string(path).c_str());
                }
            }
            if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
            const uint32_t main_size = f.ReadUint32();
            if (main_size % 4 != 0 || f.Tell() + main_size > end_offset ||
                ! HasRemaining(f, main_size)) {
                LOG_ERROR("UnkAnimTrans main_size %u invalid in %s",
                          main_size,
                          std::string(path).c_str());
                return false;
            }
            if (main_size / 4 > kMaxMdlaCurveFloats) {
                LOG_ERROR("UnkAnimTrans main float count %u invalid in %s",
                          main_size / 4,
                          std::string(path).c_str());
                return false;
            }
            trans.main_track.resize(main_size / 4);
            for (auto& v : trans.main_track) v = f.ReadFloat();
            if (extra_size > 0) {
                if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
                const uint32_t trail_zero = f.ReadUint32();
                if (trail_zero != 0) {
                    LOG_INFO("UnkAnimTrans trail_zero expected 0, got %u in %s",
                             trail_zero,
                             std::string(path).c_str());
                }
            }
        }
        if (! ParseAnimBoneCurves(f, anim.blend_curves, b_num, end_offset, path)) return false;
    }

    if (mdla >= 4) {
        if (! HasRemaining(f, 1) || f.Tell() + 1 > end_offset) return false;
        const uint8_t has_v4_events = f.ReadUint8();
        if (has_v4_events == 1) {
            if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
            const uint32_t v4_count = f.ReadUint32();
            const uint64_t min_v4_event_bytes = static_cast<uint64_t>(v4_count) * 12u;
            if (v4_count > kMaxMdlaV4Events ||
                min_v4_event_bytes > RemainingInBlock(f, end_offset)) {
                LOG_ERROR("MDLA v4 event count %u invalid in %s",
                          v4_count,
                          std::string(path).c_str());
                return false;
            }
            anim.v4_events.resize(v4_count);
            for (auto& event : anim.v4_events) {
                if (! HasRemaining(f, 12) || f.Tell() + 12 > end_offset) return false;
                event.time = f.ReadFloat();
                event.flags = f.ReadUint32();
                const uint32_t byte_size = f.ReadUint32();
                if (byte_size % 4 != 0 || f.Tell() + byte_size > end_offset ||
                    ! HasRemaining(f, byte_size)) {
                    LOG_ERROR("AnimV4Event byte_size %u invalid in %s",
                              byte_size,
                              std::string(path).c_str());
                    return false;
                }
                if (byte_size / 4 > kMaxMdlaCurveFloats) {
                    LOG_ERROR("AnimV4Event float count %u invalid in %s",
                              byte_size / 4,
                              std::string(path).c_str());
                    return false;
                }
                event.values.resize(byte_size / 4);
                for (auto& v : event.values) v = f.ReadFloat();
            }
        } else if (has_v4_events != 0) {
            LOG_INFO("Animation has_v4_events expected 0/1, got %u in %s",
                     has_v4_events,
                     std::string(path).c_str());
        }
    }

    if (mdla >= 5) {
        if (! HasRemaining(f, 24) || f.Tell() + 24 > end_offset) return false;
        for (auto& v : anim.aabb_min) v = f.ReadFloat();
        for (auto& v : anim.aabb_max) v = f.ReadFloat();
        anim.has_aabb = true;
    }

    if (mdla == 6) {
        if (! ParseAnimBoneCurves(f, anim.scalar_curves, b_num, end_offset, path)) return false;
    }

    if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
    const uint32_t event_count = f.ReadUint32();
    const uint64_t min_event_bytes = static_cast<uint64_t>(event_count) * 5u;
    if (event_count > kMaxMdlaEvents || min_event_bytes > RemainingInBlock(f, end_offset)) {
        LOG_ERROR("MDLA event count %u invalid in %s",
                  event_count,
                  std::string(path).c_str());
        return false;
    }
    anim.events.resize(event_count);
    for (auto& event : anim.events) {
        if (! HasRemaining(f, 4) || f.Tell() + 4 > end_offset) return false;
        event.time_value = f.ReadUint32();
        if (! ReadCStringBefore(f, end_offset, event.event_json)) return false;
    }
    return true;
}

bool ParseMDLA(fs::MemBinaryStream& f, WPMdl& mdl, std::string_view tag,
               std::string_view path) {
    if (! ParseVersionFromTag(tag, "MDLA", mdl.mdla)) return false;
    if (mdl.mdla == 0) return true;
    if (! mdl.puppet) return false;
    if (! HasRemaining(f, 8)) return false;

    const uint32_t end_offset_u = f.ReadUint32();
    const idx end_offset = static_cast<idx>(end_offset_u);
    if (end_offset <= f.Tell() || end_offset > f.Size()) {
        LOG_ERROR("invalid MDLA end offset %u in %s", end_offset_u, std::string(path).c_str());
        return false;
    }
    auto fail_at_end = [&]() {
        if (f.Tell() != end_offset) {
            LOG_INFO("MDLA body ended at 0x%X but end_offset=0x%X (%s)",
                     static_cast<uint32_t>(f.Tell()),
                     end_offset_u,
                     std::string(path).c_str());
            (void)SeekSetChecked(f, end_offset_u);
        }
        return false;
    };

    const uint32_t anim_num = f.ReadUint32();
    const uint64_t min_animation_bytes = static_cast<uint64_t>(anim_num) * 25u;
    if (anim_num > kMaxMdlaAnimations || min_animation_bytes > RemainingInBlock(f, end_offset)) {
        LOG_ERROR("MDLA animation count %u invalid in %s",
                  anim_num,
                  std::string(path).c_str());
        return fail_at_end();
    }
    auto& anims = mdl.puppet->anims;
    anims.resize(anim_num);
    bool ok = true;
    for (auto& anim : anims) {
        if (! ParseAnimation(f, anim, mdl.mdla, end_offset, path)) {
            ok = false;
            break;
        }
    }

    if (f.Tell() != end_offset) {
        LOG_INFO("MDLA body ended at 0x%X but end_offset=0x%X (%s)",
                 static_cast<uint32_t>(f.Tell()),
                 end_offset_u,
                 std::string(path).c_str());
        if (! SeekSetChecked(f, end_offset_u)) return false;
    }
    return ok;
}

bool ParseMDMP(fs::MemBinaryStream& f, WPMdl& mdl, std::string_view tag,
               std::string_view path) {
    if (! ParseVersionFromTag(tag, "MDMP", mdl.mdmp)) return false;
    if (! HasRemaining(f, 4)) return false;

    const uint32_t end_offset_u = f.ReadUint32();
    const idx end_offset = static_cast<idx>(end_offset_u);
    if (end_offset <= f.Tell() || end_offset > f.Size()) {
        LOG_ERROR("invalid MDMP end offset %u in %s", end_offset_u, std::string(path).c_str());
        return false;
    }

    while (f.Tell() < end_offset) {
        if (! FitsInBlock(f, 10, end_offset)) return false;
        auto& sec = mdl.morph_sections.emplace_back();
        const uint16_t count = f.ReadUint16();
        sec.event_time = f.ReadFloat();
        sec.event_id = f.ReadUint16();
        const uint16_t zero_a = f.ReadUint16();
        if (zero_a != 0) {
            LOG_INFO("MDMPSection zero_a expected 0, got %u in %s",
                     zero_a,
                     std::string(path).c_str());
        }

        sec.sections.resize(count);
        for (auto& sd : sec.sections) {
            if (! FitsInBlock(f, 8, end_offset)) return false;
            sd.shape_id = f.ReadUint32();
            const uint32_t sd_zero = f.ReadUint32();
            if (sd_zero != 0) {
                LOG_INFO("MDMPSectionData zero_a expected 0, got %u in %s",
                         sd_zero,
                         std::string(path).c_str());
            }
            if (! ReadCStringBefore(f, end_offset, sd.tag)) return false;
            if (! FitsInBlock(f, 8, end_offset)) return false;
            const uint32_t length = f.ReadUint32();
            sd.hash = f.ReadUint32();
            if (length % 6 != 0) {
                LOG_ERROR("MDMPSectionData length %u not %% 6 in %s",
                          length,
                          std::string(path).c_str());
                return false;
            }

            const uint32_t vcount = length / 6;
            if (! FitsInBlock(f, length, end_offset)) return false;
            sd.vertices.resize(vcount);
            for (auto& v : sd.vertices) {
                for (auto& x : v) x = f.ReadUint16();
            }

            if (sd.shape_id == 0) {
                if (! FitsInBlock(f, length, end_offset)) return false;
                sd.trailer.resize(length);
                for (auto& b : sd.trailer) b = f.ReadUint8();
            } else {
                const uint64_t trailer_bytes = static_cast<uint64_t>(vcount) * sizeof(uint16_t);
                if (! FitsInBlock(f, trailer_bytes, end_offset)) return false;
                sd.vertex_trailers.resize(vcount);
                for (auto& v : sd.vertex_trailers) v = f.ReadUint16();
            }
        }
    }

    if (f.Tell() != end_offset) {
        LOG_INFO("MDMP body ended at 0x%X but end_offset=0x%X (%s)",
                 static_cast<uint32_t>(f.Tell()),
                 end_offset_u,
                 std::string(path).c_str());
        if (! SeekSetChecked(f, end_offset_u)) return false;
    }
    return true;
}

bool ParseMDLE(fs::MemBinaryStream& f, WPMdl& mdl, std::string_view tag,
               std::string_view path) {
    if (! ParseVersionFromTag(tag, "MDLE", mdl.mdle)) return false;
    if (! mdl.puppet || ! HasRemaining(f, 8)) return false;

    const uint32_t end_offset_u = f.ReadUint32();
    const idx end_offset = static_cast<idx>(end_offset_u);
    if (end_offset <= f.Tell() || end_offset > f.Size()) {
        LOG_ERROR("invalid MDLE end offset %u in %s", end_offset_u, std::string(path).c_str());
        return false;
    }

    const uint32_t payload_bytes = f.ReadUint32();
    const uint64_t expected = static_cast<uint64_t>(mdl.puppet->bones.size()) * 16u * 4u;
    if (payload_bytes != expected) {
        LOG_ERROR("MDLE payload_bytes %u != bones_num*64 %llu in %s",
                  payload_bytes,
                  static_cast<unsigned long long>(expected),
                  std::string(path).c_str());
        return false;
    }
    if (! FitsInBlock(f, payload_bytes, end_offset)) return false;

    for (auto& bone : mdl.puppet->bones) {
        bone.file_world_bind = Eigen::Affine3f::Identity();
        for (auto col : bone.file_world_bind.matrix().colwise()) {
            for (auto& v : col) v = f.ReadFloat();
        }
        bone.has_file_world_bind = true;
    }

    if (f.Tell() != end_offset) {
        LOG_INFO("MDLE body ended at 0x%X but end_offset=0x%X (%s)",
                 static_cast<uint32_t>(f.Tell()),
                 end_offset_u,
                 std::string(path).c_str());
        if (! SeekSetChecked(f, end_offset_u)) return false;
    }
    return true;
}

bool ParseMDLS(fs::MemBinaryStream& f, WPMdl& mdl, std::string_view path) {
    mdl.mdls = ReadMDLVesion(f);
    if (! HasRemaining(f, 8)) return false;

    const uint32_t end_offset_u = f.ReadUint32();
    const idx end_offset = static_cast<idx>(end_offset_u);
    if (end_offset_u != 0 && (end_offset <= f.Tell() || end_offset > f.Size())) {
        LOG_ERROR("invalid MDLS end offset %u in %s", end_offset_u, std::string(path).c_str());
        return false;
    }

    const uint16_t bones_num = f.ReadUint16();
    (void)f.ReadUint16();

    mdl.puppet = std::make_shared<WPPuppet>();
    auto& bones = mdl.puppet->bones;
    bones.resize(bones_num);
    for (uint32_t i = 0; i < bones_num; ++i) {
        auto& bone = bones[i];
        if (! ReadCStringInBlock(f, end_offset, bone.name)) return false;
        if (! FitsInBlock(f, 12, end_offset)) return false;
        bone.sim_type = f.ReadInt32();

        uint32_t parent = f.ReadUint32();
        if (parent >= i && parent != WPPuppet::Bone::NO_PARENT) {
            LOG_INFO("mdl forward bone parent index %u for bone %u, treating as root",
                     parent,
                     i);
            parent = WPPuppet::Bone::NO_PARENT;
        }
        bone.parent = parent;
        bone.bind_parent = parent;
        bone.anim_parent = parent;
        bone.file_parent = parent;

        const uint32_t size = f.ReadUint32();
        if (size != 64 || ! FitsInBlock(f, size, end_offset)) {
            LOG_ERROR("mdl unsupported bones size: %u", size);
            return false;
        }
        bone.local_bind = Eigen::Affine3f::Identity();
        for (auto col : bone.local_bind.matrix().colwise()) {
            for (auto& x : col) x = f.ReadFloat();
        }

        if (! ReadCStringInBlock(f, end_offset, bone.simulation_json)) return false;
    }

    if (mdl.mdls > 1 && (end_offset_u == 0 || f.Tell() < end_offset)) {
        if (! HasRemaining(f, 2) || (end_offset_u != 0 && f.Tell() + 2 > end_offset)) return false;
        const uint16_t extras_flag = f.ReadUint16();

        if (mdl.mdls == 2) {
            if (! HasRemaining(f, 1) || (end_offset_u != 0 && f.Tell() + 1 > end_offset)) {
                return false;
            }
            const uint8_t has_world_binds = f.ReadUint8();
            if (has_world_binds) {
                const uint64_t bytes = static_cast<uint64_t>(bones_num) * 16u * 4u;
                if (! HasRemaining(f, bytes) || (end_offset_u != 0 && f.Tell() + bytes > end_offset)) {
                    return false;
                }
                for (uint32_t i = 0; i < bones_num; ++i) {
                    for (uint32_t j = 0; j < 16; ++j) (void)f.ReadFloat();
                }
            }
            if (HasRemaining(f, 8) && (end_offset_u == 0 || f.Tell() + 8 <= end_offset)) {
                for (int i = 0; i < 8; ++i) (void)f.ReadUint8();
            }
        } else {
            if (end_offset_u != 0 && f.Tell() >= end_offset) {
                return true;
            }
            if (FitsInBlock(f, 9, end_offset)) {
                const uint8_t zero_b = f.ReadUint8();
                if (zero_b != 0) {
                    LOG_INFO("MDLSv%d zero_b expected 0, got %u", mdl.mdls, zero_b);
                }
                (void)f.ReadUint32();
                (void)f.ReadUint32();
            }

            if (extras_flag == 2) {
                if (end_offset_u != 0) {
                    if (! SeekSetChecked(f, end_offset_u)) return false;
                }
            } else if (extras_flag != 0) {
                LOG_INFO("MDLSv%d unexpected extras flag %u", mdl.mdls, extras_flag);
            }
        }

        if (end_offset_u == 0 || f.Tell() < end_offset) {
            if (! HasRemaining(f, 1) || (end_offset_u != 0 && f.Tell() + 1 > end_offset)) return false;
            const uint8_t has_offset_trans = f.ReadUint8();
            if (has_offset_trans) {
                const uint64_t bytes = static_cast<uint64_t>(bones_num) * (3u * 4u + 16u * 4u);
                if (! HasRemaining(f, bytes) || (end_offset_u != 0 && f.Tell() + bytes > end_offset)) {
                    return false;
                }
                for (auto& bone : bones) {
                    bone.has_file_skin_pivot = true;
                    for (auto& v : bone.file_skin_pivot) v = f.ReadFloat();
                    for (auto col : bone.file_skin_mat.colwise()) {
                        for (auto& value : col) value = f.ReadFloat();
                    }
                }
            }

            if (! HasRemaining(f, 1) || (end_offset_u != 0 && f.Tell() + 1 > end_offset)) return false;
            const uint8_t has_index = f.ReadUint8();
            if (has_index) {
                const uint64_t bytes = static_cast<uint64_t>(bones_num) * 4u;
                if (! HasRemaining(f, bytes) || (end_offset_u != 0 && f.Tell() + bytes > end_offset)) {
                    return false;
                }
                for (uint32_t i = 0; i < bones_num; ++i) (void)f.ReadUint32();
            }

            if (mdl.mdls >= 3 && (end_offset_u == 0 || f.Tell() < end_offset)) {
                if (! HasRemaining(f, 1) || (end_offset_u != 0 && f.Tell() + 1 > end_offset)) return false;
                const uint8_t has_depth = f.ReadUint8();
                if (has_depth) {
                    const uint64_t bytes = static_cast<uint64_t>(bones_num) * 4u;
                    if (! HasRemaining(f, bytes) ||
                        (end_offset_u != 0 && f.Tell() + bytes > end_offset)) {
                        return false;
                    }
                    for (uint32_t i = 0; i < bones_num; ++i) (void)f.ReadUint32();
                }
            }
        }
    }

    if (end_offset_u > 0 && f.Tell() != end_offset) {
        LOG_INFO("MDLS body ended at 0x%X but end_offset=0x%X (%s)",
                 static_cast<uint32_t>(f.Tell()),
                 end_offset_u,
                 std::string(path).c_str());
        if (! SeekSetChecked(f, end_offset_u)) return false;
    }
    return true;
}

void SkipZeroPadding(fs::MemBinaryStream& f) {
    while (HasRemaining(f, 1)) {
        const auto pos = f.Tell();
        if (f.ReadUint8() != 0) {
            f.SeekSet(pos);
            return;
        }
    }
}

void ConsumeTrailingBody(fs::MemBinaryStream& f, const int32_t mdlv) {
    if (mdlv >= 14 && f.Tell() < f.Size()) {
        const uint8_t trailing_nul = f.ReadUint8();
        if (trailing_nul != 0) {
            LOG_INFO("mdlv%d trailing_nul expected 0, got %u", mdlv, trailing_nul);
        }
        return;
    }

    if (mdlv == 13) {
        SkipZeroPadding(f);
    }
}

void ApplyMDLS3CentroidPivot(WPMdl& mdl) {
    if (! mdl.puppet || mdl.meshes.empty()) return;
    if (mdl.puppet->world_anchored_bones) {
        for (auto& bone : mdl.puppet->bones) {
            bone.bind_parent = WPPuppet::Bone::NO_PARENT;
            bone.anim_parent = WPPuppet::Bone::NO_PARENT;
        }
    }

    const std::size_t nbones = mdl.puppet->bones.size();
    std::vector<Eigen::Vector3d> sum_pos(nbones, Eigen::Vector3d::Zero());
    std::vector<double>          sum_w(nbones, 0.0);
    auto to_vec = [](const std::array<float, 3>& p) {
        return Eigen::Vector3d { p[0], p[1], p[2] };
    };
    for (const auto& mesh : mdl.meshes) {
        if (mesh.blend_indices.empty()) continue;
        const bool has_weights = ! mesh.blend_weights.empty();
        auto weight = [&](std::size_t vi, int slot) -> float {
            if (! has_weights) return slot == 0 ? 1.0f : 0.0f;
            return mesh.blend_weights[vi][slot];
        };
        if (! mesh.indices.empty()) {
            for (const auto& tri : mesh.indices) {
                if (tri[0] >= mesh.positions.size() || tri[1] >= mesh.positions.size() ||
                    tri[2] >= mesh.positions.size()) {
                    continue;
                }
                const Eigen::Vector3d p0 = to_vec(mesh.positions[tri[0]]);
                const Eigen::Vector3d p1 = to_vec(mesh.positions[tri[1]]);
                const Eigen::Vector3d p2 = to_vec(mesh.positions[tri[2]]);
                const Eigen::Vector3d centroid = (p0 + p1 + p2) / 3.0;
                const double area = 0.5 * (p1 - p0).cross(p2 - p0).norm();
                if (area <= 0.0) continue;
                for (int corner = 0; corner < 3; ++corner) {
                    if (weight(tri[corner], 0) <= 0.0f) continue;
                    const uint32_t bone_index = mesh.blend_indices[tri[corner]][0];
                    if (bone_index >= nbones) continue;
                    sum_pos[bone_index] += centroid * (area / 3.0);
                    sum_w[bone_index] += area / 3.0;
                }
            }
        } else {
            const int slots = has_weights ? 4 : 1;
            for (std::size_t vi = 0; vi < mesh.positions.size(); ++vi) {
                for (int slot = 0; slot < slots; ++slot) {
                    const float w = weight(vi, slot);
                    const uint32_t bone_index = mesh.blend_indices[vi][slot];
                    if (w <= 0.0f || bone_index >= nbones) continue;
                    sum_pos[bone_index] += to_vec(mesh.positions[vi]) * static_cast<double>(w);
                    sum_w[bone_index] += static_cast<double>(w);
                }
            }
        }
    }

    for (std::size_t i = 0; i < nbones; ++i) {
        if (sum_w[i] <= 0.0) continue;
        const Eigen::Vector3f centroid = (sum_pos[i] / sum_w[i]).cast<float>();
        mdl.puppet->bones[i].vertex_centroid_offset =
            centroid - mdl.puppet->bones[i].local_bind.translation();
    }
}

void MirrorFirstMeshToLegacyFields(WPMdl& mdl) {
    if (mdl.meshes.empty()) return;
    const auto& mesh = mdl.meshes.front();
    mdl.mat_json_file = mesh.mat_json_file;
    mdl.indices       = mesh.indices;
    mdl.vertexs.resize(mesh.positions.size());
    for (std::size_t i = 0; i < mdl.vertexs.size(); ++i) {
        mdl.vertexs[i].position = mesh.positions[i];
        if (i < mesh.blend_indices.size()) mdl.vertexs[i].blend_indices = mesh.blend_indices[i];
        if (i < mesh.blend_weights.size()) mdl.vertexs[i].weight = mesh.blend_weights[i];
        if (i < mesh.texcoords.size()) mdl.vertexs[i].texcoord = mesh.texcoords[i];
    }
}

SceneVertexArray MakePuppetVertexArray(const std::size_t vertex_count) {
    return SceneVertexArray({ { WE_IN_POSITION.data(), VertexType::FLOAT3 },
                              { WE_IN_BLENDINDICES.data(), VertexType::UINT4 },
                              { WE_IN_BLENDWEIGHTS.data(), VertexType::FLOAT4 },
                              { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 } },
                            vertex_count);
}

std::vector<uint16_t> FlattenIndices16(std::span<const std::array<uint16_t, 3>> triangles) {
    std::vector<uint16_t> indices;
    indices.reserve(triangles.size() * 3);
    for (const auto& triangle : triangles) {
        for (const uint16_t index : triangle) indices.push_back(index);
    }
    return indices;
}

SceneIndexArray MakePuppetIndexArray(std::span<const std::array<uint16_t, 3>> triangles) {
    const auto indices = FlattenIndices16(triangles);
    if (indices.empty()) {
        static constexpr std::array<uint32_t, 1> kPaddedEmptyIndex { 0u };
        return SceneIndexArray(kPaddedEmptyIndex);
    }
    SceneIndexArray index_array(triangles.size());
    index_array.AssignHalf(0, indices);
    return index_array;
}

bool PartRangeFitsIndexPayload(const WPMdl::Mesh::Part& part, const uint32_t index_count) {
    if (part.size == 0) return false;
    if (part.start > index_count) return false;
    return part.size <= index_count - part.start;
}

bool TryAppendDrawRange(std::vector<SceneMesh::DrawRange>& ranges,
                        const WPMdl::Mesh::Part& part,
                        const uint32_t index_count) {
    if (! PartRangeFitsIndexPayload(part, index_count)) return false;
    ranges.push_back({ .indexOffset = part.start, .indexCount = part.size });
    return true;
}

std::vector<SceneMesh::DrawRange> DrawNothingRange() {
    return { { .indexOffset = 0, .indexCount = 0 } };
}

std::vector<SceneMesh::DrawRange> DrawRangesFromParts(const WPMdl::Mesh& mdl_mesh) {
    std::vector<SceneMesh::DrawRange> ranges;
    const uint32_t index_count = static_cast<uint32_t>(mdl_mesh.indices.size() * 3u);
    ranges.reserve(mdl_mesh.parts.size());
    for (const auto& part : mdl_mesh.parts) {
        TryAppendDrawRange(ranges, part, index_count);
    }
    if (ranges.empty() && ! mdl_mesh.parts.empty()) return DrawNothingRange();
    return ranges;
}

std::vector<SceneMesh::DrawRange>
DrawRangesFromPartIndices(const WPMdl::Mesh& mdl_mesh, std::span<const uint32_t> part_indices) {
    std::vector<SceneMesh::DrawRange> ranges;
    const uint32_t index_count = static_cast<uint32_t>(mdl_mesh.indices.size() * 3u);
    ranges.reserve(part_indices.size());
    for (const uint32_t part_index : part_indices) {
        if (part_index >= mdl_mesh.parts.size()) continue;
        const auto& part = mdl_mesh.parts[part_index];
        TryAppendDrawRange(ranges, part, index_count);
    }
    if (ranges.empty()) return DrawNothingRange();
    return ranges;
}

std::vector<SceneMesh::DrawRange>
DrawRangesExcludingPartIndices(const WPMdl::Mesh& mdl_mesh,
                               std::span<const uint32_t> excluded_part_indices) {
    if (mdl_mesh.parts.empty()) return {};

    std::vector<bool> excluded(mdl_mesh.parts.size(), false);
    for (const uint32_t part_index : excluded_part_indices) {
        if (part_index < excluded.size()) excluded[part_index] = true;
    }

    std::vector<SceneMesh::DrawRange> ranges;
    const uint32_t index_count = static_cast<uint32_t>(mdl_mesh.indices.size() * 3u);
    ranges.reserve(mdl_mesh.parts.size());
    for (std::size_t i = 0; i < mdl_mesh.parts.size(); ++i) {
        if (excluded[i]) continue;
        const auto& part = mdl_mesh.parts[i];
        TryAppendDrawRange(ranges, part, index_count);
    }
    if (ranges.empty()) return DrawNothingRange();
    return ranges;
}

} // namespace

// bytes * size
constexpr uint32_t singile_vertex  = 4 * (3 + 4 + 4 + 2);
constexpr uint32_t singile_indices = 2 * 3;
constexpr uint32_t std_format_vertex_size_herald_value = 0x01800009;

// alternative consts for alternative mdl format
constexpr uint32_t alt_singile_vertex = 4 * (3 + 4 + 4 + 2 + 7);
constexpr uint32_t alt_format_vertex_size_herald_value = 0x0180000F;

constexpr uint32_t singile_bone_frame = 4 * 9;

bool WPMdlParser::Parse(std::string_view path, fs::VFS& vfs, WPMdl& mdl) {
    auto str_path = std::string(path);
    auto pfile    = vfs.Open("/assets/" + str_path);
    if (! pfile) return false;
    auto memfile  = fs::MemBinaryStream(*pfile);
    auto& f = memfile;

    mdl.mdlv = ReadMDLVesion(f);
    mdl.mdl_header.mdlv = mdl.mdlv;

    int32_t mdl_flag = f.ReadInt32();
    if (mdl_flag == 9) {
        if (mdl.mdlv < 21 || ! HasRemaining(f, 8)) {
            LOG_ERROR("puppet '%s' is not complete, ignore", str_path.c_str());
            return false;
        }
        LOG_INFO("puppet '%s' has incomplete flag but contains mesh payload, parsing mesh only",
                 str_path.c_str());
        mdl_flag = 0;
    };
    mdl.mdl_header.mdl_flag = static_cast<uint32_t>(mdl_flag);
    f.ReadInt32(); // unk, 1
    mdl.mdl_header.mesh_count = f.ReadUint32();

    bool alt_mdl_format = false;

    if (mdl.mdlv >= 21) {
        if (mdl.mdl_header.mesh_count == 0 || mdl.mdl_header.mesh_count > kMaxMdlMeshes) {
            LOG_ERROR("unsupported mdl mesh count %d in %s",
                      mdl.mdl_header.mesh_count, str_path.c_str());
            return false;
        }
        mdl.meshes.resize(mdl.mdl_header.mesh_count);
        for (auto& mesh : mdl.meshes) {
            if (! ParseMesh(f, mdl.mdl_header, mesh, str_path)) return false;
        }
        MirrorFirstMeshToLegacyFields(mdl);
        if (! PeekBlockMagic(f, "MDLS")) {
            LOG_INFO("read puppet mesh: mdlv: %d, meshes: %zu, no MDLS section",
                     mdl.mdlv,
                     mdl.meshes.size());
            return true;
        }
    } else {
        // Local compatibility adapter: upstream has fully moved to the
        // multi-mesh parser, but this fork still carries MDLV<21 corpus tests
        // and fixtures. Keep the legacy reader isolated from the MDLV21+ path.
        mdl.mat_json_file = f.ReadStr();
        // 0
        f.ReadInt32();

        uint32_t curr = f.ReadUint32();

        // if the uint at the normal vertex size position is 0, then this file
        // uses the alternative MDL format, therefore the actual vertex size is
        // located after the herald value, and we'll need to account for other differences later on.
        if(curr == 0){
            alt_mdl_format = true;
            while (curr != alt_format_vertex_size_herald_value){
                const idx before = f.Tell();
                curr = f.ReadUint32();
                if (f.Tell() == before) {
                    LOG_ERROR("mdl missing alt vertex herald: %s", str_path.c_str());
                    return false;
                }
            }
            curr = f.ReadUint32();
        }
        else if(curr == std_format_vertex_size_herald_value){
            curr = f.ReadUint32();
        }

        uint32_t vertex_size = curr;
        if (vertex_size % (alt_mdl_format? alt_singile_vertex : singile_vertex) != 0) {
            LOG_ERROR("unsupport mdl vertex size %d", vertex_size);
            return false;
        }

        // if using the alternative MDL format, vertexes contain 7 extra 32-bit chunks between
        // position and blend indices
        uint32_t vertex_num = vertex_size / (alt_mdl_format ? alt_singile_vertex : singile_vertex);
        mdl.vertexs.resize(vertex_num);
        for (auto& vert : mdl.vertexs) {
            for (auto& v : vert.position) v = f.ReadFloat();
            if(alt_mdl_format) {for (int i = 0; i < 7; i++) f.ReadUint32();}
            for (auto& v : vert.blend_indices) v = f.ReadUint32();
            for (auto& v : vert.weight) v = f.ReadFloat();
            for (auto& v : vert.texcoord) v = f.ReadFloat();
        }

        uint32_t indices_size = f.ReadUint32();
        if (indices_size % singile_indices != 0) {
            LOG_ERROR("unsupport mdl indices size %d", indices_size);
            return false;
        }

        uint32_t indices_num = indices_size / singile_indices;
        mdl.indices.resize(indices_num);
        for (auto& id : mdl.indices) {
            for (auto& v : id) v = f.ReadUint16();
        }

    }

    if (! ParseMDLS(f, mdl, str_path)) return false;
    if (mdl.puppet) {
        mdl.puppet->world_anchored_bones = (mdl.mdlv == 21);
    }

    SkipZeroPadding(f);
    if (PeekBlockMagic(f, "MDAT")) {
        (void)ConsumeBlockTag(f);
        if (! ParseMDAT(f, mdl, str_path)) return false;
    }

    SkipZeroPadding(f);
    if (PeekBlockMagic(f, "MDLA")) {
        const std::string tag = ConsumeBlockTag(f);
        if (! ParseMDLA(f, mdl, tag, str_path)) {
            if (mdl.puppet) mdl.puppet->anims.clear();
            LOG_ERROR("MDLA parse aborted for %s; puppet keeps bind pose only",
                      str_path.c_str());
        }
    }

    SkipZeroPadding(f);
    if (PeekBlockMagic(f, "MDMP")) {
        const std::string tag = ConsumeBlockTag(f);
        if (! ParseMDMP(f, mdl, tag, str_path)) return false;
    }

    SkipZeroPadding(f);
    if (PeekBlockMagic(f, "MDLE")) {
        const std::string tag = ConsumeBlockTag(f);
        if (! ParseMDLE(f, mdl, tag, str_path)) return false;
    }

    ConsumeTrailingBody(f, mdl.mdlv);

    if (mdl.mdls >= 3) ApplyMDLS3CentroidPivot(mdl);
    if (mdl.puppet) mdl.puppet->prepared();

    LOG_INFO("read puppet: mdlv: %d, nmdls: %d, mdla: %d, bones: %zu, anims: %zu",
             mdl.mdlv,
             mdl.mdls,
             mdl.mdla,
             mdl.puppet ? mdl.puppet->bones.size() : 0,
             mdl.puppet ? mdl.puppet->anims.size() : 0);
    return true;
}

void WPMdlParser::GenMeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src) {
    if (src.positions.empty()) return;

    using VertexPacker = std::function<void(std::size_t, float*)>;

    std::vector<SceneVertexArray::SceneVertexAttribute> attrs;
    std::vector<VertexPacker>                           packers;

    attrs.push_back({ WE_IN_POSITION.data(), VertexType::FLOAT3 });
    packers.push_back([&src](std::size_t index, float* dst) {
        std::memcpy(dst, src.positions[index].data(), sizeof(src.positions[index]));
    });

    if (! src.blend_indices.empty()) {
        attrs.push_back({ WE_IN_BLENDINDICES.data(), VertexType::UINT4 });
        packers.push_back([&src](std::size_t index, float* dst) {
            std::memcpy(dst, src.blend_indices[index].data(), sizeof(src.blend_indices[index]));
        });

        attrs.push_back({ WE_IN_BLENDWEIGHTS.data(), VertexType::FLOAT4 });
        const bool has_weights = ! src.blend_weights.empty();
        packers.push_back([&src, has_weights](std::size_t index, float* dst) {
            if (has_weights) {
                std::memcpy(dst, src.blend_weights[index].data(), sizeof(src.blend_weights[index]));
                return;
            }
            dst[0] = 1.0f;
            dst[1] = 0.0f;
            dst[2] = 0.0f;
            dst[3] = 0.0f;
        });
    }

    if (! src.texcoords.empty()) {
        attrs.push_back({ WE_IN_TEXCOORD.data(), VertexType::FLOAT2 });
        packers.push_back([&src](std::size_t index, float* dst) {
            std::memcpy(dst, src.texcoords[index].data(), sizeof(src.texcoords[index]));
        });
    }

    SceneVertexArray vertex(attrs, src.positions.size());
    std::size_t      stride = 0;
    for (const auto& attr : attrs) {
        stride += SceneVertexArray::RealAttributeSize(attr);
    }

    std::vector<float> one_vertex(stride);
    for (std::size_t vertex_index = 0; vertex_index < src.positions.size(); ++vertex_index) {
        std::size_t offset = 0;
        for (std::size_t attr_index = 0; attr_index < packers.size(); ++attr_index) {
            packers[attr_index](vertex_index, one_vertex.data() + offset);
            offset += SceneVertexArray::RealAttributeSize(attrs[attr_index]);
        }
        vertex.SetVertexs(vertex_index, one_vertex);
    }

    submesh.AddVertexArray(std::move(vertex));
    submesh.AddIndexArray(MakePuppetIndexArray(src.indices));

    if (! src.parts.empty()) {
        submesh.SetDrawRanges(DrawRangesFromParts(src));
    }
}

void WPMdlParser::GenMaskSubmeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src,
                                        std::span<const uint32_t> part_indices) {
    GenMeshFromMdl(submesh, src);
    submesh.SetDrawRanges(DrawRangesFromPartIndices(src, part_indices));
}

void WPMdlParser::GenPuppetMesh(SceneMesh& mesh, const WPMdl& mdl, const bool include_masks) {
    mesh.Submeshes().clear();
    if (! mdl.meshes.empty()) {
        auto& submeshes = mesh.Submeshes();
        uint32_t material_slot = 0;
        for (std::size_t i = 0; i < mdl.meshes.size(); ++i) {
            const auto& mdl_mesh = mdl.meshes[i];
            if (mdl_mesh.positions.empty()) continue;

            submeshes.emplace_back();
            auto& submesh = submeshes.back();
            submesh.material_slot = material_slot++;
            GenMeshFromMdl(submesh, mdl_mesh);

            if (! include_masks) continue;

            std::vector<uint32_t> clipped_parts;
            for (const auto& mask : mdl_mesh.masks) {
                clipped_parts.insert(
                    clipped_parts.end(), mask.part_ids_a.begin(), mask.part_ids_a.end());
            }
            if (! clipped_parts.empty()) {
                submesh.SetDrawRanges(DrawRangesExcludingPartIndices(mdl_mesh, clipped_parts));
            }

            for (const auto& mask : mdl_mesh.masks) {
                submeshes.emplace_back();
                auto& mask_submesh = submeshes.back();
                mask_submesh.material_slot = material_slot++;
                mask_submesh.output_override = std::string(kPuppetMaskRenderTarget);
                GenMaskSubmeshFromMdl(mask_submesh, mdl_mesh, mask.part_ids_b);

                submeshes.emplace_back();
                auto& clipped_submesh = submeshes.back();
                clipped_submesh.material_slot = material_slot++;
                GenMaskSubmeshFromMdl(clipped_submesh, mdl_mesh, mask.part_ids_a);
            }
        }
        return;
    }

    // Local compatibility adapter for MDLV<21 files parsed above. MDLV21+
    // should always use the upstream multi-mesh path and return before here.
    SceneVertexArray vertex = MakePuppetVertexArray(mdl.vertexs.size());

    std::array<float, 16> one_vert;
    auto                  to_one = [](const WPMdl::Vertex& in, decltype(one_vert)& out) {
        uint offset = 0;
        memcpy(out.data() + 4 * (offset++), in.position.data(), sizeof(in.position));
        memcpy(out.data() + 4 * (offset++), in.blend_indices.data(), sizeof(in.blend_indices));
        memcpy(out.data() + 4 * (offset++), in.weight.data(), sizeof(in.weight));
        memcpy(out.data() + 4 * (offset++), in.texcoord.data(), sizeof(in.texcoord));
    };
    for (uint i = 0; i < mdl.vertexs.size(); i++) {
        auto& v = mdl.vertexs[i];
        to_one(v, one_vert);
        vertex.SetVertexs(i, one_vert);
    }
    mesh.AddVertexArray(std::move(vertex));
    mesh.AddIndexArray(MakePuppetIndexArray(mdl.indices));
}

void WPMdlParser::AddPuppetShaderInfo(WPShaderInfo& info, const WPMdl& mdl) {
    info.combos["SKINNING"]  = "1";
    info.combos["BONECOUNT"] = std::to_string(mdl.puppet->bones.size());
}

void WPMdlParser::AddPuppetMatInfo(wpscene::WPMaterial& mat, const WPMdl& mdl) {
    mat.combos["SKINNING"]  = 1;
    mat.combos["BONECOUNT"] = (i32)mdl.puppet->bones.size();
    mat.use_puppet          = true;
}
