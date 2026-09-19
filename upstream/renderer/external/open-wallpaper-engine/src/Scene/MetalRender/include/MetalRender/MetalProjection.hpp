#pragma once

#include <Eigen/Dense>

namespace wallpaper::metal
{

/// A Vulkan viewport, with the sign convention Vulkan allows: `height` may be
/// negative, which is how the compatibility backend gets Vulkan to agree with
/// the coordinate system the authored shaders were written for.
struct VulkanViewportBox
{
    double x { 0.0 };
    double y { 0.0 };
    double width { 0.0 };
    double height { 0.0 };
};

/// A Metal viewport. `height` is always positive; Metal has no negative-height
/// viewport, which is the entire reason this file exists.
struct MetalViewportBox
{
    double origin_x { 0.0 };
    double origin_y { 0.0 };
    double width { 0.0 };
    double height { 0.0 };
};

/// Clip space to window pixels under Vulkan's viewport transform:
///   x_w = x_ndc * (w/2) + (x + w/2)
///   y_w = y_ndc * (h/2) + (y + h/2)
/// With a negative `h` the second line reduces to y_w = y + h*(1 - y_ndc)/2,
/// which puts clip y = +1 at the top of the box.
[[nodiscard]] Eigen::Vector2d ClipToWindowVulkan(const Eigen::Vector4d& clip,
                                                 const VulkanViewportBox& viewport);

/// Clip space to window pixels under Metal's viewport transform. Metal's
/// normalized device coordinates have +Y up (its lower-left corner is (-1,-1))
/// while its render targets have their origin at the top left, so:
///   x_w = origin_x + width  * (x_ndc + 1) / 2
///   y_w = origin_y + height * (1 - y_ndc) / 2
[[nodiscard]] Eigen::Vector2d ClipToWindowMetal(const Eigen::Vector4d& clip,
                                                const MetalViewportBox& viewport);

/// The matrix the Metal backend folds into every view-projection it uploads,
/// so an authored vertex shader's clip-space output lands on the same window
/// pixel it lands on under the compatibility backend.
///
/// The answer is the identity, and that is a result rather than an omission.
/// Vulkan's NDC has +Y down against a +Y-down framebuffer; the compatibility
/// backend's negative-height viewport is what makes Vulkan behave the way the
/// authored GL-style shaders expect. Metal already behaves that way, because
/// its NDC has +Y up against a top-left-origin target -- the same window
/// mapping, reached without a negative height. Adding a flip here would invert
/// every scene and every render-to-target sample.
///
/// It is computed from the two transforms above rather than written down, so
/// this stays a derivation a test can falsify: `MetalClipSpaceFold` changes if
/// either convention above is edited, and the Y-flip test fails if anyone
/// inserts a flip or deletes the derivation.
[[nodiscard]] Eigen::Matrix4d MetalClipSpaceFold();

/// The view-projection to upload to a Metal shader, given the one the
/// compatibility backend would upload for the same camera.
[[nodiscard]] Eigen::Matrix4d MetalViewProjection(const Eigen::Matrix4d& compatibility_vp);

/// The Metal viewport that covers the same window region as a Vulkan viewport,
/// including one written with a negative height.
[[nodiscard]] MetalViewportBox ToMetalViewport(const VulkanViewportBox& viewport);

/// Both APIs clip depth to [0, 1], and the engine's `Ortho` already maps z into
/// that range, so no depth remap is folded in either. Asserted rather than
/// assumed: this reports whether a clip-space z is inside the range both APIs
/// keep, and the projection test drives the scene's own near and far planes
/// through it.
[[nodiscard]] bool MetalDepthInClipRange(double clip_z, double clip_w);

} // namespace wallpaper::metal
