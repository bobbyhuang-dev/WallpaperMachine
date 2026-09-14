#include "WPMaterial.h"

#include <cstddef>

using namespace wallpaper::wpscene;

namespace
{
WPUserTexture ParseUserTexture(const nlohmann::json& json) {
    WPUserTexture user_texture;
    if (json.is_null()) return user_texture;
    if (json.is_string()) {
        GET_JSON_VALUE_NOWARN(json, user_texture.name);
        return user_texture;
    }
    if (json.is_object()) {
        GET_JSON_NAME_VALUE_NOWARN(json, "name", user_texture.name);
        GET_JSON_NAME_VALUE_NOWARN(json, "type", user_texture.type);
    }
    return user_texture;
}

void ParseUserTextures(const nlohmann::json& json, std::vector<WPUserTexture>& usertextures) {
    if (! json.contains("usertextures")) return;
    for (const auto& item : json.at("usertextures")) {
        usertextures.push_back(ParseUserTexture(item));
    }
}

bool UserTextureEmpty(const WPUserTexture& user_texture) {
    return user_texture.name.empty() && user_texture.type.empty();
}

WPConstantShaderValue ParseConstantShaderValue(const nlohmann::json& json) {
    WPConstantShaderValue result;

    if (json.is_object()) {
        GET_JSON_NAME_VALUE_NOWARN(json, "user", result.user);
        GET_JSON_NAME_VALUE_NOWARN(json, "script", result.script);
        if (json.contains("scriptproperties")) {
            result.scriptproperties = json.at("scriptproperties");
        }
        if (json.contains("value")) {
            if (json.at("value").is_array()) {
                result.value = json.at("value").get<std::vector<float>>();
            } else {
                GET_JSON_VALUE(json.at("value"), result.value);
            }
        }
        return result;
    }

    GET_JSON_VALUE(json, result.value);
    return result;
}

void MergeUserTextures(std::vector<WPUserTexture>&       target,
                       const std::vector<WPUserTexture>& source) {
    if (source.size() > target.size()) target.resize(source.size());
    for (std::size_t index = 0; index < source.size(); ++index) {
        if (! UserTextureEmpty(source[index])) target[index] = source[index];
    }
}
} // namespace

bool WPMaterialPassBindItem::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "name", name);
    GET_JSON_NAME_VALUE(json, "index", index);
    return true;
}

void WPMaterialPass::Update(const WPMaterialPass& p) {
    int32_t i = -1;
    for (const auto& el : p.textures) {
        i++;
        if (p.textures.size() > textures.size()) textures.resize(p.textures.size());
        if (! el.empty()) {
            textures[i] = el;
        }
    }
    MergeUserTextures(usertextures, p.usertextures);
    for (const auto& el : p.constantshadervalues) {
        constantshadervalues[el.first] = el.second;
    }
    for (const auto& el : p.combos) {
        combos[el.first] = el.second;
    }
}

void WPMaterial::MergePass(const WPMaterialPass& p) {
    int32_t i = -1;
    for (const auto& el : p.textures) {
        i++;
        if (p.textures.size() > textures.size()) textures.resize(p.textures.size());
        if (! el.empty()) {
            textures[i] = el;
        }
    }
    MergeUserTextures(usertextures, p.usertextures);
    for (const auto& el : p.constantshadervalues) {
        constantshadervalues[el.first] = el.second;
    }
    for (const auto& el : p.combos) {
        combos[el.first] = el.second;
    }
}

bool WPMaterialPass::FromJson(const nlohmann::json& json) {
    if (json.contains("textures")) {
        for (const auto& jT : json.at("textures")) {
            std::string tex;
            if (! jT.is_null()) GET_JSON_VALUE(jT, tex);
            textures.push_back(tex);
        }
    }
    ParseUserTextures(json, usertextures);
    if (json.contains("constantshadervalues")) {
        for (const auto& jC : json.at("constantshadervalues").items()) {
            std::string name;
            GET_JSON_VALUE(jC.key(), name);
            constantshadervalues[name] = ParseConstantShaderValue(jC.value());
        }
    }
    if (json.contains("combos")) {
        for (const auto& jC : json.at("combos").items()) {
            std::string name;
            int32_t     value;
            GET_JSON_VALUE(jC.key(), name);
            GET_JSON_VALUE(jC.value(), value);
            combos[name] = value;
        }
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "target", target);
    if (json.contains("bind")) {
        for (const auto& jB : json.at("bind")) {
            WPMaterialPassBindItem bindItem;
            bindItem.FromJson(jB);
            bind.push_back(bindItem);
        }
    }
    return true;
}

bool WPMaterial::FromJson(const nlohmann::json& json) {
    if (! json.contains("passes") || json.at("passes").size() == 0) {
        LOG_ERROR("material no data");
        return false;
    }
    const auto jContent = json.at("passes").at(0);
    if (! jContent.contains("shader")) {
        LOG_ERROR("material no shader");
        return false;
    }
    GET_JSON_NAME_VALUE(jContent, "blending", blending);
    GET_JSON_NAME_VALUE(jContent, "cullmode", cullmode);
    GET_JSON_NAME_VALUE(jContent, "depthtest", depthtest);
    GET_JSON_NAME_VALUE(jContent, "depthwrite", depthwrite);
    GET_JSON_NAME_VALUE(jContent, "shader", shader);
    if (jContent.contains("textures")) {
        for (const auto& jT : jContent.at("textures")) {
            std::string tex;
            if (! jT.is_null()) GET_JSON_VALUE(jT, tex);
            textures.push_back(tex);
        }
    }
    ParseUserTextures(jContent, usertextures);
    if (jContent.contains("constantshadervalues")) {
        for (const auto& jC : jContent.at("constantshadervalues").items()) {
            std::string name;
            GET_JSON_VALUE(jC.key(), name);
            constantshadervalues[name] = ParseConstantShaderValue(jC.value());
        }
    }
    if (jContent.contains("combos")) {
        for (const auto& jC : jContent.at("combos").items()) {
            std::string name;
            int32_t     value;
            GET_JSON_VALUE(jC.key(), name);
            GET_JSON_VALUE(jC.value(), value);
            combos[name] = value;
        }
    }
    return true;
}
