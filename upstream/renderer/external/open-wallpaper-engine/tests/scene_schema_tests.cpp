#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <map>
#include <memory>
#include <span>
#include <string>
#include <vector>
#include <cstring>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Audio/SoundManager.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/SceneCamera.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "WPShaderValueUpdater.hpp"
#include "WPSceneParser.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPMiscObject.hpp"
#include "wpscene/WPParticleObject.h"
#include "wpscene/WPScene.h"

namespace
{
using namespace wallpaper;

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::string> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        const auto& s = it->second;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(s.begin(), s.end()));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::string> m_files;
};

class Bytes {
public:
    void Stamp(std::string_view prefix, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "%.4s%.4d", prefix.data(), version);
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(stamp), sizeof(stamp)));
    }
    void Str(std::string_view value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(value.data()), value.size()));
        U8(0);
    }
    void U8(uint8_t value) { RawValue(value); }
    void U16(uint16_t value) { RawValue(value); }
    void U32(uint32_t value) { RawValue(value); }
    void I32(int32_t value) { RawValue(value); }
    void F32(float value) { RawValue(value); }
    std::size_t Size() const { return m_bytes.size(); }
    void PatchU32(std::size_t offset, uint32_t value) {
        ASSERT_LE(offset + sizeof(value), m_bytes.size());
        std::memcpy(m_bytes.data() + offset, &value, sizeof(value));
    }

    std::string TakeString() {
        return std::string(reinterpret_cast<const char*>(m_bytes.data()), m_bytes.size());
    }

private:
    template<typename T>
    void RawValue(const T& value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(&value), sizeof(value)));
    }
    void Raw(std::span<const uint8_t> bytes) {
        m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
    }

    std::vector<uint8_t> m_bytes;
};

constexpr uint32_t kSceneTestSkinUvFlag = 0x00800000u | 0x01000000u | 0x00000008u;
constexpr uint32_t kSceneTestVideoFlag = 1u << 5;

void WriteMeshOnlyPuppetVertex(Bytes& b, float x, float y, float u) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
}

void WritePuppetVertex(Bytes& b, float x, float y, float u, uint32_t bone = 0) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.U32(bone);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.F32(1.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
}

void WriteMeshOnlyPuppetMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(0x00000008u);
    b.U32(3u * 20u);
    WriteMeshOnlyPuppetVertex(b, 0.0f, 0.0f, 0.0f);
    WriteMeshOnlyPuppetVertex(b, 1.0f, 0.0f, 0.5f);
    WriteMeshOnlyPuppetVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

void WritePuppetMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(3u * 52u);
    WritePuppetVertex(b, 0.0f, 0.0f, 0.0f);
    WritePuppetVertex(b, 1.0f, 0.0f, 0.5f);
    WritePuppetVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

void WriteIdentity3x4(Bytes& b) {
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            b.F32(row == col ? 1.0f : 0.0f);
        }
    }
}

void WriteTranslate3x4(Bytes& b, float x, float y, float z) {
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            float value = row == col ? 1.0f : 0.0f;
            if (col == 3 && row == 0) value = x;
            if (col == 3 && row == 1) value = y;
            if (col == 3 && row == 2) value = z;
            b.F32(value);
        }
    }
}

std::string BuildTwoMeshPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(1);
    b.U32(2);
    WritePuppetMesh(b, "mat/head.json", 10);
    WritePuppetMesh(b, "mat/eyes.json", 20);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string BuildMaskedTwoMeshPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 23);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(1);
    b.U32(2);
    WritePuppetMesh(b, "mat/head.json", 10);
    b.U32(1);
    b.U32(7);
    b.U32(0);
    b.Str("mat/head_mask.json");
    b.U32(0);
    b.U32(1);
    b.U32(0);
    b.U32(1);
    b.U32(0);
    WritePuppetMesh(b, "mat/eyes.json", 20);
    b.U32(0);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string BuildAttachmentPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WritePuppetMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(2);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("head");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDAT", 1);
    const auto mdat_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(1);
    b.Str("hat_anchor");
    WriteTranslate3x4(b, 4.0f, 5.0f, 6.0f);
    b.PatchU32(mdat_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string BuildMeshOnlyPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(0x00000008u);
    b.U32(1);
    b.U32(2);
    WriteMeshOnlyPuppetMesh(b, "mat/head.json", 10);
    WriteMeshOnlyPuppetMesh(b, "mat/eyes.json", 20);
    return b.TakeString();
}

std::string BuildLegacySingleMeshPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 20);
    b.U32(kSceneTestSkinUvFlag);
    b.U32(1);
    b.U32(1);
    b.Str("legacy.json");
    b.U32(0);
    b.U32(3u * 52u);
    WritePuppetVertex(b, 0.0f, 0.0f, 0.0f);
    WritePuppetVertex(b, 1.0f, 0.0f, 0.5f);
    WritePuppetVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string BuildVideoTexFixture() {
    Bytes b;
    b.Stamp("TEXV", 5);
    b.Stamp("TEXI", 1);
    b.I32(0);
    b.U32(kSceneTestVideoFlag);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp("TEXB", 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.I32(0);
    b.I32(0);
    return b.TakeString();
}

void MountSceneFiles(fs::VFS& vfs) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
        { "/particle.json",
          R"({"emitter":[{"name":"emit","id":1}],"material":"mat.json","maxcount":4,"starttime":0,
              "children":[{"name":"child_particle.json","type":"eventspawn","maxcount":3,
                "origin":[1,2,3],"scale":[0.5,0.5,1],"angles":[0,0,45]}]})" },
        { "/child_particle.json",
          R"({"emitter":[{"name":"child_emit","id":2}],"material":"mat.json","maxcount":2,"starttime":1})" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

std::string PuppetMaterialJson(std::string_view shader,
                               std::string_view texture) {
    return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                       R"("depthtest":"disabled","depthwrite":"disabled","shader":")") +
           std::string(shader) + R"(","textures":[")" + std::string(texture) + R"("]}]})";
}

std::string PuppetMaterialJson(std::string_view                        shader,
                               std::initializer_list<std::string_view> textures) {
    std::string texture_json;
    for (const auto texture : textures) {
        if (! texture_json.empty()) texture_json += ",";
        texture_json += "\"" + std::string(texture) + "\"";
    }
    return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                       R"("depthtest":"disabled","depthwrite":"disabled","shader":")") +
           std::string(shader) + R"(","textures":[)" + texture_json + R"(]}]})";
}

void AddPuppetImageSceneFiles(std::map<std::string, std::string>& files,
                              bool                               include_eyes_material = true,
                              bool                               legacy_puppet = false,
                              bool                               mesh_only_puppet = false) {
    files["/puppet_image.json"] =
        R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})";
    files["/puppet.mdl"] = legacy_puppet       ? BuildLegacySingleMeshPuppetMdlFixture()
                            : mesh_only_puppet ? BuildMeshOnlyPuppetMdlFixture()
                                               : BuildTwoMeshPuppetMdlFixture();
    files["/mat/base.json"] = PuppetMaterialJson("baseimage", "base.tex");
    files["/mat/head.json"] = PuppetMaterialJson("headimage", "head.tex");
    if (include_eyes_material) {
        files["/mat/eyes.json"] = PuppetMaterialJson("eyesimage", "eyes.tex");
    }
    files["/shaders/baseimage.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/baseimage.frag"] = R"(
uniform sampler2D g_Texture0;
uniform float g_Tint; // {"material":"tint","default":0.0}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
}
)";
    files["/shaders/headimage.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/headimage.frag"] = R"(
uniform sampler2D g_Texture0;
uniform float g_Tint; // {"material":"tint","default":0.0}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
}
)";
    files["/shaders/eyesimage.vert"] = files["/shaders/headimage.vert"];
    files["/shaders/eyesimage.frag"] = R"(
uniform sampler2D g_Texture0;
uniform float g_Tint; // {"material":"tint","default":0.0}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
}
)";
    files["/materials/base.tex.tex"] = "";
    files["/materials/head.tex.tex"] = "";
    files["/materials/eyes.tex.tex"] = "";
}

void AddPuppetSlotRenderTargetSceneFiles(std::map<std::string, std::string>& files) {
    AddPuppetImageSceneFiles(files);
    files["/mat/eyes.json"] = PuppetMaterialJson("eyesimage", "_rt_4FrameBuffer");
}

void AddMaskedTwoMeshPuppetSceneFiles(std::map<std::string, std::string>& files) {
    AddPuppetImageSceneFiles(files);
    files["/puppet.mdl"] = BuildMaskedTwoMeshPuppetMdlFixture();
    files["/mat/head_mask.json"] = PuppetMaterialJson("headmaskimage", "head_mask.tex");
    files["/materials/head_mask.tex.tex"] = "";
    files["/materials/mat/head_mask.json.tex"] = "";
    files["/shaders/clippingmaskimage4.vert"] = files["/shaders/headimage.vert"];
    files["/shaders/clippingmaskimage4.frag"] = R"(
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * texture(g_Texture1, v_TexCoord);
}
)";
}

void AddMultiVideoImageSceneFiles(std::map<std::string, std::string>& files) {
    files["/image.json"] =
        R"({"width":64,"height":32,"material":"mat/multi_video.json"})";
    files["/mat/multi_video.json"] =
        PuppetMaterialJson("multivideo", { "diffuse.tex", "mask.tex" });
    files["/shaders/multivideo.vert"] = R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/multivideo.frag"] = R"(
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) + texture(g_Texture1, v_TexCoord);
}
)";
    const auto video_tex = BuildVideoTexFixture();
    files["/materials/diffuse.tex.tex"] = video_tex;
    files["/materials/mask.tex.tex"] = video_tex;
}

std::string BasicImageSceneJson() {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":310,"name":"video image","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";
}

std::string DynamicImageSceneJson() {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":310,"name":"valid scripted image","image":"valid.json",
         "origin":{"value":[4,0,0],"script":"export function update(value) { return value; }"},
         "angles":[0,0,0],"visible":true},
        {"id":311,"name":"failed dynamic image","image":"image.json",
         "origin":{"value":[0,0,0],"script":"export function update(value) { return value; }"},
         "scale":{"value":[1,1,1],"user":"scaleProperty"},
         "angles":[0,0,0],"visible":true}
      ]
    })";
}

std::string DynamicParticleSceneJson() {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":310,"name":"valid scripted particle","particle":"valid_particle.json",
         "origin":{"value":[4,0,0],"script":"export function update(value) { return value; }"},
         "angles":[0,0,0],"visible":true},
        {"id":312,"name":"failed dynamic particle","particle":"particle.json",
         "origin":{"value":[0,0,0],"script":"export function update(value) { return value; }"},
         "scale":{"value":[1,1,1],"user":"scaleProperty"},
         "angles":[0,0,0],
         "visible":{"value":true,"script":"thisScene.on('cursorClick', function() { thisScene.getLayer('failed dynamic particle').visible = false; });"}}
      ]
    })";
}

std::string BasicPuppetSceneJson(bool dynamic_alpha = false) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"puppet image","image":"puppet_image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true, "alpha":)") +
           (dynamic_alpha
                ? R"({"value":0.6,"animation":{"c0":[{"frame":0,"value":0.6},{"frame":1,"value":0.3}],"options":{"fps":30}}})"
                : "0.6") +
           R"(}
      ]
    })";
}

std::string PuppetParallaxSceneJson() {
    return R"({
      "camera": {"center":[10,0,0], "eye":[10,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":true,
        "cameraparallaxamount":2, "cameraparallaxdelay":0.25,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"puppet image","image":"puppet_image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "alpha":0.6, "parallaxDepth":[0.5,0.25]}
      ]
    })";
}

std::shared_ptr<SceneNode> FindRootChildByName(const Scene& scene, std::string_view name) {
    if (scene.sceneGraph == nullptr) return nullptr;
    const auto& root_children = scene.sceneGraph->GetChildren();
    auto        it            = std::find_if(
        root_children.begin(), root_children.end(), [name](const auto& node) {
            return node != nullptr && node->Name() == name;
        });
    if (it == root_children.end()) return nullptr;
    return *it;
}

SceneNode* FindFirstChildByName(SceneNode& node, std::string_view name) {
    auto child = std::find_if(node.GetChildren().begin(), node.GetChildren().end(),
                              [name](const auto& candidate) {
                                  return candidate != nullptr && candidate->Name() == name;
                              });
    return child == node.GetChildren().end() ? nullptr : child->get();
}

std::array<float, 3> VertexPosition(const SceneVertexArray& vertices, std::size_t index) {
    EXPECT_LT(index, vertices.VertexCount());
    const float* data = vertices.Data() + index * vertices.OneSize();
    return { data[0], data[1], data[2] };
}

std::array<float, 2> VertexUv(const SceneVertexArray& vertices, std::size_t index) {
    EXPECT_LT(index, vertices.VertexCount());
    const float* data = vertices.Data() + index * vertices.OneSize();
    return { data[4], data[5] };
}

void ExpectVec3Near(std::array<float, 3> actual, std::array<float, 3> expected, float tolerance) {
    EXPECT_NEAR(actual[0], expected[0], tolerance);
    EXPECT_NEAR(actual[1], expected[1], tolerance);
    EXPECT_NEAR(actual[2], expected[2], tolerance);
}

void ExpectVec2Near(std::array<float, 2> actual, std::array<float, 2> expected, float tolerance) {
    EXPECT_NEAR(actual[0], expected[0], tolerance);
    EXPECT_NEAR(actual[1], expected[1], tolerance);
}

