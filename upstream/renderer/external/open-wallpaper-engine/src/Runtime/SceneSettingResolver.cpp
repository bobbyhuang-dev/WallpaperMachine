#include "Runtime/SceneSettingResolver.hpp"

#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cmath>
#include <sstream>

namespace wallpaper
{
namespace
{

const nlohmann::json& unwrap_value(const nlohmann::json& value)
{
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

Eigen::Vector3f parse_vec3(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_array() && source.size() >= 3) {
        return Eigen::Vector3f(
            source.at(0).get<float>(),
            source.at(1).get<float>(),
            source.at(2).get<float>());
    }
    if (source.is_number()) {
        const float scalar = source.get<float>();
        return Eigen::Vector3f(scalar, scalar, scalar);
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        float x = 0.0f;
        float y = 0.0f;
        float z = 0.0f;
        stream >> x >> y >> z;
        return Eigen::Vector3f(x, y, z);
    }
    return Eigen::Vector3f::Zero();
}

float parse_float(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_number()) return source.get<float>();
    if (source.is_boolean()) return source.get<bool>() ? 1.0f : 0.0f;
    if (source.is_string()) {
        try {
            return std::stof(source.get<std::string>());
        } catch (...) {
            return 0.0f;
        }
    }
    return 0.0f;
}

bool parse_bool(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_boolean()) return source.get<bool>();
    if (source.is_number()) return source.get<float>() != 0.0f;
    if (source.is_string()) return source.get<std::string>() == "true" || source.get<std::string>() == "1";
    return false;
}

std::string parse_string(const nlohmann::json& value)
{
    const auto& source = unwrap_value(value);
    if (source.is_string()) return source.get<std::string>();
    if (source.is_object() && source.contains("text") && source.at("text").is_string()) {
        return source.at("text").get<std::string>();
    }
    return source.dump();
}

std::optional<ConditionInfo> parse_condition(const nlohmann::json& setting, std::string* user_name)
{
    if (!setting.is_object() || !setting.contains("user")) return std::nullopt;

    const auto& user = setting.at("user");
    if (user.is_string()) {
        *user_name = user.get<std::string>();
        return std::nullopt;
    }
    if (user.is_object() && user.contains("name") && user.at("name").is_string()) {
        *user_name = user.at("name").get<std::string>();
        if (user.contains("condition") && user.at("condition").is_string()) {
            return ConditionInfo {
                .name = *user_name,
                .condition = user.at("condition").get<std::string>(),
            };
        }
    }
    return std::nullopt;
}

DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting);
DynamicValueUniquePtr resolve_auto_setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name);

void bind_user_property(SceneRuntimeContext& context, const nlohmann::json& setting, DynamicValue& value)
{
    std::string user_name;
    const auto  condition = parse_condition(setting, &user_name);
    if (user_name.empty()) return;

    if (condition.has_value()) value.attachCondition(*condition);

    if (auto* property_value = context.FindPropertyValue(user_name); property_value != nullptr) {
        value.connect(property_value);
    }
}

void bind_vec3_user_property(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    DynamicValue& value)
{
    std::string user_name;
    const auto  condition = parse_condition(setting, &user_name);
    if (user_name.empty()) return;

    if (condition.has_value()) value.attachCondition(*condition);

    auto* property_value = context.FindPropertyValue(user_name);
    if (property_value == nullptr) return;

    value.connectVec3(property_value);
}

DynamicValueUniquePtr wrap_script_if_needed(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view     current_layer_name,
    DynamicValueUniquePtr value,
    ScriptedValueSemantic semantic = ScriptedValueSemantic::Generic,
    bool allow_script_update = true)
{
    if (!setting.is_object() || !setting.contains("script") || !setting.at("script").is_string()) {
        return value;
    }

    const auto script_source = setting.at("script").get<std::string>();
    if (!allow_script_update ||
        script_source.find("export function update") == std::string::npos) {
        return value;
    }

    std::map<std::string, DynamicValueUniquePtr> script_properties;
    if (setting.contains("scriptproperties") && setting.at("scriptproperties").is_object()) {
        for (const auto& [name, property] : setting.at("scriptproperties").items()) {
            script_properties.emplace(name, resolve_auto_setting(context, property, current_layer_name));
        }
    }

    auto scripted_value = std::make_unique<ScriptedDynamicValue>(
        context,
        script_source,
        std::string(current_layer_name),
        std::move(script_properties),
        *value,
        semantic);
    context.RegisterScriptedValue(scripted_value.get());
    return scripted_value;
}

DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting)
{
    return resolve_auto_setting(context, setting, {});
}

