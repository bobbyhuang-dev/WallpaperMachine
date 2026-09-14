#include "WPParticleObject.h"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"
#include "Fs/VFS.h"
#include "Core/StringHelper.hpp"

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

void remember_user_binding(
    const nlohmann::json&                  json,
    const char*                            key,
    std::map<std::string, std::string>*    bindings)
{
    if (bindings == nullptr || !json.contains(key)) return;
    const auto& value = json.at(key);
    if (!value.is_object() || !value.contains("user") || !value.at("user").is_string()) return;
    (*bindings)[key] = value.at("user").get<std::string>();
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

bool ParticleChild::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    GET_JSON_NAME_VALUE(json, "name", name);
    GET_JSON_NAME_VALUE(json, "type", type);

    if (name.empty()) {
        return false;
    }

    nlohmann::json jParticle;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + name), jParticle)) return false;

    if (! obj.FromJson(jParticle, vfs)) return false;

    GET_JSON_NAME_VALUE_NOWARN(json, "maxcount", maxcount);
    GET_JSON_NAME_VALUE_NOWARN(json, "controlpointstartindex", controlpointstartindex);
    GET_JSON_NAME_VALUE_NOWARN(json, "probability", probability);

    GET_JSON_NAME_VALUE_NOWARN(json, "origin", origin);
    GET_JSON_NAME_VALUE_NOWARN(json, "scale", scale);
    GET_JSON_NAME_VALUE_NOWARN(json, "angles", angles);
    return true;
}

bool ParticleControlpoint::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "id", id);

    uint32_t _raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", _raw_flags);
    flags = EFlags(_raw_flags);

    GET_JSON_NAME_VALUE_NOWARN(json, "offset", offset);
    return true;
};

bool ParticleRender::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "name", name);
    // ropetrail require subdivition, replaced
    if (name == "ropetrail") name = "spritetrail";

    if (sstart_with(name, "rope")) {
        GET_JSON_NAME_VALUE_NOWARN(json, "subdivision", subdivision);
    }
    if (name == "spritetrail" || name == "ropetrail") {
        GET_JSON_NAME_VALUE_NOWARN(json, "length", length);
        GET_JSON_NAME_VALUE_NOWARN(json, "maxlength", maxlength);
    }
    return true;
}

bool Emitter::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "name", name);
    GET_JSON_NAME_VALUE(json, "id", id);

    GET_JSON_NAME_VALUE_NOWARN(json, "speedmin", speedmin);
    GET_JSON_NAME_VALUE_NOWARN(json, "speedmax", speedmax);
    GET_JSON_NAME_VALUE_NOWARN(json, "instantaneous", instantaneous);
    GET_JSON_NAME_VALUE_NOWARN(json, "distancemax", distancemax);
    GET_JSON_NAME_VALUE_NOWARN(json, "distancemin", distancemin);
    GET_JSON_NAME_VALUE_NOWARN(json, "rate", rate);
    GET_JSON_NAME_VALUE_NOWARN(json, "directions", directions);
    GET_JSON_NAME_VALUE_NOWARN(json, "origin", origin);
    GET_JSON_NAME_VALUE_NOWARN(json, "sign", sign);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingmode", audioprocessingmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "controlpoint", controlpoint);

    if (controlpoint >= 8) LOG_ERROR("wrong controlpoint %d", controlpoint);
    controlpoint = controlpoint % 8; // limited to 0-7

    uint32_t _raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", _raw_flags);
    flags = EFlags(_raw_flags);

    std::transform(sign.begin(), sign.end(), sign.begin(), [](int32_t v) {
        if (v != 0)
            return v / std::abs(v);
        else
            return 0;
    });
    return true;
}