void MountBloomSceneFiles(fs::VFS& vfs) {
    auto files = std::map<std::string, std::string> {
        { "/materials/util/downsample_quarter_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_downsample_quarter","textures":["_rt_default"],"constantshadervalues":{"bloomstrength":[9.0],"bloomthreshold":[9.0],"bloomtint":[9.0,9.0,9.0]}}]})" },
        { "/materials/util/downsample_eighth_blur_v.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_v","textures":["_rt_bloom_mip1"]}]})" },
        { "/materials/util/blur_h_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_h","textures":["_rt_bloom_mip2"]}]})" },
        { "/materials/util/combine_ldr.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_combine_ldr","textures":["_rt_default","_rt_bloom_mip1"]}]})" },
        { "/shaders/bloom_downsample_quarter.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_downsample_quarter.frag",
          R"(uniform sampler2D g_Texture0;
uniform float g_BloomStrength; // {"material":"bloomstrength","default":0.0}
uniform float g_BloomThreshold; // {"material":"bloomthreshold","default":0.0}
uniform vec3 g_BloomTint; // {"material":"bloomtint","default":"1 1 1"}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_BloomStrength;
}
)" },
        { "/shaders/bloom_blur_v.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_v.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/bloom_blur_h.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_h.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/bloom_combine_ldr.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_combine_ldr.frag",
          R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) + texture(g_Texture1, v_TexCoord);
}
)" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

void MountBrokenBloomSceneFiles(fs::VFS& vfs) {
    auto files = std::map<std::string, std::string> {
        { "/materials/util/downsample_quarter_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_downsample_quarter","textures":["_rt_default"]}]})" },
        { "/materials/util/downsample_eighth_blur_v.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_v","textures":["_rt_bloom_mip1"]}]})" },
        { "/materials/util/blur_h_bloom.json",
          R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"bloom_blur_h","textures":["_rt_bloom_mip2"]}]})" },
        { "/shaders/bloom_downsample_quarter.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_downsample_quarter.frag",
          R"(uniform sampler2D g_Texture0;
uniform float g_BloomStrength; // {"material":"bloomstrength","default":0.0}
uniform float g_BloomThreshold; // {"material":"bloomthreshold","default":0.0}
uniform vec3 g_BloomTint; // {"material":"bloomtint","default":"1 1 1"}
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_BloomStrength;
}
)" },
        { "/shaders/bloom_blur_v.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_v.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/bloom_blur_h.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/bloom_blur_h.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

std::string BloomSceneJson(bool hdr) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0, "bloom":true,
        "bloomstrength":1.5, "bloomthreshold":0.25,
        "bloomtint":[0.2,0.4,0.6], "hdr":)") +
           (hdr ? "true" : "false") + R"(,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": []
    })";
}

const ScenePostProcessPass* PostProcessPassAt(const ScenePostProcess& post, std::size_t index) {
    if (index >= post.steps.size()) return nullptr;
    return std::get_if<ScenePostProcessPass>(&post.steps[index]);
}

const ScenePostProcessCopy* PostProcessCopyAt(const ScenePostProcess& post, std::size_t index) {
    if (index >= post.steps.size()) return nullptr;
    return std::get_if<ScenePostProcessCopy>(&post.steps[index]);
}

void ExpectTextureResolution(const ScenePostProcessPass& pass, int width, int height) {
    ASSERT_NE(pass.node, nullptr);
    ASSERT_NE(pass.node->Mesh(), nullptr);
    ASSERT_NE(pass.node->Mesh()->Material(), nullptr);
    const auto& constants = pass.node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(constants.contains(WE_GLTEX_RESOLUTION_NAMES[0]));
    const auto& resolution = constants.at(WE_GLTEX_RESOLUTION_NAMES[0]);
    EXPECT_FLOAT_EQ(resolution[0], static_cast<float>(width));
    EXPECT_FLOAT_EQ(resolution[1], static_cast<float>(height));
    EXPECT_FLOAT_EQ(resolution[2], static_cast<float>(width));
    EXPECT_FLOAT_EQ(resolution[3], static_cast<float>(height));
}

} // namespace

TEST(SceneSchema, AbsorbsGeneralKeysAndLightConfig) {
    wpscene::WPScene scene;
    const auto       json = nlohmann::json::parse(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.1,0.2,0.3], "skylightcolor":[0.4,0.5,0.6],
        "clearcolor":[0.7,0.8,0.9], "cameraparallax":true,
        "cameraparallaxamount":1.5, "cameraparallaxdelay":0.25,
        "cameraparallaxmouseinfluence":0.75, "zoom":2.0,
        "fov":63.0, "nearz":0.5, "farz":9000.0,
        "bloom":true, "bloomstrength":1.25, "bloomthreshold":0.8,
        "hdr":true, "norecompile":true, "bloomtint":[0.2,0.3,0.4],
        "perspectiveoverridefov":70.0, "windenabled":true,
        "winddirection":[1,0,0], "windstrength":3.0,
        "gravitydirection":[0,-1,0], "gravitystrength":9.8,
        "transparentsorting":true, "fogdistance":true,
        "fogdistancestart":10.0, "fogdistanceend":100.0,
        "fogdistancecolor":[0.6,0.7,0.8],
        "fogheight":true, "fogheightstart":2.0, "fogheightend":8.0,
        "fogheightcolor":[0.9,0.8,0.7],
        "lightconfig":{"directional":1,"point":2,"spotshadow":3},
        "orthogonalprojection":{"width":1280,"height":720}
      },
      "objects": []
    })");

    ASSERT_TRUE(scene.FromJson(json));
    EXPECT_TRUE(scene.general.hdr);
    EXPECT_TRUE(scene.general.norecompile);
    EXPECT_FLOAT_EQ(scene.general.bloomtint[2], 0.4f);
    EXPECT_TRUE(scene.general.windenabled);
    EXPECT_FLOAT_EQ(scene.general.windstrength, 3.0f);
    EXPECT_TRUE(scene.general.transparentsorting);
    EXPECT_TRUE(scene.general.fogdistance);
    EXPECT_TRUE(scene.general.fogheight);
    EXPECT_EQ(scene.general.lightconfig.at("point"), 2);
}

TEST(SceneSchema, GeneralPackageVersionGatesHigherVersionFields) {
    const auto json = nlohmann::json::parse(R"({
      "ambientcolor":[0.1,0.2,0.3], "skylightcolor":[0.4,0.5,0.6],
      "clearcolor":[0.7,0.8,0.9], "cameraparallax":false,
      "cameraparallaxamount":0, "cameraparallaxdelay":0,
      "cameraparallaxmouseinfluence":0, "hdr":true, "norecompile":true,
      "bloomtint":[0.2,0.3,0.4], "windenabled":true, "windstrength":3.0,
      "lightconfig":{"directional":1,"point":2}, "transparentsorting":true,
      "fogdistance":true, "fogdistancestart":10.0, "fogheight":true,
      "fogheightstart":2.0
    })");

    wpscene::WPSceneGeneral v9;
    ASSERT_TRUE(v9.FromJson(json, 9));
    EXPECT_FALSE(v9.hdr);
    EXPECT_FALSE(v9.norecompile);

    wpscene::WPSceneGeneral v10;
    ASSERT_TRUE(v10.FromJson(json, 10));
    EXPECT_TRUE(v10.hdr);
    EXPECT_TRUE(v10.norecompile);

    wpscene::WPSceneGeneral v19;
    ASSERT_TRUE(v19.FromJson(json, 19));
    EXPECT_FLOAT_EQ(v19.bloomtint[2], 1.0f);

    wpscene::WPSceneGeneral v20;
    ASSERT_TRUE(v20.FromJson(json, 20));
    EXPECT_FLOAT_EQ(v20.bloomtint[2], 0.4f);
    EXPECT_FALSE(v20.windenabled);
    EXPECT_TRUE(v20.lightconfig.is_null());

    wpscene::WPSceneGeneral v21;
    ASSERT_TRUE(v21.FromJson(json, 21));
    EXPECT_TRUE(v21.windenabled);
    EXPECT_FLOAT_EQ(v21.windstrength, 3.0f);
    EXPECT_EQ(v21.lightconfig.at("point"), 2);
    EXPECT_FALSE(v21.transparentsorting);
    EXPECT_FALSE(v21.fogdistance);

    wpscene::WPSceneGeneral v22;
    ASSERT_TRUE(v22.FromJson(json, 22));
    EXPECT_TRUE(v22.transparentsorting);
    EXPECT_TRUE(v22.fogdistance);
    EXPECT_FALSE(v22.fogheight);

    wpscene::WPSceneGeneral v23;
    ASSERT_TRUE(v23.FromJson(json, 23));
    EXPECT_TRUE(v23.fogheight);
    EXPECT_FLOAT_EQ(v23.fogheightstart, 2.0f);
}

TEST(SceneSchema, SceneRootPackageVersionGatesGeneralFields) {
    const auto root = nlohmann::json::parse(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.1,0.2,0.3], "skylightcolor":[0.4,0.5,0.6],
        "clearcolor":[0.7,0.8,0.9], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0, "hdr":true,
        "bloomtint":[0.2,0.3,0.4], "windenabled":true,
        "lightconfig":{"point":2}, "fogheight":true
      },
      "objects": []
    })");

    wpscene::WPScene v20;
    ASSERT_TRUE(v20.FromJson(root, 20));
    EXPECT_TRUE(v20.general.hdr);
    EXPECT_FLOAT_EQ(v20.general.bloomtint[2], 0.4f);
    EXPECT_FALSE(v20.general.windenabled);
    EXPECT_TRUE(v20.general.lightconfig.is_null());
    EXPECT_FALSE(v20.general.fogheight);

    wpscene::WPScene v23;
    ASSERT_TRUE(v23.FromJson(root, 23));
    EXPECT_TRUE(v23.general.windenabled);
    EXPECT_EQ(v23.general.lightconfig.at("point"), 2);
    EXPECT_TRUE(v23.general.fogheight);
}

TEST(SceneSchema, ImageAbsorbsDependenciesInstanceAnimationLayersAndBindings) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    wpscene::WPImageObject image;
    const auto             json = nlohmann::json::parse(R"({
      "image":"image.json", "id":7, "name":"image layer",
      "dependencies":[1,2], "origin":[1,2,3], "attachment":"hat_anchor",
      "alpha":{"value":0.5,"animation":{"c0":[{"frame":0,"value":0.5}],"options":{"fps":30}}},
      "visible":{"value":true,"script":"export function update() { return true; }",
        "scriptproperties":{"speed":{"value":1.0}}},
      "instance":{"id":42,"combos":{"BLENDMODE":1},"textures":["override.tex"],
        "usertextures":[{"name":"$mediaThumbnail","type":"system"}]},
      "animationlayers":[{"animation":11,"blend":0.75,"rate":1.25,"visible":true,
        "id":3,"name":"blink","additive":true,"blendin":true,"blendout":true,"blendtime":0.4}]
    })");

    ASSERT_TRUE(image.FromJson(json, vfs));
    EXPECT_EQ(image.dependencies, (std::vector<int32_t> { 1, 2 }));
    EXPECT_EQ(image.attachment, "hat_anchor");
    ASSERT_TRUE(image.instance.enabled);
    EXPECT_EQ(image.instance.id, 42);
    EXPECT_EQ(image.instance.combos.at("BLENDMODE"), 1);
    ASSERT_EQ(image.instance.usertextures.size(), 1u);
    EXPECT_EQ(image.instance.usertextures[0].type, "system");
    ASSERT_EQ(image.puppet_layers.size(), 1u);
    EXPECT_EQ(image.puppet_layers[0].layer_id, 3);
    EXPECT_EQ(image.puppet_layers[0].name, "blink");
    EXPECT_TRUE(image.puppet_layers[0].additive);
    EXPECT_TRUE(image.field_bindings.contains("alpha"));
    EXPECT_TRUE(image.field_bindings.contains("visible"));
}

TEST(SceneSchema, MaterialConstantShaderValueUserBindingsSurvivePassParsingAndMerge) {
    const auto material_json = nlohmann::json::parse(R"({
      "passes": [{
        "blending": "translucent",
        "cullmode": "nocull",
        "depthtest": "disabled",
        "depthwrite": "disabled",
        "shader": "genericimage",
        "textures": ["a.tex"],
        "constantshadervalues": {
          "Opacity": { "user": "opacity_user", "value": [0.25] },
          "Tint": { "user": "tint_user", "value": [0.1, 0.2, 0.3] }
        }
      }]
    })");
    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(material_json));

    ASSERT_TRUE(material.constantshadervalues.contains("Opacity"));
    EXPECT_EQ(material.constantshadervalues.at("Opacity").user, "opacity_user");
    ASSERT_EQ(material.constantshadervalues.at("Opacity").value.size(), 1u);
    EXPECT_FLOAT_EQ(material.constantshadervalues.at("Opacity").value[0], 0.25f);

    wpscene::WPMaterialPass pass;
    ASSERT_TRUE(pass.FromJson(nlohmann::json::parse(R"({
      "constantshadervalues": {
        "Opacity": { "user": "override_opacity", "value": [0.75] }
      }
    })")));

    material.MergePass(pass);

    ASSERT_TRUE(material.constantshadervalues.contains("Opacity"));
    EXPECT_EQ(material.constantshadervalues.at("Opacity").user, "override_opacity");
    ASSERT_EQ(material.constantshadervalues.at("Opacity").value.size(), 1u);
    EXPECT_FLOAT_EQ(material.constantshadervalues.at("Opacity").value[0], 0.75f);
}

