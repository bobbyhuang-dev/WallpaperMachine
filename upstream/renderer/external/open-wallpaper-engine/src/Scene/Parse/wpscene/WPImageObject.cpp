#include "WPImageObject.h"
#include "WPObjectSchema.hpp"
#include "Utils/Logging.h"
#include "Fs/VFS.h"

#include <sstream>

using namespace wallpaper::wpscene;

namespace
{

const nlohmann::json& unwrap_setting(const nlohmann::json& value)
{
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

bool has_dynamic_setting(const nlohmann::json& value)
{
    return value.is_object() && (value.contains("script") || value.contains("user"));
}

void read_vec3_setting(
    const nlohmann::json&  json,
    const char*            key,
    std::array<float, 3>*  destination,
    nlohmann::json*        setting,
    bool*                  dynamic)
{
    if (!json.contains(key) || destination == nullptr || setting == nullptr || dynamic == nullptr) return;

    *setting = json.at(key);
    *dynamic = has_dynamic_setting(*setting);

    const auto& source = unwrap_setting(*setting);
    if (source.is_array() && source.size() >= 3) {
        (*destination)[0] = source.at(0).get<float>();
        (*destination)[1] = source.at(1).get<float>();
        (*destination)[2] = source.at(2).get<float>();
        return;
    }
    if (source.is_number()) {
        const float scalar = source.get<float>();
        *destination = { scalar, scalar, scalar };
        return;
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        stream >> (*destination)[0] >> (*destination)[1] >> (*destination)[2];
    }
}

} // namespace


bool WPEffectCommand::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "command", command);
    GET_JSON_NAME_VALUE(json, "target", target);
    GET_JSON_NAME_VALUE(json, "source", source);
    return true;
}

bool WPEffectFbo::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "name", name);
    GET_JSON_NAME_VALUE(json, "format", format);

    GET_JSON_NAME_VALUE(json, "scale", scale);
    if(scale == 0) { 
        LOG_ERROR("fbo scale can't be 0");
        scale = 1;
    }
    return true;
}

// Define and initialize the static property
const std::unordered_set<std::string> WPImageEffect::BLACKLISTED_WORKSHOP_EFFECTS = 
{
    "2799421411" // Audio Responsive Oscilloscope   --  causes vulcan deadlock
};


bool WPImageEffect::IsEffectBlacklisted(const std::string& filePath) {
    
    std::filesystem::path path(filePath);
    // Check if the path has a parent path
    if (path.has_parent_path()) {
        path = path.parent_path();
        if(path.has_parent_path()) {
            std::string effectId = path.parent_path().filename().string();
            std::string parentPath = path.parent_path().string();
            return WPImageEffect::BLACKLISTED_WORKSHOP_EFFECTS.find(effectId) != WPImageEffect::BLACKLISTED_WORKSHOP_EFFECTS.end();
        }
    }
    return false;
}
    
bool WPImageEffect::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    std::string filePath;
    GET_JSON_NAME_VALUE(json, "file", filePath);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if(this->IsEffectBlacklisted(filePath)) {
        //hide blacklisted effects
        visible = false;
    }
	GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    nlohmann::json jEffect;
    if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + filePath), jEffect))
        return false;
    if(!FromFileJson(jEffect, vfs))
        return false;

    if(json.contains("passes")) {
        const auto& jPasses = json.at("passes");
        if(jPasses.size() > passes.size()) {
            LOG_ERROR("passes is not injective");
            return false;
        }
        int32_t i = 0;
        for(const auto& jP:jPasses) {
            WPMaterialPass pass;
            pass.FromJson(jP);
            passes[i++].Update(pass); 
        }
    }
    return true;
}

bool WPImageEffect::FromFileJson(const nlohmann::json& json, fs::VFS& vfs) {
	GET_JSON_NAME_VALUE_NOWARN(json, "version", version);
    GET_JSON_NAME_VALUE(json, "name", name);
    if(json.contains("fbos")) {
        for(auto& jF:json.at("fbos")) {
            WPEffectFbo fbo;
            fbo.FromJson(jF);
            fbos.push_back(std::move(fbo));
        }
    }
    if(json.contains("passes")) {
        const auto& jEPasses = json.at("passes");
        bool compose {false};
        for(const auto& jP:jEPasses) {
            if(!jP.contains("material")) {
                if(jP.contains("command")) {
                    WPEffectCommand cmd;
                    cmd.FromJson(jP);
                    cmd.afterpos = passes.size();
                    commands.push_back(cmd);
                    continue;
                }
                LOG_ERROR("no material in effect pass");
                return false;
            }
            std::string matPath;
            GET_JSON_NAME_VALUE(jP, "material", matPath);
            nlohmann::json jMat;
            if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + matPath), jMat))
                return false;
            WPMaterial material;
            material.FromJson(jMat);
            materials.push_back(std::move(material));
            WPMaterialPass pass;
            pass.FromJson(jP);
            passes.push_back(std::move(pass));
            if(jP.contains("compose"))
	            GET_JSON_NAME_VALUE(jP, "compose", compose);
        }
        if(compose) {
            if(passes.size() != 2) {
                LOG_ERROR("effect compose option error");
                return false;
            }
            WPEffectFbo fbo; {fbo.name = "_rt_FullCompoBuffer1"; fbo.scale = 1;}
            fbos.push_back(fbo);
            passes.at(0).bind.push_back({ "previous", 0});
            passes.at(0).target = "_rt_FullCompoBuffer1";
            passes.at(1).bind.push_back({"_rt_FullCompoBuffer1", 0});
        }
    } else {
        LOG_ERROR("no passes in effect file");
        return false;
    }
    return true;
}

