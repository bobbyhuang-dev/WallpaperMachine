#include "Scene/include/Scene/SceneBackendSelection.hpp"

#include <atomic>

namespace wallpaper
{
namespace
{
/// Compatibility by default. The native backend covers a subset of what the
/// compatibility one does, so opting in is a deliberate act.
std::atomic<SceneRendererPreference> g_preference { SceneRendererPreference::Compatibility };
} // namespace

void SetSceneRendererPreference(SceneRendererPreference preference)
{
    g_preference.store(preference, std::memory_order_relaxed);
}

SceneRendererPreference CurrentSceneRendererPreference()
{
    return g_preference.load(std::memory_order_relaxed);
}

} // namespace wallpaper