TEST(SceneSchema, ParticleAbsorbsInstanceOverrideExtrasAndNestedChildren) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    wpscene::WPParticleObject particle;
    const auto                json = nlohmann::json::parse(R"({
      "particle":"particle.json", "id":9, "name":"particles",
      "dependencies":[7],
      "instanceoverride":{"id":5,"alpha":0.5,"count":2.0,"color":[0.1,0.2,0.3]},
      "origin":{"value":[0,0,0],"scriptproperties":{"x":{"value":1}}},
      "visible":true
    })");

    ASSERT_TRUE(particle.FromJson(json, vfs));
    EXPECT_EQ(particle.dependencies, (std::vector<int32_t> { 7 }));
    EXPECT_TRUE(particle.instanceoverride.enabled);
    EXPECT_EQ(particle.instanceoverride.id, 5);
    EXPECT_TRUE(particle.instanceoverride.overColor);
    EXPECT_TRUE(particle.field_bindings.contains("origin"));
    ASSERT_EQ(particle.particleObj.children.size(), 1u);
    const auto& child = particle.particleObj.children[0];
    EXPECT_EQ(child.name, "child_particle.json");
    EXPECT_EQ(child.type, "eventspawn");
    EXPECT_EQ(child.maxcount, 3);
    EXPECT_FLOAT_EQ(child.origin[1], 2.0f);
    EXPECT_EQ(child.obj.emitters[0].name, "child_emit");
}

TEST(SceneSchema, AbsorbsTextModelAndCameraObjectKinds) {
    fs::VFS vfs;
    MountSceneFiles(vfs);

    wpscene::WPTextObject text;
    ASSERT_TRUE(text.FromJson(nlohmann::json::parse(R"({
      "id":1,"text":{"value":"hello"},"font":"Arial","pointsize":24,
      "padding":4,"horizontalalign":"center","verticalalign":"middle",
      "anchor":"center","maxrows":2,"maxwidth":300,"limitrows":true,
      "limitwidth":true,"limituseellipsis":true,"dependencies":[9],
      "alpha":{"script":"export function update() { return 1; }"}
    })"),
                              vfs));
    EXPECT_EQ(text.text.at("value"), "hello");
    EXPECT_TRUE(text.limituseellipsis);
    EXPECT_TRUE(text.field_bindings.contains("alpha"));

    wpscene::WPModelObject model;
    ASSERT_TRUE(model.FromJson(nlohmann::json::parse(R"({
      "id":2,"model":"model.mdl","attachment":"head","perspective":true,
      "dependencies":[1]
    })"),
                               vfs));
    EXPECT_EQ(model.model, "model.mdl");
    EXPECT_TRUE(model.perspective);

    wpscene::WPCameraObject camera;
    ASSERT_TRUE(camera.FromJson(nlohmann::json::parse(R"({
      "id":3,"camera":"main","path":"camera.json","fov":80,"zoom":1.5,
      "solid":true,"disablepropagation":true
    })"),
                                vfs));
    EXPECT_EQ(camera.camera, "main");
    EXPECT_FLOAT_EQ(camera.zoom, 1.5f);
    EXPECT_TRUE(camera.disablepropagation);
}

TEST(SceneSchema, ParserCreatesTextChildWithoutBreakingLayerParents) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":100,"name":"group","visible":true},
        {"id":101,"parent":100,"text":"hello","font":"Arial","visible":true}
      ]
    })";

    auto parsed = parser.Parse("schema-only", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_TRUE(parsed->sceneGraph != nullptr);
    EXPECT_TRUE(parsed->HasRenderTarget("_alias_lightCookie"));
    const auto& root_children = parsed->sceneGraph->GetChildren();
    auto group = std::find_if(root_children.begin(), root_children.end(), [](const auto& node) {
        return node != nullptr && node->Name() == "group";
    });
    ASSERT_NE(group, root_children.end());
    EXPECT_EQ((*group)->Parent(), parsed->sceneGraph.get());
    ASSERT_EQ((*group)->GetChildren().size(), 1u);
    EXPECT_EQ((*group)->GetChildren().front()->Name(), "__we_text_101");
    EXPECT_NE((*group)->GetChildren().front()->Mesh(), nullptr);
}

TEST(SceneSchema, ParserKeepsInvisibleImageDependencySources) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":159,"name":"dependency source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":160,"name":"consumer","image":"image.json","dependencies":[159],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("invisible-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto source = FindRootChildByName(*parsed, "dependency source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_EQ(source->ID(), 159);
    ASSERT_NE(source->Mesh(), nullptr);
    auto consumer = FindRootChildByName(*parsed, "consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

TEST(SceneSchema, ParserKeepsTransitiveInvisibleImageDependencySources) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":159,"name":"transitive source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":200,"name":"hidden relay","image":"image.json","dependencies":[159],
         "origin":[4,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":201,"name":"visible consumer","image":"image.json","dependencies":[200],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("transitive-invisible-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto source = FindRootChildByName(*parsed, "transitive source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_EQ(source->ID(), 159);
    ASSERT_NE(source->Mesh(), nullptr);
    auto relay = FindRootChildByName(*parsed, "hidden relay");
    ASSERT_NE(relay, nullptr);
    EXPECT_FALSE(relay->Visible());
    auto consumer = FindRootChildByName(*parsed, "visible consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

TEST(SceneSchema, ParserKeepsTransitiveInvisibleImageDependenciesFromDynamicVisibleImageRoots) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":180,"name":"dynamic transitive source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":181,"name":"dynamic hidden relay","image":"image.json","dependencies":[180],
         "origin":[4,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":182,"name":"dynamic image consumer","image":"image.json","dependencies":[181],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],
         "visible":{"value":false,"script":"export function update(value) { return value; }"}}
      ]
    })";

    auto parsed =
        parser.Parse("dynamic-visible-image-root-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto source = FindRootChildByName(*parsed, "dynamic transitive source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    auto relay = FindRootChildByName(*parsed, "dynamic hidden relay");
    ASSERT_NE(relay, nullptr);
    EXPECT_FALSE(relay->Visible());
    auto consumer = FindRootChildByName(*parsed, "dynamic image consumer");
    ASSERT_NE(consumer, nullptr);
}

TEST(SceneSchema, ParserDoesNotRetainInvisibleImageDependenciesFromNonImageRoots) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":190,"name":"hidden image source from particle","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":191,"name":"visible particle root","particle":"particle.json","dependencies":[190],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("non-image-root-image-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    EXPECT_EQ(FindRootChildByName(*parsed, "hidden image source from particle"), nullptr);
    auto particle = FindRootChildByName(*parsed, "visible particle root");
    ASSERT_NE(particle, nullptr);
    EXPECT_TRUE(particle->Visible());
}

TEST(SceneSchema, ParserDoesNotRetainInvisibleNonImageDependencySources) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":170,"name":"hidden particle source","particle":"particle.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":171,"name":"image consumer","image":"image.json","dependencies":[170],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("invisible-non-image-dependency-source", scene, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    EXPECT_EQ(FindRootChildByName(*parsed, "hidden particle source"), nullptr);
    auto consumer = FindRootChildByName(*parsed, "image consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

TEST(SceneSchema, SchemaOnlyObjectPreservesRenderableChildParentTransform) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":200,"name":"text parent","text":"hello","origin":[25,0,0],"visible":true},
        {"id":201,"parent":200,"name":"image child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("schema-only-parent", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_TRUE(parsed->sceneGraph != nullptr);
    const auto& root_children = parsed->sceneGraph->GetChildren();
    auto parent = std::find_if(root_children.begin(), root_children.end(), [](const auto& node) {
        return node != nullptr && node->Name() == "text parent";
    });
    ASSERT_NE(parent, root_children.end());
    ASSERT_EQ((*parent)->GetChildren().size(), 1u);
    const auto& child = (*parent)->GetChildren().front();
    ASSERT_NE(child, nullptr);
    EXPECT_EQ(child->Name(), "image child");
    EXPECT_EQ(child->Parent(), parent->get());

    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 30.0, 1.0e-5);
}

TEST(SceneSchema, CameraUsesParentModelTransform) {
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate({ 10.0f, 20.0f, 30.0f });
    parent->SetRotation({ 0.0f, 0.0f, static_cast<float>(EIGEN_PI / 2.0) });

    auto child = std::make_shared<SceneNode>();
    child->SetTranslate({ 2.0f, 3.0f, 4.0f });
    parent->AppendChild(child);

    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(child);
    camera.Update();

    const auto position = camera.GetPosition();
    EXPECT_NEAR(position.x(), 7.0, 1.0e-5);
    EXPECT_NEAR(position.y(), 22.0, 1.0e-5);
    EXPECT_NEAR(position.z(), 34.0, 1.0e-5);

    const auto direction = camera.GetDirection();
    EXPECT_NEAR(direction.x(), 0.0, 1.0e-5);
    EXPECT_NEAR(direction.y(), 0.0, 1.0e-5);
    EXPECT_NEAR(direction.z(), -1.0, 1.0e-5);

    child->UpdateTrans();
    const auto expected_view = child->ModelTrans().inverse().eval();
    const auto actual_view   = camera.GetViewMatrix();
    EXPECT_TRUE(actual_view.isApprox(expected_view, 1.0e-5));
}

TEST(SceneSchema, CameraViewGetterUpdatesAfterParentTransformChange) {
    auto parent = std::make_shared<SceneNode>();
    auto child  = std::make_shared<SceneNode>();
    parent->AppendChild(child);

    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(child);
    const auto initial_view = camera.GetViewMatrix();
    EXPECT_NEAR(initial_view(0, 3), 0.0, 1.0e-5);

    parent->SetTranslate({ 12.0f, 0.0f, 0.0f });
    const auto updated_view = camera.GetViewMatrix();
    EXPECT_NEAR(updated_view(0, 3), -12.0, 1.0e-5);
}

TEST(SceneSchema, CameraViewMatrixUsesScaledModelTransformInverse) {
    auto node = std::make_shared<SceneNode>();
    node->SetTranslate({ 4.0f, 6.0f, 8.0f });
    node->SetScale({ 2.0f, 3.0f, 4.0f });

    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(node);

    node->UpdateTrans();
    const auto expected_view = node->ModelTrans().inverse().eval();
    const auto actual_view   = camera.GetViewMatrix();
    EXPECT_TRUE(actual_view.isApprox(expected_view, 1.0e-5));
}

TEST(SceneSchema, ParserPreservesDeclarationOrderWhenContainersAttachLate) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":200,"name":"early container","origin":[10,0,0],"visible":true},
        {"id":201,"name":"middle sibling","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":202,"parent":200,"name":"late child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("declaration-order-containers", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->sceneGraph, nullptr);

    const auto& root_children = parsed->sceneGraph->GetChildren();
    std::vector<std::shared_ptr<SceneNode>> named_root_children;
    for (const auto& child : root_children) {
        if (child != nullptr && ! child->Name().empty()) {
            named_root_children.push_back(child);
        }
    }
    ASSERT_GE(named_root_children.size(), 2u);
    const auto& first = named_root_children[0];
    const auto& second = named_root_children[1];
    ASSERT_NE(first, nullptr);
    ASSERT_NE(second, nullptr);
    EXPECT_EQ(first->Name(), "early container");
    EXPECT_EQ(second->Name(), "middle sibling");

    ASSERT_EQ(first->GetChildren().size(), 1u);
    const auto& late_child = first->GetChildren().front();
    ASSERT_NE(late_child, nullptr);
    EXPECT_EQ(late_child->Name(), "late child");
    EXPECT_EQ(late_child->Parent(), first.get());
    late_child->UpdateTrans();
    EXPECT_NEAR(late_child->ModelTrans()(0, 3), 15.0, 1.0e-5);
}

TEST(SceneSchema, ParserKeepsForwardReferencedParentInDeclarationOrder) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":302,"parent":300,"name":"early child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":301,"name":"middle root","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":300,"name":"late parent","origin":[10,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("forward-parent-declaration-order", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->sceneGraph, nullptr);

    const auto& root_children = parsed->sceneGraph->GetChildren();
    std::vector<std::shared_ptr<SceneNode>> named_root_children;
    for (const auto& child : root_children) {
        if (child != nullptr && ! child->Name().empty()) {
            named_root_children.push_back(child);
        }
    }

    ASSERT_GE(named_root_children.size(), 2u);
    ASSERT_NE(named_root_children[0], nullptr);
    ASSERT_NE(named_root_children[1], nullptr);
    EXPECT_EQ(named_root_children[0]->Name(), "middle root");
    EXPECT_EQ(named_root_children[1]->Name(), "late parent");

    ASSERT_EQ(named_root_children[1]->GetChildren().size(), 1u);
    const auto& early_child = named_root_children[1]->GetChildren().front();
    ASSERT_NE(early_child, nullptr);
    EXPECT_EQ(early_child->Name(), "early child");
    EXPECT_EQ(early_child->Parent(), named_root_children[1].get());
    early_child->UpdateTrans();
    EXPECT_NEAR(early_child->ModelTrans()(0, 3), 15.0, 1.0e-5);
}

