#pragma once

#include <cstdint>
#include <nlohmann/json.hpp>
#include <vector>

namespace wallpaper::wpscene
{

inline void ParseDependencies(const nlohmann::json& json, std::vector<int32_t>& out) {
    if (! json.contains("dependencies") || ! json.at("dependencies").is_array()) return;
    for (const auto& item : json.at("dependencies")) {
        if (item.is_number_integer()) out.push_back(item.get<int32_t>());
    }
}

inline void AbsorbFieldBindings(const nlohmann::json& json, nlohmann::json& out) {
    for (const auto& item : json.items()) {
        if (item.value().is_object() &&
            (item.value().contains("animation") ||
             item.value().contains("scriptproperties") ||
             item.value().contains("script"))) {
            out[item.key()] = item.value();
        }
    }
}

} // namespace wallpaper::wpscene
