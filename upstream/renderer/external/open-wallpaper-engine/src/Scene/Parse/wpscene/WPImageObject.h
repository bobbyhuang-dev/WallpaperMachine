#pragma once
#include "WPJson.hpp"
#include <nlohmann/json.hpp>
#include "WPMaterial.h"
#include <vector>
#include <unordered_map>
#include "WPPuppet.hpp"
#include <unordered_set>
#include <string>
#include <filesystem>

namespace wallpaper
{
namespace fs
{
class VFS;
}

namespace wpscene
{

class WPEffectCommand {
public:
    bool        FromJson(const nlohmann::json&);
    std::string command;
    std::string target;
    std::string source;

    i32 afterpos { 0 }; // 0 for begin, start from 1
};

class WPEffectFbo {
public:
    bool        FromJson(const nlohmann::json&);
    std::string name;
    std::string format;
    uint32_t    scale { 1 };
};

class WPImageEffect {
private:
    static const std::unordered_set<std::string> BLACKLISTED_WORKSHOP_EFFECTS;
    bool IsEffectBlacklisted(const std::string& filePath);
public:
    bool                         FromJson(const nlohmann::json&, fs::VFS& vfs);
    bool                         FromFileJson(const nlohmann::json&, fs::VFS& vfs);
    int32_t                      id;
    std::string                  name;
    bool                         visible { true };
    int32_t                      version;
    std::vector<WPMaterial>      materials;
    std::vector<WPMaterialPass>  passes;
    std::vector<WPEffectCommand> commands;
    std::vector<WPEffectFbo>     fbos;
};

class WPImageObject {
public:
    struct Config {
        bool passthrough { false };
    };
    struct Instance {
        bool                                      enabled { false };
        int32_t                                   id { 0 };
        std::unordered_map<std::string, int32_t> combos;
        std::vector<std::string>                  textures;
        std::vector<WPUserTexture>                usertextures;
    };
    bool                       FromJson(const nlohmann::json&, fs::VFS&);
    int32_t                    id { 0 };
    int32_t                    parent_id { -1 };
    std::string                name;
    std::array<float, 3>       origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3>       scale { 1.0f, 1.0f, 1.0f };
    std::array<float, 3>       angles { 0.0f, 0.0f, 0.0f };
    std::array<float, 2>       size { 2.0f, 2.0f };
    std::array<float, 2>       parallaxDepth { 0.0f, 0.0f };
    std::array<float, 2>       cropoffset { 0.0f, 0.0f };
    std::array<float, 3>       color { 1.0f, 1.0f, 1.0f };
    int32_t                    colorBlendMode { 0 };
    bool                       copybackground { true };
    float                      alpha { 1.0f };
    float                      brightness { 1.0f };
    bool                       fullscreen { false };
    bool                       nopadding { false };
    bool                       visible { true };
    bool                       autosize { false };
    bool                       dynamic_origin { false };
    bool                       dynamic_scale { false };
    bool                       dynamic_angles { false };
    bool                       dynamic_visible { false };
    bool                       dynamic_alpha { false };
    std::string                image;
    std::string                alignment { "center" };
    nlohmann::json             origin_setting;
    nlohmann::json             scale_setting;
    nlohmann::json             angles_setting;
    nlohmann::json             visible_setting;
    nlohmann::json             alpha_setting;
    WPMaterial                 material;
    std::vector<WPImageEffect> effects;
    Config                     config;
    std::vector<int32_t>       dependencies;
    Instance                   instance;
    nlohmann::json             field_bindings;

    std::string                                puppet;
    std::vector<WPPuppetLayer::AnimationLayer> puppet_layers;
    std::string                                attachment;
};

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPEffectFbo, name, scale);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPImageEffect, name, visible, passes, fbos, materials);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPImageObject, name, origin, angles, scale, size, visible,
                                   material, effects, autosize, cropoffset);

} // namespace wpscene
} // namespace wallpaper
