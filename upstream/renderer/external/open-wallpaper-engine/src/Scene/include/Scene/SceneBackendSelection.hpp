#pragma once

#include <cstdint>
#include <string>

namespace wallpaper
{

/// Which renderer the user asked for.
///
/// A preference, never an outcome. Asking for the native backend does not make
/// a scene use it: the scene is checked against what that backend can actually
/// draw, and one it cannot draw runs on the compatibility backend and says why.
enum class SceneRendererPreference : uint8_t
{
    Compatibility = 0,
    NativeMetalPreferred = 1,
};

/// Which renderer actually drew a scene.
enum class SceneBackend : uint8_t
{
    LegacyVulkan = 0,
    NativeMetal = 1,
};

void SetSceneRendererPreference(SceneRendererPreference preference);
SceneRendererPreference CurrentSceneRendererPreference();

/// Why a scene is not on the preferred backend.
///
/// Empty means it is. Every rejection carries a specific, user-readable reason:
/// "unsupported" with no reason is indistinguishable from a bug, and this is
/// the string a user will quote when asking why their wallpaper did not switch.
struct SceneBackendSelection
{
    SceneBackend backend { SceneBackend::LegacyVulkan };
    std::string  fallback_reason;

    [[nodiscard]] bool fell_back() const { return ! fallback_reason.empty(); }
};

} // namespace wallpaper
