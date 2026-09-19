#include "MetalRender/MetalVideoSupport.hpp"

#include "Scene/Scene.h"

namespace wallpaper::metal
{

std::string MetalVideoTextureRejection(const Scene& scene, const std::string& texture_name)
{
    const auto iterator = scene.textures.find(texture_name);
    // A texture the scene never described is not a claim of anything. The
    // parser resolves it later, and the frames decide.
    if (iterator == scene.textures.end()) return {};

    const SceneTexture& texture = iterator->second;
    if (! texture.isVideo) return {};

    // A sprite sheet is played by stepping frames of one uploaded image; a
    // video texture that is also one would need both, and this path only ever
    // produces the video frame.
    if (texture.isSprite) return "the video texture is an animated sprite sheet";

    if (texture.url.empty()) return "the video texture names no media";

    return {};
}

} // namespace wallpaper::metal
