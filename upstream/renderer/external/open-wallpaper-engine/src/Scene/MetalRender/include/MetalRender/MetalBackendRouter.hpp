#pragma once

#include "Scene/SceneBackendSelection.hpp"

#include <string_view>

namespace wallpaper
{
class Scene;

namespace metal
{

/// Decides which backend a scene runs on, once, before either is created.
///
/// Combines three things in this order, because each is cheaper and more
/// decisive than the next:
///   1. the user's preference -- asking for compatibility ends it,
///   2. a remembered native prepare failure for this scene,
///   3. the capability gate.
///
/// Choosing compatibility because the user asked for it is not a fallback, so
/// it carries no reason. Every other compatibility answer carries one.
[[nodiscard]] SceneBackendSelection SelectSceneBackend(const Scene& scene);

/// Records that the native backend failed to prepare this scene.
///
/// Without this, a scene that fails to prepare would be offered the native
/// backend again on the next load and fail again, which is a flip-flop between
/// two renderers rather than a fallback. The memory is dropped when the
/// preference changes, which is the one thing a user can do that makes the
/// question worth asking again.
void RecordMetalPrepareFailure(const Scene& scene, std::string_view reason);

/// Drops every remembered failure. Called when something material changes --
/// the renderer preference, a shader-pipeline revision, a project reload with
/// different content.
void ForgetMetalPrepareFailures();

} // namespace metal
} // namespace wallpaper
