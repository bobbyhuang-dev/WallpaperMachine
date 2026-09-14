#pragma once
#include <cstdint>
#include <unordered_map>
#include <cstdint>
#include "WPJson.hpp"
#include <nlohmann/json.hpp>

namespace wallpaper
{

namespace wpscene
{

class Orthogonalprojection {
public:
    bool    FromJson(const nlohmann::json&);
    int32_t width;
    int32_t height;
    bool    auto_ { false };
};

class WPSceneCamera {
public:
    bool                 FromJson(const nlohmann::json&);
    std::array<float, 3> center { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> eye { 0.0f, 0.0f, 1.0f };
    std::array<float, 3> up { 0.0f, 1.0f, 0.0f };
};

class WPSceneGeneral {
public:
    static constexpr uint16_t kSceneVersionUnknown { 0 };

    bool                 FromJson(const nlohmann::json&);
    bool                 FromJson(const nlohmann::json&, uint16_t pkg_version);
    std::array<float, 3> clearcolor { 0.0f, 0.0f, 0.0f };
    nlohmann::json       clearcolor_setting;
    bool                 dynamic_clearcolor { false };
    bool                 clearenabled { true };
    bool                 cameraparallax { false };
    float                cameraparallaxamount;
    float                cameraparallaxdelay;
    float                cameraparallaxmouseinfluence;
    bool                 isOrtho { true };
    Orthogonalprojection orthogonalprojection { 1920, 1080 };
    float                zoom { 1.0f };
    float                fov { 50.0f };
    float                nearz { 0.01f };
    float                farz { 10000.0f };
    std::array<float, 3> ambientcolor { 0.2f, 0.2f, 0.2f };
    std::array<float, 3> skylightcolor { 0.3f, 0.3f, 0.3f };
    bool                 bloom { false };
    float                bloomstrength { 0.0f };
    float                bloomthreshold { 0.0f };
    bool                 hdr { false };
    bool                 norecompile { false };
    std::array<float, 3> bloomtint { 1.0f, 1.0f, 1.0f };
    float                perspectiveoverridefov { 0.0f };
    bool                 windenabled { false };
    std::array<float, 3> winddirection { 0.0f, 0.0f, 1.0f };
    float                windstrength { 0.0f };
    std::array<float, 3> gravitydirection { 0.0f, -1.0f, 0.0f };
    float                gravitystrength { 0.0f };
    bool                 transparentsorting { false };
    bool                 fogdistance { false };
    float                fogdistancestart { 0.0f };
    float                fogdistanceend { 0.0f };
    std::array<float, 3> fogdistancecolor { 1.0f, 1.0f, 1.0f };
    bool                 fogheight { false };
    float                fogheightstart { 0.0f };
    float                fogheightend { 0.0f };
    std::array<float, 3> fogheightcolor { 1.0f, 1.0f, 1.0f };
    nlohmann::json       lightconfig;
};

class WPScene {
public:
    bool           FromJson(const nlohmann::json&);
    bool           FromJson(const nlohmann::json&, uint16_t pkg_version);
    uint16_t       pkg_version { WPSceneGeneral::kSceneVersionUnknown };
    WPSceneCamera  camera;
    WPSceneGeneral general;
};

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Orthogonalprojection, width, height);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPSceneCamera, center, eye, up);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPSceneGeneral,
    clearcolor,
    clearenabled,
    orthogonalprojection,
    zoom);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(WPScene, camera, general);
} // namespace wpscene
} // namespace wallpaper
