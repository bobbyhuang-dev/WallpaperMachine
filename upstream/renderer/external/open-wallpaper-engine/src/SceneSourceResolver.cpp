#include "SceneSourceResolver.hpp"

#include "Project/ProjectManifest.hpp"

#include <filesystem>

namespace wallpaper
{

namespace
{

constexpr const char* kProjectFileName = "project.json";
constexpr const char* kDefaultSceneEntry = "scene.json";

bool resolve_scene_entry(
    const std::filesystem::path& source_path,
    const std::filesystem::path& entry_path,
    SceneSourcePaths*            resolved,
    std::string*                 error)
{
    if (resolved == nullptr) {
        if (error != nullptr) *error = "resolved scene source must not be null";
        return false;
    }
    if (entry_path.empty()) {
        if (error != nullptr) *error = "scene entry path must not be empty";
        return false;
    }
    if (entry_path.is_absolute()) {
        if (error != nullptr) *error = "project scene entry must be a relative path";
        return false;
    }

    const std::filesystem::path pkg_dir_fs = source_path.parent_path();
    auto                        pkg_path_fs = pkg_dir_fs / entry_path;
    auto                        pkg_entry_fs = entry_path;

    pkg_path_fs.replace_extension("pkg");
    pkg_entry_fs.replace_extension("json");

    resolved->pkg_path = pkg_path_fs.native();
    resolved->pkg_entry = pkg_entry_fs.generic_string();
    resolved->pkg_dir = pkg_dir_fs.native();
    resolved->scene_id = pkg_dir_fs.filename().native();
    return true;
}

} // namespace

bool ResolveSceneSourcePaths(
    const std::string&     source,
    SceneSourceResolution* resolved,
    std::string*           error)
{
    if (resolved == nullptr) {
        if (error != nullptr) *error = "resolved scene source must not be null";
        return false;
    }
    if (source.empty()) {
        if (error != nullptr) *error = "scene source must not be empty";
        return false;
    }

    const std::filesystem::path source_path { source };
    resolved->scene_source = {};
    resolved->manifest = {};

    if (source_path.filename() == kProjectFileName) {
        if (!ParseProjectManifest(source, &resolved->manifest, error)) return false;
        if (resolved->manifest.type != WallpaperProjectType::Scene) {
            resolved->kind = SceneSourceResolutionKind::NotSceneProject;
            return true;
        }

        const auto entry_path = resolved->manifest.file.empty()
            ? std::filesystem::path(kDefaultSceneEntry)
            : std::filesystem::path(resolved->manifest.file);
        resolved->kind = SceneSourceResolutionKind::Scene;
        return resolve_scene_entry(source_path, entry_path, &resolved->scene_source, error);
    }

    resolved->kind = SceneSourceResolutionKind::Scene;
    resolved->manifest.type = WallpaperProjectType::Scene;
    resolved->manifest.file = source_path.filename().generic_string();
    resolved->manifest.workshop_id = source_path.parent_path().filename().native();
    return resolve_scene_entry(source_path, source_path.filename(), &resolved->scene_source, error);
}

bool ResolveSceneSourcePaths(
    const std::string& source,
    SceneSourcePaths*  resolved,
    std::string*       error)
{
    SceneSourceResolution resolution;
    if (!ResolveSceneSourcePaths(source, &resolution, error)) return false;
    if (resolution.kind != SceneSourceResolutionKind::Scene) {
        if (error != nullptr) {
            *error = std::string("project is not a scene wallpaper: ") +
                     ToString(resolution.manifest.type);
        }
        return false;
    }

    if (resolved == nullptr) {
        if (error != nullptr) *error = "resolved scene source must not be null";
        return false;
    }

    *resolved = std::move(resolution.scene_source);
    return true;
}

} // namespace wallpaper