bool WPImageObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    GET_JSON_NAME_VALUE(json, "image", image);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if (json.contains("visible")) {
        visible_setting  = json.at("visible");
        dynamic_visible = visible_setting.is_object() &&
                          (visible_setting.contains("script") || visible_setting.contains("user"));
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "alignment", alignment);
    nlohmann::json jImage;
    if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + image), jImage)) {
        LOG_ERROR("Can't load image json: %s", image.c_str());
        return false;
    }
    GET_JSON_NAME_VALUE_NOWARN(jImage, "fullscreen", fullscreen);
    GET_JSON_NAME_VALUE_NOWARN(jImage, "passthrough", config.passthrough);
	GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
	GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
	GET_JSON_NAME_VALUE_NOWARN(json, "parent", parent_id);
	GET_JSON_NAME_VALUE_NOWARN(json, "attachment", attachment);
	GET_JSON_NAME_VALUE_NOWARN(json, "colorBlendMode", colorBlendMode);
    GET_JSON_NAME_VALUE_NOWARN(json, "copybackground", copybackground);
    read_vec3_setting(json, "origin", &origin, &origin_setting, &dynamic_origin);
    read_vec3_setting(json, "scale", &scale, &scale_setting, &dynamic_scale);
    read_vec3_setting(json, "angles", &angles, &angles_setting, &dynamic_angles);
	if(!fullscreen) {
		GET_JSON_NAME_VALUE_NOWARN(json, "parallaxDepth", parallaxDepth);
		if(jImage.contains("width")) {
			int32_t w,h;
			GET_JSON_NAME_VALUE(jImage, "width", w);	
			GET_JSON_NAME_VALUE(jImage, "height", h);	
			size = {(float)w, (float)h};
		} else if(json.contains("size")) {
			GET_JSON_NAME_VALUE(json, "size", size);	
		} else {
			size = {origin.at(0)*2, origin.at(1)*2};
		}
    }
    GET_JSON_NAME_VALUE_NOWARN(jImage, "nopadding", nopadding);
    GET_JSON_NAME_VALUE_NOWARN(json, "color", color);
    if (json.contains("alpha")) {
        alpha_setting = json.at("alpha");
        dynamic_alpha = alpha_setting.is_object() && alpha_setting.contains("animation");
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "alpha", alpha);
    GET_JSON_NAME_VALUE_NOWARN(json, "brightness", brightness);

	GET_JSON_NAME_VALUE_NOWARN(jImage, "puppet", puppet);	
    if(jImage.contains("material")) {
        std::string matPath;
		GET_JSON_NAME_VALUE(jImage, "material", matPath);	
        nlohmann::json jMat;
        if(!PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + matPath), jMat)) {
            LOG_ERROR("Can't load material json: %s", matPath.c_str());
            return false;
        }
        material.FromJson(jMat);
    } else {
        LOG_INFO("image object no material");
        return false;
    }
    if(json.contains("effects")) {
        for(const auto& jE:json.at("effects")) {
            WPImageEffect wpeff;
            wpeff.FromJson(jE, vfs);
            effects.push_back(std::move(wpeff));
        }
    }
    if(json.contains("animationlayers")) {
        for(const auto& jLayer:json.at("animationlayers")) {
             WPPuppetLayer::AnimationLayer layer;
             GET_JSON_NAME_VALUE(jLayer, "animation", layer.id);
             GET_JSON_NAME_VALUE(jLayer, "blend", layer.blend);
             GET_JSON_NAME_VALUE(jLayer, "rate", layer.rate);
             GET_JSON_NAME_VALUE_NOWARN(jLayer, "visible", layer.visible);
             GET_JSON_NAME_VALUE_NOWARN(jLayer, "id", layer.layer_id);
             GET_JSON_NAME_VALUE_NOWARN(jLayer, "name", layer.name);
             GET_JSON_NAME_VALUE_NOWARN(jLayer, "additive", layer.additive);
             GET_JSON_NAME_VALUE_NOWARN(jLayer, "blendin", layer.blendin);
             GET_JSON_NAME_VALUE_NOWARN(jLayer, "blendout", layer.blendout);
             GET_JSON_NAME_VALUE_NOWARN(jLayer, "blendtime", layer.blendtime);
             puppet_layers.push_back(layer);
        }
    }
    if(json.contains("config")) {
        const auto& jConf = json.at("config");
        GET_JSON_NAME_VALUE_NOWARN(jConf, "passthrough", config.passthrough);
    }
    ParseDependencies(json, dependencies);
    if (json.contains("instance") && json.at("instance").is_object()) {
        const auto& jInstance = json.at("instance");
        instance.enabled = true;
        GET_JSON_NAME_VALUE_NOWARN(jInstance, "id", instance.id);
        if (jInstance.contains("textures")) {
            for (const auto& jT : jInstance.at("textures")) {
                std::string texture;
                if (! jT.is_null()) GET_JSON_VALUE_NOWARN(jT, texture);
                instance.textures.push_back(texture);
            }
        }
        if (jInstance.contains("usertextures")) {
            for (const auto& jT : jInstance.at("usertextures")) {
                WPUserTexture user_texture;
                if (jT.is_string()) {
                    GET_JSON_VALUE_NOWARN(jT, user_texture.name);
                } else if (jT.is_object()) {
                    GET_JSON_NAME_VALUE_NOWARN(jT, "name", user_texture.name);
                    GET_JSON_NAME_VALUE_NOWARN(jT, "type", user_texture.type);
                }
                instance.usertextures.push_back(user_texture);
            }
        }
        if (jInstance.contains("combos")) {
            for (const auto& jC : jInstance.at("combos").items()) {
                int32_t value { 0 };
                GET_JSON_VALUE_NOWARN(jC.value(), value);
                instance.combos[jC.key()] = value;
            }
        }
    }
    AbsorbFieldBindings(json, field_bindings);
    return true;
}