TEST(SceneSchema, ImageEffectFinalTransformIncludesDeferredParentAttachment) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"effect_mat.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/effect_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"effect parent","origin":[40,0,0],"visible":true},
        {"id":301,"parent":300,"name":"nested effect","image":"image.json",
         "origin":[6,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/copy/effect.json","id":302,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("nested-effect-final-transform", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto parent = FindRootChildByName(*parsed, "effect parent");
    ASSERT_NE(parent, nullptr);
    auto* child = FindFirstChildByName(*parent, "nested effect");
    ASSERT_NE(child, nullptr);
    ASSERT_FALSE(child->Camera().empty());

    auto camera = parsed->cameras.find(child->Camera());
    ASSERT_NE(camera, parsed->cameras.end());
    ASSERT_NE(camera->second, nullptr);
    ASSERT_TRUE(camera->second->HasImgEffect());

    auto& final_node = camera->second->GetImgEffect()->FinalNode();
    final_node.UpdateTrans();
    EXPECT_NEAR(final_node.RenderTrans()(0, 3), 46.0, 1.0e-5);
}

TEST(SceneSchema, PassthroughImageEffectBaseMeshUsesLayerLocalCardGeometry) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/models/util/composelayer.json",
          R"({"width":64,"height":32,"passthrough":true,"material":"materials/base_passthrough.json"})" },
        { "/materials/base_passthrough.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"passthrough","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/effect_copy.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/materials/effect_copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"effectcopy","textures":[null]}]})" },
        { "/shaders/passthrough.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/passthrough.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/effectcopy.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/effectcopy.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":401,"name":"green audio bars","image":"models/util/composelayer.json",
         "origin":[180,90,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "config":{"passthrough":true},
         "effects":[{"file":"effects/copy/effect.json","id":402,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("passthrough-effect-local-card", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "green audio bars");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->Submeshes().size(), 1u);
    ASSERT_EQ(node->Mesh()->Submeshes()[0].VertexCount(), 1u);
    const auto& vertices = node->Mesh()->Submeshes()[0].GetVertexArray(0);
    ASSERT_EQ(vertices.VertexCount(), 4u);

    EXPECT_EQ(VertexPosition(vertices, 0), (std::array<float, 3> { -32.0f, -16.0f, 0.0f }));
    EXPECT_EQ(VertexPosition(vertices, 1), (std::array<float, 3> { -32.0f, 16.0f, 0.0f }));
    EXPECT_EQ(VertexPosition(vertices, 2), (std::array<float, 3> { 32.0f, -16.0f, 0.0f }));
    EXPECT_EQ(VertexPosition(vertices, 3), (std::array<float, 3> { 32.0f, 16.0f, 0.0f }));
}

TEST(SceneSchema, PassthroughNonComposeImageEffectKeepsProjectionBakedBaseMesh) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json",
          R"({"width":64,"height":32,"passthrough":true,"material":"materials/base_passthrough.json"})" },
        { "/materials/base_passthrough.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"passthrough","textures":["a.tex"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/effect_copy.json","bind":[{"name":"previous","index":0}]}]})" },
        { "/materials/effect_copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"effectcopy","textures":[null]}]})" },
        { "/shaders/passthrough.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/passthrough.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/effectcopy.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/effectcopy.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":501,"name":"regular passthrough effect","image":"image.json",
         "origin":[180,90,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "config":{"passthrough":true},
         "effects":[{"file":"effects/copy/effect.json","id":502,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("passthrough-non-compose-effect", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "regular passthrough effect");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->Submeshes().size(), 1u);
    ASSERT_EQ(node->Mesh()->Submeshes()[0].VertexCount(), 1u);
    const auto& vertices = node->Mesh()->Submeshes()[0].GetVertexArray(0);
    ASSERT_EQ(vertices.VertexCount(), 4u);

    EXPECT_NE(VertexPosition(vertices, 0), (std::array<float, 3> { -32.0f, -16.0f, 0.0f }));
    EXPECT_NE(VertexUv(vertices, 0), (std::array<float, 2> { 0.0f, 1.0f }));
    ExpectVec3Near(
        VertexPosition(vertices, 0), { -0.5375f, -0.5888889f, 0.0f }, 1.0e-6f);
    ExpectVec3Near(
        VertexPosition(vertices, 1), { -0.5375f, -0.41111112f, 0.0f }, 1.0e-6f);
    ExpectVec3Near(
        VertexPosition(vertices, 2), { -0.3375f, -0.5888889f, 0.0f }, 1.0e-6f);
    ExpectVec3Near(
        VertexPosition(vertices, 3), { -0.3375f, -0.41111112f, 0.0f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 0), { 0.23125f, 0.79444444f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 1), { 0.23125f, 0.70555556f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 2), { 0.33125f, 0.79444444f }, 1.0e-6f);
    ExpectVec2Near(VertexUv(vertices, 3), { 0.33125f, 0.70555556f }, 1.0e-6f);
}

TEST(SceneSchema, ImageChildAttachmentAnchorsToParentPuppetMdat) {
    fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/puppet_image.json",
          R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})" },
        { "/puppet.mdl", BuildAttachmentPuppetMdlFixture() },
        { "/mat/base.json", PuppetMaterialJson("baseimage", "base.tex") },
        { "/mat/head.json", PuppetMaterialJson("headimage", "head.tex") },
        { "/child_image.json", R"({"width":16,"height":8,"material":"mat/child.json"})" },
        { "/mat/child.json", PuppetMaterialJson("childimage", "child.tex") },
        { "/shaders/baseimage.vert", R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/baseimage.frag", R"(
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/headimage.vert", R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/headimage.frag", R"(
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/childimage.vert", R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/childimage.frag", R"(
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/base.tex.tex", "" },
        { "/materials/head.tex.tex", "" },
        { "/materials/child.tex.tex", "" },
    };
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    const std::string   scene = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"puppet parent","image":"puppet_image.json",
         "origin":[10,20,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":301,"name":"hat child","parent":300,"attachment":"hat_anchor",
         "image":"child_image.json","origin":[1,2,3],"scale":[1,1,1],
         "angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("attachment-child", scene, vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    auto parent = FindRootChildByName(*parsed, "puppet parent");
    ASSERT_NE(parent, nullptr);
    auto* child = FindFirstChildByName(*parent, "hat child");
    ASSERT_NE(child, nullptr);
    EXPECT_EQ(child->Parent(), parent.get());

    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 15.0, 1.0e-5);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 27.0, 1.0e-5);
    EXPECT_NEAR(child->ModelTrans()(2, 3), 9.0, 1.0e-5);
    auto reordered = nlohmann::json::parse(scene);
    std::reverse(reordered["objects"].begin(), reordered["objects"].end());
    auto reversed = parser.Parse("attachment-child-reversed", reordered.dump(), vfs, sound_manager);
    ASSERT_NE(reversed, nullptr);
    auto reversed_parent = FindRootChildByName(*reversed, "puppet parent");
    ASSERT_NE(reversed_parent, nullptr);
    auto* reversed_child = FindFirstChildByName(*reversed_parent, "hat child");
    ASSERT_NE(reversed_child, nullptr);
    reversed_child->UpdateTrans();
    EXPECT_TRUE(reversed_child->ModelTrans().isApprox(child->ModelTrans(), 1e-6));
}

TEST(SceneSchema, PuppetAttachmentFollowsAnimatedAffineAndPreservesLocalEdits) {
    Scene scene;
    WPShaderValueUpdater updater(&scene);
    updater.SetCameraParallax({ false, 0.0f, 1.0f, 0.0f });
    auto puppet = std::make_shared<WPPuppet>();
    auto& root = puppet->bones.emplace_back();
    root.local_bind.translate(Eigen::Vector3f(100, 200, 0));
    auto& animation = puppet->anims.emplace_back();
    animation.id = 1;
    animation.fps = 1;
    animation.length = 1;
    animation.mode = WPPuppet::PlayMode::Single;
    auto& track = animation.bone_tracks.emplace_back();
    track.frames.push_back({ Eigen::Vector3f(10, 20, 0), Eigen::Vector3f::Zero(),
                             Eigen::Vector3f::Ones() });
    track.frames.push_back({ Eigen::Vector3f(30, 40, 0), Eigen::Vector3f(0, 0, 1.57079632679f),
                             Eigen::Vector3f(2, 3, 1) });
    puppet->prepared();
    WPPuppetLayer layer(puppet);
    WPPuppetLayer::AnimationLayer settings;
    settings.id = 1;
    layer.prepared(std::span(&settings, 1));
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate(Eigen::Vector3f(5, 7, 0));
    parent->SetScale(Eigen::Vector3f(2, 2, 1));
    auto child = std::make_shared<SceneNode>();
    child->SetTranslate(Eigen::Vector3f(1, 2, 0));
    parent->AppendChild(child);
    auto attachment = puppet->bones[0].world_bind;
    attachment.translate(Eigen::Vector3f(4, 5, 0));
    updater.RegisterPuppetAttachments(layer, { { child.get(), 0, attachment } });
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 35, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 61, 1e-4);
    scene.PassFrameTime(1.0);
    updater.FrameBegin();
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 23, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 107, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(0, 1), -6, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 0), 4, 1e-4);
    const Eigen::Matrix4d sampled = child->ModelTrans();
    updater.FrameBegin();
    child->UpdateTrans();
    EXPECT_TRUE(child->ModelTrans().isApprox(sampled, 1e-6));
    child->SetTranslate(Eigen::Vector3f(3, 2, 0));
    updater.FrameBegin();
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 23, 1e-4);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 115, 1e-4);
    SceneCamera camera(640, 360, 0.01f, 100.0f);
    scene.activeCamera = &camera;
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    parent->AddMesh(mesh);
    WPShaderValueData shader_data;
    shader_data.puppet_layer = layer;
    updater.SetNodeData(parent.get(), shader_data);
    updater.InitUniforms(parent.get(), [](std::string_view name) { return name == "g_Bones"; });
    sprite_map_t sprites;
    Eigen::Matrix4f uniform = Eigen::Matrix4f::Zero();
    int bone_updates = 0;
    const auto capture_bones = [&](std::string_view name, const ShaderValue& value) {
        if (name != "g_Bones") return;
        ASSERT_EQ(value.size(), 16u);
        for (int i = 0; i < 16; ++i) uniform.data()[i] = value[i];
        ++bone_updates;
    };
    updater.UpdateUniforms(parent.get(), sprites, capture_bones);
    ASSERT_EQ(bone_updates, 1);
    ASSERT_TRUE(layer.setFrame(0, 0.5));
    updater.FrameBegin();
    updater.UpdateUniforms(parent.get(), sprites, capture_bones);
    ASSERT_EQ(bone_updates, 2);
    Eigen::Affine3f expected = Eigen::Affine3f::Identity();
    expected.translate(Eigen::Vector3f(20, 30, 0));
    expected.rotate(Eigen::AngleAxisf(0.785398163395f, Eigen::Vector3f::UnitZ()));
    expected.scale(Eigen::Vector3f(1.5f, 2.0f, 1.0f));
    expected = expected * puppet->bones[0].inv_bind;
    EXPECT_TRUE(uniform.isApprox(expected.matrix(), 1e-5));
    Eigen::Affine3d local = Eigen::Affine3d::Identity();
    local.translate(Eigen::Vector3d(3, 2, 0));
    child->UpdateTrans();
    EXPECT_TRUE(child->ModelTrans().isApprox(
        parent->ModelTrans() * (expected * attachment).matrix().cast<double>() * local.matrix(), 1e-5));
    child->SetTranslate(Eigen::Vector3f(4, 6, 0));
    updater.FrameBegin();
    updater.UpdateUniforms(parent.get(), sprites, capture_bones);
    ASSERT_EQ(bone_updates, 3);
    EXPECT_TRUE(uniform.isApprox(expected.matrix(), 1e-5));
    local = Eigen::Affine3d::Identity();
    local.translate(Eigen::Vector3d(4, 6, 0));
    child->UpdateTrans();
    EXPECT_TRUE(child->ModelTrans().isApprox(
        parent->ModelTrans() * (expected * attachment).matrix().cast<double>() * local.matrix(), 1e-5));
    scene.activeCamera = nullptr;
}

TEST(SceneSchema, ParserUsesStableRuntimeNamesForDuplicateGenericLayerNames) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "duplicate-layer-names",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":400,"height":300}
      },
      "objects": [
        {
          "id": 10,
          "name": "tap target",
          "origin": [100,150,0],
          "visible": {
            "value": true,
            "script": "export function update(value) { return value; }"
          }
        },
        {
          "id": 11,
          "name": "tap target",
          "origin": [300,150,0],
          "visible": {
            "value": true,
            "script": "export function update(value) { return value; }"
          }
        }
      ]
    })",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("tap target"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_10"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_11"));
}

TEST(SceneSchema, ParserUsesStableRuntimeNamesForDuplicateImageLayerNames) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "duplicate-image-layer-names",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":400,"height":300}
      },
      "objects": [
        {
          "id": 20,
          "name": "tap target",
          "image": "image.json",
          "origin": [100,150,0],
          "size": [64,32],
          "visible": true
        },
        {
          "id": 21,
          "name": "tap target",
          "image": "image.json",
          "origin": [300,150,0],
          "size": [64,32],
          "visible": true
        }
      ]
    })",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("tap target"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_20"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_layer_21"));
    EXPECT_EQ(scene->runtime->NodeSize("__we_layer_20"), Eigen::Vector2f(64.0f, 32.0f));
    EXPECT_EQ(scene->runtime->NodeSize("__we_layer_21"), Eigen::Vector2f(64.0f, 32.0f));
}

