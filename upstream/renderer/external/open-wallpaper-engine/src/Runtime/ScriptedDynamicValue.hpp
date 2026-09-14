#pragma once

#include "Runtime/DynamicValue.hpp"

#include <map>
#include <string>
#include <string_view>

namespace wallpaper
{

class SceneRuntimeContext;
class PropertyScriptProgram;
struct ScriptHostContext;

enum class ScriptedValueSemantic
{
    Generic,
    AnglesDegrees,
};

class ScriptedDynamicValue final : public DynamicValue {
public:
    ScriptedDynamicValue(SceneRuntimeContext& runtime, std::string script_source,
                         std::string                                  current_layer_name,
                         std::map<std::string, DynamicValueUniquePtr> script_properties,
                         DynamicValue                                 base_value,
                         ScriptedValueSemantic semantic = ScriptedValueSemantic::Generic);
    ~ScriptedDynamicValue() override;

    void update(const DynamicValue& other) override;

    const std::string& LayerName() const { return m_current_layer_name; }

    void reevaluate();
    void DispatchCursorClick(const ScriptHostContext& host_context);
    void DispatchCursorDown(const ScriptHostContext& host_context);
    void DispatchCursorEnter(const ScriptHostContext& host_context);
    void DispatchCursorLeave(const ScriptHostContext& host_context);
    void DispatchCursorMove(const ScriptHostContext& host_context);
    void DispatchCursorUp(const ScriptHostContext& host_context);
    void DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                       const Eigen::Vector3f& text_color);
    void DispatchMediaEventJson(std::string_view event_json);

private:
    SceneRuntimeContext*                         m_runtime = nullptr;
    std::string                                  m_current_layer_name;
    std::map<std::string, DynamicValueUniquePtr> m_script_properties;
    std::unique_ptr<PropertyScriptProgram>       m_program;
    DynamicValue                                 m_base_value;
    ScriptedValueSemantic                        m_semantic { ScriptedValueSemantic::Generic };
};

} // namespace wallpaper
