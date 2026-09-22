#pragma once
#include <cstdint>
#include <cmath>
#include <vector>
#include <memory>
#include <optional>
#include <Eigen/Dense>
#include "SceneImageEffectLayer.h"

namespace wallpaper
{

class SceneNode;

class SceneCamera {
public:
    explicit SceneCamera(i32 width, i32 height, float near, float far)
        : m_width(width),
          m_height(height),
          m_aspect(m_width / m_height),
          m_nearClip(near),
          m_farClip(far),
          m_perspective(false) {}

    explicit SceneCamera(float aspect, float near, float far, float fov)
        : m_aspect(aspect), m_nearClip(near), m_farClip(far), m_fov(fov), m_perspective(true) {}

    SceneCamera(const SceneCamera&) = default;

    void Update();

    void AttatchNode(std::shared_ptr<SceneNode>);

    bool   IsPerspective() const { return m_perspective; }
    double Aspect() const { return m_aspect; }
    double Width() const { return m_width; }
    double Height() const { return m_height; }
    double NearClip() const { return m_nearClip; }
    double FarClip() const { return m_farClip; }
    double Fov() const { return m_fov; }

    void SetWidth(double value) {
        m_width  = value;
        m_aspect = m_width / m_height;
    }
    void SetHeight(double value) {
        m_height = value;
        m_aspect = m_width / m_height;
    }
    void SetAspect(double aspect) { m_aspect = aspect; }
    void SetFov(double value) { m_fov = value; }
    /// A camera object's own zoom, separate from the scene-wide zoom that
    /// writes width and height. Larger zooms in; anything not positive and
    /// finite frames the full canvas.
    void   SetZoom(double value) { m_zoom = value; }
    double Zoom() const { return m_zoom; }
    /// The extent the orthographic projection actually shows. Pointer mapping
    /// reads this rather than the authored width and height: a click has to
    /// land where the zoomed image is, not where an unzoomed one would be.
    double VisibleWidth() const { return m_width / EffectiveZoom(); }
    double VisibleHeight() const { return m_height / EffectiveZoom(); }

    void  AttatchImgEffect(std::shared_ptr<SceneImageEffectLayer> eff) { m_imgEffect = eff; }
    bool  HasImgEffect() const { return (bool)m_imgEffect; }
    auto& GetImgEffect() { return m_imgEffect; }
    void  SetComposeLayer(bool compose) { m_isComposeLayer = compose; }
    bool  IsComposeLayer() const { return m_isComposeLayer; }

    Eigen::Vector3d GetPosition() const;
    Eigen::Vector3d GetDirection() const;
    Eigen::Vector3d GetUp() const;
    Eigen::Vector3d GetRight() const;

    void LockFov(bool lock) { m_fovLocked = lock; }
    bool FovLocked() const { return m_fovLocked; }

    Eigen::Matrix4d GetViewMatrix() const;
    Eigen::Matrix4d GetViewProjectionMatrix() const;

    /// World-space axes of the attached node, which is the basis the particle
    /// shaders read as `g_Orientation*`. Identity when no node is attached,
    /// matching the constants the parser writes for an unrotated camera.
    struct Axes {
        Eigen::Vector3d right { 1.0, 0.0, 0.0 };
        Eigen::Vector3d up { 0.0, 1.0, 0.0 };
        Eigen::Vector3d forward { 0.0, 0.0, 1.0 };
    };
    Axes GetAxes() const;

    std::shared_ptr<SceneNode> GetAttachedNode() const { return m_node; }

    void Clone(const SceneCamera& cam) {
        m_width       = cam.m_width;
        m_height      = cam.m_height;
        m_aspect      = cam.m_aspect;
        m_nearClip    = cam.m_nearClip;
        m_farClip     = cam.m_farClip;
        m_perspective = cam.m_perspective;
        m_fov         = cam.m_fov;
        m_fovLocked   = cam.m_fovLocked;
        m_zoom        = cam.m_zoom;
        m_isComposeLayer = cam.m_isComposeLayer;
    }

private:
    void CalculateViewProjectionMatrix();
    // A zoom of zero, a negative one or a NaN is not a frame anybody can see,
    // so it reads as the whole canvas rather than as a division.
    double EffectiveZoom() const {
        return (std::isfinite(m_zoom) && m_zoom > 0.0) ? m_zoom : 1.0;
    }

    double m_width { 1.0f };
    double m_height { 1.0f };
    double m_aspect { 16.0f / 9.0f };
    double m_nearClip { 0.01f };
    double m_farClip { 1000.0f };
    double m_fov { 45.0f };
    double m_zoom { 1.0 };
    bool   m_perspective;
    bool   m_fovLocked { false };

    Eigen::Matrix4d m_viewMat { Eigen::Matrix4d::Identity() };
    Eigen::Matrix4d m_viewProjectionMat { Eigen::Matrix4d::Identity() };

    std::shared_ptr<SceneNode>             m_node;
    std::shared_ptr<SceneImageEffectLayer> m_imgEffect { nullptr };
    bool                                   m_isComposeLayer { false };
};

/// Intersects the camera ray through NDC `(ndc_x, ndc_y)` with `node`'s local
/// z = 0 plane. NDC is the shared clip space after the perspective divide,
/// x/y in [-1, 1], with this engine's near = 0 and far = 1. Returns local
/// coordinates on the plane, or nullopt if the inverse is degenerate, the ray
/// is parallel to the plane, or the hit lies outside the clip volume.
[[nodiscard]] std::optional<Eigen::Vector3d> IntersectNdcWithNodePlane(
    const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y);
} // namespace wallpaper