TEST(SceneSchema, CallbackOnlyDuplicateButtonsToggleNamedGroupsThroughParser) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    WPSceneParser parser;
    const nlohmann::json setting = {
        {"value", true}, {"script", R"JS(
export var scriptProperties = createScriptProperties()
    .addText({name: 'target', value: 'missing'}).finish();
let visible;
export function init(value) { visible = true; return value; }
export function cursorClick() {
    visible = !visible;
    thisScene.getLayer(scriptProperties.target).visible = visible;
}
)JS"}, {"scriptproperties", {{"target", "mode"}}}};
    const nlohmann::json source = {
        {"camera", {{"center", {0, 0, 0}}, {"eye", {0, 0, 1}}, {"up", {0, 1, 0}}}},
        {"general", {{"ambientcolor", {0, 0, 0}}, {"skylightcolor", {0, 0, 0}},
                     {"clearcolor", {0, 0, 0}}, {"cameraparallax", false},
                     {"orthogonalprojection", {{"width", 400}, {"height", 300}}}}},
        {"objects", nlohmann::json::array({
            {{"id", 1}, {"name", "mode"}, {"visible", true}},
            {{"id", 2}, {"name", "content"}, {"image", "image.json"}, {"parent", 1}},
            {{"id", 3}, {"name", "button"}, {"image", "image.json"},
             {"origin", {200, 150, 0}}, {"size", {80, 80}}, {"visible", setting}},
            {{"id", 4}, {"name", "button"}, {"image", "image.json"}, {"parent", 3},
             {"scale", {0.9, 0.9, 1}}, {"size", {80, 80}}, {"visible", setting}}
        })}
    };
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "callback-buttons", .project_properties = &properties,
    }, source.dump(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(0.01);
    runtime.SetCursorInput(0.5f, 0.5f);
    runtime.SetCursorEnter(true);
    for (bool visible : {false, true, false}) {
        runtime.SetCursorButtons(0, 1, 1);
        runtime.DispatchCursorFrameEvents(true);
        runtime.SetCursorButtons(0, 0, 0);
        runtime.Tick(0.01);
        EXPECT_EQ(runtime.NodeVisible("mode"), visible);
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    WPSceneParser        parser;
    // Authored "value" is the initial state handed to the script, not a licence
    // to run it: a layer hidden at authoring time must still follow update().
    const auto visibility = [](const char* property) {
        return nlohmann::json {
            { "value", false },
            { "script", std::string(R"JS(
let on = false;
export function applyUserProperties(changed) { if (changed.hasOwnProperty(')JS") +
                            property + R"JS(')) on = changed.)JS" + property + R"JS(; }
export function update() { return on; }
)JS" },
        };
    };
    const nlohmann::json source = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0, 0, 0 } },
            { "skylightcolor", { 0, 0, 0 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } } },
        { "objects",
          nlohmann::json::array(
              { { { "id", 11 },
                  { "name", "shown by script" },
                  { "image", "image.json" },
                  { "size", { 80, 60 } },
                  { "origin",
                    { { "value", { 0, 0, 0 } },
                      { "script", "export function update() { return new Vec3(30, 0, 0); }" } } },
                  { "visible", visibility("show_first") } },
                { { "id", 12 },
                  { "name", "hidden by script" },
                  { "image", "image.json" },
                  { "size", { 80, 60 } },
                  { "visible", visibility("show_second") } } }) }
    };
    ProjectProperties properties {
        { "show_first", RuntimeScalarValue::Bool(true) },
        { "show_second", RuntimeScalarValue::Bool(false) },
    };
    auto scene = parser.Parse(SceneParseRequest {
                                  .scene_id           = "hidden-default-visibility-script",
                                  .project_properties = &properties,
                              },
                              source.dump(),
                              vfs,
                              sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(0.01);

    auto shown = FindRootChildByName(*scene, "shown by script");
    ASSERT_NE(shown, nullptr);
    EXPECT_TRUE(shown->Visible());
    EXPECT_FLOAT_EQ(shown->Translate().x(), 30.0f);
    auto hidden = FindRootChildByName(*scene, "hidden by script");
    ASSERT_NE(hidden, nullptr);
    EXPECT_FALSE(hidden->Visible());
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, ImageAlignmentAnchorSurvivesScriptedOriginAndScale) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound;
    WPSceneParser        parser;
    const nlohmann::json source = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0, 0, 0 } },
            { "skylightcolor", { 0, 0, 0 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } } },
        { "objects",
          nlohmann::json::array(
              { { { "id", 21 },
                  { "name", "scripted origin" },
                  { "image", "image.json" },
                  { "alignment", "bottom" },
                  { "size", { 200, 100 } },
                  { "visible", true },
                  { "origin",
                    { { "value", { 50, 0, 0 } },
                      { "script", "export function update(value) { return value; }" } } } },
                { { "id", 22 },
                  { "name", "scaled anchor" },
                  { "image", "image.json" },
                  { "alignment", "left" },
                  { "size", { 100, 100 } },
                  { "scale", { 2, 2, 1 } },
                  { "visible", true },
                  { "origin", { 10, 0, 0 } } },
                { { "id", 23 },
                  { "name", "scripted scale anchor" },
                  { "image", "image.json" },
                  { "alignment", "left" },
                  { "size", { 100, 100 } },
                  { "visible", true },
                  { "origin", { 10, 0, 0 } },
                  { "scale",
                    { { "value", { 2, 2, 1 } },
                      { "script",
                        "export function update() { return new Vec3(0.5, 0.5, 1); }" } } } } }) }
    };
    ProjectProperties properties;
    auto              scene = parser.Parse(SceneParseRequest {
                                  .scene_id           = "image-alignment-anchor",
                                  .project_properties = &properties,
                              },
                              source.dump(),
                              vfs,
                              sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    // The layer size comes from the mounted image, so express the anchor offset
    // in terms of the registered size instead of fixture constants.
    const auto scripted_size = runtime.NodeSize("scripted origin");
    const auto scaled_size   = runtime.NodeSize("scaled anchor");

    // A scripted origin replaces the translate every tick, so the anchor offset
    // has to be re-derived instead of being baked in once at parse time.
    auto scripted = FindRootChildByName(*scene, "scripted origin");
    ASSERT_NE(scripted, nullptr);
    EXPECT_FLOAT_EQ(scripted->Translate().y(), scripted_size.y() * 0.5f);
    runtime.Tick(0.01);
    EXPECT_FLOAT_EQ(scripted->Translate().x(), 50.0f);
    EXPECT_FLOAT_EQ(scripted->Translate().y(), scripted_size.y() * 0.5f);

    // The anchor sits on the scaled edge, so scale participates in the offset.
    auto scaled = FindRootChildByName(*scene, "scaled anchor");
    ASSERT_NE(scaled, nullptr);
    EXPECT_FLOAT_EQ(scaled->Translate().x(), 10.0f + scaled_size.x() * 2.0f * 0.5f);

    // Every Register* helper re-registers the node; the anchor origin must stay
    // the authored origin so a scripted scale replaces the offset, never stacks
    // a second one on top of it.
    const auto scripted_scale_size = runtime.NodeSize("scripted scale anchor");
    auto       scripted_scale      = FindRootChildByName(*scene, "scripted scale anchor");
    ASSERT_NE(scripted_scale, nullptr);
    EXPECT_FLOAT_EQ(scripted_scale->Scale().x(), 0.5f);
    EXPECT_FLOAT_EQ(scripted_scale->Translate().x(),
                    10.0f + scripted_scale_size.x() * 0.5f * 0.5f);
    runtime.Tick(0.01);
    EXPECT_FLOAT_EQ(scripted_scale->Translate().x(),
                    10.0f + scripted_scale_size.x() * 0.5f * 0.5f);
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(SceneSchema, DuplicateParsedImageClickScriptsGateRealAssetSoundLayers) {
    fs::VFS vfs;
    MountSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "click_count", RuntimeScalarValue::String("2") },
    };
    SceneParseRequest request {
        .scene_id           = "duplicate-click-script-sounds",
        .project_properties = &properties,
    };

    const auto click_script = R"JS(
'use strict';
export var scriptProperties = createScriptProperties()
  .addText({ name: 'count1', label: 'Count1', value: '1' })
  .addText({ name: 'voice1', label: 'Voice1', value: 'Voice1' })
  .addText({ name: 'count2', label: 'Count2', value: '2' })
  .addText({ name: 'voice2', label: 'Voice2', value: 'Voice2' })
  .addText({ name: 'waitingtime', label: 'Waitingtime', value: '1.0' })
  .finish();
