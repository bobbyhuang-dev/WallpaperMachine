#include "MetalRender/MetalProjection.hpp"

#include <cmath>

namespace wallpaper::metal
{
namespace
{

Eigen::Vector2d Ndc(const Eigen::Vector4d& clip)
{
    const double w = clip.w() == 0.0 ? 1.0 : clip.w();
    return Eigen::Vector2d { clip.x() / w, clip.y() / w };
}

/// Recovers the diagonal scale that makes the Metal mapping agree with the
/// Vulkan one, by probing both transforms with the same viewport rather than
/// asserting a known answer. A test can then disagree with it.
Eigen::Vector4d DeriveFold()
{
    // An asymmetric box, so a sign error cannot cancel against a symmetric one.
    const VulkanViewportBox vulkan { .x = 17.0, .y = 11.0 + 73.0, .width = 29.0, .height = -73.0 };
    const auto              metal = ToMetalViewport(vulkan);

    const auto probe = [&](double ndc_x, double ndc_y) {
        const Eigen::Vector4d clip { ndc_x, ndc_y, 0.5, 1.0 };
        const auto            want = ClipToWindowVulkan(clip, vulkan);
        const auto            got  = ClipToWindowMetal(clip, metal);
        return Eigen::Vector2d { want.x() - got.x(), want.y() - got.y() };
    };

    // If the two conventions already agree, the fold is the identity. If they
    // disagree by a reflection, the same probe at -1 and +1 shows it.
    const auto at_low  = probe(-1.0, -1.0);
    const auto at_high = probe(1.0, 1.0);

    const double y_scale =
        (std::abs(at_low.y()) < 1e-9 && std::abs(at_high.y()) < 1e-9) ? 1.0 : -1.0;
    const double x_scale =
        (std::abs(at_low.x()) < 1e-9 && std::abs(at_high.x()) < 1e-9) ? 1.0 : -1.0;
    return Eigen::Vector4d { x_scale, y_scale, 1.0, 1.0 };
}

} // namespace

Eigen::Vector2d ClipToWindowVulkan(const Eigen::Vector4d& clip, const VulkanViewportBox& viewport)
{
    const auto ndc = Ndc(clip);
    return Eigen::Vector2d {
        ndc.x() * (viewport.width / 2.0) + (viewport.x + viewport.width / 2.0),
        ndc.y() * (viewport.height / 2.0) + (viewport.y + viewport.height / 2.0),
    };
}

Eigen::Vector2d ClipToWindowMetal(const Eigen::Vector4d& clip, const MetalViewportBox& viewport)
{
    const auto ndc = Ndc(clip);
    return Eigen::Vector2d {
        viewport.origin_x + viewport.width * (ndc.x() + 1.0) / 2.0,
        viewport.origin_y + viewport.height * (1.0 - ndc.y()) / 2.0,
    };
}

Eigen::Matrix4d MetalClipSpaceFold()
{
    static const Eigen::Matrix4d fold = [] {
        const auto      scale = DeriveFold();
        Eigen::Matrix4d matrix = Eigen::Matrix4d::Identity();
        matrix(0, 0)           = scale.x();
        matrix(1, 1)           = scale.y();
        matrix(2, 2)           = scale.z();
        matrix(3, 3)           = scale.w();
        return matrix;
    }();
    return fold;
}

Eigen::Matrix4d MetalViewProjection(const Eigen::Matrix4d& compatibility_vp)
{
    return MetalClipSpaceFold() * compatibility_vp;
}

MetalViewportBox ToMetalViewport(const VulkanViewportBox& viewport)
{
    // A negative height names the same window rows as the positive one that
    // starts where it ends. Metal cannot express the sign, only the region.
    const double height   = std::abs(viewport.height);
    const double origin_y = viewport.height < 0.0 ? viewport.y + viewport.height : viewport.y;
    const double width    = std::abs(viewport.width);
    const double origin_x = viewport.width < 0.0 ? viewport.x + viewport.width : viewport.x;
    return MetalViewportBox {
        .origin_x = origin_x,
        .origin_y = origin_y,
        .width    = width,
        .height   = height,
    };
}

bool MetalDepthInClipRange(double clip_z, double clip_w)
{
    if (clip_w == 0.0) return false;
    const double z = clip_z / clip_w;
    return z >= 0.0 && z <= 1.0;
}

} // namespace wallpaper::metal
