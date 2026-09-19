#pragma once

#include <cstdint>

namespace wallpaper
{

/// How one scene's video textures reached the shaders that sample them.
///
/// A report, never a request. It lives here rather than beside the Metal
/// renderer because the wallpaper that publishes it and the host binding that
/// reads it both sit below that renderer, and two enumerations with the same
/// meaning would be two definitions that can drift.
enum class SceneVideoPath : uint8_t
{
    /// Nothing has been imported yet, the scene binds no video, or it is drawn
    /// by a backend with only one video path.
    None = 0,
    /// A BGRA frame, imported zero-copy and sampled as one image.
    Bgra,
    /// NV12 planes, sampled directly by every consumer. No colour conversion
    /// was encoded and no conversion destination exists.
    Nv12Direct,
    /// NV12 converted once into one BGRA image, which every consumer samples.
    Nv12Converted,
    /// NV12 with both: the planes for the consumers that can read them and one
    /// shared conversion for the consumers that cannot. Also what a scene whose
    /// video textures took different paths reports.
    Nv12Mixed,
};

/// The name the diagnostics surface uses for one path.
[[nodiscard]] inline const char* SceneVideoPathName(SceneVideoPath path)
{
    switch (path) {
    case SceneVideoPath::Bgra: return "bgra";
    case SceneVideoPath::Nv12Direct: return "nv12_direct";
    case SceneVideoPath::Nv12Converted: return "nv12_converted";
    case SceneVideoPath::Nv12Mixed: return "nv12_mixed";
    case SceneVideoPath::None: break;
    }
    return "none";
}

} // namespace wallpaper
