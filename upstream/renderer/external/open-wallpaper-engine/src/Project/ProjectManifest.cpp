#include "Project/ProjectManifest.hpp"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include <sstream>

namespace wallpaper
{
namespace
{

bool read_file(const std::filesystem::path& path, std::string* content)
{
    if (content == nullptr) return false;

    std::ifstream input(path);
    if (!input.good()) return false;

    std::ostringstream buffer;
    buffer << input.rdbuf();
    *content = buffer.str();
    return input.good() || input.eof();
}

WallpaperProjectType ParseProjectType(std::string type)
{
    std::transform(
        type.begin(),
        type.end(),
        type.begin(),
        [](unsigned char value) {
            return static_cast<char>(std::tolower(value));
        });

    if (type == "scene") return WallpaperProjectType::Scene;
    if (type == "video") return WallpaperProjectType::Video;
    if (type == "web") return WallpaperProjectType::Web;
    return WallpaperProjectType::Unknown;
}

} // namespace

const char* ToString(WallpaperProjectType type)
{
    switch (type) {
    case WallpaperProjectType::Scene: return "scene";
    case WallpaperProjectType::Video: return "video";
    case WallpaperProjectType::Web: return "web";
    case WallpaperProjectType::Unknown: return "unknown";
    }
    return "unknown";
}

bool ParseProjectManifest(
    const std::string& project_path,
    ProjectManifest*   manifest,
    std::string*       error)
{
    if (manifest == nullptr) {
        if (error != nullptr) *error = "project manifest output must not be null";
        return false;
    }
    if (project_path.empty()) {
        if (error != nullptr) *error = "project manifest path must not be empty";
        return false;
    }

    std::string content;
    if (!read_file(project_path, &content)) {
        if (error != nullptr) *error = "failed to read project manifest";
        return false;
    }

    nlohmann::json project;
    try {
        project = nlohmann::json::parse(content);
    } catch (const nlohmann::json::exception& exception) {
        if (error != nullptr) *error = exception.what();
        return false;
    }

    ProjectManifest parsed;
    if (project.contains("type")) {
        if (!project.at("type").is_string()) {
            if (error != nullptr) *error = "project manifest `type` must be a string";
            return false;
        }
        parsed.type = ParseProjectType(project.at("type").get<std::string>());
    }

    if (project.contains("file")) {
        if (!project.at("file").is_string()) {
            if (error != nullptr) *error = "project manifest `file` must be a string";
            return false;
        }
        parsed.file = project.at("file").get<std::string>();
    }

    if (project.contains("workshopid")) {
        const auto& workshop_id = project.at("workshopid");
        if (workshop_id.is_string()) {
            parsed.workshop_id = workshop_id.get<std::string>();
        } else if (workshop_id.is_number_integer()) {
            parsed.workshop_id = std::to_string(workshop_id.get<long long>());
        } else if (workshop_id.is_number_unsigned()) {
            parsed.workshop_id = std::to_string(workshop_id.get<unsigned long long>());
        }
    }

    *manifest = std::move(parsed);
    return true;
}

} // namespace wallpaper