DynamicValueUniquePtr resolve_auto_setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name)
{
    const auto& source = unwrap_value(setting);
    if (source.is_boolean()) return ResolveBoolSetting(context, setting, current_layer_name);

    DynamicValueUniquePtr value;
    if (source.is_number()) {
        value = std::make_unique<DynamicValue>(parse_float(setting));
    } else if (source.is_string()) {
        value = std::make_unique<DynamicValue>(parse_string(setting));
    } else {
        value = std::make_unique<DynamicValue>();
    }
    bind_user_property(context, setting, *value);
    return value;
}

} // namespace

float ScalarAnimation::Evaluate(double seconds) const
{
    if (!(fps > 0.0) || keyframes.empty() || !std::isfinite(seconds) || seconds <= 0.0) {
        return initial_value;
    }

    double frame = seconds * fps;
    const double animation_length =
        length_frames > 0.0 ? length_frames : keyframes.back().frame;

    if (mode == ScalarAnimationMode::Loop && animation_length > 0.0) {
        frame = std::fmod(frame, animation_length);
        if (frame < 0.0) frame += animation_length;
    } else {
        if (frame < keyframes.front().frame) return initial_value;
        if (frame >= keyframes.back().frame) return keyframes.back().value;
    }

    const auto upper = std::upper_bound(
        keyframes.begin(),
        keyframes.end(),
        frame,
        [](double target, const ScalarAnimationKeyframe& keyframe) {
            return target < keyframe.frame;
        });

    if (upper == keyframes.begin()) return keyframes.front().value;
    if (upper == keyframes.end()) return keyframes.back().value;

    const auto& left  = *(upper - 1);
    const auto& right = *upper;
    const double span = right.frame - left.frame;
    if (span <= 0.0) return right.value;

    const double factor = std::clamp((frame - left.frame) / span, 0.0, 1.0);
    return static_cast<float>(left.value + (right.value - left.value) * factor);
}

std::unique_ptr<DynamicValue> ResolveBoolSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    bool allow_script_update)
{
    auto value = std::make_unique<DynamicValue>(parse_bool(setting));
    value      = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        ScriptedValueSemantic::Generic,
        allow_script_update);
    bind_user_property(context, setting, *value);
    return value;
}

std::unique_ptr<DynamicValue> ResolveVec3Setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    Vec3SettingSemantic semantic,
    bool allow_script_update)
{
    auto value = std::make_unique<DynamicValue>(parse_vec3(setting));
    const auto scripted_semantic =
        semantic == Vec3SettingSemantic::AnglesDegrees
        ? ScriptedValueSemantic::AnglesDegrees
        : ScriptedValueSemantic::Generic;
    value      = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        scripted_semantic,
        allow_script_update);
    bind_vec3_user_property(context, setting, *value);
    return value;
}

std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    bool allow_script_update)
{
    auto value = std::make_unique<DynamicValue>(parse_string(setting));
    value      = wrap_script_if_needed(
        context,
        setting,
        current_layer_name,
        std::move(value),
        ScriptedValueSemantic::Generic,
        allow_script_update);
    bind_user_property(context, setting, *value);
    return value;
}

std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& setting)
{
    if (!setting.is_object() || !setting.contains("animation")) return std::nullopt;

    const auto& animation = setting.at("animation");
    if (!animation.is_object()) return std::nullopt;

    const auto options_iterator = animation.find("options");
    const auto curve_iterator   = animation.find("c0");
    if (options_iterator == animation.end() || curve_iterator == animation.end()) {
        return std::nullopt;
    }
    if (!options_iterator->is_object() || !curve_iterator->is_array() || curve_iterator->empty()) {
        return std::nullopt;
    }

    ScalarAnimation result;
    result.initial_value = parse_float(setting);

    const auto& options = *options_iterator;
    if (options.contains("fps")) {
        result.fps = static_cast<double>(parse_float(options.at("fps")));
    }
    if (options.contains("length")) {
        result.length_frames = static_cast<double>(parse_float(options.at("length")));
    }
    if (options.contains("mode") && options.at("mode").is_string()) {
        result.mode = options.at("mode").get<std::string>() == "loop"
                          ? ScalarAnimationMode::Loop
                          : ScalarAnimationMode::Single;
    }

    for (const auto& keyframe : *curve_iterator) {
        if (!keyframe.is_object() || !keyframe.contains("frame") || !keyframe.contains("value")) {
            continue;
        }

        ScalarAnimationKeyframe parsed;
        parsed.frame = static_cast<double>(parse_float(keyframe.at("frame")));
        parsed.value = parse_float(keyframe.at("value"));
        result.keyframes.push_back(parsed);
    }

    if (result.keyframes.empty()) return std::nullopt;

    std::sort(
        result.keyframes.begin(),
        result.keyframes.end(),
        [](const ScalarAnimationKeyframe& left, const ScalarAnimationKeyframe& right) {
            return left.frame < right.frame;
        });
    return result;
}

} // namespace wallpaper
