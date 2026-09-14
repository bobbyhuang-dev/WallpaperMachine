#include "WPScene.h"

#include <sstream>

using namespace wallpaper::wpscene;

bool Orthogonalprojection::FromJson(const nlohmann::json& json) {
    if(json.is_null()) return false;
	if(json.contains("auto")) {
		GET_JSON_NAME_VALUE(json, "auto", auto_);
	}
	else {
		GET_JSON_NAME_VALUE(json, "width", width);
		GET_JSON_NAME_VALUE(json, "height", height);
	}
    return true;
}

bool WPSceneCamera::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "center", center);
    GET_JSON_NAME_VALUE(json, "eye", eye);
    GET_JSON_NAME_VALUE(json, "up", up);
    return true;
}

bool WPSceneGeneral::FromJson(const nlohmann::json& json) {
    return FromJson(json, kSceneVersionUnknown);
}

namespace
{
bool WantsVersion(uint16_t pkg_version, uint16_t gate) {
    return pkg_version == WPSceneGeneral::kSceneVersionUnknown || pkg_version >= gate;
}

const nlohmann::json& UnwrapSettingValue(const nlohmann::json& value) {
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

bool HasDynamicSetting(const nlohmann::json& value) {
    return value.is_object() && (value.contains("script") || value.contains("user"));
}

void ReadVec3Setting(const nlohmann::json& json, const char* key, std::array<float, 3>* destination,
                     nlohmann::json* setting, bool* dynamic) {
    if (! json.contains(key) || destination == nullptr || setting == nullptr || dynamic == nullptr)
        return;

    *setting           = json.at(key);
    *dynamic           = HasDynamicSetting(*setting);
    const auto& source = UnwrapSettingValue(*setting);

    if (source.is_array() && source.size() >= 3) {
        (*destination)[0] = source.at(0).get<float>();
        (*destination)[1] = source.at(1).get<float>();
        (*destination)[2] = source.at(2).get<float>();
        return;
    }
    if (source.is_number()) {
        const float scalar = source.get<float>();
        *destination       = { scalar, scalar, scalar };
        return;
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        stream >> (*destination)[0] >> (*destination)[1] >> (*destination)[2];
    }
}
}

bool WPSceneGeneral::FromJson(const nlohmann::json& json, uint16_t pkg_version) {
    GET_JSON_NAME_VALUE(json, "ambientcolor", ambientcolor);
    GET_JSON_NAME_VALUE(json, "skylightcolor", skylightcolor);
    ReadVec3Setting(json, "clearcolor", &clearcolor, &clearcolor_setting, &dynamic_clearcolor);
	GET_JSON_NAME_VALUE_NOWARN(json, "clearenabled", clearenabled);
	GET_JSON_NAME_VALUE(json, "cameraparallax", cameraparallax);
	GET_JSON_NAME_VALUE(json, "cameraparallaxamount", cameraparallaxamount);
	GET_JSON_NAME_VALUE(json, "cameraparallaxdelay", cameraparallaxdelay);
	GET_JSON_NAME_VALUE(json, "cameraparallaxmouseinfluence", cameraparallaxmouseinfluence);
	GET_JSON_NAME_VALUE_NOWARN(json, "zoom", zoom);
	GET_JSON_NAME_VALUE_NOWARN(json, "fov", fov);
	GET_JSON_NAME_VALUE_NOWARN(json, "nearz", nearz);
	GET_JSON_NAME_VALUE_NOWARN(json, "farz", farz);
	GET_JSON_NAME_VALUE_NOWARN(json, "bloom", bloom);
	GET_JSON_NAME_VALUE_NOWARN(json, "bloomstrength", bloomstrength);
	GET_JSON_NAME_VALUE_NOWARN(json, "bloomthreshold", bloomthreshold);
    if (WantsVersion(pkg_version, 10)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "hdr", hdr);
	    GET_JSON_NAME_VALUE_NOWARN(json, "norecompile", norecompile);
    }
    if (WantsVersion(pkg_version, 20)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "bloomtint", bloomtint);
    }
    if (WantsVersion(pkg_version, 21)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "perspectiveoverridefov", perspectiveoverridefov);
	    GET_JSON_NAME_VALUE_NOWARN(json, "windenabled", windenabled);
	    GET_JSON_NAME_VALUE_NOWARN(json, "winddirection", winddirection);
	    GET_JSON_NAME_VALUE_NOWARN(json, "windstrength", windstrength);
	    GET_JSON_NAME_VALUE_NOWARN(json, "gravitydirection", gravitydirection);
	    GET_JSON_NAME_VALUE_NOWARN(json, "gravitystrength", gravitystrength);
    }
    if (WantsVersion(pkg_version, 22)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "transparentsorting", transparentsorting);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistance", fogdistance);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistancestart", fogdistancestart);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistanceend", fogdistanceend);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistancecolor", fogdistancecolor);
    }
    if (WantsVersion(pkg_version, 23)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogheight", fogheight);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightstart", fogheightstart);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightend", fogheightend);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightcolor", fogheightcolor);
    }
    if (WantsVersion(pkg_version, 21) &&
        json.contains("lightconfig") && json.at("lightconfig").is_object()) {
        lightconfig = json.at("lightconfig");
    }
    if(json.contains("orthogonalprojection")) {
        const auto& ortho = json.at("orthogonalprojection");
        if(ortho.is_null())
            isOrtho = false;
        else {
            isOrtho = true;
            orthogonalprojection.FromJson(ortho);
        }
    }
    return true;
}

bool WPScene::FromJson(const nlohmann::json& json) {
    return FromJson(json, WPSceneGeneral::kSceneVersionUnknown);
}

bool WPScene::FromJson(const nlohmann::json& json, uint16_t pkg_version) {
    this->pkg_version = pkg_version;
    if(json.contains("camera")) {
        camera.FromJson(json.at("camera"));
    } else {
        LOG_ERROR("scene no camera");
        return false;
    }
    if(json.contains("general")) {
        general.FromJson(json.at("general"), pkg_version);
    } else {
        LOG_ERROR("scene no genera data");
        return false;
    }
    return true; 
}
