#include "Runtime/ScriptedDynamicValue.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scripting/ScriptEngine.hpp"

namespace wallpaper
{

ScriptedDynamicValue::ScriptedDynamicValue(
    SceneRuntimeContext& runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValueUniquePtr> script_properties, DynamicValue base_value,
    ScriptedValueSemantic semantic)
    : m_runtime(&runtime),
      m_current_layer_name(std::move(current_layer_name)),
      m_script_properties(std::move(script_properties)),
      m_base_value(std::move(base_value)),
      m_semantic(semantic) {
    DynamicValue::update(m_base_value);

    std::map<std::string, DynamicValue*> raw_properties;
    for (auto& [name, property] : m_script_properties) {
        if (property == nullptr) continue;
        raw_properties.emplace(name, property.get());
    }

    const auto program_semantic = m_semantic == ScriptedValueSemantic::AnglesDegrees
                                      ? PropertyScriptValueSemantic::AnglesDegrees
                                      : PropertyScriptValueSemantic::Generic;
    m_program                   = m_runtime->scriptEngine().CreatePropertyScriptProgram(m_runtime,
                                                                      std::move(script_source),
                                                                      m_current_layer_name,
                                                                      std::move(raw_properties),
                                                                      m_base_value,
                                                                      m_runtime->hostContext(),
                                                                      program_semantic);

    for (auto& [name, property] : m_script_properties) {
        (void)name;
        if (property == nullptr) continue;
        property->listen([this](const DynamicValue&) {
            reevaluate();
        });
    }
}

ScriptedDynamicValue::~ScriptedDynamicValue() = default;

void ScriptedDynamicValue::update(const DynamicValue& other) {
    m_base_value.update(other);
    DynamicValue::update(other);
}

void ScriptedDynamicValue::reevaluate() {
    if (m_program == nullptr || ! m_program->Valid()) return;

    auto result = m_program->Evaluate(m_runtime->hostContext(), m_base_value);
    if (result != nullptr) DynamicValue::update(*result);
}

void ScriptedDynamicValue::DispatchCursorClick(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorClick(host_context);
}

void ScriptedDynamicValue::DispatchCursorDown(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorDown(host_context);
}

void ScriptedDynamicValue::DispatchCursorEnter(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorEnter(host_context);
}

void ScriptedDynamicValue::DispatchCursorLeave(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorLeave(host_context);
}

void ScriptedDynamicValue::DispatchCursorMove(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorMove(host_context);
}

void ScriptedDynamicValue::DispatchCursorUp(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorUp(host_context);
}

void ScriptedDynamicValue::DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                         const Eigen::Vector3f& text_color) {
    if (m_program != nullptr) {
        m_program->DispatchMediaThumbnailChanged(primary_color, text_color);
    }
}

void ScriptedDynamicValue::DispatchMediaEventJson(std::string_view event_json) {
    if (m_program != nullptr) {
        m_program->DispatchMediaEventJson(event_json);
    }
}

} // namespace wallpaper
