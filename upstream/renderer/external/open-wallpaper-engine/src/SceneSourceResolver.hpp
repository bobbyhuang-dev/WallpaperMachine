#pragma once

#include "Project/ProjectManifest.hpp"

#include <string>

namespace wallpaper
{

struct SceneSourcePaths {
    std::string pkg_path;
    std::string pkg_entry;
    std::string pkg_dir;
    std::string scene_id;
};

enum class SceneSourceResolutionKind
{
    Scene,
    NotSceneProject,
};

struct SceneSourceResolution {
    SceneSourceResolutionKind kind { SceneSourceResolutionKind::Scene };
    ProjectManifest           manifest;
    SceneSourcePaths          scene_source;
};

bool ResolveSceneSourcePaths(
    const std::string&      source,
    SceneSourceResolution*  resolved,
    std::string*            error);

bool ResolveSceneSourcePaths(
    const std::string& source,
    SceneSourcePaths* resolved,
    std::string* error);

} // namespace wallpaper
