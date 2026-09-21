// What an internal render scale is allowed to change, and what it must leave
// alone.
//
// The scale exists to rasterize fewer pixels. It is not a window scale and not
// the wallpaper's fit/fill: the author's canvas, and therefore presentation
// layout and cursor mapping, must resolve to the same numbers at every scale.
// Targets whose size comes from decoded media are not the author's canvas and
// must keep their own resolution.

#include "Scene/Scene.h"
#include "Scene/SpecTexs.hpp"
#include "VulkanRender/PassCommon.hpp"

#include <gtest/gtest.h>

namespace wallpaper::vulkan
{
namespace
{

constexpr VkExtent2D kOutput { 3840, 2160 };

/// The shape a parsed authored scene has: a default target at the author's
/// canvas size, a screen-bound half-size effect target, and an unbound scratch
/// target the parser sized directly.
void InstallAuthoredTargets(Scene& scene, i32 width, i32 height) {
    scene.scene_extent[0] = width;
    scene.scene_extent[1] = height;
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width           = width,
        .height          = height,
        .authored_width  = width,
        .authored_height = height,
        .bind            = { .enable = true, .screen = true },
    };
    scene.renderTargets["_rt_bloom_mip1"] = SceneRenderTarget {
        .width  = width / 2,
        .height = height / 2,
        .bind   = { .enable = true, .screen = true, .scale = 0.5 },
    };
    scene.renderTargets["_rt_4FrameBuffer"] = SceneRenderTarget {
        .width  = width / 4,
        .height = height / 4,
    };
}

TEST(RenderScale, FullScaleLeavesEveryTargetAtTheAuthoredSize) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    EXPECT_EQ(extents.source.width, 1920u);
    EXPECT_EQ(extents.raster.width, 1920u);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 1920);
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 960);
}

TEST(RenderScale, HalfScaleHalvesTheRasterButNotTheAuthoredCanvas) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.render_scale = 0.5;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    // The canvas the composition is laid out against is untouched. This is what
    // keeps fit/fill and the cursor hit test where they were.
    EXPECT_EQ(extents.source.width, 1920u);
    EXPECT_EQ(extents.source.height, 1080u);

    EXPECT_EQ(extents.raster.width, 960u);
    EXPECT_EQ(extents.raster.height, 540u);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 960);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].height, 540);
    // A screen-bound target keeps its own relative scale on top of the raster.
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 480);
}

TEST(RenderScale, ThreeQuarterScaleRoundsRatherThanTruncates) {
    Scene scene;
    InstallAuthoredTargets(scene, 1366, 768);
    scene.render_scale = 0.75;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    EXPECT_EQ(extents.raster.width, 1025u); // 1024.5 rounds up
    EXPECT_EQ(extents.raster.height, 576u);
}

TEST(RenderScale, ReturningToFullScaleRestoresTheExactAuthoredSize) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);

    // Deriving each size from the latched authored size rather than from the
    // current one is what stops repeated changes drifting a rounding step at a
    // time until the image no longer matches the canvas.
    for (double scale : { 0.5, 0.75, 0.5, 1.0 }) {
        scene.render_scale = scale;
        ResolveScreenBoundRenderTargetSizes(scene, kOutput);
        ResolveRenderScaledSize(scene.renderTargets["_rt_4FrameBuffer"],
                                ResolveSceneRenderScale(scene));
    }

    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 1920);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].height, 1080);
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 960);
    EXPECT_EQ(scene.renderTargets["_rt_4FrameBuffer"].width, 480);
}

TEST(RenderScale, MediaSizedTargetsKeepTheirOwnResolution) {
    Scene scene;
    scene.scene_extent[0] = 1280;
    scene.scene_extent[1] = 720;
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width           = 1280,
        .height          = 720,
        .authored_width  = 1280,
        .authored_height = 720,
        .media_sized     = true,
        .bind            = { .enable = true, .screen = true },
    };
    scene.render_scale = 0.5;

    ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    // The frame was already decoded at this size. Shrinking the target it is
    // copied into would resample it twice for no saving upstream.
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 1280);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].height, 720);
}

TEST(RenderScale, PlainVideoScenesReportTheScaleAsNotApplied) {
    Scene scene;
    scene.single_video_source = true;
    scene.render_scale        = 0.5;

    EXPECT_DOUBLE_EQ(ResolveSceneRenderScale(scene), 1.0);
}

TEST(RenderScale, ScalesBelowTheFloorAreClampedRatherThanHonoured) {
    Scene scene;
    scene.render_scale = 0.01;
    EXPECT_DOUBLE_EQ(ResolveSceneRenderScale(scene), kMinRenderScale);

    scene.render_scale = 4.0;
    EXPECT_DOUBLE_EQ(ResolveSceneRenderScale(scene), 1.0);

    scene.render_scale = std::nan("");
    EXPECT_DOUBLE_EQ(ResolveSceneRenderScale(scene), 1.0);
}

TEST(RenderScale, ASceneWithNoLatchedCanvasStillResolvesAgainstItsOwnSize) {
    // Scenes built before the canvas is latched fall back to the default target
    // and then to the author's ortho, never to the output extent, so a large
    // display cannot silently become the composition size.
    Scene scene;
    scene.ortho[0] = 1600;
    scene.ortho[1] = 900;
    scene.render_scale = 0.5;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    EXPECT_EQ(extents.source.width, 1600u);
    EXPECT_EQ(extents.raster.width, 800u);
}

TEST(RenderScale, AScreenBoundTargetsResolutionReachesTheMaterialThatSamplesIt) {
    // A target that follows the screen is registered with placeholder
    // dimensions, because the output size is not known while the scene is
    // parsed. `g_TextureNResolution` is folded into the material at that same
    // moment, so without a refresh a shader is handed 2x2 -- and a separable
    // blur, which steps by `1 / g_Texture0Resolution.zw`, then puts every one
    // of its taps outside the texture and returns a flat wash instead of a
    // blur.
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.renderTargets["_rt_QuarterCompoBuffer1"] = SceneRenderTarget {
        .width  = 2,
        .height = 2,
        .bind   = { .enable = true, .screen = true, .scale = 0.25 },
    };

    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial material;
    material.textures = { "_rt_QuarterCompoBuffer1" };
    material.customShader.constValues["g_Texture0Resolution"] =
        std::array<float, 4> { 2.0F, 2.0F, 2.0F, 2.0F };
    mesh->AddMaterial(std::move(material));
    node->AddMesh(mesh);
    scene.sceneGraph = std::make_shared<SceneNode>();
    scene.sceneGraph->AppendChild(node);

    ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    const auto* slot = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(slot, nullptr);
    const auto found = slot->customShader.constValues.find("g_Texture0Resolution");
    ASSERT_NE(found, slot->customShader.constValues.end());
    ASSERT_EQ(found->second.size(), 4u);
    // All four: a blur divides by `.zw`, which a test that only checked the
    // first two would have let stay at the placeholder.
    EXPECT_FLOAT_EQ(found->second[0], 480.0F);
    EXPECT_FLOAT_EQ(found->second[1], 270.0F);
    EXPECT_FLOAT_EQ(found->second[2], 480.0F);
    EXPECT_FLOAT_EQ(found->second[3], 270.0F);
}

} // namespace
} // namespace wallpaper::vulkan
