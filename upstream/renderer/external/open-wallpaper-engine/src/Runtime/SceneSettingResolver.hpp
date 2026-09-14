#pragma once

#include "Runtime/DynamicValue.hpp"
#include "Runtime/ScalarAnimation.hpp"

#include <nlohmann/json_fwd.hpp>

#include <memory>
#include <optional>
#include <string_view>

namespace wallpaper
{

class SceneRuntimeContext;

enum class Vec3SettingSemantic
{
    Generic,
    AnglesDegrees,
};

std::unique_ptr<DynamicValue> ResolveBoolSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {},
    bool allow_script_update = true);
std::unique_ptr<DynamicValue> ResolveVec3Setting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {},
    Vec3SettingSemantic semantic = Vec3SettingSemantic::Generic,
    bool allow_script_update = true);
std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {},
    bool allow_script_update = true);
std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& value);

} // namespace wallpaper
