#pragma once
#include "WPJson.hpp"
#include <nlohmann/json.hpp>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace wallpaper
{
namespace wpscene
{

class WPMaterialPassBindItem {
public:
    bool        FromJson(const nlohmann::json&);
    std::string name;
    int32_t     index;
};

struct WPUserTexture {
    std::string name;
    std::string type;
};

struct WPConstantShaderValue {
    std::vector<float> value;
    std::string        user;
    std::string        script;
    nlohmann::json     scriptproperties;
};

class WPMaterialPass {
public:
    bool                                                FromJson(const nlohmann::json&);
    void                                                Update(const WPMaterialPass&);
    std::vector<std::string>                            textures;
    std::vector<WPUserTexture>                          usertextures;
    std::unordered_map<std::string, int32_t>            combos;
    std::unordered_map<std::string, WPConstantShaderValue> constantshadervalues;
    std::string                                         target;
    std::vector<WPMaterialPassBindItem>                 bind;
};

class WPMaterial {
public:
    bool                                                FromJson(const nlohmann::json&);
    void                                                MergePass(const WPMaterialPass&);
    std::string                                         blending { "translucent" };
    std::string                                         cullmode { "nocull" };
    std::string                                         shader;
    std::string                                         depthtest { "disabled" };
    std::string                                         depthwrite { "disabled" };
    std::vector<std::string>                            textures;
    std::vector<WPUserTexture>                          usertextures;
    std::unordered_map<std::string, int32_t>            combos;
    std::unordered_map<std::string, WPConstantShaderValue> constantshadervalues;

    bool use_puppet { false };
};

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPMaterialPassBindItem, name, index);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPUserTexture, name, type);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPConstantShaderValue, value, user);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPMaterialPass, bind, target, textures, combos,
                                   constantshadervalues);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPMaterial, blending, shader, textures, combos,
                                   constantshadervalues);
} // namespace wpscene
} // namespace wallpaper
