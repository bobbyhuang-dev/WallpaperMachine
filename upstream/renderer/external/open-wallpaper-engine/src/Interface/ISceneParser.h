#pragma once
#include <cstdint>
#include <string>
#include <memory>

#include "Project/ProjectProperties.hpp"
#include "Scene/Scene.h"

namespace wallpaper
{

namespace fs{ class VFS; }
namespace audio{ class SoundManager; }

struct SceneParseRequest
{
    static constexpr uint16_t kUnknownPkgVersion { 0 };

    std::string              scene_id {};
    std::string              project_path {};
    const ProjectProperties* project_properties { nullptr };
    uint16_t                 pkg_version { kUnknownPkgVersion };
};

class ISceneParser {
public:
	ISceneParser() = default;
	virtual ~ISceneParser() = default;
	virtual std::shared_ptr<Scene> Parse(const SceneParseRequest&, const std::string&, fs::VFS&, audio::SoundManager&) = 0;
};
}