var count = 0;
var waitingtime = 0;
export function cursorClick() {
  waitingtime = 0;
  count++;
  if (count == scriptProperties.count1)
    thisScene.getLayer(scriptProperties.voice1).play();
  if (count == scriptProperties.count2)
    thisScene.getLayer(scriptProperties.voice2).play();
}
export function update(value) {
  if (count != 0) waitingtime += engine.frametime;
  if (waitingtime > scriptProperties.waitingtime) {
    waitingtime = 0;
    count = 0;
  }
}
)JS";
    const auto script_setting = [&](std::string_view sound_name) {
        return nlohmann::json {
            { "value", true },
            { "script", click_script },
            { "scriptproperties",
              nlohmann::json {
                  { "count1",
                    nlohmann::json {
                        { "user", "click_count" },
                        { "value",
                          nlohmann::json {
                              { "user", "unused_default" },
                              { "value", "2" },
                          } },
                    } },
                  { "count2", "200" },
                  { "voice1", std::string(sound_name) },
                  { "voice2", "Voice2" },
                  { "waitingtime", "1.0" },
              } },
        };
    };

    nlohmann::json scene_json = {
        { "camera", { { "center", { 0, 0, 0 } }, { "eye", { 0, 0, 1 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          {
              { "ambientcolor", { 0, 0, 0 } },
              { "skylightcolor", { 0, 0, 0 } },
              { "clearcolor", { 0, 0, 0 } },
              { "cameraparallax", false },
              { "cameraparallaxamount", 0 },
              { "cameraparallaxdelay", 0 },
              { "cameraparallaxmouseinfluence", 0 },
              { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } },
          } },
        { "objects",
          nlohmann::json::array(
              { {
                    { "id", 43 },
                    { "name", "tap target" },
                    { "image", "image.json" },
                    { "origin", { 100, 150, 0 } },
                    { "size", { 80, 80 } },
                    { "visible", script_setting("headAudio") },
                },
                {
                    { "id", 59 },
                    { "name", "tap target" },
                    { "image", "image.json" },
                    { "origin", { 200, 150, 0 } },
                    { "size", { 80, 80 } },
                    { "visible", script_setting("bodyAudio") },
                },
                {
                    { "id", 62 },
                    { "name", "tap target" },
                    { "image", "image.json" },
                    { "origin", { 300, 150, 0 } },
                    { "size", { 80, 80 } },
                    { "visible", script_setting("legAudio") },
                },
                {
                    { "id", 74 },
                    { "name", "bodyAudio" },
                    { "sound", nlohmann::json::array({ "sounds/body.wav" }) },
                    { "playbackmode", "single" },
                    { "startsilent", true },
                },
                {
                    { "id", 75 },
                    { "name", "headAudio" },
                    { "sound", nlohmann::json::array({ "sounds/head.wav" }) },
                    { "playbackmode", "single" },
                    { "startsilent", true },
                },
                {
                    { "id", 77 },
                    { "name", "legAudio" },
                    { "sound", nlohmann::json::array({ "sounds/leg.wav" }) },
                    { "playbackmode", "single" },
                    { "startsilent", true },
                },
                {
                    { "id", 69 },
                    { "name", "backgroundAudio" },
                    { "sound", nlohmann::json::array({ "sounds/background.wav" }) },
                    { "playbackmode", "loop" },
                    { "startsilent", false },
                } }) },
    };

    auto scene = parser.Parse(request, scene_json.dump(), vfs, sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->runtime->SoundLayerPlaying("backgroundAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));

    scene->runtime->SetCursorInput(0.5f, 0.5f);
    scene->runtime->SetCursorEnter(true);
    bool cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(false);
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));

    scene->runtime->SetCursorButtons(0u, 1u, 0u);
    cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));

    scene->runtime->SetCursorButtons(0u, 0u, 0u);
    cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    scene->runtime->Tick(1.0 / 60.0);
    scene->runtime->SetCursorButtons(0u, 1u, 0u);
    cursor_was_in_window = scene->runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(cursor_was_in_window);
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("headAudio"));
    EXPECT_TRUE(scene->runtime->SoundLayerPlaying("bodyAudio"));
    EXPECT_FALSE(scene->runtime->SoundLayerPlaying("legAudio"));
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(SceneSchema, ParserBuildsLdrBloomPostProcessWhenBloomEnabledWithoutHdr) {
    fs::VFS vfs;
    MountBloomSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("ldr-bloom", BloomSceneJson(false), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);

    ASSERT_EQ(parsed->post_processes.size(), 1u);
    ASSERT_NE(parsed->post_processes[0], nullptr);
    const auto& bloom = *parsed->post_processes[0];
    EXPECT_EQ(bloom.name, "__bloom");
    ASSERT_EQ(bloom.steps.size(), 5u);

    const auto* pass0 = PostProcessPassAt(bloom, 0);
    const auto* pass1 = PostProcessPassAt(bloom, 1);
    const auto* pass2 = PostProcessPassAt(bloom, 2);
    const auto* pass3 = PostProcessPassAt(bloom, 3);
    const auto* copy  = PostProcessCopyAt(bloom, 4);
    ASSERT_NE(pass0, nullptr);
    ASSERT_NE(pass1, nullptr);
    ASSERT_NE(pass2, nullptr);
    ASSERT_NE(pass3, nullptr);
    ASSERT_NE(copy, nullptr);
    EXPECT_EQ(pass0->output, "_rt_bloom_mip1");
    EXPECT_EQ(pass1->output, "_rt_bloom_mip2");
    EXPECT_EQ(pass2->output, "_rt_bloom_mip1");
    EXPECT_EQ(pass3->output, "_rt_bloom_combine");
    EXPECT_EQ(copy->src, "_rt_bloom_combine");
    EXPECT_EQ(copy->dst, SpecTex_Default);

    ASSERT_NE(pass0->node, nullptr);
    ASSERT_NE(pass1->node, nullptr);
    ASSERT_NE(pass2->node, nullptr);
    ASSERT_NE(pass3->node, nullptr);
    ASSERT_NE(pass0->node->Mesh(), nullptr);
    ASSERT_NE(pass0->node->Mesh()->Material(), nullptr);
    const auto& constants = pass0->node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(constants.contains("g_BloomStrength"));
    ASSERT_TRUE(constants.contains("g_BloomThreshold"));
    ASSERT_TRUE(constants.contains("g_BloomTint"));
    EXPECT_FLOAT_EQ(constants.at("g_BloomStrength")[0], 1.5f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomThreshold")[0], 0.25f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[0], 0.2f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[1], 0.4f);
    EXPECT_FLOAT_EQ(constants.at("g_BloomTint")[2], 0.6f);

    ExpectTextureResolution(*pass1, 160, 90);
    ExpectTextureResolution(*pass2, 80, 45);
    ExpectTextureResolution(*pass3, 640, 360);

    const auto* default_rt = parsed->FindRenderTarget(SpecTex_Default);
    const auto* mip1_rt    = parsed->FindRenderTarget("_rt_bloom_mip1");
    const auto* mip2_rt    = parsed->FindRenderTarget("_rt_bloom_mip2");
    const auto* combine_rt = parsed->FindRenderTarget("_rt_bloom_combine");
    ASSERT_NE(default_rt, nullptr);
    ASSERT_NE(mip1_rt, nullptr);
    ASSERT_NE(mip2_rt, nullptr);
    ASSERT_NE(combine_rt, nullptr);
    EXPECT_TRUE(default_rt->bind.enable);
    EXPECT_TRUE(default_rt->bind.screen);
    EXPECT_EQ(default_rt->width, 640);
    EXPECT_EQ(default_rt->height, 360);
    EXPECT_TRUE(mip1_rt->bind.enable);
    EXPECT_TRUE(mip1_rt->bind.screen);
    EXPECT_DOUBLE_EQ(mip1_rt->bind.scale, 0.25);
    EXPECT_EQ(mip1_rt->width, 160);
    EXPECT_EQ(mip1_rt->height, 90);
    EXPECT_TRUE(mip2_rt->bind.enable);
    EXPECT_TRUE(mip2_rt->bind.screen);
    EXPECT_DOUBLE_EQ(mip2_rt->bind.scale, 0.125);
    EXPECT_EQ(mip2_rt->width, 80);
    EXPECT_EQ(mip2_rt->height, 45);
    EXPECT_TRUE(combine_rt->bind.enable);
    EXPECT_TRUE(combine_rt->bind.screen);
    EXPECT_DOUBLE_EQ(combine_rt->bind.scale, 1.0);
    EXPECT_EQ(combine_rt->width, 640);
    EXPECT_EQ(combine_rt->height, 360);
}

TEST(SceneSchema, ParserDoesNotBuildLdrBloomPostProcessWhenHdrBloomEnabled) {
    fs::VFS vfs;
    MountBloomSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("hdr-bloom", BloomSceneJson(true), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->post_processes.empty());
}

TEST(SceneSchema, ParserDoesNotCommitPartialBloomStateWhenMaterialLoadFails) {
    fs::VFS vfs;
    MountBrokenBloomSceneFiles(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("broken-ldr-bloom", BloomSceneJson(false), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->post_processes.empty());
    EXPECT_EQ(parsed->FindRenderTarget("_rt_bloom_mip1"), nullptr);
    EXPECT_EQ(parsed->FindRenderTarget("_rt_bloom_mip2"), nullptr);
    EXPECT_EQ(parsed->FindRenderTarget("_rt_bloom_combine"), nullptr);
}

TEST(SceneSchema, ParserLoadsPuppetMeshMaterialSlotsFromPerMeshMaterialFiles) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slots", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    ASSERT_EQ(mesh.MaterialSlots().size(), 2u);
    ASSERT_NE(mesh.MaterialForSlot(0), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(1), nullptr);
    EXPECT_EQ(mesh.MaterialForSlot(0)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(1)->name, "eyesimage");
    ASSERT_EQ(mesh.MaterialForSlot(0)->textures.size(), 1u);
    ASSERT_EQ(mesh.MaterialForSlot(1)->textures.size(), 1u);
    EXPECT_EQ(mesh.MaterialForSlot(0)->textures[0], "head.tex");
    EXPECT_EQ(mesh.MaterialForSlot(1)->textures[0], "eyes.tex");
}

TEST(SceneSchema, ParserKeepsMeshOnlyPuppetMaterialSlotsWithoutMdlsBlock) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files, true, false, true);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("mesh-only-puppet-slots", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    ASSERT_EQ(mesh.MaterialSlots().size(), 2u);
    ASSERT_NE(mesh.MaterialForSlot(0), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(1), nullptr);
    EXPECT_EQ(mesh.MaterialForSlot(0)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(1)->name, "eyesimage");
    ASSERT_EQ(mesh.MaterialForSlot(0)->textures.size(), 1u);
    ASSERT_EQ(mesh.MaterialForSlot(1)->textures.size(), 1u);
    EXPECT_EQ(mesh.MaterialForSlot(0)->textures[0], "head.tex");
    EXPECT_EQ(mesh.MaterialForSlot(1)->textures[0], "eyes.tex");
}

TEST(SceneSchema, ParserAlignsMaskedMultiMeshPuppetMaterialSlotsWithSubmeshes) {
    auto files = std::map<std::string, std::string> {};
    AddMaskedTwoMeshPuppetSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("masked-puppet-slots", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 4u);
    ASSERT_EQ(mesh.MaterialSlots().size(), 4u);

    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    EXPECT_EQ(mesh.Submeshes()[1].output_override, "_rt_puppet_mask");
    EXPECT_EQ(mesh.Submeshes()[2].material_slot, 2u);
    EXPECT_EQ(mesh.Submeshes()[3].material_slot, 3u);

    ASSERT_NE(mesh.MaterialForSlot(0), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(1), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(2), nullptr);
    ASSERT_NE(mesh.MaterialForSlot(3), nullptr);
    EXPECT_EQ(mesh.MaterialForSlot(0)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(1)->name, "clippingmaskimage4");
    EXPECT_EQ(mesh.MaterialForSlot(2)->name, "headimage");
    EXPECT_EQ(mesh.MaterialForSlot(3)->name, "eyesimage");
    ASSERT_FALSE(mesh.MaterialForSlot(2)->textures.empty());
    ASSERT_FALSE(mesh.MaterialForSlot(3)->textures.empty());
    EXPECT_EQ(mesh.MaterialForSlot(2)->textures[0], "head.tex");
    EXPECT_EQ(mesh.MaterialForSlot(3)->textures[0], "eyes.tex");
}

TEST(SceneSchema, ParserBuildsMeshOnlyPuppetSubmeshesWithMeshVertexLayout) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files, true, false, true);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("mesh-only-puppet-layout", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    ASSERT_EQ(mesh.Submeshes()[0].VertexCount(), 1u);
    const auto& attrs = mesh.Submeshes()[0].GetVertexArray(0).Attributes();
    ASSERT_EQ(attrs.size(), 2u);
    EXPECT_EQ(attrs[0].name, std::string(WE_IN_POSITION));
    EXPECT_EQ(attrs[0].type, VertexType::FLOAT3);
    EXPECT_EQ(attrs[1].name, std::string(WE_IN_TEXCOORD));
    EXPECT_EQ(attrs[1].type, VertexType::FLOAT2);
}

TEST(SceneSchema, ParserAppliesPuppetMaterialInfoBeforeLoadingSlotMaterials) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-combos", BasicPuppetSceneJson(true), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
    for (uint32_t slot = 0; slot < 2; ++slot) {
        const auto* material = node->Mesh()->MaterialForSlot(slot);
        ASSERT_NE(material, nullptr);
        ASSERT_NE(material->customShader.shader, nullptr);
        EXPECT_GT(material->customShader.shader->codes[0].size(), 0u);
    }
    EXPECT_FLOAT_EQ(node->Mesh()->MaterialForSlot(0)->customShader.constValues.at("g_Alpha")[0],
                    0.6f);
    EXPECT_FLOAT_EQ(node->Mesh()->MaterialForSlot(1)->customShader.constValues.at("g_Alpha")[0],
                    0.6f);
}

TEST(SceneSchema, ParserRegistersPuppetSlotShaderValueDataByMaterialSlot) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetSlotRenderTargetSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-render-targets", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(parsed->shaderValueUpdater, nullptr);
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(parsed->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_Texture0Resolution";
    });

    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    updater->UpdateUniforms(node.get(), 1, sprites, [&](std::string_view name, const ShaderValue& value) {
        updates.emplace(std::string(name), value);
    });

    ASSERT_TRUE(updates.contains("g_Texture0Resolution"));
    EXPECT_FLOAT_EQ(updates.at("g_Texture0Resolution")[0], 160.0f);
    EXPECT_FLOAT_EQ(updates.at("g_Texture0Resolution")[1], 90.0f);
}

TEST(SceneSchema, ParserCopiesImageParallaxDepthToPuppetMaterialSlots) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-parallax", PuppetParallaxSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
    ASSERT_NE(parsed->shaderValueUpdater, nullptr);
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(parsed->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_ModelMatrix";
    });

    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    updater->UpdateUniforms(node.get(), 1, sprites, [&](std::string_view name, const ShaderValue& value) {
        updates.emplace(std::string(name), value);
    });

    ASSERT_TRUE(updates.contains("g_ModelMatrix"));
    EXPECT_NE(updates.at("g_ModelMatrix")[12], 0.0f);
    EXPECT_NE(updates.at("g_ModelMatrix")[13], 0.0f);
}

TEST(SceneSchema, ParserKeepsLegacyEmptyPuppetMeshSingleMaterialSlotFallback) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files, true, true);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("legacy-puppet-slot", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& mesh = *node->Mesh();
    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    ASSERT_EQ(mesh.Submeshes()[0].VertexCount(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].GetVertexArray(0).VertexCount(), 3u);
    ASSERT_EQ(mesh.Submeshes()[0].IndexCount(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].GetIndexArray(0).DataCount(), 2u);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 1u);
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    EXPECT_EQ(node->Mesh()->Material()->name, "baseimage");
}

