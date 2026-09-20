#pragma once
#include <string>
#include <vector>
#include <memory>
#include <unordered_set>

#include "SceneShader.h"
#include "Type.hpp"

namespace wallpaper
{

struct SceneMaterialCustomShader {
    std::shared_ptr<SceneShader> shader;
    ShaderValues                 constValues;
};

struct SceneMaterial {
public:
    SceneMaterial()                     = default;
    SceneMaterial(const SceneMaterial&) = default;
    SceneMaterial(SceneMaterial&&)      = default;
    SceneMaterial& operator=(SceneMaterial&&) = default;

    std::string              name;
    std::vector<std::string> textures;
    std::vector<std::string> defines;

    bool hasSprite { false };

    SceneMaterialCustomShader customShader;
    BlendMode                 blenmode { BlendMode::Disable };
    /// Authored `depthtest` other than disabled/enabled/less/lessorequal.
    /// Presence is a whole-scene Metal fallback, not a silent disable.
    bool                      depth_compare_unsupported { false };
    bool                      depth_test { false };
    bool                      depth_write { false };
};
} // namespace wallpaper
