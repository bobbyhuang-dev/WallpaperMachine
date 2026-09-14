#include "Runtime/VirtualAssetRegistry.hpp"

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Utils/Logging.h"

#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace
{
constexpr std::string_view kMountName = "runtime_virtual_assets";
constexpr std::string_view kMountPoint = "/assets";

std::vector<uint8_t> ToBytes(std::string_view content)
{
    return std::vector<uint8_t>(content.begin(), content.end());
}

class VirtualAssetFs final : public wallpaper::fs::Fs
{
public:
    explicit VirtualAssetFs(std::unordered_map<std::string, std::string> files)
        : m_files(std::move(files))
    {
    }

    bool Contains(std::string_view path) const override
    {
        return m_files.count(std::string(path)) != 0;
    }

    std::shared_ptr<wallpaper::fs::IBinaryStream> Open(std::string_view path) override
    {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) {
            LOG_ERROR("virtual asset not found: %s", path.data());
            return nullptr;
        }
        return std::make_shared<wallpaper::fs::MemBinaryStream>(ToBytes(it->second));
    }

    std::shared_ptr<wallpaper::fs::IBinaryStreamW> OpenW(std::string_view) override
    {
        return nullptr;
    }

private:
    std::unordered_map<std::string, std::string> m_files;
};

std::unordered_map<std::string, std::string> BuildVirtualAssets()
{
    return {
        {
            "/effects/wpenginelinux/bloomeffect.json",
            R"json({
  "name": "camerabloom_wpengine_linux",
  "group": "wpengine_linux_camera",
  "dependencies": [],
  "passes": [
    {
      "material": "materials/util/downsample_quarter_bloom.json",
      "target": "_rt_4FrameBuffer",
      "bind": [
        { "name": "_rt_FullFrameBuffer", "index": 0 }
      ]
    },
    {
      "material": "materials/util/downsample_eighth_blur_v.json",
      "target": "_rt_8FrameBuffer",
      "bind": [
        { "name": "_rt_4FrameBuffer", "index": 0 }
      ]
    },
    {
      "material": "materials/util/blur_h_bloom.json",
      "target": "_rt_Bloom",
      "bind": [
        { "name": "_rt_8FrameBuffer", "index": 0 }
      ]
    },
    {
      "material": "materials/util/combine.json",
      "target": "_rt_FullFrameBuffer",
      "bind": [
        { "name": "_rt_imageLayerComposite_-1_a", "index": 0 },
        { "name": "_rt_Bloom", "index": 1 }
      ]
    }
  ]
})json",
        },
        {
            "/models/wpenginelinux.json",
            R"json({
  "material": "materials/wpenginelinux.json"
})json",
        },
        {
            "/materials/wpenginelinux.json",
            R"json({
  "passes": [
    {
      "blending": "normal",
      "cullmode": "nocull",
      "depthtest": "disabled",
      "depthwrite": "disabled",
      "shader": "genericimage2",
      "textures": [
        "_rt_FullFrameBuffer"
      ]
    }
  ]
})json",
        },
        {
            "/shaders/commands/copy.frag",
            "uniform sampler2D g_Texture0;\n"
            "in vec2 v_TexCoord;\n"
            "void main () {\n"
            "out_FragColor = texture (g_Texture0, v_TexCoord);\n"
            "}\n",
        },
        {
            "/shaders/commands/copy.vert",
            "in vec3 a_Position;\n"
            "in vec2 a_TexCoord;\n"
            "out vec2 v_TexCoord;\n"
            "void main () {\n"
            "gl_Position = vec4 (a_Position, 1.0);\n"
            "v_TexCoord = a_TexCoord;\n"
            "}\n",
        },
    };
}
} // namespace

namespace wallpaper
{
bool InstallVirtualAssets(fs::VFS& vfs)
{
    if (vfs.IsMounted(kMountName)) {
        return true;
    }

    if (!vfs.Mount(kMountPoint, std::make_unique<VirtualAssetFs>(BuildVirtualAssets()), kMountName)) {
        LOG_ERROR("failed to mount virtual assets");
        return false;
    }

    return true;
}
} // namespace wallpaper
