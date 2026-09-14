#pragma once

#include <Eigen/Dense>

#include <functional>
#include <list>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper
{

struct ConditionInfo
{
    std::string name;
    std::string condition;
};

class DynamicValue
{
public:
    enum UnderlyingType
    {
        Null = 0,
        IVec4 = 1,
        IVec3 = 2,
        IVec2 = 3,
        Vec4 = 4,
        Vec3 = 5,
        Vec2 = 6,
        Float = 7,
        Int = 8,
        Boolean = 9,
        String = 10,
    };

    DynamicValue() = default;
    explicit DynamicValue(const Eigen::Vector4i& value);
    explicit DynamicValue(const Eigen::Vector3i& value);
    explicit DynamicValue(const Eigen::Vector2i& value);
    explicit DynamicValue(const Eigen::Vector4f& value);
    explicit DynamicValue(const Eigen::Vector3f& value);
    explicit DynamicValue(const Eigen::Vector2f& value);
    explicit DynamicValue(float value);
    explicit DynamicValue(int value);
    explicit DynamicValue(bool value);
    explicit DynamicValue(std::string value);
    virtual ~DynamicValue();

    [[nodiscard]] const Eigen::Vector4i& getIVec4() const;
    [[nodiscard]] const Eigen::Vector3i& getIVec3() const;
    [[nodiscard]] const Eigen::Vector2i& getIVec2() const;
    [[nodiscard]] const Eigen::Vector4f& getVec4() const;
    [[nodiscard]] const Eigen::Vector3f& getVec3() const;
    [[nodiscard]] const Eigen::Vector2f& getVec2() const;
    [[nodiscard]] const float&           getFloat() const;
    [[nodiscard]] const int&             getInt() const;
    [[nodiscard]] const bool&            getBool() const;
    [[nodiscard]] const std::string&     getString() const;
    [[nodiscard]] UnderlyingType         getType() const;
    [[nodiscard]] virtual std::string    toString() const;

    virtual void update(float new_value);
    virtual void update(int new_value);
    virtual void update(bool new_value);
    virtual void update(const Eigen::Vector2f& new_value);
    virtual void update(const Eigen::Vector3f& new_value);
    virtual void update(const Eigen::Vector4f& new_value);
    virtual void update(const Eigen::Vector2i& new_value);
    virtual void update(const Eigen::Vector3i& new_value);
    virtual void update(const Eigen::Vector4i& new_value);
    virtual void update(const std::string& new_value);
    virtual void update(const DynamicValue& other);
    virtual void update();

    std::function<void()> listen(const std::function<void(const DynamicValue&)>& callback);
    void                  connect(DynamicValue* other);
    void                  connectVec3(DynamicValue* other);
    void                  disconnect();
    void                  attachCondition(const ConditionInfo& condition);

private:
    void propagate() const;

    std::shared_ptr<bool>                            m_alive_flag = std::make_shared<bool>(true);
    std::list<std::function<void(const DynamicValue&)>> m_listeners {};
    std::vector<std::function<void()>>              m_connections {};

    Eigen::Vector4i m_ivec4 = Eigen::Vector4i::Zero();
    Eigen::Vector3i m_ivec3 = Eigen::Vector3i::Zero();
    Eigen::Vector2i m_ivec2 = Eigen::Vector2i::Zero();
    Eigen::Vector4f m_vec4  = Eigen::Vector4f::Zero();
    Eigen::Vector3f m_vec3  = Eigen::Vector3f::Zero();
    Eigen::Vector2f m_vec2  = Eigen::Vector2f::Zero();
    float           m_float = 0.0f;
    int             m_int   = 0;
    bool            m_bool  = false;
    std::string     m_string {};
    UnderlyingType  m_type = Null;
    std::optional<ConditionInfo> m_condition = std::nullopt;
};

using DynamicValueUniquePtr = std::unique_ptr<DynamicValue>;

} // namespace wallpaper