bool ParticleInstanceoverride::FromJosn(const nlohmann::json& json) {
    enabled = true;
    for (const char* key : { "alpha", "size", "lifetime", "rate", "speed", "count", "color", "colorn" }) {
        remember_user_binding(json, key, &bindings);
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "alpha", alpha);
    GET_JSON_NAME_VALUE_NOWARN(json, "size", size);
    GET_JSON_NAME_VALUE_NOWARN(json, "lifetime", lifetime);
    GET_JSON_NAME_VALUE_NOWARN(json, "rate", rate);
    GET_JSON_NAME_VALUE_NOWARN(json, "speed", speed);
    GET_JSON_NAME_VALUE_NOWARN(json, "count", count);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    if (json.contains("color")) {
        GET_JSON_NAME_VALUE(json, "color", color);
        overColor = true;
    } else if (json.contains("colorn")) {
        GET_JSON_NAME_VALUE(json, "colorn", colorn);
        overColorn = true;
    }
    return true;
};

bool Particle::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (! json.contains("emitter")) {
        LOG_ERROR("particle no emitter");
        return false;
    }
    for (const auto& el : json.at("emitter")) {
        Emitter emi;
        emi.FromJson(el);
        emitters.push_back(emi);
    }
    if (json.contains("renderer")) {
        for (const auto& el : json.at("renderer")) {
            ParticleRender pr;
            pr.FromJson(el);
            renderers.push_back(pr);
        }
    }
    // add sprite if no renderers
    if (renderers.empty()) {
        ParticleRender pr;
        pr.name = "sprite";
        renderers.push_back(pr);
    }
    if (json.contains("initializer")) {
        for (const auto& el : json.at("initializer")) {
            initializers.push_back(el);
        }
    }
    if (json.contains("operator")) {
        for (const auto& el : json.at("operator")) {
            operators.push_back(el);
        }
    }
    if (json.contains("controlpoint")) {
        for (const auto& el : json.at("controlpoint")) {
            ParticleControlpoint pc;
            pc.FromJson(el);
            controlpoints.push_back(pc);
        }
    }

    if (json.contains("children")) {
        for (const auto& el : json.at("children")) {
            ParticleChild child;
            if (child.FromJson(el, vfs)) {
                children.push_back(child);
            }
        }
    }
    if (json.contains("material")) {
        std::string matPath;
        GET_JSON_NAME_VALUE(json, "material", matPath);
        nlohmann::json jMat;
        if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + matPath), jMat)) return false;
        material.FromJson(jMat);
    } else {
        LOG_ERROR("particle object no material");
        return false;
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "animationmode", animationmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "sequencemultiplier", sequencemultiplier);
    GET_JSON_NAME_VALUE(json, "maxcount", maxcount);
    GET_JSON_NAME_VALUE(json, "starttime", starttime);

    uint32_t rawflags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", rawflags);
    flags = EFlags(rawflags);

    return true;
}

bool WPParticleObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    GET_JSON_NAME_VALUE(json, "particle", particle);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if (json.contains("visible")) {
        visible_setting  = json.at("visible");
        dynamic_visible = visible_setting.is_object() &&
                          (visible_setting.contains("script") || visible_setting.contains("user"));
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    GET_JSON_NAME_VALUE_NOWARN(json, "parent", parent_id);
    read_vec3_setting(json, "origin", &origin, &origin_setting, &dynamic_origin);
    read_vec3_setting(json, "angles", &angles, &angles_setting, &dynamic_angles);
    read_vec3_setting(json, "scale", &scale, &scale_setting, &dynamic_scale);
    GET_JSON_NAME_VALUE_NOWARN(json, "parallaxDepth", parallaxDepth);
    ParseDependencies(json, dependencies);

    if (json.contains("instanceoverride") && ! json.at("instanceoverride").is_null()) {
        instanceoverride.FromJosn(json.at("instanceoverride"));
    }

    nlohmann::json jParticle;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + particle), jParticle)) return false;
    if (! particleObj.FromJson(jParticle, vfs)) return false;
    AbsorbFieldBindings(json, field_bindings);
    return true;
}
