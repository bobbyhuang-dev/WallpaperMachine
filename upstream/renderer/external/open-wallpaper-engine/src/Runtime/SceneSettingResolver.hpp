#pragma once

#include "Runtime/DynamicValue.hpp"
#include "Runtime/ScalarAnimation.hpp"

#include <nlohmann/json_fwd.hpp>

#include <cstddef>
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
    std::string_view current_layer_name = {});
std::unique_ptr<DynamicValue> ResolveFloatSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {});
std::unique_ptr<DynamicValue> ResolveVec3Setting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {},
    Vec3SettingSemantic semantic = Vec3SettingSemantic::Generic);
// Resolves a setting at the component count the shader declares. Handing a two-
// or four-component constant to a property script as a string loses the vector:
// the script reads `.x` off that string and hands back NaN.
std::unique_ptr<DynamicValue> ResolveVectorSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::size_t components,
    std::string_view current_layer_name = {});
std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {});
// `component` selects the `c0`-`c3` curve and the matching entry of a vector
// initial value; scalar settings keep their single curve at component 0.
std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& value,
                                                      std::size_t component = 0);

} // namespace wallpaper
