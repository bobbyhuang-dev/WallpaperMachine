#pragma once

#include <string>

namespace wallpaper
{
class Scene;

namespace metal
{

/// Why this scene's video texture cannot be played by the native backend, or
/// empty when nothing about it is known to be unsupported.
///
/// This is the compile-time half of the answer and it only reads what the scene
/// already recorded: no decoder is opened, no media is probed and nothing here
/// touches Metal, so it stays usable from the capability gate. A format the
/// decoder actually produces is a different question and is answered where the
/// frames are — `MetalVideoTextures::prepare` rejects the pixel formats the
/// import cannot handle, with the frame in hand.
[[nodiscard]] std::string MetalVideoTextureRejection(const Scene&       scene,
                                                     const std::string& texture_name);

} // namespace metal
} // namespace wallpaper
