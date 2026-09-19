#pragma once
#include <vector>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <algorithm>
#include <span>
#include <optional>
#include <memory>

#include <Eigen/Dense>

#include "Core/MapSet.hpp"
#include "Core/ArrayHelper.hpp"

namespace wallpaper
{
using ShaderValueInter = std::array<float, 16>;

class ShaderValue {
public:
    using value_type = float;

public:
    ShaderValue()  = default;
    ~ShaderValue() = default;

    ShaderValue(const ShaderValue&)            = default;
    ShaderValue& operator=(const ShaderValue&) = default;

    ShaderValue(const value_type& value) noexcept { fromSpan(spanone { value }); }
    template<typename Range>
    ShaderValue(const Range& range) noexcept {
        fromSpan(range);
    }
    ShaderValue(const value_type* ptr, std::size_t num) noexcept { fromSpan({ ptr, num }); }

    static ShaderValue fromMatrix(const Eigen::Ref<const Eigen::MatrixXf>& mat) {
        return ShaderValue(std::span { mat.data(), (size_t)mat.size() });
    }
    static ShaderValue fromMatrix(const Eigen::Ref<const Eigen::MatrixXd>& mat) {
        const Eigen::Ref<const Eigen::MatrixXf>& matf = mat.cast<float>();
        return fromMatrix(matf);
    };
    const auto& operator[](std::size_t index) const { return _value()[index]; }
    auto& operator[](std::size_t index) { return m_dynamic ? m_dvalue[index] : m_value[index]; }

    auto data() const noexcept { return _value().data(); };
    // constexpr auto data() noexcept { return m_value.data(); };
    size_t size() const noexcept { return m_size; };

    void setSize(size_t v) noexcept { m_size = std::min(v, (size_t)_value().size()); }

private:
    void fromSpan(std::span<const value_type> s) noexcept;

    std::span<const value_type> _value() const noexcept {
        if (m_dynamic) return m_dvalue;
        return m_value;
    }
    bool                    m_dynamic { false };
    ShaderValueInter        m_value;
    std::vector<value_type> m_dvalue;
    size_t                  m_size { 0 };
};

using ShaderValues   = Map<std::string, ShaderValue>;
using ShaderValueMap = ShaderValues;

using ShaderCode = std::vector<unsigned int>;

struct ShaderAttribute {
public:
    std::string name;
    uint32_t    location;
};

/// Metal Shading Language translation of a shader program, defined by the
/// native Metal backend. Deliberately incomplete here: `shared_ptr` erases the
/// deleter at construction, so this declaration gives the scene library the
/// field without giving it a dependency on the renderer that fills it.
struct SceneMetalProgram;

struct SceneShader {
public:
    uint32_t    id;
    std::string name;

    /*
    std::string vertexCode;
    std::string geometryCode;
    std::string fragmentCode;
    */

    std::vector<ShaderCode> codes;

    std::vector<ShaderAttribute> attrs;
    ShaderValues                 default_uniforms;
    std::optional<std::string>   rust_reflection_json;
    /// Null means translation was never attempted, which is the normal state
    /// whenever the compatibility renderer is selected. A non-null program
    /// that reports an error means it was attempted and failed. The two must
    /// stay distinguishable: only the second is a fault in the shader.
    std::shared_ptr<const SceneMetalProgram> metal_program;
};
} // namespace wallpaper
