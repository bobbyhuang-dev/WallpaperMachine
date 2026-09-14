#pragma once
#include "Interface/ISceneParser.h"

#include <string>
#include <string_view>
#include <random>
#include <vector>

namespace wallpaper
{
struct SceneMaterial;
struct WPShaderInfo;

namespace wpscene
{
class WPMaterial;
struct WPUserTexture;
}

void ApplySystemUserTextures(std::vector<std::string>& textures,
                             const std::vector<wpscene::WPUserTexture>& usertextures);
void LoadMaterialConstantShaderValues(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                                      const WPShaderInfo& info);

class WPSceneParser : public ISceneParser {
public:
    WPSceneParser()  = default;
    ~WPSceneParser() = default;
    std::shared_ptr<Scene> Parse(const SceneParseRequest&, const std::string&, fs::VFS&, audio::SoundManager&) override;
    std::shared_ptr<Scene> Parse(std::string_view scene_id, const std::string&, fs::VFS&, audio::SoundManager&);
};
} // namespace wallpaper