TEST(SceneSchema, ParserFallsBackWhenPuppetMeshSlotMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {};
    AddPuppetImageSceneFiles(files, false);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    auto parsed = parser.Parse("puppet-slot-fallback", BasicPuppetSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    auto node = FindRootChildByName(*parsed, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_EQ(node->Mesh()->Submeshes().size(), 2u);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 1u);
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    EXPECT_EQ(node->Mesh()->Material()->name, "baseimage");
    ASSERT_EQ(node->Mesh()->Submeshes().size(), 2u);
    EXPECT_EQ(node->Mesh()->Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(node->Mesh()->Submeshes()[1].material_slot, 0u);
}

std::shared_ptr<Scene> ParseCameraZoomScene(const nlohmann::json& zoom) {
    auto source = nlohmann::json::parse(BasicImageSceneJson());
    source["objects"] = nlohmann::json::array();
    source["general"]["orthogonalprojection"] = {{"width", 960}, {"height", 540}};
    source["general"]["zoom"] = zoom;
    fs::VFS vfs;
    audio::SoundManager sound;
    ProjectProperties properties;
    return WPSceneParser().Parse(SceneParseRequest {
        .scene_id = "camera-zoom", .project_properties = &properties,
    }, source.dump(), vfs, sound);
}

TEST(SceneSchema, CameraZoomTimelineRevealsFullCanvasWithoutResizingRenderTargets) {
    auto parsed = ParseCameraZoomScene(nlohmann::json::parse(R"({
        "value":3,"animation":{
            "options":{"fps":30,"length":450,"mode":"single","name":"intro"},
            "c0":[{"frame":0,"value":3},{"frame":300,"value":3},
                  {"frame":450,"value":1}]
        }
    })"));
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    auto camera = parsed->cameras.at("global");
    auto perspective = parsed->cameras.at("global_perspective");
    auto linked = std::make_shared<SceneCamera>(*camera);
    parsed->cameras["linked"] = linked;
    parsed->linkedCameras["global"].push_back("linked");
    EXPECT_DOUBLE_EQ(camera->Width(), 320);
    EXPECT_DOUBLE_EQ(camera->Height(), 180);
    const auto initial_fov = perspective->Fov();
    const auto target = parsed->renderTargets.at(std::string(SpecTex_Default));
    parsed->runtime->Tick(10.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 320);
    parsed->runtime->Tick(2.5);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    EXPECT_DOUBLE_EQ(camera->Height(), 270);
    parsed->runtime->Tick(2.5);
    EXPECT_DOUBLE_EQ(camera->Width(), 960);
    EXPECT_DOUBLE_EQ(camera->Height(), 540);
    EXPECT_DOUBLE_EQ(linked->Width(), camera->Width());
    EXPECT_DOUBLE_EQ(linked->Height(), camera->Height());
    EXPECT_GT(perspective->Fov(), initial_fov);
    EXPECT_DOUBLE_EQ(perspective->Aspect(), camera->Aspect());
    for (const auto* view : {camera.get(), perspective.get(), linked.get()}) {
        for (const auto& corner : {Eigen::Vector4d(0, 0, 0, 1),
                                   Eigen::Vector4d(960, 540, 0, 1)}) {
            const Eigen::Vector4d clip = view->GetViewProjectionMatrix() * corner;
            EXPECT_NEAR(std::abs(clip.x() / clip.w()), 1.0, 1e-6);
            EXPECT_NEAR(std::abs(clip.y() / clip.w()), 1.0, 1e-6);
        }
    }
    parsed->runtime->Tick(20.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 960);
    EXPECT_EQ(parsed->ortho[0], 960);
    EXPECT_EQ(parsed->ortho[1], 540);
    EXPECT_EQ(parsed->renderTargets.at(std::string(SpecTex_Default)).width, target.width);
    EXPECT_EQ(parsed->renderTargets.at(std::string(SpecTex_Default)).height, target.height);
}

TEST(SceneSchema, CameraZoomTimelineHonorsPausedFirstKeyAndLooping) {
    auto parsed = ParseCameraZoomScene(nlohmann::json::parse(R"({
        "value":7,"animation":{
            "options":{"fps":30,"length":60,"mode":"loop","startpaused":true,"name":"zoom"},
            "c0":[{"frame":0,"value":2},{"frame":30,"value":1},{"frame":60,"value":2}]
        }
    })"));
    ASSERT_NE(parsed, nullptr);
    auto camera = parsed->cameras.at("global");
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    parsed->runtime->Tick(5.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    auto* animation = parsed->runtime->FindScalarAnimation("", "zoom");
    ASSERT_NE(animation, nullptr);
    animation->Play();
    parsed->runtime->Tick(1.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 960);
    parsed->runtime->Tick(1.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
    animation->Stop();
    parsed->runtime->Tick(1.0);
    EXPECT_DOUBLE_EQ(camera->Width(), 480);
}

TEST(SceneSchema, StaticAndInvalidCameraZoomRemainStable) {
    for (const auto& zoom : {nlohmann::json(2), nlohmann::json(0), nlohmann::json(-1),
                            nlohmann::json::parse(R"({"value":2,"animation":{}})")}) {
        auto parsed = ParseCameraZoomScene(zoom);
        ASSERT_NE(parsed, nullptr);
        const double width = zoom.is_number() && zoom.get<float>() <= 0 ? 960 : 480;
        EXPECT_DOUBLE_EQ(parsed->cameras.at("global")->Width(), width);
        parsed->runtime->Tick(20.0);
        EXPECT_DOUBLE_EQ(parsed->cameras.at("global")->Width(), width);
    }
}

TEST(SceneSchema, ParserPreservesPausedMaterialTimelineAndAppliesItsFirstKey) {
    auto files = std::map<std::string, std::string> {};
    AddMultiVideoImageSceneFiles(files);
    auto material = nlohmann::json::parse(files.at("/mat/multi_video.json"));
    material["passes"][0]["constantshadervalues"]["Opacity"] = nlohmann::json::parse(R"({
        "value":1.5,"animation":{
            "options":{"fps":30,"length":9,"mode":"single","startpaused":true,"name":"transition"},
            "c0":[{"frame":0,"value":0},{"frame":5,"value":1.5},{"frame":9,"value":0}]
        }
    })");
    files["/mat/multi_video.json"] = material.dump();
    files["/shaders/multivideo.frag"] = R"(
uniform float u_Opacity; // {"material":"Opacity","default":1}
void main() { gl_FragColor = vec4(u_Opacity); }
)";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser parser;
    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id = "paused-material-timeline",
        .project_properties = &properties,
    };
    auto parsed = parser.Parse(request, BasicImageSceneJson(), vfs, sound_manager);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    auto node = FindRootChildByName(*parsed, "video image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    const auto& values = node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(values.contains("u_Opacity"));
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f);
    parsed->runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f);
    auto* animation = parsed->runtime->FindScalarAnimation("video image", "transition");
    ASSERT_NE(animation, nullptr);
    animation->Play();
    parsed->runtime->Tick(5.0 / 30.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 1.5f);
    parsed->runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f);
}

TEST(SceneSchema, ParserRegistersEveryVideoTextureInImageMaterialForLayerControls) {
    auto files = std::map<std::string, std::string> {};
    AddMultiVideoImageSceneFiles(files);
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id = "multi-video-image",
          .project_properties = &properties,
    };

    auto parsed = parser.Parse(request, BasicImageSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_TRUE(parsed->runtime->PauseNodeVideoTexture("video image"));
    EXPECT_TRUE(parsed->runtime->SetNodeVideoTextureCurrentTime("video image", 7.5));
    EXPECT_TRUE(parsed->runtime->SetNodeVideoTextureRate("video image", 0.25f));

    const auto diffuse = parsed->runtime->ResolveVideoPlaybackState("diffuse.tex", 99.0);
    EXPECT_TRUE(diffuse.paused);
    EXPECT_FLOAT_EQ(diffuse.rate, 0.25f);
    EXPECT_DOUBLE_EQ(diffuse.scene_elapsed_seconds, 7.5);

    const auto mask = parsed->runtime->ResolveVideoPlaybackState("mask.tex", 99.0);
    EXPECT_TRUE(mask.paused);
    EXPECT_FLOAT_EQ(mask.rate, 0.25f);
    EXPECT_DOUBLE_EQ(mask.scene_elapsed_seconds, 7.5);
}

TEST(SceneSchema, ParserUnregistersRuntimeNodeWhenImageMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {
        { "/valid.json", R"({"width":64,"height":32,"material":"valid_mat.json"})" },
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/valid_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"validimage","textures":["a.tex"]}]})" },
        { "/shaders/validimage.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/validimage.frag",
          R"(void main() {
  gl_FragColor = vec4(1.0);
}
)" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"brokenimage","textures":["a.tex"]}]})" },
        { "/shaders/brokenimage.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/brokenimage.frag",
          R"(this is not valid GLSL
)" },
        { "/materials/a.tex.tex", "" },
    };
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "failed-dynamic-image",
          .project_properties = &properties,
    };

    auto parsed = parser.Parse(request, DynamicImageSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_EQ(parsed->runtime->sceneScriptCount(), 1u);
    EXPECT_TRUE(parsed->runtime->HasNodeNamed("valid scripted image"));
    EXPECT_FALSE(parsed->runtime->HasNodeNamed("failed dynamic image"));
    parsed->runtime->Tick(1.0 / 60.0);
}

TEST(SceneSchema, ParserRemovesQueuedSceneScriptWhenImageMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"brokenimage","textures":["a.tex"]}]})" },
        { "/shaders/brokenimage.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/brokenimage.frag",
          R"(this is not valid GLSL
)" },
        { "/materials/a.tex.tex", "" },
    };
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "failed-scene-script-image",
          .project_properties = &properties,
    };
    const auto scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":313,"name":"failed scene-script image","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],
         "visible":{"value":true,"script":"thisScene.on('cursorClick', function() { thisScene.getLayer('failed scene-script image').visible = false; });"}}
      ]
    })";

    auto parsed = parser.Parse(request, scene_json, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_FALSE(parsed->runtime->HasNodeNamed("failed scene-script image"));
    EXPECT_EQ(parsed->runtime->sceneScriptCount(), 0u);
}

TEST(SceneSchema, RuntimeScopedUnregisterPreservesExistingSameNameNode) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto previous_node = std::make_shared<SceneNode>(
        Eigen::Vector3f(25.0f, 0.0f, 0.0f),
        Eigen::Vector3f::Ones(),
        Eigen::Vector3f::Zero(),
        "runtime target");
    auto failed_node = std::make_shared<SceneNode>(
        Eigen::Vector3f(50.0f, 0.0f, 0.0f),
        Eigen::Vector3f::Ones(),
        Eigen::Vector3f::Zero(),
        "runtime target");

    runtime->RegisterNode("runtime target", previous_node.get());
    const auto previous = runtime->CaptureNodeRegistration("runtime target");
    runtime->RegisterNode("runtime target", failed_node.get());
    ASSERT_FLOAT_EQ(runtime->NodeTranslate("runtime target").x(), 50.0f);
    runtime->RollbackNodeRegistration("runtime target", failed_node.get(), previous);

    EXPECT_TRUE(runtime->HasNodeNamed("runtime target"));
    EXPECT_FLOAT_EQ(runtime->NodeTranslate("runtime target").x(), 25.0f);

    runtime->RegisterNode("runtime target", failed_node.get());
    runtime->RollbackNodeRegistration("runtime target", failed_node.get(), nullptr);
    EXPECT_FALSE(runtime->HasNodeNamed("runtime target"));
}

TEST(SceneSchema, ParserUnregistersRuntimeNodeWhenParticleMaterialFailsToLoad) {
    auto files = std::map<std::string, std::string> {
        { "/valid_particle.json",
          R"({"emitter":[{"name":"emit","id":1}],"material":"valid_mat.json","maxcount":4,"starttime":0})" },
        { "/particle.json",
          R"({"emitter":[{"name":"emit","id":1}],"material":"mat.json","maxcount":4,"starttime":0})" },
        { "/valid_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"validparticle","textures":["a.tex"]}]})" },
        { "/shaders/validparticle.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/validparticle.frag",
          R"(void main() {
  gl_FragColor = vec4(1.0);
}
)" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"brokenparticle","textures":["a.tex"]}]})" },
        { "/shaders/brokenparticle.vert",
          R"(attribute vec3 a_Position;
void main() {
  gl_Position = vec4(a_Position, 1.0);
}
)" },
        { "/shaders/brokenparticle.frag",
          R"(this is not valid GLSL
)" },
        { "/materials/a.tex.tex", "" },
    };
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "failed-dynamic-particle",
          .project_properties = &properties,
    };

    auto parsed = parser.Parse(request, DynamicParticleSceneJson(), vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_EQ(parsed->runtime->sceneScriptCount(), 1u);
    EXPECT_TRUE(parsed->runtime->HasNodeNamed("valid scripted particle"));
    EXPECT_FALSE(parsed->runtime->HasNodeNamed("failed dynamic particle"));
    parsed->runtime->Tick(1.0 / 60.0);
}

TEST(SceneSchema, RuntimeProjectPropertyResolutionStillWorks) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "speed", RuntimeScalarValue::Float(2.5f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto* value = runtime->FindPropertyValue("speed");
    ASSERT_NE(value, nullptr);
    EXPECT_FLOAT_EQ(value->getFloat(), 2.5f);
}

TEST(SceneSchema, SchemecolorUserPropertyUpdatesSceneClearColor) {
    fs::VFS vfs;
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::map<std::string, std::string> {})));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "background_color", RuntimeScalarValue::String("0.25 0.5 0.75") },
    };
    SceneParseRequest request {
        .scene_id           = "schemecolor-clearcolor",
        .project_properties = &properties,
    };
    const auto scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":{"user":"background_color","value":"0.1 0.2 0.3"},
        "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": []
    })";

    auto parsed = parser.Parse(request, scene_json, vfs, sound_manager);

    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    EXPECT_FLOAT_EQ(parsed->clearColor[0], 0.25f);
    EXPECT_FLOAT_EQ(parsed->clearColor[1], 0.5f);
    EXPECT_FLOAT_EQ(parsed->clearColor[2], 0.75f);

    parsed->runtime->ApplyProjectPropertyOverride({
        { "background_color", RuntimeScalarValue::String("0.5 0.25 0.125") },
    });

    EXPECT_FLOAT_EQ(parsed->clearColor[0], 0.5f);
    EXPECT_FLOAT_EQ(parsed->clearColor[1], 0.25f);
    EXPECT_FLOAT_EQ(parsed->clearColor[2], 0.125f);
}

#include <chrono>
#include <condition_variable>
#include <mutex>
#include "SceneWallpaper.hpp"
#include "Scene/Scene.h"
#if defined(__APPLE__)
#include "Platform/Apple/SceneWallpaperBindings.h"
#endif

namespace {
struct NativePointerObservation {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<bool> values;
    int drops { 0 };
    int first_frames { 0 };
    bool block { false };
    bool released { false };

    void Observe(bool accepts) {
        std::unique_lock lock(mutex);
        values.push_back(accepts);
        changed.notify_all();
        if (block) changed.wait(lock, [&] { return released; });
    }
    void Release() {
        std::lock_guard lock(mutex);
        released = true;
        changed.notify_all();
    }
    bool Wait(std::size_t count, int drop_count = 0) {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [&] {
            return values.size() >= count && drops >= drop_count;
        });
    }
    std::vector<bool> Values() {
        std::lock_guard lock(mutex);
        return values;
    }
    int Drops() {
        std::lock_guard lock(mutex);
        return drops;
    }
};

std::shared_ptr<wallpaper::Scene> MakePointerCommitScene(bool accepts) {
    auto scene = std::make_shared<wallpaper::Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->accepts_pointer_input = accepts;
    return scene;
}
}

TEST(SceneSchema, PointerCapabilityFollowsActualCommitsWithoutFirstFrame) {
    NativePointerObservation observation;
    NativePointerObservation replacement;
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyObject(wallpaper::PROPERTY_FIRST_FRAME_CALLBACK,
        std::make_shared<wallpaper::FirstFrameCallback>([&] {
            std::lock_guard lock(observation.mutex);
            ++observation.first_frames;
        }));
    wallpaper.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK,
        std::make_shared<wallpaper::PointerInputCallback>([&](bool accepts) {
            observation.Observe(accepts);
        }));
    ASSERT_TRUE(observation.Wait(1));
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true }));

    auto video = MakePointerCommitScene(false);
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, video);
    ASSERT_TRUE(observation.Wait(2));
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true, false }));

    // Configuration is not a scene commit; replacement is a main-looper barrier.
    wallpaper.setPropertyBool(wallpaper::PROPERTY_FORCE_SHADER_REFRESH, true);
    wallpaper.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK,
        std::make_shared<wallpaper::PointerInputCallback>([&](bool accepts) {
            replacement.Observe(accepts);
        }));
    ASSERT_TRUE(replacement.Wait(1));
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true, false }));
    EXPECT_EQ(replacement.Values(), (std::vector<bool> { false }));

    auto scene = std::make_shared<wallpaper::Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->textures["video-texture"].isVideo = true;
    ASSERT_TRUE(scene->accepts_pointer_input);
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    ASSERT_TRUE(replacement.Wait(2));
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    ASSERT_TRUE(replacement.Wait(3));
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, video);
    ASSERT_TRUE(replacement.Wait(4));
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, nullptr);
    ASSERT_TRUE(replacement.Wait(5));
    wallpaper.shutdown();
    EXPECT_EQ(replacement.Values(), (std::vector<bool> { false, true, true, false, true }));
    EXPECT_FALSE(video->first_frame_ok);
    EXPECT_FALSE(scene->first_frame_ok);
    std::lock_guard lock(observation.mutex);
    EXPECT_EQ(observation.first_frames, 0);
}

#if defined(__APPLE__)
namespace {
struct NativePointerUserData {
    NativePointerObservation* observation;
};
void NativePointerCallback(void* data, bool accepts) {
    static_cast<NativePointerUserData*>(data)->observation->Observe(accepts);
}
void NativeFirstFrameCallback(void* data) {
    auto& observation = *static_cast<NativePointerUserData*>(data)->observation;
    std::lock_guard lock(observation.mutex);
    ++observation.first_frames;
    observation.changed.notify_all();
}
void NativePointerDrop(void* data) {
    std::unique_ptr<NativePointerUserData> owner(static_cast<NativePointerUserData*>(data));
    auto& observation = *owner->observation;
    std::lock_guard lock(observation.mutex);
    ++observation.drops;
    observation.changed.notify_all();
}
struct NativePointerSceneDeleter {
    void operator()(owe_scene_wallpaper* scene) const { owe_scene_wallpaper_delete(scene); }
};
using NativePointerSceneOwner = std::unique_ptr<owe_scene_wallpaper, NativePointerSceneDeleter>;
struct NativePointerReleaseOnExit {
    NativePointerObservation& observation;
    ~NativePointerReleaseOnExit() { observation.Release(); }
};
int RegisterNativePointer(owe_scene_wallpaper* scene, NativePointerObservation& observation) {
    auto data = std::make_unique<NativePointerUserData>();
    data->observation = &observation;
    const int status = owe_scene_wallpaper_set_pointer_input_callback(
        scene, NativePointerCallback, data.get(), NativePointerDrop);
    if (status == 0) data.release();
    return status;
}
int RegisterNativeFirstFrame(owe_scene_wallpaper* scene, NativePointerObservation& observation) {
    auto data = std::make_unique<NativePointerUserData>();
    data->observation = &observation;
    const int status = owe_scene_wallpaper_set_first_frame_callback(
        scene, NativeFirstFrameCallback, data.get(), NativePointerDrop);
    if (status == 0) data.release();
    return status;
}
}

TEST(SceneSchema, PointerCallbackReplacementAndClearRetainInflightUserData) {
    NativePointerObservation first;
    NativePointerObservation second;
    first.block = true;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    NativePointerReleaseOnExit release { first };
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), first), 0);
    ASSERT_TRUE(first.Wait(1));
    ASSERT_EQ(RegisterNativePointer(scene.get(), second), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_pointer_input_callback(
        scene.get(), nullptr, nullptr, nullptr), 0);
    EXPECT_EQ(first.Drops(), 0);
    EXPECT_EQ(second.Drops(), 0);
    EXPECT_TRUE(second.Values().empty());
    first.Release();
    ASSERT_TRUE(first.Wait(1, 1));
    ASSERT_TRUE(second.Wait(1, 1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    scene.reset();
    EXPECT_EQ(first.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(second.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(first.Drops(), 1);
    EXPECT_EQ(second.Drops(), 1);
}

TEST(SceneSchema, PointerCallbackShutdownStopsDeliveryAndReleasesOwnershipOnDelete) {
    NativePointerObservation observation;
    NativePointerObservation rejected;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), observation), 0);
    ASSERT_TRUE(observation.Wait(1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_NE(RegisterNativePointer(scene.get(), rejected), 0);
    EXPECT_EQ(rejected.Drops(), 0);
    EXPECT_TRUE(rejected.Values().empty());
    scene.reset();
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(observation.Drops(), 1);
    EXPECT_EQ(rejected.Drops(), 0);
}

TEST(SceneSchema, NativeCallbackRegistrationFailureDoesNotConsumeUserData) {
    NativePointerObservation pointer;
    NativePointerObservation first_frame;
    EXPECT_NE(RegisterNativePointer(nullptr, pointer), 0);
    EXPECT_NE(RegisterNativeFirstFrame(nullptr, first_frame), 0);
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    EXPECT_NE(RegisterNativePointer(scene.get(), pointer), 0);
    EXPECT_NE(RegisterNativeFirstFrame(scene.get(), first_frame), 0);
    scene.reset();
    EXPECT_EQ(pointer.Drops(), 0);
    EXPECT_EQ(first_frame.Drops(), 0);
    EXPECT_TRUE(pointer.Values().empty());
    EXPECT_EQ(first_frame.first_frames, 0);
}

TEST(SceneSchema, FirstFrameCallbackReplacementClearAndShutdownDropExactlyOnce) {
    NativePointerObservation first;
    NativePointerObservation second;
    NativePointerObservation barrier;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativeFirstFrame(scene.get(), first), 0);
    ASSERT_EQ(RegisterNativeFirstFrame(scene.get(), second), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_first_frame_callback(
        scene.get(), nullptr, nullptr, nullptr), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), barrier), 0);
    ASSERT_TRUE(barrier.Wait(1));
    ASSERT_TRUE(first.Wait(0, 1));
    ASSERT_TRUE(second.Wait(0, 1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    scene.reset();
    EXPECT_EQ(first.Drops(), 1);
    EXPECT_EQ(second.Drops(), 1);
    EXPECT_EQ(barrier.Drops(), 1);
    EXPECT_EQ(first.first_frames, 0);
    EXPECT_EQ(second.first_frames, 0);
}

TEST(SceneSchema, MouseButtonBaselineReconcilesLevelsWithoutInventingOrClearingEdges) {
    using Access = wallpaper::SceneWallpaperInputTestAccess;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    auto& native = Access::FromNative(*scene);
    const auto expect_buttons = [&](uint32_t down, uint32_t pressed, uint32_t released) {
        const auto snapshot = Access::ConsumeMouseButtons(native);
        EXPECT_EQ(snapshot.down, down);
        EXPECT_EQ(snapshot.pressed, pressed);
        EXPECT_EQ(snapshot.released, released);
    };

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 31, true), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(nullptr, 0), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0x80000000u, 0x80000000u, 0);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0, 0, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 1), 0);
    expect_buttons(1, 1, 1);
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(0, 0, 1);

    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 1), 0);
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(0, 0, 1);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 2, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(4, 4, 0);
}

TEST(SceneSchema, MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch) {
    using Access = wallpaper::SceneWallpaperInputTestAccess;
    NativePointerObservation observation;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    auto& native = Access::FromNative(*scene);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), observation), 0);
    ASSERT_TRUE(observation.Wait(1));
    const auto expect_buttons = [&](uint32_t down, uint32_t pressed, uint32_t released) {
        const auto snapshot = Access::ConsumeMouseButtons(native);
        EXPECT_EQ(snapshot.down, down);
        EXPECT_EQ(snapshot.pressed, pressed);
        EXPECT_EQ(snapshot.released, released);
    };
    auto interactive = MakePointerCommitScene(true);
    auto video = MakePointerCommitScene(false);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    Access::PostScene(native, interactive);
    ASSERT_TRUE(observation.Wait(2));
    expect_buttons(0, 1, 1);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    Access::PostScene(native, MakePointerCommitScene(true));
    ASSERT_TRUE(observation.Wait(3));
    expect_buttons(1, 1, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, false), 0);
    Access::PostScene(native, video);
    ASSERT_TRUE(observation.Wait(4));
    expect_buttons(1, 0, 0);
    // The release observed during video was intentionally not sent to native.
    Access::PostScene(native, interactive);
    ASSERT_TRUE(observation.Wait(5));
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    expect_buttons(1, 1, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    Access::PostScene(native, video);
    ASSERT_TRUE(observation.Wait(6));
    expect_buttons(0, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, false), 0);
    Access::PostScene(native, MakePointerCommitScene(true));
    ASSERT_TRUE(observation.Wait(7));
    expect_buttons(0, 0, 0);
    // Post-commit edges survive the held-level seed from the new sample.
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 2, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 5), 0);
    expect_buttons(5, 4, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(4, 0, 1);
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_FALSE(interactive->first_frame_ok);
    EXPECT_FALSE(video->first_frame_ok);
}
#endif

TEST(SceneSchema, FailedPuppetMaterialRollsBackDynamicControlsAndSubscriptions) {
    std::map<std::string, std::string> files;
    AddPuppetImageSceneFiles(files);
    files["/shaders/baseimage.frag"] = "this is not valid GLSL";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    auto json = nlohmann::json::parse(BasicPuppetSceneJson());
    json["objects"][0]["animationlayers"] = nlohmann::json::array({
        {{"animation", 7}, {"name", "gesture"},
         {"visible", {{"value", true}, {"user", "visible"}}},
         {"rate", {{"value", 1.0}, {"user", "rate"}}},
         {"blend", {{"value", 1.0}, {"user", "blend"}}}},
    });
    ProjectProperties properties {
        {"visible", RuntimeScalarValue::Bool(true)},
        {"rate", RuntimeScalarValue::Float(1.0f)},
        {"blend", RuntimeScalarValue::Float(1.0f)},
    };
    SceneParseRequest request { .scene_id = "failed-puppet-controls", .project_properties = &properties };
    audio::SoundManager sound;
    WPSceneParser parser;
    auto scene = parser.Parse(request, json.dump(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("puppet image"));
    EXPECT_EQ(scene->runtime->FindPuppetLayer("puppet image"), nullptr);
    scene->runtime->ApplyProjectPropertyOverride({
        {"visible", RuntimeScalarValue::Bool(false)},
        {"rate", RuntimeScalarValue::Float(2.0f)},
        {"blend", RuntimeScalarValue::Float(0.25f)},
    });
    scene->runtime->Tick(0.01);
    EXPECT_EQ(scene->runtime->FindPuppetLayer("puppet image"), nullptr);
    EXPECT_EQ(scene->runtime->PuppetAnimationControl("puppet image", "gesture", "exists", 0, false), 0.0);
}

TEST(SceneSchema, ParserCoverageUsesAuthoredRegionOfPaddedRgbaTexture) {
    Bytes bytes;
    bytes.Stamp("TEXV", 5);
    bytes.Stamp("TEXI", 1);
    bytes.I32(0);
    bytes.U32(0);
    // A 4x2 allocation contains a top-left 2x1 authored image.
    bytes.I32(4);
    bytes.I32(2);
    bytes.I32(2);
    bytes.I32(1);
    bytes.I32(0);
    bytes.Stamp("TEXB", 3);
    bytes.I32(1);
    bytes.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    bytes.I32(1);
    bytes.I32(4);
    bytes.I32(2);
    bytes.I32(0);
    bytes.I32(0);
    bytes.I32(32);
    // Only the authored second texel meets the hit threshold; padding is transparent.
    for (int texel = 0; texel < 8; ++texel) {
        bytes.U8(255); bytes.U8(255); bytes.U8(255);
        bytes.U8(texel == 0 ? 15 : texel == 1 ? 16 : 0);
    }
    std::map<std::string, std::string> files;
    AddPuppetImageSceneFiles(files);
    files["/puppet_image.json"] = R"({"width":40,"height":20,"material":"mat/base.json"})";
    files["/materials/base.tex.tex"] = bytes.TakeString();
    auto json = nlohmann::json::parse(BasicPuppetSceneJson());
    auto& object = json["objects"][0];
    object["origin"] = {100, 100, 0};
    object["visible"] = {
        {"value", true},
        {"script", "export function cursorClick() { thisLayer.visible = false; }"},
    };
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    audio::SoundManager sound;
    WPSceneParser parser;
    // Runtime bootstrap is explicit, even when this scene has no user properties.
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "padded-alpha-region", .project_properties = &properties,
    }, json.dump(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    runtime.Tick(0.0);
    EXPECT_EQ(runtime.NodeSize("puppet image"), Eigen::Vector2f(40.0f, 20.0f));
    EXPECT_TRUE(runtime.NodeVisible("puppet image"));
    runtime.SetCursorEnter(true);
    runtime.SetCursorButtons(0, 1, 1);
    runtime.SetCursorWorldPosition(Eigen::Vector3f(90, 100, 0));
    runtime.DispatchCursorFrameEvents(false);
    EXPECT_TRUE(runtime.NodeVisible("puppet image"));
    runtime.SetCursorWorldPosition(Eigen::Vector3f(110, 100, 0));
    runtime.DispatchCursorFrameEvents(true);
    EXPECT_FALSE(runtime.NodeVisible("puppet image"));
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}
