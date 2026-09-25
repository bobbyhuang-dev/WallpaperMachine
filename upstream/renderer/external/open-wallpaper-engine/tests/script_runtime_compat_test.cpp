#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"
#include "Scene/include/Scene/SceneImageEffectLayer.h"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "WPShaderValueUpdater.hpp"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scripting/ScriptEngine.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <iterator>
#include <memory>
#include <thread>
#include <unordered_map>

namespace wallpaper::audio {
void SetAudioSpectrumSnapshotForTesting(const AudioSpectrumSnapshot&);
}

namespace wallpaper
{
namespace
{

DynamicValue EvaluateScalar(ScriptEngine& engine, std::string script,
                            const ScriptHostContext& host = {}) {
    DynamicValue initial(0.0f);
    auto result = engine.Evaluate(script, {}, initial, host);
    if (result == nullptr) return DynamicValue();
    return *result;
}

std::unique_ptr<SceneRuntimeContext> MakeRuntimeWithScene(Scene& scene) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    if (runtime != nullptr) {
        runtime->AttachScene(&scene);
    }
    return runtime;
}

TEST(ScriptRuntimeCompat, CallbackOnlyPropertyScriptsInitializeAndToggleLayersOnHit) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto button = std::make_shared<SceneNode>();
    auto target = std::make_shared<SceneNode>();
    button->SetTranslate(Eigen::Vector3f(300, 200, 0));
    runtime->RegisterNode("button", button.get());
    runtime->RegisterNodeSize("button", Eigen::Vector2f(80, 60));
    runtime->RegisterNode("target", target.get());
    runtime->RegisterNodeVisibility("button", button.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
let visible;
export function init(value) { visible = true; return value; }
export function cursorClick(event) {
    visible = !visible;
    thisScene.getLayer('target').visible = visible;
}
)JS"}}, "button"));
    runtime->Tick(0.01);
    runtime->SetCursorEnter(true);
    runtime->SetCursorWorldPosition(Eigen::Vector3f(600, 200, 0));
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_TRUE(target->Visible());
    runtime->SetCursorWorldPosition(Eigen::Vector3f(300, 200, 0));
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(0.01);
    EXPECT_FALSE(target->Visible());
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(0.01);
    EXPECT_TRUE(target->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, CallbackOnlySelfWritesSurviveSubsequentTicksAndUserChanges) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"enabled", RuntimeScalarValue::Bool(true)}},
    });
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("button", node.get());
    runtime->RegisterNodeVisibility("button", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"user", "enabled"}, {"script", R"JS(
export function cursorClick() { thisLayer.visible = !thisLayer.visible; }
)JS"}}, "button"));
    runtime->Tick(0.01);
    runtime->DispatchCursorClick();
    EXPECT_FALSE(node->Visible());
    for (int i = 0; i < 3; ++i) runtime->Tick(0.01);
    EXPECT_FALSE(node->Visible());
    runtime->ApplyProjectPropertyOverride({{"enabled", RuntimeScalarValue::Bool(true)}});
    runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(Eigen::Vector3f(300, 200, 0));
    runtime->RegisterNodeSize("hover", Eigen::Vector2f(80, 60));
    runtime->RegisterNodeScale("hover", node.get(), ResolveVec3Setting(*runtime, {
        {"value", "1 2 1"}, {"script", R"JS(
import * as WEMath from 'WEMath';
let original, enlarged, hovered = false;
export function init(value) {
    original = value;
    enlarged = value.multiply(1.2);
}
export function cursorEnter() { hovered = true; }
export function cursorLeave() { hovered = false; }
export function update(value) {
    const target = hovered ? enlarged : original;
    return new Vec3(WEMath.mix(value.x, target.x, 0.1),
                    WEMath.mix(value.y, target.y, 0.1),
                    WEMath.mix(value.z, target.z, 0.1));
}
)JS"}}, "hover"));
    runtime->Tick(1.0 / 60.0);
    runtime->SetCursorEnter(true);
    runtime->SetCursorWorldPosition(Eigen::Vector3f(300, 200, 0));
    runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.02f, 1.0e-6f);
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.038f, 1.0e-6f);
    EXPECT_NEAR(node->Scale().y(), 2.076f, 1.0e-6f);

    runtime->SetCursorWorldPosition(Eigen::Vector3f(600, 200, 0));
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.0342f, 1.0e-6f);
    runtime->SetCursorWorldPosition(Eigen::Vector3f(300, 200, 0));
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.05078f, 1.0e-6f);

    for (int frame = 0; frame < 120; ++frame) {
        runtime->DispatchCursorFrameEvents(true);
        runtime->Tick(1.0 / 60.0);
    }
    EXPECT_NEAR(node->Scale().x(), 1.2f, 1.0e-5f);
    EXPECT_NEAR(node->Scale().y(), 2.4f, 1.0e-5f);
    runtime->SetCursorEnter(false);
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.18f, 1.0e-5f);
    for (int frame = 0; frame < 120; ++frame) runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.0f, 1.0e-5f);
    EXPECT_NEAR(node->Scale().y(), 2.0f, 1.0e-5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// Real wallpapers receive the cursor as a window fraction, not scene
// coordinates. A 7680x2160 scene on the recorded 4112x2658 output is cropped by
// the FILL presentation, so hover hit boxes only line up with the drawn layer
// when the window fraction is mapped back through that presentation rectangle.
TEST(ScriptRuntimeCompat, HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper) {
    Scene scene;
    auto  runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
         .canvas_width  = 7680,
         .canvas_height = 2160,
    });
    ASSERT_NE(runtime, nullptr);
    runtime->AttachScene(&scene);

    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(Eigen::Vector3f(3850.0f, 865.0f, 0.0f));
    runtime->RegisterNodeSize("hover", Eigen::Vector2f(275.0f, 134.0f));
    runtime->RegisterNodeScale("hover",
                               node.get(),
                               ResolveVec3Setting(*runtime,
                                                  { { "value", "1 1 1" }, { "script", R"JS(
import * as WEMath from 'WEMath';
let original, enlarged, hovered = false;
export function init(value) {
    original = value;
    enlarged = value.multiply(1.2);
}
export function cursorEnter() { hovered = true; }
export function cursorLeave() { hovered = false; }
export function update(value) {
    const target = hovered ? enlarged : original;
    return new Vec3(WEMath.mix(value.x, target.x, 0.2),
                    WEMath.mix(value.y, target.y, 0.2),
                    WEMath.mix(value.z, target.z, 0.2));
}
)JS" } },
                                                  "hover"));

    // Recorded runtime configuration: output_px 4112x2658, display_scale 2.0,
    // scaling mode fill, factor 1.0.
    const auto layout =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 2056, 1329, 2.0, 1.0);
    const auto mapping = ComputeWallpaperCursorMapping(layout, 3840.0, 1080.0, 7680.0, 2160.0);
    ASSERT_TRUE(mapping.valid);
    runtime->SetCursorViewport(CursorViewport {
        .origin = Eigen::Vector2f(static_cast<float>(mapping.origin_x),
                                  static_cast<float>(mapping.origin_y)),
        .size =
            Eigen::Vector2f(static_cast<float>(mapping.size_x), static_cast<float>(mapping.size_y)),
        .content_origin = Eigen::Vector2f(static_cast<float>(mapping.content_origin_x),
                                          static_cast<float>(mapping.content_origin_y)),
        .content_size   = Eigen::Vector2f(static_cast<float>(mapping.content_size_x),
                                        static_cast<float>(mapping.content_size_y)),
    });

    // Window fraction where the presented wallpaper draws a scene point.
    const auto screen_x = [&](double world) {
        const double fraction = (world - 3840.0) / 7680.0 + 0.5;
        return static_cast<float>((fraction * layout.viewport_px.width + layout.viewport_px.x) /
                                  4112.0);
    };
    const auto screen_y = [&](double world) {
        const double fraction = 0.5 - (world - 1080.0) / 2160.0;
        return static_cast<float>((fraction * layout.viewport_px.height + layout.viewport_px.y) /
                                  2658.0);
    };

    bool       inside = false;
    const auto settle = [&](double world_x, double world_y, int frames) {
        runtime->SetCursorInput(screen_x(world_x), screen_y(world_y));
        for (int frame = 0; frame < frames; ++frame) {
            inside = runtime->DispatchCursorFrameEvents(inside);
            runtime->Tick(1.0 / 60.0);
        }
        return node->Scale().x();
    };

    runtime->SetCursorEnter(true);
    // 120 scene units right of centre is inside the 275-unit layer, but outside
    // the strip a canvas-relative mapping would cover.
    EXPECT_NEAR(settle(3850.0 + 120.0, 865.0, 120), 1.2f, 1.0e-4f);
    EXPECT_NEAR(settle(3850.0 + 400.0, 865.0, 120), 1.0f, 1.0e-4f);
    EXPECT_NEAR(settle(3850.0 - 120.0, 865.0, 120), 1.2f, 1.0e-4f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, PropertyFeedbackResumesFromExplicitUserValueChanges) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"progress", RuntimeScalarValue::Float(2.0f)}},
    });
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "u_Progress", ResolveVec3Setting(*runtime, {
        {"value", "0 0 0"}, {"user", "progress"}, {"script", R"JS(
export function update(value) { value.x += engine.frametime; return value; }
)JS"}}));
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 2.25f);
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 2.5f);

    runtime->ApplyProjectPropertyOverride({{"progress", RuntimeScalarValue::Float(5.0f)}});
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 5.25f);
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 5.5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A video-texture control script hides the layer in init() and re-shows it
// from update() without returning a value. The native write must survive the
// next reevaluation instead of being overwritten by the authored `false`.
TEST(ScriptRuntimeCompat, UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetVisible(false);
    runtime->RegisterNode("clip", node.get());
    runtime->RegisterNodeVisibility("clip", node.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
export function init() { thisLayer.visible = false; }
export function update(value) { thisLayer.visible = true; }
)JS"}}, "clip"));
    for (int i = 0; i < 3; ++i) runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// An icon script asks its dock whether it is showing before it does anything
// else, through `getParent()`. Without that call the whole update threw once a
// frame, so the icons never scaled, never faded and never opened anything.
TEST(ScriptRuntimeCompat, LayerGetParentReachesTheParentLayer) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto dock    = std::make_shared<SceneNode>();
    auto icon    = std::make_shared<SceneNode>();
    dock->SetName("App Launcher Dock");
    icon->SetName("Launcher 1");
    dock->AppendChild(icon);
    dock->SetVisible(true);
    runtime->RegisterNode("App Launcher Dock", dock.get());
    runtime->RegisterNodeVisibility("Launcher 1", icon.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
let parent;
export function init() { parent = thisLayer.getParent(); }
export function update() { return parent !== null && parent.visible; }
)JS"}}, "Launcher 1"));

    runtime->Tick(0.01);
    EXPECT_TRUE(icon->Visible());
    dock->SetVisible(false);
    runtime->Tick(0.01);
    EXPECT_FALSE(icon->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A layer at the scene root has no parent layer, and saying so is the whole
// answer: an object standing in for the graph's unnamed root would report a
// visibility that belongs to nothing the author wrote.
TEST(ScriptRuntimeCompat, LayerGetParentIsNullAtTheSceneRoot) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetName("backdrop");
    runtime->RegisterNode("backdrop", node.get());
    runtime->RegisterNodeVisibility("backdrop", node.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
export function update() { return thisLayer.getParent() === null; }
)JS"}}, "backdrop"));

    runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// `layer.alpha = x` is how one script fades another layer. It has to reach the
// material the flat shader reads, not stop at a number the script layer keeps
// to itself.
TEST(ScriptRuntimeCompat, LayerAlphaWritesReachTheMaterial) {
    auto runtime  = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node     = std::make_shared<SceneNode>();
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterNode("icon", node.get());
    runtime->RegisterNodeAlpha("icon", material, 1.0f);
    runtime->RegisterNodeVisibility("icon", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
export function update(value) { thisLayer.alpha = 0.25; return value; }
)JS"}}, "icon"));

    runtime->Tick(0.01);
    ASSERT_TRUE(material->customShader.constValues.contains("g_UserAlpha"));
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_UserAlpha")[0], 0.25f);
    EXPECT_FLOAT_EQ(*runtime->NodeAlpha("icon"), 0.25f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A layer with no material of its own — a sound layer, an empty group — still
// remembers what a script wrote to it rather than reporting a made-up 1.
TEST(ScriptRuntimeCompat, LayerAlphaWithoutAMaterialKeepsWhatWasWritten) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("group", node.get());
    runtime->RegisterNodeVisibility("group", node.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
export function update() {
  thisLayer.alpha = 0.5;
  return thisLayer.alpha === 0.5;
}
)JS"}}, "group"));

    runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_FALSE(runtime->NodeAlpha("group").has_value());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

namespace
{

std::shared_ptr<WPPuppet> MakeSingleShotPuppet() {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.emplace_back();
    WPPuppet::Animation animation;
    animation.id     = 7;
    animation.fps    = 10.0;
    animation.length = 5;
    animation.mode   = WPPuppet::PlayMode::Single;
    animation.name   = "gesture";
    WPPuppet::Animation::BoneTrack track;
    for (int frame = 0; frame <= animation.length; ++frame) {
        track.frames.push_back(WPPuppet::BoneFrame {
            .position = Eigen::Vector3f(static_cast<float>(frame), 0.0f, 0.0f),
            .angle    = Eigen::Vector3f::Zero(),
            .scale    = Eigen::Vector3f::Ones(),
        });
    }
    animation.bone_tracks.push_back(std::move(track));
    puppet->anims.push_back(std::move(animation));
    puppet->prepared();
    return puppet;
}

} // namespace

// getAnimationLayer(...).play() from a click handler restarts a single-shot
// puppet layer that already finished, and every copy of the layer follows.
TEST(ScriptRuntimeCompat, PuppetAnimationLayerPlayRestartsFinishedSingleShotForAllCopies) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());

    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id   = 7;
    authored[0].name = "siche";
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    WPPuppetLayer render_copy = layer;
    runtime->RegisterPuppetLayer("character", layer);

    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
export function cursorClick(event) { thisLayer.getAnimationLayer("siche").play(); }
)JS"}}, "character"));
    runtime->Tick(0.01);

    render_copy.genFrame(0.0);
    render_copy.genFrame(2.0);
    EXPECT_FALSE(render_copy.isPlaying(0));
    EXPECT_DOUBLE_EQ(render_copy.frame(0), 5.0);
    EXPECT_FLOAT_EQ(render_copy.genFrame(2.0)[0].translation().x(), 5.0f);

    runtime->DispatchCursorClick();
    EXPECT_TRUE(render_copy.isPlaying(0));
    EXPECT_DOUBLE_EQ(render_copy.frame(0), 0.0);
    EXPECT_FLOAT_EQ(render_copy.genFrame(2.0)[0].translation().x(), 0.0f);
    EXPECT_FLOAT_EQ(layer.genFrame(2.0)[0].translation().x(), 0.0f);
    render_copy.genFrame(2.1);
    EXPECT_NEAR(render_copy.frame(0), 1.0, 1e-9);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// Puppet animation layers bound to a user property toggle their visibility on
// the shared state when the property changes.
TEST(ScriptRuntimeCompat, PuppetAnimationLayerVisibilityFollowsUserProperty) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"outfit", RuntimeScalarValue::String("1")}},
    });
    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id = 7;
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    WPPuppetLayer copy = layer;
    runtime->RegisterDynamicValueListener(
        ResolveBoolSetting(*runtime, {{"value", true}, {"user", {{"name", "outfit"}, {"condition", "0"}}}}),
        [layer](const DynamicValue& value) mutable { layer.setVisible(0, value.getBool()); });
    EXPECT_FALSE(copy.visible(0));
    ASSERT_TRUE(layer.setFrame(0, 2.5));
    EXPECT_FLOAT_EQ(copy.genFrame(0.0)[0].translation().x(), 0.0f);
    runtime->ApplyProjectPropertyOverride({{"outfit", RuntimeScalarValue::String("0")}});
    EXPECT_TRUE(copy.visible(0));
    EXPECT_FLOAT_EQ(copy.genFrame(0.0)[0].translation().x(), 2.5f);
    runtime->ApplyProjectPropertyOverride({{"outfit", RuntimeScalarValue::String("1")}});
    EXPECT_FLOAT_EQ(copy.genFrame(0.0)[0].translation().x(), 0.0f);
}

// Two interlocking triangle buttons share a bounding box; the cursor must only
// hit the one whose texels are opaque under it.
TEST(ScriptRuntimeCompat, CursorHitTestRespectsCoverageMask) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetTranslate(Eigen::Vector3f(100.0f, 100.0f, 0.0f));
    runtime->RegisterNode("button", node.get());
    runtime->RegisterNodeSize("button", Eigen::Vector2f(40.0f, 40.0f));
    // Left half opaque, right half transparent.
    NodeHitMask mask;
    mask.width  = 4;
    mask.height = 2;
    mask.alpha  = { 255, 255, 0, 0, 255, 255, 0, 0 };
    runtime->RegisterNodeHitMask("button", std::move(mask));
    runtime->RegisterNodeVisibility("button", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
export function cursorClick(event) { thisLayer.visible = false; }
)JS"}}, "button"));
    runtime->Tick(0.01);
    runtime->SetCursorEnter(true);

    runtime->SetCursorWorldPosition(Eigen::Vector3f(110.0f, 100.0f, 0.0f));
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_TRUE(node->Visible());

    runtime->SetCursorWorldPosition(Eigen::Vector3f(90.0f, 100.0f, 0.0f));
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, TextureAnimationSelectsAMPMFrameWithoutScriptErrors) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("ampm", node.get());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(), R"JS(
export function update(value) {
    thisLayer.getTextureAnimation().setFrame(1);
    return thisLayer.getTextureAnimation().getFrame();
}
)JS", "ampm", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_TRUE(program->Valid());
    for (int i = 0; i < 120; ++i) {
        const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
        ASSERT_NE(result, nullptr);
        EXPECT_FLOAT_EQ(result->getFloat(), 1.0f);
    }
    EXPECT_EQ(node->TextureFrame(), 1.0);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);

    SpriteAnimation animation;
    animation.AppendFrame(SpriteFrame { .imageId = 0, .frametime = 0.1f });
    animation.AppendFrame(SpriteFrame { .imageId = 1, .frametime = 0.1f });
    EXPECT_EQ(animation.SetFrame(1).imageId, 1);
    EXPECT_EQ(animation.SetFrame(-1).imageId, 0);
    EXPECT_EQ(animation.SetFrame(100).imageId, 1);
}

TEST(ScriptRuntimeCompat, ComposeBackgroundUsesScreenCameraAndParentTransform) {
    Scene scene;
    auto screen = std::make_shared<SceneCamera>(640, 360, -1, 1);
    auto effect = std::make_shared<SceneCamera>(64, 32, -1, 1);
    scene.activeCamera = screen.get();
    scene.cameras["effect-test"] = effect;
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate(Eigen::Vector3f(200, 100, 0));
    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(Eigen::Vector3f(10, 20, 0));
    node->SetScale(Eigen::Vector3f(-0.3f, 0.2f, 1));
    node->SetCamera("effect-test");
    node->SetRenderTransformOverride(Eigen::Matrix4d::Identity());
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial material;
    material.name = "composelayer";
    mesh->AddMaterial(std::move(material));
    node->AddMesh(mesh);
    parent->AppendChild(node);
    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), [](std::string_view n) {
        return n == "g_ModelViewProjectionMatrix";
    });
    sprite_map_t sprites;
    ShaderValue actual;
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view n, const ShaderValue& v) {
        if (n == "g_ModelViewProjectionMatrix") actual = v;
    });
    const auto expected = ShaderValue::fromMatrix(screen->GetViewProjectionMatrix() * node->ModelTrans());
    ASSERT_EQ(actual.size(), expected.size());
    for (std::size_t i = 0; i < actual.size(); ++i) EXPECT_NEAR(actual[i], expected[i], 1e-5);

    parent->SetTranslate(Eigen::Vector3f(260, 80, 0));
    auto screen_node = std::make_shared<SceneNode>();
    screen_node->SetTranslate(Eigen::Vector3f(30, 0, 0));
    screen->AttatchNode(screen_node);
    actual = ShaderValue {};
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view n, const ShaderValue& v) {
        if (n == "g_ModelViewProjectionMatrix") actual = v;
    });
    const auto second_expected =
        ShaderValue::fromMatrix(screen->GetViewProjectionMatrix() * node->ModelTrans());
    ASSERT_EQ(actual.size(), second_expected.size());
    for (std::size_t i = 0; i < actual.size(); ++i) {
        EXPECT_NEAR(actual[i], second_expected[i], 1e-5);
    }

    // Drawn into its own composite for another layer to sample, the compose
    // layer still samples the screen behind where it sits: that is what its
    // card holds.
    auto composite = std::make_shared<SceneCamera>(64, 32, -1, 1);
    composite->SetLayerLocal(true);
    scene.cameras["composite-test"] = composite;
    node->SetCamera("composite-test");
    actual = ShaderValue {};
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view n, const ShaderValue& v) {
        if (n == "g_ModelViewProjectionMatrix") actual = v;
    });
    const auto composite_expected =
        ShaderValue::fromMatrix(screen->GetViewProjectionMatrix() * node->ModelTrans());
    ASSERT_EQ(actual.size(), composite_expected.size());
    for (std::size_t i = 0; i < actual.size(); ++i) {
        EXPECT_NEAR(actual[i], composite_expected[i], 1e-5);
    }
}

TEST(ScriptRuntimeCompat, ThisLayerAndThisSceneResolveCurrentLayer) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(Eigen::Vector3f(12.0f, 34.0f, 0.0f));
    runtime->RegisterNode("probe", node.get());
    runtime->RegisterNodeSize("probe", Eigen::Vector2f(320.0f, 240.0f));

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
export function update(value) {
  var same = thisLayer === thisScene.getLayer('probe') ? 1 : 0;
  return same + thisLayer.origin.x * 10 + thisLayer.size.y * 1000;
}
)JS",
        "probe",
        {},
        DynamicValue(0.0f),
        runtime->hostContext());
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 1.0f + 120.0f + 240000.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, SceneNodeIdentityIsStableAcrossLookups) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("probe", node.get());

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
var cached = thisScene.getObject('probe');
export function update(value) {
  return (cached === thisScene.getLayer('probe') &&
          cached === thisLayer &&
          thisScene.getSprite('probe') === thisLayer) ? 7 : -1;
}
)JS",
        "probe",
        {},
        DynamicValue(0.0f),
        runtime->hostContext());
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 7.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ThisLayerTextSetterMutatesRuntimeTextState) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption", TextLayerState {
                                              .text       = "before",
                                              .font_key   = "Arial",
                                              .point_size = 12.0f,
                                          });

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
export function update(value) {
  thisLayer.text = "after";
  var indirect = thisScene.getLayer('caption');
  indirect.text = indirect.text + " indirect";
  return thisLayer.text === "after indirect" ? 1 : -1;
}
)JS",
        "caption",
        {},
        DynamicValue(0.0f),
        runtime->hostContext());
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 1.0f);
    EXPECT_EQ(runtime->NodeText("caption"), "after indirect");
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, SetTimeoutGlobalAndEngineAliasesFireOnceAndCancel) {
    ScriptEngine      engine;
    ScriptHostContext host {};
    host.runtime_seconds = 0.0;

    auto program = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
var fired = 0;
var canceled = 0;
setTimeout(function() { fired += 1; }, 100);
var handle = engine.setTimeout(function() { canceled += 1; }, 100);
clearTimeout(handle);
export function update(value) { return fired * 10 + canceled; }
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(program, nullptr);

    host.runtime_seconds = 0.05;
    auto before = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(before, nullptr);
    EXPECT_FLOAT_EQ(before->getFloat(), 0.0f);

    host.runtime_seconds = 0.15;
    auto after = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(after, nullptr);
    EXPECT_FLOAT_EQ(after->getFloat(), 10.0f);

    host.runtime_seconds = 0.30;
    auto later = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(later, nullptr);
    EXPECT_FLOAT_EQ(later->getFloat(), 10.0f);
}

TEST(ScriptRuntimeCompat, UpstreamConsoleInputAndEngineCompatibilityStubsAreCallable) {
    ScriptEngine      engine;
    ScriptHostContext host {};
    host.canvas_size                = Eigen::Vector2f(1920.0f, 1080.0f);
    host.cursor_normalized_position = Eigen::Vector2f(0.25f, 0.75f);
    host.cursor_world_position      = Eigen::Vector3f(480.0f, 270.0f, 0.0f);
    host.cursor_in_window           = true;
    host.mouse_buttons_down         = 3u;
    host.mouse_buttons_pressed      = 1u;
    host.mouse_buttons_released     = 2u;

    auto program = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
console.debug('debug');
console.trace('trace');
console.dir({ value: 1 });
console.assert(false, 'assertion text is ignored by the no-op shim');
console.group('group');
console.groupCollapsed('collapsed');
console.groupEnd();

export function update(value) {
  var ok = 0;
  if (typeof engine.isRunningInEditor === 'function' && engine.isRunningInEditor() === false) ok += 1;
  if (typeof engine.isScreensaver === 'function' && engine.isScreensaver() === false) ok += 1;
  if (input.cursorPosition.x === 0.25 && input.cursorPosition.y === 0.75) ok += 1;
  if (input.cursorWorldPosition.x === 480 && input.cursorWorldPosition.y === 270) ok += 1;
  if (input.cursorLocalPosition && input.cursorLocalPosition.x === 480) ok += 1;
  if (input.cursorScreenPosition && input.cursorScreenPosition.y === 270) ok += 1;
  if (input.mouseButtonsDown === 3 && input.mouseButtonsPressed === 1 && input.mouseButtonsReleased === 2) ok += 1;
  if (input.inWindow === true) ok += 1;
  return ok;
}
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 8.0f);
}

TEST(ScriptRuntimeCompat, ThrowingOneShotTimeoutDoesNotFireAgainOrBlockLaterTimers) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    ScriptHostContext host {};
    host.runtime_seconds = 0.0;

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
var later = 0;
setTimeout(function() { throw new Error('timeout failed once'); }, 100);
setTimeout(function() { later += 1; }, 150);
export function update(value) { return later; }
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(program, nullptr);

    host.runtime_seconds = 0.12;
    auto first_due = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(first_due, nullptr);
    EXPECT_FLOAT_EQ(first_due->getFloat(), 0.0f);
    ASSERT_EQ(runtime->scriptErrorCount(), 1u);

    host.runtime_seconds = 0.20;
    auto later_due = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(later_due, nullptr);
    EXPECT_FLOAT_EQ(later_due->getFloat(), 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 1u);
}

TEST(ScriptRuntimeCompat, ThrowingIntervalDoesNotBlockLaterTimersOrKeepStaleDeadline) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    ScriptHostContext host {};
    host.runtime_seconds = 0.0;

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
var later = 0;
var throwCount = 0;
setInterval(function() {
  throwCount += 1;
  if (throwCount <= 1) throw new Error('interval failed once');
}, 100);
setTimeout(function() { later += 1; }, 150);
export function update(value) { return later * 100 + throwCount; }
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(program, nullptr);

    host.runtime_seconds = 0.12;
    auto first_due = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(first_due, nullptr);
    EXPECT_FLOAT_EQ(first_due->getFloat(), 1.0f);
    ASSERT_EQ(runtime->scriptErrorCount(), 1u);

    host.runtime_seconds = 0.16;
    auto later_due = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(later_due, nullptr);
    EXPECT_FLOAT_EQ(later_due->getFloat(), 101.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 1u);

    host.runtime_seconds = 0.18;
    auto before_next_interval = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(before_next_interval, nullptr);
    EXPECT_FLOAT_EQ(before_next_interval->getFloat(), 101.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 1u);
}

TEST(ScriptRuntimeCompat, LocalStorageRoundTripsObjectsInSharedRuntime) {
    ScriptEngine      engine;
    ScriptHostContext host {};

    auto writer = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
localStorage.set('number', 42);
localStorage.set('object', { nested: { value: 8 } });
export function update(value) { return 0; }
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(writer, nullptr);
    ASSERT_NE(writer->Evaluate(host, DynamicValue(0.0f)), nullptr);

    auto reader = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
export function update(value) {
  var object = localStorage.get('object');
  return localStorage.get('number') + object.nested.value;
}
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(reader, nullptr);
    const auto result = reader->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 50.0f);
}

TEST(ScriptRuntimeCompat, WEMathProvidesWallpaperEngineAliases) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
import * as M from 'WEMath';
export function update(value) {
  return Math.round(M.smoothStep(0, 1, 0.5) * 100) +
         Math.round(M.smoothstep(0, 1, 0.5) * 100) * 100 +
         Math.round(M.deg2rad(180) * 1000) * 10000 +
         Math.round(M.rad2deg(Math.PI)) * 1000000000;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 50.0f + 50.0f * 100.0f + 3142.0f * 10000.0f +
                                           180.0f * 1000000000.0f);
}

TEST(ScriptRuntimeCompat, WEColorHsv2RgbSupportsNamespaceImport) {
    ScriptEngine engine;
    const auto   result = EvaluateScalar(
        engine,
        R"JS(
import * as WEColor from 'WEColor';
export function update(value) {
  var red = WEColor.hsv2rgb({ x: 0.0, y: 1.0, z: 1.0 });
  var green = WEColor.hsv2rgb({ x: 1.0 / 3.0, y: 1.0, z: 1.0 });
  var blue = WEColor.hsv2rgb({ x: 2.0 / 3.0, y: 1.0, z: 1.0 });
  return red.x + green.y * 10 + blue.z * 100;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 111.0f);
}

// Scripts pasted from a rich-text editor carry U+00A0 where a space was typed.
// JavaScript reads that as whitespace, so `export` has to be stripped after it
// as after a space: left in place, the program does not compile and the layer
// keeps its authored value for good. One export starts its line and the other
// follows a statement: those are the two places the rewrite looks. Only the
// keyword goes: a comment that ends with the word keeps its line break, or the
// next line would become part of the comment.
TEST(ScriptRuntimeCompat, ExportFollowedByUnicodeWhitespaceStillCompiles) {
    ScriptEngine engine;
    const auto   result = EvaluateScalar(engine,
                                       "// values we export\n"
                                       "var scale = 2;\n"
                                       "export\u00a0var\u00a0factor = 3;\n"
                                       "var unused = 0; export\u00a0function\u00a0update (value) {\n"
                                       "  return factor * 7 * scale;\n"
                                       "}\n");
    EXPECT_FLOAT_EQ(result.getFloat(), 42.0f);
}

// A property script that also listens for scene events is run as a property
// only when it declares `update`. The declaration has to be found whatever the
// author put between the tokens: missed, the script runs as a scene script and
// the property never moves.
TEST(ScriptRuntimeCompat, AnUpdateSeparatedByUnicodeWhitespaceStillDrivesItsProperty) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto value   = ResolveFloatSetting(
        *runtime,
        { { "value", 1.0f },
          { "script", "engine.on('resizeScreen', function() {});\n"
                      "export\u00a0function\u00a0update(value) {\n"
                      "  return 5;\n"
                      "}\n" } });
    ASSERT_NE(value, nullptr);
    runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(value->getFloat(), 5.0f);
}

// The rarer separators are matched here, where no JavaScript is compiled.
TEST(ScriptModuleSyntax, AnExportedFunctionIsFoundAcrossEverySeparatorAndNowhereElse) {
    EXPECT_TRUE(ExportsFunction("export function update(value) {}", "update"));
    // U+FEFF is whitespace to JavaScript but not Unicode White_Space.
    EXPECT_TRUE(ExportsFunction("export\ufefffunction\u3000update (value) {}", "update"));
    EXPECT_TRUE(ExportsFunction("export\n  function\tupdate\u00a0(value) {}", "update"));
    // Wherever a statement can start.
    EXPECT_TRUE(ExportsFunction("var a = 1;export function update(value) {}", "update"));
    EXPECT_TRUE(ExportsFunction("function a() {}export function update(value) {}", "update"));
    EXPECT_TRUE(ExportsFunction("var a = 1;\u3000export function update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("reexport function update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("module.export function update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("export function updateAll(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("export functionupdate(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("exportfunction update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("function update(value) {}", "update"));
}

TEST(ScriptRuntimeCompat, Vec3SupportsCopyAndScalarSplat) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
export function update(value) {
  var splat = new Vec3(3);
  var copy = splat.copy();
  copy.x = 9;
  return splat.x + splat.y * 10 + splat.z * 100 + copy.x * 1000;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 9333.0f);
}

TEST(ScriptRuntimeCompat, HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    ScriptHostContext host {};
    host.canvas_size                = Eigen::Vector2f(100.0f, 50.0f);
    host.cursor_normalized_position = Eigen::Vector2f(0.1f, 0.2f);
    host.cursor_world_position      = Eigen::Vector3f(10.0f, 20.0f, 0.0f);
    DynamicValue tint(Eigen::Vector4f(0.5f, 0.25f, 0.125f, 0.75f));

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
var savedVec2 = Vec2;
var savedVec3 = Vec3;
var savedVec4 = Vec4;
Vec2 = function(x, y) { return new Vec2(x, y); };
Vec3 = function(x, y, z) { return new Vec3(x, y, z); };
Vec4 = function(x, y, z, w) { return new Vec4(x, y, z, w); };

export function update(value) {
  var constructed = new savedVec3(1, 2, 3);
  return input.cursorPosition.x + input.cursorWorldPosition.y + engine.canvasSize.x +
         scriptProperties.tint.w + constructed.z;
}
)JS",
        "",
        { { "tint", &tint } },
        DynamicValue(0.0f),
        host);
    ASSERT_NE(program, nullptr);

    host.canvas_size                = Eigen::Vector2f(200.0f, 100.0f);
    host.cursor_normalized_position = Eigen::Vector2f(0.25f, 0.75f);
    host.cursor_world_position      = Eigen::Vector3f(25.0f, 75.0f, 0.0f);
    const auto result = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 279.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, CreateLayerClonesTemplateAndFansOutMaterialBindings) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);

    auto source_node = std::make_shared<SceneNode>(
        Eigen::Vector3f(100.0f, 50.0f, 0.0f),
        Eigen::Vector3f::Ones(),
        Eigen::Vector3f::Zero(),
        "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene.sceneGraph->AppendChild(source_node);

    DynamicValue tint(Eigen::Vector3f(0.25f, 0.5f, 0.75f));
    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/123456/bar.json",
                                   source_node,
                                   Eigen::Vector2f(20.0f, 10.0f));
    runtime->RegisterMaterialConstant(source_mesh->MaterialSlotPtr(), "g_Tint", std::make_unique<DynamicValue>(tint));

    runtime->RegisterSceneScript(
        R"JS(
function update() {
  var a = thisScene.createLayer('models/bar.json');
  var b = thisScene.createLayer('models/bar.json');
  a.origin = new Vec3(10, 20, 0);
  b.origin = new Vec3(30, 40, 0);
}
)JS",
        "source");

    runtime->Tick(1.0 / 60.0);

    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 3u);
    EXPECT_TRUE(runtime->ConsumeSceneGraphMutationFlag());
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        if (child.get() == source_node.get()) continue;
        ASSERT_NE(child->Mesh(), nullptr);
        ASSERT_NE(child->Mesh()->Material(), nullptr);
        const auto constant = child->Mesh()->Material()->customShader.constValues.find("g_Tint");
        ASSERT_NE(constant, child->Mesh()->Material()->customShader.constValues.end());
        ASSERT_EQ(constant->second.size(), 3u);
        EXPECT_FLOAT_EQ(constant->second[0], 0.25f);
        EXPECT_FLOAT_EQ(constant->second[1], 0.5f);
        EXPECT_FLOAT_EQ(constant->second[2], 0.75f);
    }
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, PropertyScriptCreateLayerWaitsForMaterialBindings) {
    Scene scene;
    auto  runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
         .canvas_width  = 1920,
         .canvas_height = 1080,
         .project_properties = {
             { "bar_count", RuntimeScalarValue::Float(4.0f) },
             { "visualizer_visible", RuntimeScalarValue::Bool(true) },
         },
    });
    ASSERT_NE(runtime, nullptr);
    runtime->AttachScene(&scene);

    auto source_node = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene.sceneGraph->AppendChild(source_node);
    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/2652516218/bar.json",
                                   source_node,
                                   Eigen::Vector2f(20.0f, 120.0f));

    auto visualizer_node = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "visualizer");
    scene.sceneGraph->AppendChild(visualizer_node);
    runtime->RegisterNode("visualizer", visualizer_node.get());
    runtime->RegisterLayerTemplate("models/workshop/2652516218/visualizer.json",
                                   visualizer_node,
                                   Eigen::Vector2f(200.0f, 200.0f));

    auto visibility = ResolveBoolSetting(
        *runtime,
        nlohmann::json {
            {
                "script",
                R"JS(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'count', value: 4 })
  .finish();
export function update(value) {
  for (var i = 0; i < scriptProperties.count; ++i) {
    var bar = thisScene.createLayer('models/bar.json');
    bar.angles = new Vec3(0, 0, i * 90);
  }
  return value;
}
)JS",
            },
            {
                "scriptproperties",
                {
                    { "count", { { "user", "bar_count" }, { "value", 4.0f } } },
                },
            },
            { "user", "visualizer_visible" },
            { "value", true },
        },
        "visualizer");
    runtime->RegisterNodeVisibility("visualizer", visualizer_node.get(), std::move(visibility));

    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);

    DynamicValue tint(Eigen::Vector3f(0.25f, 0.5f, 0.75f));
    runtime->RegisterMaterialConstant(
        source_mesh->MaterialSlotPtr(), "g_Tint", std::make_unique<DynamicValue>(tint));

    runtime->Tick(1.0 / 60.0);

    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 6u);
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        if (child.get() == source_node.get() || child.get() == visualizer_node.get()) continue;
        ASSERT_NE(child->Mesh(), nullptr);
        ASSERT_NE(child->Mesh()->Material(), nullptr);
        const auto constant = child->Mesh()->Material()->customShader.constValues.find("g_Tint");
        ASSERT_NE(constant, child->Mesh()->Material()->customShader.constValues.end());
        ASSERT_EQ(constant->second.size(), 3u);
        EXPECT_FLOAT_EQ(constant->second[0], 0.25f);
        EXPECT_FLOAT_EQ(constant->second[1], 0.5f);
        EXPECT_FLOAT_EQ(constant->second[2], 0.75f);
    }
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, PausedMaterialTimelinePlaysOnlyWhenScriptRequestsIt) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);
    auto material = std::make_shared<SceneMaterial>();
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    const auto setting = nlohmann::json::parse(R"({
        "value":1.5,
        "animation":{
            "options":{"fps":30,"length":9,"mode":"single","startpaused":true,"name":"transition"},
            "c0":[{"frame":0,"value":0},{"frame":5,"value":1.5},{"frame":9,"value":0}]
        }
    })");
    const auto animation = ResolveScalarAnimation(setting);
    ASSERT_TRUE(animation.has_value());
    auto timeline             = std::make_shared<MaterialConstantAnimation>();
    timeline->components[0]   = *animation;
    timeline->component_count = 1;
    timeline->playback        = runtime->RegisterScalarAnimation("subject", *animation);
    runtime->RegisterMaterialConstant(material, "u_Opacity", std::make_unique<DynamicValue>(1.5f),
                                      timeline);
    const auto command = [&](std::string source) {
        auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
            runtime.get(), "export function update(value) { " + source + "; return value; }",
            "subject", {}, DynamicValue(0.0f), runtime->hostContext());
        EXPECT_TRUE(program->Valid());
        program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    };

    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    command("thisLayer.getAnimation('transition').play()");
    runtime->Tick(5.0 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    command("thisLayer.getAnimation('transition').pause()");
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    command("thisLayer.getAnimation('transition').play()");
    runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    command("thisLayer.getAnimation('transition').play(); thisLayer.getAnimation('transition').rate = 2");
    runtime->Tick(2.5 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    command("thisLayer.getAnimation('transition').stop()");
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    command("thisLayer.getAnimation('transition').setFrame(5)");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// Vector constants animate per component, so a shader reading `xyzw` has to see
// every animated channel move and every unanimated channel keep its own value.
std::shared_ptr<MaterialConstantAnimation> BuildComponentTimeline(const nlohmann::json& setting,
                                                                  std::size_t components) {
    auto timeline             = std::make_shared<MaterialConstantAnimation>();
    timeline->component_count = components;
    for (std::size_t index = 0; index < components; ++index) {
        if (auto curve = ResolveScalarAnimation(setting, index)) {
            timeline->components[index] = std::move(*curve);
        } else {
            timeline->components[index].initial_value =
                setting.at("value").at(index).get<float>();
        }
    }
    return timeline;
}

TEST(ScriptRuntimeCompat, VectorMaterialTimelineDrivesEveryComponentSeparately) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);
    auto material = std::make_shared<SceneMaterial>();
    auto node     = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    const auto setting = nlohmann::json::parse(R"({
        "value":[0,0,0.25,0],
        "animation":{
            "options":{"fps":30,"length":6,"mode":"single","startpaused":true,"name":"fold"},
            "c0":[{"frame":0,"value":1},{"frame":6,"value":2}],
            "c1":[{"frame":0,"value":-1},{"frame":6,"value":-4}],
            "c3":[{"frame":0,"value":10},{"frame":3,"value":16}]
        }
    })");
    auto timeline      = BuildComponentTimeline(setting, 4);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(
        material, "u_Fold", std::make_unique<DynamicValue>(Eigen::Vector4f(0.0f, 0.0f, 0.0f, 0.0f)),
        timeline);
    const auto component = [&](std::size_t index) {
        return material->customShader.constValues.at("u_Fold")[index];
    };
    const auto command = [&](std::string source) {
        auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
            runtime.get(), "export function update(value) { " + source + "; return value; }",
            "subject", {}, DynamicValue(0.0f), runtime->hostContext());
        EXPECT_TRUE(program->Valid());
        program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    };

    ASSERT_EQ(material->customShader.constValues.at("u_Fold").size(), 4u);
    EXPECT_FLOAT_EQ(component(0), 1.0f);
    EXPECT_FLOAT_EQ(component(1), -1.0f);
    EXPECT_FLOAT_EQ(component(2), 0.25f);
    EXPECT_FLOAT_EQ(component(3), 10.0f);
    command("thisLayer.getAnimation('fold').play()");
    runtime->Tick(3.0 / 30.0);
    EXPECT_FLOAT_EQ(component(0), 1.5f);
    EXPECT_FLOAT_EQ(component(1), -2.5f);
    EXPECT_FLOAT_EQ(component(2), 0.25f);
    EXPECT_FLOAT_EQ(component(3), 16.0f);
    command("thisLayer.getAnimation('fold').setFrame(6)");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(component(0), 2.0f);
    EXPECT_FLOAT_EQ(component(1), -4.0f);
    EXPECT_FLOAT_EQ(component(2), 0.25f);
    // The short curve holds its last key instead of restarting on its own.
    EXPECT_FLOAT_EQ(component(3), 16.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ClonedTemplateLayersShareOneTimelineAndKeepEveryBinding) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);

    auto source_node = std::make_shared<SceneNode>(Eigen::Vector3f(100.0f, 50.0f, 0.0f),
                                                   Eigen::Vector3f::Ones(),
                                                   Eigen::Vector3f::Zero(), "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene.sceneGraph->AppendChild(source_node);
    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/123456/bar.json", source_node,
                                   Eigen::Vector2f(20.0f, 10.0f));
    runtime->RegisterMaterialConstant(
        source_mesh->MaterialSlotPtr(), "g_Tint",
        std::make_unique<DynamicValue>(Eigen::Vector3f(0.25f, 0.5f, 0.75f)));
    const auto setting = nlohmann::json::parse(R"({
        "value":[0,0.625],
        "animation":{
            "options":{"fps":1,"length":4,"mode":"single","name":"slide"},
            "c0":[{"frame":0,"value":0},{"frame":4,"value":1}]
        }
    })");
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("source", timeline->components[0]);
    runtime->RegisterMaterialConstant(source_mesh->MaterialSlotPtr(), "g_Point",
                                      std::make_unique<DynamicValue>(Eigen::Vector2f(0.0f, 0.0f)),
                                      timeline);

    runtime->Tick(2.0);
    ASSERT_FALSE(runtime->CreateLayerFromTemplate("models/bar.json", "source").empty());
    // A clone joins the running timeline; it must not rewind or restart it.
    auto* clock = runtime->FindScalarAnimation("source", "slide");
    ASSERT_NE(clock, nullptr);
    EXPECT_DOUBLE_EQ(clock->frame, 2.0);
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    const auto expect_layer = [](SceneNode& node, float slide) {
        ASSERT_NE(node.Mesh(), nullptr);
        ASSERT_NE(node.Mesh()->Material(), nullptr);
        const auto& values = node.Mesh()->Material()->customShader.constValues;
        ASSERT_TRUE(values.contains("g_Tint"));
        ASSERT_EQ(values.at("g_Tint").size(), 3u);
        EXPECT_FLOAT_EQ(values.at("g_Tint")[0], 0.25f);
        EXPECT_FLOAT_EQ(values.at("g_Tint")[2], 0.75f);
        ASSERT_TRUE(values.contains("g_Point"));
        ASSERT_EQ(values.at("g_Point").size(), 2u);
        EXPECT_FLOAT_EQ(values.at("g_Point")[0], slide);
        EXPECT_FLOAT_EQ(values.at("g_Point")[1], 0.625f);
    };
    for (const auto& child : scene.sceneGraph->GetChildren()) expect_layer(*child, 0.5f);
    runtime->Tick(2.0);
    for (const auto& child : scene.sceneGraph->GetChildren()) expect_layer(*child, 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// An authored timeline can name frames; the layer's own scripts react to them.
// The handler counts on the marker's scale so a missed or repeated event shows.
nlohmann::json TimelineEventSetting(const char* options) {
    auto setting = nlohmann::json::parse(std::string(R"({
        "value":[0,0],
        "animation":{
            "options":)") + options + R"(,
            "c0":[{"frame":0,"value":0},{"frame":9,"value":1}],
            "c1":[{"frame":0,"value":0},{"frame":9,"value":2}]
        }
    })");
    setting["script"] = R"JS(
let fired = 0;
export function animationEvent(event) {
  if (event.name === 'half') {
    fired += 1;
    thisScene.getLayer('marker').scale = new Vec3(fired, 1, 1);
  }
  if (event.name === 'done') thisScene.getLayer('subject').visible = false;
}
)JS";
    return setting;
}

TEST(ScriptRuntimeCompat, TimelineEventsFireWhenThePlayheadCrossesTheirFrame) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    marker->SetScale(Eigen::Vector3f(0.0f, 1.0f, 1.0f));
    const auto setting = TimelineEventSetting(
        R"({"fps":30,"length":9,"mode":"single","startpaused":true,"name":"fold",
            "events":[{"frame":5,"name":"half"},{"frame":9,"name":"done"}]})");
    auto material      = std::make_shared<SceneMaterial>();
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(material, "g_Point",
                                      ResolveVectorSetting(*runtime, setting, 2, "subject"),
                                      timeline);
    const auto command = [&](std::string source) {
        auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
            runtime.get(), "export function update(value) { " + source + "; return value; }",
            "subject", {}, DynamicValue(0.0f), runtime->hostContext());
        EXPECT_TRUE(program->Valid());
        program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    };

    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 0.0f);
    EXPECT_TRUE(subject->Visible());
    command("thisLayer.getAnimation('fold').play()");
    runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 0.0f);
    runtime->Tick(1.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    EXPECT_TRUE(subject->Visible());
    runtime->Tick(4.0 / 30.0);
    // The last frame of a single timeline still crosses its event.
    EXPECT_FALSE(subject->Visible());
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    // Seeking is an explicit jump, not playback, so it replays nothing.
    command("thisLayer.getAnimation('fold').stop()");
    command("thisLayer.getAnimation('fold').setFrame(9)");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, LoopingTimelineEventsFireOncePerLapAndOncePerStall) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    marker->SetScale(Eigen::Vector3f(0.0f, 1.0f, 1.0f));
    const auto setting = TimelineEventSetting(
        R"({"fps":30,"length":10,"mode":"loop","name":"fold",
            "events":[{"frame":5,"name":"half"}]})");
    auto material      = std::make_shared<SceneMaterial>();
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(material, "g_Point",
                                      ResolveVectorSetting(*runtime, setting, 2, "subject"),
                                      timeline);

    runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 0.0f);
    runtime->Tick(2.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    // Wrapping past the end and back over the event counts one more crossing.
    runtime->Tick(10.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 2.0f);
    // A stall longer than the whole loop reports each event once, not per lap.
    runtime->Tick(100.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 3.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// The handler records how many markers it saw, the frame of the last one and
// the sum of all their frames, so a missed, repeated or misordered marker and a
// missing `event.frame` all show up in one Vec3.
nlohmann::json MarkerTallySetting(const char* options) {
    auto setting = nlohmann::json::parse(std::string(R"({
        "value":[0,0],
        "animation":{"options":)") + options + R"(,
            "c0":[{"frame":0,"value":0},{"frame":10,"value":1}],
            "c1":[{"frame":0,"value":0},{"frame":10,"value":2}]}
    })");
    setting["script"] = R"JS(
let seen = 0;
let total = 0;
export function animationEvent(event) {
  seen += 1;
  total += event.frame;
  thisScene.getLayer('marker').scale = new Vec3(seen, event.frame, total);
}
)JS";
    return setting;
}

std::shared_ptr<ScalarAnimationPlayback> AttachMarkerTally(SceneRuntimeContext& runtime,
                                                           const nlohmann::json& setting,
                                                           std::shared_ptr<SceneMaterial> material) {
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime.RegisterScalarAnimation("subject", timeline->components[0]);
    runtime.RegisterMaterialConstant(std::move(material), "g_Point",
                                     ResolveVectorSetting(runtime, setting, 2, "subject"),
                                     timeline);
    return timeline->playback;
}

TEST(ScriptRuntimeCompat, OneTickReportsEveryCrossedMarkerWithItsAuthoredFrame) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    auto playback = AttachMarkerTally(
        *runtime,
        MarkerTallySetting(R"({"fps":1,"length":10,"mode":"single","name":"fold",
            "events":[{"frame":7,"name":"c"},{"frame":2,"name":"a"},{"frame":3,"name":"b"}]})"),
        std::make_shared<SceneMaterial>());

    runtime->Tick(8.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 3.0f);
    // Ascending frame order, so the last marker seen is the furthest one.
    EXPECT_FLOAT_EQ(marker->Scale().y(), 7.0f);
    EXPECT_FLOAT_EQ(marker->Scale().z(), 12.0f);
    EXPECT_DOUBLE_EQ(playback->frame, 8.0);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, LoopMarkersSurviveReverseTravelAndExactWraps) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    auto playback = AttachMarkerTally(
        *runtime,
        MarkerTallySetting(R"({"fps":1,"length":10,"mode":"loop","name":"fold",
            "events":[{"frame":0,"name":"seam"},{"frame":8,"name":"late"}]})"),
        std::make_shared<SceneMaterial>());

    // Running backwards past the seam still meets the late marker on the far
    // side, in the order the playhead reaches them.
    playback->SetFrame(1.0);
    playback->rate = -1.0;
    runtime->Tick(4.0);
    EXPECT_DOUBLE_EQ(playback->frame, 7.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 2.0f);
    EXPECT_FLOAT_EQ(marker->Scale().y(), 8.0f);
    EXPECT_FLOAT_EQ(marker->Scale().z(), 8.0f);

    // Landing exactly on the seam counts as reaching frame 0.
    playback->SetFrame(6.0);
    playback->rate = 1.0;
    runtime->Tick(4.0);
    EXPECT_DOUBLE_EQ(playback->frame, 0.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 4.0f);
    EXPECT_FLOAT_EQ(marker->Scale().y(), 0.0f);
    EXPECT_FLOAT_EQ(marker->Scale().z(), 16.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, TimelineMarkersReachInitializedScriptsOnTheFirstTick) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    auto setting = nlohmann::json::parse(R"({
        "value":[0,0],
        "animation":{"options":{"fps":1,"length":10,"mode":"single","name":"fold",
                                "events":[{"frame":1,"name":"tick"}]},
                     "c0":[{"frame":0,"value":0},{"frame":10,"value":1}],
                     "c1":[{"frame":0,"value":0},{"frame":10,"value":2}]}
    })");
    // The handler can only report 7 if `init` ran before the marker arrived.
    setting["script"] = R"JS(
let ready;
export function init(value) { ready = 7; return value; }
export function animationEvent(event) {
  thisScene.getLayer('marker').scale = new Vec3(ready === undefined ? -1 : ready, 1, 1);
}
)JS";
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(std::make_shared<SceneMaterial>(), "g_Point",
                                      ResolveVectorSetting(*runtime, setting, 2, "subject"),
                                      timeline);

    runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 7.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, GlobalAnimationListenersRunOncePerMarkerWhateverIsBound) {
    for (const int scene_scripts : { 0, 2 }) {
        Scene scene;
        auto  runtime = MakeRuntimeWithScene(scene);
        ASSERT_NE(runtime, nullptr);
        auto subject  = std::make_shared<SceneNode>();
        auto marker   = std::make_shared<SceneNode>();
        auto listener = std::make_shared<SceneNode>();
        runtime->RegisterNode("subject", subject.get());
        runtime->RegisterNode("marker", marker.get());
        runtime->RegisterNode("listener", listener.get());
        // The global list lives on the shared context, so it must run once per
        // marker whether nothing or several scene scripts are bound here.
        runtime->RegisterSceneScript(R"JS(
let heard = 0;
engine.on('animationEvent', function(event) {
  heard += 1;
  thisScene.getLayer('listener').scale = new Vec3(heard, event.frame, 1);
});
function update() {}
)JS",
                                     "elsewhere");
        for (int index = 0; index < scene_scripts; ++index) {
            runtime->RegisterSceneScript(R"JS(
function update() {}
export function animationEvent(event) {
  var layer = thisScene.getLayer('marker');
  layer.scale = new Vec3(layer.scale.x + 1, 1, 1);
}
)JS",
                                         "subject");
        }
        AttachMarkerTally(
            *runtime,
            MarkerTallySetting(R"({"fps":1,"length":10,"mode":"single","name":"fold",
                "events":[{"frame":2,"name":"only"}]})"),
            std::make_shared<SceneMaterial>());

        runtime->Tick(3.0);
        EXPECT_FLOAT_EQ(listener->Scale().x(), 1.0f) << "scene scripts: " << scene_scripts;
        EXPECT_FLOAT_EQ(listener->Scale().y(), 2.0f) << "scene scripts: " << scene_scripts;
        EXPECT_EQ(runtime->scriptErrorCount(), 0u);
    }
}

TEST(ScriptRuntimeCompat, GlobalOnlyAnimationListenerSeesTheCurrentTickTime) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto listener = std::make_shared<SceneNode>();
    runtime->RegisterNode("listener", listener.get());
    // No property script and no layer export: the global listener is the only
    // consumer, so nothing else refreshes `engine` before it runs.
    runtime->RegisterSceneScript(R"JS(
engine.on('animationEvent', function(event) {
  thisScene.getLayer('listener').scale =
      new Vec3(engine.runtime, engine.frametime, event.frame);
});
function update() {}
)JS",
                                 "elsewhere");
    ScalarAnimation clock;
    clock.fps           = 1.0;
    clock.length_frames = 10.0;
    clock.name          = "fold";
    clock.keyframes     = { { .frame = 0.0, .value = 0.0f }, { .frame = 10.0, .value = 1.0f } };
    clock.events        = { { .frame = 1.0, .name = "tick" } };
    runtime->RegisterScalarAnimation("subject", clock);

    runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(listener->Scale().x(), 2.0f);
    EXPECT_FLOAT_EQ(listener->Scale().y(), 2.0f);
    EXPECT_FLOAT_EQ(listener->Scale().z(), 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, SceneGetAnimationFindsATimelineOnAnotherLayer) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto page = std::make_shared<SceneNode>();
    runtime->RegisterNode("page", page.get());
    const auto setting = nlohmann::json::parse(R"({
        "value":[0,0],
        "animation":{"options":{"fps":30,"length":30,"mode":"single","startpaused":true,
                                "name":"111"},
                     "c0":[{"frame":0,"value":0},{"frame":30,"value":1}],
                     "c1":[{"frame":0,"value":0},{"frame":30,"value":2}]}
    })");
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("page", timeline->components[0]);
    auto material      = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "g_Point",
                                      std::make_unique<DynamicValue>(Eigen::Vector2f(0.0f, 0.0f)),
                                      timeline);
    auto other = std::make_shared<SceneNode>();
    runtime->RegisterNode("other", other.get());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        "export function update(value) { thisScene.getAnimation('111').play(); return value; }",
        "other", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);

    EXPECT_FALSE(timeline->playback->playing);
    program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    EXPECT_TRUE(timeline->playback->playing);
    runtime->Tick(15.0 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Point")[0], 0.5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ScalarTimelineUsesBezierTimeHandlesAndExactInitialKey) {
    const auto animation = ResolveScalarAnimation(nlohmann::json::parse(R"({
        "value":9,"animation":{
            "options":{"fps":10,"length":10,"mode":"single"},
            "c0":[
                {"frame":0,"value":0,"front":{"enabled":true,"x":1,"y":0}},
                {"frame":10,"value":1,"back":{"enabled":true,"x":-1,"y":0}}
            ]
        }
    })"));
    ASSERT_TRUE(animation.has_value());
    EXPECT_FLOAT_EQ(animation->Evaluate(0.0), 0.0f);
    // At Bezier parameter 1/4, time is .184375 and value is .15625, not linear.
    EXPECT_NEAR(animation->Evaluate(0.184375), 0.15625f, 1e-6f);
    EXPECT_FLOAT_EQ(animation->Evaluate(1.0), 1.0f);
}

TEST(ScriptRuntimeCompat, MaterialConstantUserBindingUpdatesThroughRuntimeProperties) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "tint", RuntimeScalarValue::String("0.25 0.5 0.75") },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(
        material,
        "g_Tint",
        ResolveVec3Setting(
            *runtime,
            nlohmann::json {
                { "user", "tint" },
                { "value", { 1.0f, 1.0f, 1.0f } },
            }));

    runtime->Tick(1.0 / 60.0);
    auto constant = material->customShader.constValues.find("g_Tint");
    ASSERT_NE(constant, material->customShader.constValues.end());
    ASSERT_EQ(constant->second.size(), 3u);
    EXPECT_FLOAT_EQ(constant->second[0], 0.25f);
    EXPECT_FLOAT_EQ(constant->second[1], 0.5f);
    EXPECT_FLOAT_EQ(constant->second[2], 0.75f);

    runtime->ApplyProjectPropertyOverride({
        { "tint", RuntimeScalarValue::String("0.1 0.2 0.3") },
    });
    runtime->Tick(1.0 / 60.0);

    constant = material->customShader.constValues.find("g_Tint");
    ASSERT_NE(constant, material->customShader.constValues.end());
    ASSERT_EQ(constant->second.size(), 3u);
    EXPECT_FLOAT_EQ(constant->second[0], 0.1f);
    EXPECT_FLOAT_EQ(constant->second[1], 0.2f);
    EXPECT_FLOAT_EQ(constant->second[2], 0.3f);
}

TEST(ScriptRuntimeCompat, SceneScriptCreateLayerInUpdateReusesGeneratedLayer) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);

    auto source_node = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene.sceneGraph->AppendChild(source_node);

    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/123456/bar.json",
                                   source_node,
                                   Eigen::Vector2f(20.0f, 10.0f));

    runtime->RegisterSceneScript(
        R"JS(
function update() {
  var layer = thisScene.createLayer('models/bar.json');
  layer.origin = new Vec3(10, 20, 0);
}
)JS",
        "source");

    runtime->Tick(1.0 / 60.0);
    ASSERT_TRUE(runtime->ConsumeSceneGraphMutationFlag());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    const auto generated_name = scene.sceneGraph->GetChildren().back()->Name();
    ASSERT_FALSE(generated_name.empty());

    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    EXPECT_EQ(scene.sceneGraph->GetChildren().back()->Name(), generated_name);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, SceneUpdateCallbackCreateLayerReusesGeneratedLayer) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);

    auto source_node = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene.sceneGraph->AppendChild(source_node);

    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/123456/bar.json",
                                   source_node,
                                   Eigen::Vector2f(20.0f, 10.0f));

    runtime->RegisterSceneScript(
        R"JS(
scene.on('update', function() {
  var layer = thisScene.createLayer('models/bar.json');
  layer.origin = new Vec3(10, 20, 0);
});
)JS",
        "source");

    runtime->Tick(1.0 / 60.0);
    ASSERT_TRUE(runtime->ConsumeSceneGraphMutationFlag());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    const auto generated_name = scene.sceneGraph->GetChildren().back()->Name();
    ASSERT_FALSE(generated_name.empty());

    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    EXPECT_EQ(scene.sceneGraph->GetChildren().back()->Name(), generated_name);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ExportAndCallbackCreateLayerUpdatesUseSeparateGeneratedLayers) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);

    auto source_node = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene.sceneGraph->AppendChild(source_node);

    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/123456/bar.json",
                                   source_node,
                                   Eigen::Vector2f(20.0f, 10.0f));

    runtime->RegisterSceneScript(
        R"JS(
function update() {
  var exported = thisScene.createLayer('models/bar.json');
  exported.origin = new Vec3(10, 20, 0);
}

scene.on('update', function() {
  var callback = thisScene.createLayer('models/bar.json');
  callback.origin = new Vec3(30, 40, 0);
});
)JS",
        "source");

    runtime->Tick(1.0 / 60.0);
    ASSERT_TRUE(runtime->ConsumeSceneGraphMutationFlag());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 3u);
    auto first_generated  = std::next(scene.sceneGraph->GetChildren().begin());
    auto second_generated = std::next(first_generated);
    const auto first_generated_name  = (*first_generated)->Name();
    const auto second_generated_name = (*second_generated)->Name();
    ASSERT_FALSE(first_generated_name.empty());
    ASSERT_FALSE(second_generated_name.empty());
    ASSERT_NE(first_generated_name, second_generated_name);

    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 3u);
    first_generated  = std::next(scene.sceneGraph->GetChildren().begin());
    second_generated = std::next(first_generated);
    EXPECT_EQ((*first_generated)->Name(), first_generated_name);
    EXPECT_EQ((*second_generated)->Name(), second_generated_name);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, RepeatedSortLayerToHigherIndexMutatesOnlyOnce) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);

    auto first = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "first");
    auto second = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "second");
    auto third = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "third");
    scene.sceneGraph->AppendChild(first);
    scene.sceneGraph->AppendChild(second);
    scene.sceneGraph->AppendChild(third);
    runtime->RegisterNode("first", first.get());
    runtime->RegisterNode("second", second.get());
    runtime->RegisterNode("third", third.get());

    runtime->RegisterSceneScript(
        R"JS(
function update() {
  scene.sortLayer('first', 2);
}
)JS",
        "");

    runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(runtime->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(runtime->NodeSiblingIndex("first"), 2);

    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(runtime->NodeSiblingIndex("first"), 2);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, VisibleOnlyBindingIgnoresObjectReturn) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "visible", RuntimeScalarValue::Bool(false) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNodeVisibility(
        "probe",
        node.get(),
        ResolveBoolSetting(
            *runtime,
            nlohmann::json {
                { "script", "export function update(value) { return { x: 1 }; }" },
                { "user", "visible" },
                { "value", true },
            },
            "probe"));

    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->NodeVisible("probe"));
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ScriptPropertiesUseUserPropertyWrites) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1000,
        .canvas_height = 500,
        .project_properties = {
            { "x", RuntimeScalarValue::Float(0.8f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("probe", node.get());
    runtime->RegisterNodeTranslate(
        "probe",
        node.get(),
        ResolveVec3Setting(
            *runtime,
            nlohmann::json {
                {
                    "script",
                    R"JS(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'x', value: 0.5 })
  .finish();
export function update(value) {
  value.x = scriptProperties.x * engine.canvasSize.x;
  return value;
}
)JS",
                },
                { "scriptproperties", { { "x", { { "user", "x" }, { "value", 0.5f } } } } },
                { "value", "0 0 0" },
            },
            "probe"));

    runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(runtime->NodeTranslate("probe").x(), 800.0f);

    runtime->ApplyProjectPropertyOverride({
        { "x", RuntimeScalarValue::Float(0.25f) },
    });
    runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(runtime->NodeTranslate("probe").x(), 250.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, CursorCallbacksReceiveButtonAndPositions) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    node->SetVisible(false);
    runtime->RegisterNode("probe", node.get());
    runtime->RegisterSceneScript(
        R"JS(
var ok = 0;
function cursorDown(event) {
  if (event.button === 1 &&
      event.normalizedPosition.x === 0.25 &&
      event.position.x === 480 &&
      event.worldPosition.y === 270) ok++;
}
function update() {
  if (ok === 1) scene.getObject('probe').visible = true;
}
)JS",
        "");

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorButton(1, true);
    runtime->DispatchCursorDown(1);
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(runtime->NodeVisible("probe"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(AudioResponseCompat, RegisteredBuffersSupportTypedViewsAndClearWhenDisabled) {
    audio::ResetAudioResponseServiceForTesting();
    std::array<float, 2400> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = 0.025f * std::sin(2.0 * 3.141592653589793 * 234.375 * index / 12000.0);
    }
    std::string error;
    ASSERT_TRUE(audio::SubmitMonoAudioFrames(12000, samples.size(), samples.data(), &error))
        << error;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (audio::CurrentAudioSpectrumSnapshot().generation == 0 &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_GT(audio::CurrentAudioSpectrumSnapshot().generation, 0u);

    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->SetAudioResponseEnabled(true);
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(),
                                                                       R"JS(
const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
const bass = audio.average.subarray(0, 1);
export function update(value) {
    return bass[0];
}
)JS",
                                                                       "",
                                                                       {},
                                                                       DynamicValue(0.0f),
                                                                       runtime->hostContext());
    ASSERT_TRUE(program->Valid());
    const auto active = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(active, nullptr);
    EXPECT_GT(active->getFloat(), 0.05f);
    runtime->SetAudioResponseEnabled(false);
    const auto disabled = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(disabled, nullptr);
    EXPECT_FLOAT_EQ(disabled->getFloat(), 0.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(AudioResponseCompat, ShaderSpectrumUniformsUseVec4ArrayStride) {
    struct ResetAudioOnExit {
        ~ResetAudioOnExit() { audio::ResetAudioResponseServiceForTesting(); }
    } reset_audio;
    audio::AudioSpectrumSnapshot snapshot;
    snapshot.generation = 17;
    const auto fill = [](auto& values, float offset) {
        for (std::size_t i = 0; i < values.size(); ++i) values[i] = offset + float(i) / 128.0f;
    };
    fill(snapshot.left16, 0.125f);
    fill(snapshot.right16, 0.25f);
    fill(snapshot.left32, 0.375f);
    fill(snapshot.right32, 0.5f);
    fill(snapshot.left64, 0.625f);
    fill(snapshot.right64, 0.75f);
    audio::SetAudioSpectrumSnapshotForTesting(snapshot);
    Scene scene;
    SceneCamera camera(1920, 1080, 0.01f, 1000.0f);
    scene.activeCamera = &camera;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    scene.runtime->AttachScene(&scene);
    scene.runtime->SetAudioResponseEnabled(true);
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    WPShaderValueUpdater updater(&scene);
    const ExistsUniformOp has_spectrum = [](std::string_view name) {
        return name == "g_AudioSpectrum16Left" || name == "g_AudioSpectrum16Right" ||
               name == "g_AudioSpectrum32Left" || name == "g_AudioSpectrum32Right" ||
               name == "g_AudioSpectrum64Left" || name == "g_AudioSpectrum64Right";
    };
    updater.InitUniforms(node.get(), 0, has_spectrum);
    updater.InitUniforms(node.get(), 1, has_spectrum);
    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    const UpdateUniformOp capture = [&](std::string_view name, const ShaderValue& value) {
        updates.insert_or_assign(std::string(name), value);
    };
    const auto expect_snapshot = [&](const audio::AudioSpectrumSnapshot& expected) {
        ASSERT_EQ(updates.size(), 6u);
        const auto expect_packed = [&](const char* name, const auto& source) {
            const auto it = updates.find(name);
            ASSERT_NE(it, updates.end()) << name;
            ASSERT_EQ(it->second.size(), source.size() * 4u) << name;
            for (std::size_t i = 0; i < source.size(); ++i) {
                EXPECT_FLOAT_EQ(it->second[i * 4u], source[i]);
                EXPECT_FLOAT_EQ(it->second[i * 4u + 1u], 0.0f);
                EXPECT_FLOAT_EQ(it->second[i * 4u + 2u], 0.0f);
                EXPECT_FLOAT_EQ(it->second[i * 4u + 3u], 0.0f);
            }
        };
        expect_packed("g_AudioSpectrum16Left", expected.left16);
        expect_packed("g_AudioSpectrum16Right", expected.right16);
        expect_packed("g_AudioSpectrum32Left", expected.left32);
        expect_packed("g_AudioSpectrum32Right", expected.right32);
        expect_packed("g_AudioSpectrum64Left", expected.left64);
        expect_packed("g_AudioSpectrum64Right", expected.right64);
    };
    updater.UpdateUniforms(node.get(), 0, sprites, capture);
    expect_snapshot(snapshot);
    // Same generation and elapsed time, with no intervening FrameBegin.
    fill(snapshot.left16, -0.125f);
    fill(snapshot.right16, -0.25f);
    fill(snapshot.left32, -0.375f);
    fill(snapshot.right32, -0.5f);
    fill(snapshot.left64, -0.625f);
    fill(snapshot.right64, -0.75f);
    audio::SetAudioSpectrumSnapshotForTesting(snapshot);
    updates.clear();
    updater.UpdateUniforms(node.get(), 1, sprites, capture);
    expect_snapshot(snapshot);
    updater.InitUniforms(node.get(), 0, has_spectrum);
    updates.clear();
    updater.UpdateUniforms(node.get(), 0, sprites, capture);
    expect_snapshot(snapshot);
    scene.runtime->SetAudioResponseEnabled(false);
    updates.clear();
    updater.UpdateUniforms(node.get(), 1, sprites, capture);
    expect_snapshot({});
    scene.runtime->SetAudioResponseEnabled(true);
    audio::SetAudioSpectrumSnapshotForTesting({});
    updates.clear();
    updater.UpdateUniforms(node.get(), 0, sprites, capture);
    expect_snapshot({});
    audio::SetAudioSpectrumSnapshotForTesting(snapshot);
    scene.runtime.reset();
    updates.clear();
    updater.UpdateUniforms(node.get(), 1, sprites, capture);
    expect_snapshot({});
    scene.activeCamera = nullptr;
}

TEST(ShaderValuePacking, FixedMatricesAndExpressionsPreserveColumnMajorValues) {
    Eigen::Matrix4d matrix;
    matrix << 1, 2, 0, 4,
              0, 2, 1, 3,
              0, 0, 4, 2,
              0, 0, 0, 1;
    const std::array<float, 16> expected_matrix {
        1, 0, 0, 0,
        2, 2, 0, 0,
        0, 1, 4, 0,
        4, 3, 2, 1,
    };
    const std::array<float, 16> expected_inverse {
        1, 0, 0, 0,
        -1, 0.5f, 0, 0,
        0.25f, -0.125f, 0.25f, 0,
        -1.5f, -1.25f, -0.5f, 1,
    };
    const std::array<float, 16> expected_product {
        21, 16, 8, 4,
        16, 14, 10, 3,
        8, 10, 20, 2,
        4, 3, 2, 1,
    };
    const auto expect_packed = [](const char* context, const ShaderValue& actual,
                                  const std::array<float, 16>& expected) {
        SCOPED_TRACE(context);
        ASSERT_EQ(actual.size(), expected.size());
        for (std::size_t i = 0; i < expected.size(); ++i) {
            EXPECT_FLOAT_EQ(actual[i], expected[i]) << "coefficient " << i;
        }
    };
    expect_packed("fixed double", ShaderValue::fromMatrix(matrix), expected_matrix);
    expect_packed("inverse", ShaderValue::fromMatrix(matrix.inverse()), expected_inverse);
    expect_packed("product", ShaderValue::fromMatrix(matrix * matrix.transpose()), expected_product);

    const Eigen::Matrix<float, 4, 4> float_matrix = matrix.cast<float>();
    expect_packed("fixed float", ShaderValue::fromMatrix(float_matrix), expected_matrix);
    const Eigen::Matrix<double, 4, 4, Eigen::RowMajor> row_major = matrix;
    expect_packed("row major", ShaderValue::fromMatrix(row_major), expected_matrix);
    Eigen::Matrix<double, 6, 7> padded = Eigen::Matrix<double, 6, 7>::Constant(-99.0);
    padded.block<4, 4>(1, 2) = matrix;
    expect_packed("strided block", ShaderValue::fromMatrix(padded.block<4, 4>(1, 2)),
                  expected_matrix);
}

TEST(ShaderValuePacking, PackedValuesOwnTheirStorageAcrossInputChanges) {
    const auto packed = [] {
        Eigen::Matrix4d inline_matrix;
        Eigen::Matrix<double, 5, 5> large_matrix;
        Eigen::MatrixXd empty_matrix(0, 0);
        for (Eigen::Index column = 0; column < inline_matrix.cols(); ++column) {
            for (Eigen::Index row = 0; row < inline_matrix.rows(); ++row) {
                inline_matrix(row, column) = (10 * column + row + 1) / 10.0;
            }
        }
        for (Eigen::Index column = 0; column < large_matrix.cols(); ++column) {
            for (Eigen::Index row = 0; row < large_matrix.rows(); ++row) {
                large_matrix(row, column) = (10 * column + row + 1) / 10.0;
            }
        }
        std::array<ShaderValue, 3> values {
            ShaderValue::fromMatrix(inline_matrix),
            ShaderValue::fromMatrix(large_matrix),
            ShaderValue::fromMatrix(empty_matrix),
        };
        inline_matrix.setConstant(-99.0);
        large_matrix.setConstant(-99.0);
        empty_matrix.resize(4, 4);
        empty_matrix.setConstant(-99.0);
        return values;
    }();

    const std::array<float, 16> expected_inline {
        0.1f, 0.2f, 0.3f, 0.4f,
        1.1f, 1.2f, 1.3f, 1.4f,
        2.1f, 2.2f, 2.3f, 2.4f,
        3.1f, 3.2f, 3.3f, 3.4f,
    };
    const std::array<float, 25> expected_large {
        0.1f, 0.2f, 0.3f, 0.4f, 0.5f,
        1.1f, 1.2f, 1.3f, 1.4f, 1.5f,
        2.1f, 2.2f, 2.3f, 2.4f, 2.5f,
        3.1f, 3.2f, 3.3f, 3.4f, 3.5f,
        4.1f, 4.2f, 4.3f, 4.4f, 4.5f,
    };
    ASSERT_EQ(packed[0].size(), expected_inline.size());
    for (std::size_t i = 0; i < expected_inline.size(); ++i) {
        EXPECT_FLOAT_EQ(packed[0][i], expected_inline[i]) << "inline coefficient " << i;
    }
    ASSERT_EQ(packed[1].size(), expected_large.size());
    for (std::size_t i = 0; i < expected_large.size(); ++i) {
        EXPECT_FLOAT_EQ(packed[1][i], expected_large[i]) << "dynamic coefficient " << i;
    }
    EXPECT_EQ(packed[2].size(), 0u);
}

TEST(ShaderValueUpdaterCompat, UniformMetadataIsIsolatedPerMaterialSlot) {
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    scene.runtime->AttachScene(&scene);
    scene.activeCamera = new SceneCamera(1920, 1080, 0.01f, 1000.0f);

    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);

    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), 0, [](std::string_view name) {
        return name == "g_ModelMatrix";
    });
    updater.InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_Time";
    });

    sprite_map_t slot_zero_sprites;
    std::unordered_map<std::string, ShaderValue> slot_zero_updates;
    updater.UpdateUniforms(
        node.get(),
        0,
        slot_zero_sprites,
        [&](std::string_view name, const ShaderValue& value) {
            slot_zero_updates.emplace(std::string(name), value);
        });

    sprite_map_t slot_one_sprites;
    std::unordered_map<std::string, ShaderValue> slot_one_updates;
    updater.UpdateUniforms(
        node.get(),
        1,
        slot_one_sprites,
        [&](std::string_view name, const ShaderValue& value) {
            slot_one_updates.emplace(std::string(name), value);
        });

    EXPECT_TRUE(slot_zero_updates.contains("g_ModelMatrix"));
    EXPECT_FALSE(slot_zero_updates.contains("g_Time"));
    EXPECT_FALSE(slot_one_updates.contains("g_ModelMatrix"));
    EXPECT_TRUE(slot_one_updates.contains("g_Time"));

    delete scene.activeCamera;
    scene.activeCamera = nullptr;
}

TEST(ShaderValueUpdaterCompat, SlotUniformsUpdateWhenSlotZeroMaterialIsMissing) {
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    scene.runtime->AttachScene(&scene);
    scene.activeCamera = new SceneCamera(1920, 1080, 0.01f, 1000.0f);

    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->MaterialSlots().push_back(nullptr);
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);

    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_Time";
    });

    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    updater.UpdateUniforms(node.get(), 1, sprites, [&](std::string_view name, const ShaderValue& value) {
        updates.emplace(std::string(name), value);
    });

    EXPECT_TRUE(updates.contains("g_Time"));

    delete scene.activeCamera;
    scene.activeCamera = nullptr;
}

// Camera parallax moves a layer by the cursor and the layer's depth alone. With
// the cursor centred every layer rests where it was authored; offsetting a deep
// layer by its distance from the camera as well pushed a planet near the top of
// a 4K canvas out of the frame. Away from the centre, layers of one depth move
// together wherever they sit, nested in a group or not, and depth scales it.
TEST(ShaderValueUpdaterCompat, CameraParallaxFollowsTheCursorAndDepthNotThePosition) {
    Scene scene;
    scene.ortho[0] = 3840;
    scene.ortho[1] = 2160;
    auto camera      = std::make_shared<SceneCamera>(3840, 2160, -1.0f, 1.0f);
    auto camera_node = std::make_shared<SceneNode>();
    camera_node->SetTranslate(Eigen::Vector3f(1920, 1080, 0));
    camera->AttatchNode(camera_node);
    scene.activeCamera = camera.get();

    const auto layer = [] {
        auto node = std::make_shared<SceneNode>();
        auto mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(SceneMaterial {});
        node->AddMesh(mesh);
        return node;
    };
    WPShaderValueUpdater updater(&scene);
    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.5f,
                                .mouseinfluence = 0.5f });
    // How far the drawn layer sits from where its node places it.
    const auto displacement = [&](SceneNode& node, float depth) {
        WPShaderValueData data;
        data.parallaxDepth = { depth, depth };
        updater.SetNodeData(&node, data);
        updater.InitUniforms(&node, [](std::string_view name) { return name == "g_ModelMatrix"; });
        sprite_map_t sprites;
        ShaderValue  value;
        updater.UpdateUniforms(&node, sprites, [&](std::string_view name, const ShaderValue& v) {
            if (name == "g_ModelMatrix") value = v;
        });
        node.UpdateTrans();
        const auto model = node.ModelTrans();
        return Eigen::Vector2f(value[12] - static_cast<float>(model(0, 3)),
                               value[13] - static_cast<float>(model(1, 3)));
    };

    auto planet = layer();
    planet->SetTranslate(Eigen::Vector3f(1907, 2647, 0));
    auto group = std::make_shared<SceneNode>();
    group->SetTranslate(Eigen::Vector3f(1000, 500, 0));
    auto nested = layer();
    nested->SetTranslate(Eigen::Vector3f(500, 200, 0));
    group->AppendChild(nested);
    auto centred = layer();
    centred->SetTranslate(Eigen::Vector3f(1920, 1080, 0));

    EXPECT_LT(displacement(*planet, 0.5f).norm(), 1e-3f) << "an off-centre layer left its place";
    EXPECT_LT(displacement(*nested, 0.5f).norm(), 1e-3f) << "a nested layer left its place";

    updater.MouseInput(1.0, 0.0);
    scene.frameTime = 0.5; // the whole delay: the smoothed cursor has arrived
    updater.FrameBegin();
    const Eigen::Vector2f moved = displacement(*centred, 0.5f);
    EXPECT_GT(moved.norm(), 1.0f) << "a cursor away from the centre must move the layer";
    EXPECT_LT((displacement(*planet, 0.5f) - moved).norm(), 1e-3f);
    EXPECT_LT((displacement(*nested, 0.5f) - moved).norm(), 1e-3f);
    EXPECT_LT((displacement(*centred, 1.0f) - 2.0f * moved).norm(), 1e-3f);
    EXPECT_LT(displacement(*centred, 0.0f).norm(), 1e-3f) << "depth zero stays put";
}

// Camera parallax moves a layer through its model matrix, which neither the
// uniforms its shader declares nor the node transform the static cache hashes
// reveal. Such a pass has to be reported as following the cursor, or it is
// reused while the cursor moves and a still scene never wakes for it. The
// camera the pass draws through decides: the effect camera and a layer-local
// one, which draws a layer into a composite another layer samples, move nothing.
TEST(ShaderValueUpdaterCompat, ParallaxLayersAreReportedAsFollowingTheCursor) {
    Scene scene;
    scene.ortho[0] = 1920;
    scene.ortho[1] = 1080;
    auto camera        = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera = camera.get();
    scene.cameras["effect"] = std::make_shared<SceneCamera>(64, 32, -1.0f, 1.0f);
    auto composite = std::make_shared<SceneCamera>(64, 32, -1.0f, 1.0f);
    composite->SetLayerLocal(true);
    scene.cameras["composite"] = composite;
    WPShaderValueUpdater updater(&scene);
    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.5f,
                                .mouseinfluence = 0.5f });

    std::vector<std::shared_ptr<SceneNode>> nodes;
    const auto layer = [&](float depth, const char* camera_name) {
        auto node = std::make_shared<SceneNode>();
        auto mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(SceneMaterial {});
        node->AddMesh(mesh);
        node->SetCamera(camera_name);
        WPShaderValueData data;
        data.parallaxDepth = { depth, depth };
        updater.SetNodeData(node.get(), data);
        updater.InitUniforms(node.get(), [](std::string_view name) {
            return name == "g_ModelViewProjectionMatrix";
        });
        nodes.push_back(node);
        return node.get();
    };
    const auto follows_cursor = [&](SceneNode* node, const std::string& camera_override) {
        return (updater.FrameVaryingUniforms(node, 0, camera_override) &
                frame_varying_uniform::kParallax) != 0;
    };

    auto* deep   = layer(0.5f, "");
    auto* flat   = layer(0.0f, "");
    auto* effect = layer(0.5f, "effect");
    EXPECT_TRUE(follows_cursor(deep, ""));
    EXPECT_FALSE(follows_cursor(flat, "")) << "depth zero never moves";
    EXPECT_FALSE(follows_cursor(effect, "")) << "effect passes draw through the effect camera";
    EXPECT_FALSE(follows_cursor(deep, "composite"))
        << "drawn into its composite through a layer-local camera, the layer does not move";

    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.5f,
                                .mouseinfluence = 0.0f });
    EXPECT_FALSE(follows_cursor(deep, "")) << "without mouse influence the cursor moves nothing";
}

TEST(ShaderValueUpdaterCompat, SlotRenderTargetUniformsUseSlotShaderValueData) {
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    scene.runtime->AttachScene(&scene);
    scene.activeCamera = new SceneCamera(1920, 1080, 0.01f, 1000.0f);
    scene.renderTargets["_rt_slot_zero"] = SceneRenderTarget {
        .width        = 64,
        .height       = 32,
        .mipmap_level = 2,
    };
    scene.renderTargets["_rt_slot_one"] = SceneRenderTarget {
        .width        = 128,
        .height       = 96,
        .mipmap_level = 4,
    };

    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);

    WPShaderValueData slot_zero_data;
    slot_zero_data.renderTargets.push_back({ 0, "_rt_slot_zero" });
    WPShaderValueData slot_one_data;
    slot_one_data.renderTargets.push_back({ 0, "_rt_slot_one" });

    WPShaderValueUpdater updater(&scene);
    updater.SetNodeData(node.get(), 0, slot_zero_data);
    updater.SetNodeData(node.get(), 1, slot_one_data);
    updater.InitUniforms(node.get(), 0, [](std::string_view name) {
        return name == "g_Texture0Resolution";
    });
    updater.InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_Texture0Resolution";
    });

    sprite_map_t slot_zero_sprites;
    std::unordered_map<std::string, ShaderValue> slot_zero_updates;
    updater.UpdateUniforms(
        node.get(),
        0,
        slot_zero_sprites,
        [&](std::string_view name, const ShaderValue& value) {
            slot_zero_updates.emplace(std::string(name), value);
        });

    sprite_map_t slot_one_sprites;
    std::unordered_map<std::string, ShaderValue> slot_one_updates;
    updater.UpdateUniforms(
        node.get(),
        1,
        slot_one_sprites,
        [&](std::string_view name, const ShaderValue& value) {
            slot_one_updates.emplace(std::string(name), value);
        });

    ASSERT_TRUE(slot_zero_updates.contains("g_Texture0Resolution"));
    ASSERT_TRUE(slot_one_updates.contains("g_Texture0Resolution"));
    EXPECT_FLOAT_EQ(slot_zero_updates.at("g_Texture0Resolution")[0], 64.0f);
    EXPECT_FLOAT_EQ(slot_zero_updates.at("g_Texture0Resolution")[1], 32.0f);
    EXPECT_FLOAT_EQ(slot_one_updates.at("g_Texture0Resolution")[0], 128.0f);
    EXPECT_FLOAT_EQ(slot_one_updates.at("g_Texture0Resolution")[1], 96.0f);

    delete scene.activeCamera;
    scene.activeCamera = nullptr;
}

TEST(ShaderValueUpdaterCompat, EffectMatricesRetainOwnerScaleAndMapQuadToLayer) {
    Scene scene;
    auto camera = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera = camera.get();
    scene.cameras["effect"] = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
    SceneNode owner;
    owner.SetScale(Eigen::Vector3f(0.8f, 0.6f, 1.0f));
    owner.SetTranslate(Eigen::Vector3f(100.0f, 200.0f, 0.0f));
    owner.UpdateTrans();
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    node->SetCamera("effect");
    WPShaderValueData data;
    data.effect_owner = &owner;
    data.effect_extent = Eigen::Vector2f(280, 300);
    WPShaderValueUpdater updater(&scene);
    updater.SetNodeData(node.get(), data);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_LayerModelMatrix" || name == "g_EffectModelViewProjectionMatrix";
    });
    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> values;
    auto capture = [&](std::string_view name, const ShaderValue& value) {
        values[std::string(name)] = value;
    };
    updater.UpdateUniforms(node.get(), sprites, capture);
    ASSERT_TRUE(values.contains("g_LayerModelMatrix"));
    EXPECT_NEAR(values.at("g_LayerModelMatrix")[0], 0.8f, 1e-6f);
    Eigen::Matrix4d extent = Eigen::Matrix4d::Identity();
    extent(0, 0) = 140;
    extent(1, 1) = 150;
    const Eigen::Matrix4d expected = camera->GetViewProjectionMatrix() * owner.ModelTrans() * extent;
    for (int i = 0; i < 16; ++i)
        EXPECT_NEAR(values.at("g_EffectModelViewProjectionMatrix")[i], expected.data()[i], 1e-5);
    node->SetCamera("");
    updater.UpdateUniforms(node.get(), sprites, capture);
    const Eigen::Matrix4d final_expected = camera->GetViewProjectionMatrix() * owner.ModelTrans();
    for (int i = 0; i < 16; ++i)
        EXPECT_NEAR(values.at("g_EffectModelViewProjectionMatrix")[i], final_expected.data()[i], 1e-5);
}

TEST(ScriptRuntimeCompat, CompiledExportsIgnoreSourceTextAndRecognizePlainFunctions) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("plain", node.get());
    runtime->RegisterNodeTranslate("plain", node.get(), ResolveVec3Setting(*runtime, {
        {"value", "1 2 3"},
        {"script", "function update(value) { value.x += 2; return value; }"},
    }, "plain"));
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(node->Translate().x(), 3.0f);
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(node->Translate().x(), 5.0f);

    auto callback = ResolveBoolSetting(*runtime, {
        {"value", true},
        {"script", R"JS(
// export function update(value) { return false; }
const notAnExport = 'export function update';
function init() { thisLayer.visible = false; }
function cursorClick() { thisLayer.visible = !thisLayer.visible; }
)JS"},
    }, "plain");
    int notifications = 0;
    callback->listen([&](const DynamicValue&) { ++notifications; });
    runtime->RegisterNodeVisibility("plain", node.get(), std::move(callback));
    runtime->Tick(0.0);
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(notifications, 1);
    runtime->Tick(0.0);
    EXPECT_EQ(notifications, 1);
    runtime->DispatchCursorClick();
    runtime->Tick(0.0);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(notifications, 2);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, InitOnlyProgramsStillRunTimersAndConvenienceInitialization) {
    ScriptEngine engine;
    const auto initial = engine.Evaluate(R"JS(
function init() { localStorage.set('init-only-proof', 17); }
)JS", {}, DynamicValue(9.0f), {});
    ASSERT_NE(initial, nullptr);
    EXPECT_FLOAT_EQ(initial->getFloat(), 9.0f);
    EXPECT_FLOAT_EQ(EvaluateScalar(engine,
        "function update() { return Number(localStorage.get('init-only-proof')); }").getFloat(), 17.0f);

    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("timer", node.get());
    runtime->RegisterNodeVisibility("timer", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
function init() {
    thisLayer.visible = false;
    setTimeout(function() { thisLayer.visible = true; }, 100);
}
)JS"},
    }, "timer"));
    runtime->Tick(0.0);
    EXPECT_FALSE(node->Visible());
    runtime->Tick(0.2);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, UpdateExceptionAndBooleanObjectKeepLiveNativeWrites) {
    for (const auto& ending : { std::string("throw new Error('expected update failure');"),
                               std::string("return new Boolean(false);") }) {
        auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
        auto node = std::make_shared<SceneNode>();
        runtime->RegisterNode("live", node.get());
        runtime->RegisterNodeVisibility("live", node.get(), ResolveBoolSetting(*runtime, {
            {"value", false},
            {"script", "function update() { thisLayer.visible = true; " + ending + " }"},
        }, "live"));
        for (int index = 0; index < 3; ++index) {
            runtime->SetNodeVisible("live", false);
            runtime->Tick(0.01);
            EXPECT_TRUE(node->Visible());
            EXPECT_EQ(runtime->scriptErrorCount(), ending.starts_with("throw") ? index + 1u : 0u);
        }
    }
}

TEST(ScriptRuntimeCompat, SharedCallbacksRetainPerProgramDispatchAndDynamicRegistration) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto marker = std::make_shared<SceneNode>();
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(R"JS(
let registered = false;
scene.on('update', function() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x += 1;
    marker.origin = origin;
    if (!registered) {
        registered = true;
        scene.on('cursorClick', function() {
            const marker = thisScene.getLayer('marker');
            const origin = marker.origin;
            origin.y += 1;
            marker.origin = origin;
        });
    }
});
)JS", "");
    runtime->RegisterSceneScript("const noExports = true;", "");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 2.0f);
    runtime->DispatchCursorClick();
    EXPECT_FLOAT_EQ(marker->Translate().y(), 2.0f);
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 4.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, TransformBindingsRepairDestinationsAndRefreshIdentityAndSize) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto original = std::make_shared<SceneNode>();
    runtime->RegisterNodeTranslate("anchor", original.get(),
        std::make_unique<DynamicValue>(Eigen::Vector3f(10, 20, 0)));
    runtime->RegisterNodeScale("anchor", original.get(),
        std::make_unique<DynamicValue>(Eigen::Vector3f(2, 3, 1)));
    runtime->SetNodeAnchorAlignment("anchor", "left bottom", Eigen::Vector3f(10, 20, 0));
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(Eigen::Vector3f(10, 20, 0)));
    runtime->RegisterNodeSize("anchor", Eigen::Vector2f(20, 10));
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(Eigen::Vector3f(30, 35, 0)));
    original->SetTranslate(Eigen::Vector3f(-99, -99, 0));
    original->SetScale(Eigen::Vector3f::Ones());
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(Eigen::Vector3f(30, 35, 0)));
    EXPECT_TRUE(original->Scale().isApprox(Eigen::Vector3f(2, 3, 1)));
    runtime->RegisterNode("anchor", original.get());
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(Eigen::Vector3f(30, 35, 0)));
    runtime->RegisterNodeSize("anchor", Eigen::Vector2f(40, 20));
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(Eigen::Vector3f(50, 50, 0)));

    auto replacement = std::make_shared<SceneNode>();
    runtime->RegisterNode("anchor", replacement.get());
    runtime->SetNodeAnchorAlignment("anchor", "left bottom", Eigen::Vector3f(10, 20, 0));
    runtime->Tick(0.0);
    EXPECT_TRUE(replacement->Translate().isApprox(Eigen::Vector3f(50, 50, 0)));
    EXPECT_TRUE(replacement->Scale().isApprox(Eigen::Vector3f(2, 3, 1)));
}

TEST(ScriptRuntimeCompat, TextReflowInvalidatesAnchoredTranslationWithoutSourceChanges) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNodeTranslate("caption", node.get(),
        std::make_unique<DynamicValue>(Eigen::Vector3f(10, 20, 0)));
    runtime->RegisterTextLayer("caption", TextLayerState {
        .text = "a", .font_key = "Arial", .point_size = 10.0f,
    });
    runtime->SetNodeAnchorAlignment("caption", "left top", Eigen::Vector3f(10, 20, 0));
    runtime->Tick(0.0);
    const auto before = runtime->NodeSize("caption");
    ASSERT_TRUE(runtime->SetNodeText("caption", "a substantially longer caption"));
    for (int attempt = 0; attempt < 200 && runtime->NodeTextDirty("caption"); ++attempt) {
        runtime->PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_FALSE(runtime->NodeTextDirty("caption"));
    const auto size = runtime->NodeSize("caption");
    ASSERT_GT(size.x(), before.x());
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(10 + size.x() * 0.5f, 20 - size.y() * 0.5f, 0)));
    node->SetTranslate(Eigen::Vector3f::Zero());
    runtime->Tick(0.0);
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(10 + size.x() * 0.5f, 20 - size.y() * 0.5f, 0)));
}

TEST(ScriptRuntimeCompat, EffectFinalRepairUsesCurrentParentAttachmentAndResolvedTarget) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto parent = std::make_shared<SceneNode>();
    auto source = std::make_shared<SceneNode>();
    parent->AppendChild(source);
    SceneImageEffectLayer layer(source.get(), 40, 20, "a", "b");
    runtime->RegisterNodeEffectFinal("effect", source.get(), &layer);
    runtime->Tick(0.0);
    layer.FinalNode().ClearRenderTransformOverride();
    parent->SetTranslate(Eigen::Vector3f(7, 8, 0));
    Eigen::Affine3d attachment = Eigen::Affine3d::Identity();
    attachment.translate(Eigen::Vector3d(3, 4, 0));
    source->SetAttachmentTransform(attachment.matrix());
    runtime->Tick(0.0);
    EXPECT_TRUE(layer.FinalNode().HasRenderTransformOverride());
    EXPECT_TRUE(layer.FinalNode().RenderTrans().isApprox(source->ModelTrans(), 1e-12));
    layer.FinalNode().SetRenderTransformOverride(Eigen::Matrix4d::Identity());
    runtime->Tick(0.0);
    EXPECT_TRUE(layer.FinalNode().RenderTrans().isApprox(source->ModelTrans(), 1e-12));
    layer.SetFinalBlend(BlendMode::Normal);
    SceneMesh default_mesh;
    auto effect = std::make_shared<SceneImageEffect>();
    auto first = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    first->AddMesh(mesh);
    effect->nodes.push_back({ std::string(SpecTex_Default), first });
    layer.AddEffect(effect);
    layer.ResolveEffect(default_mesh, "effect");
    runtime->Tick(0.0);
    EXPECT_TRUE(first->RenderTrans().isApprox(source->ModelTrans(), 1e-12));
    auto second = std::make_shared<SceneNode>();
    auto second_mesh = std::make_shared<SceneMesh>();
    second_mesh->AddMaterial(SceneMaterial {});
    second->AddMesh(second_mesh);
    effect->nodes.back().sceneNode = second;
    layer.ResolveEffect(default_mesh, "effect");
    runtime->Tick(0.0);
    EXPECT_TRUE(second->HasRenderTransformOverride());
    EXPECT_TRUE(second->RenderTrans().isApprox(source->ModelTrans(), 1e-12));
}

TEST(ScriptRuntimeCompat, MaterialBindingsRepairCurrentMapsAndPreserveSecondPhasePrecedence) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto material = std::make_shared<SceneMaterial>();
    auto value = std::make_unique<DynamicValue>(std::string("1 2 3"));
    auto* source = value.get();
    runtime->RegisterMaterialConstant(material, "u_Value", std::move(value));
    runtime->RegisterMaterialConstant(material, "u_Null", std::make_unique<DynamicValue>());
    auto alpha = std::make_shared<ScalarAnimationPlayback>();
    runtime->RegisterMaterialAlphaAnimation(material, alpha);
    runtime->RegisterMaterialConstant(material, "g_Alpha", std::make_unique<DynamicValue>(0.75f));
    runtime->RegisterMaterialConstant(material, "u_Duplicate", std::make_unique<DynamicValue>(1.0f));
    runtime->RegisterMaterialConstant(material, "u_Duplicate", std::make_unique<DynamicValue>(2.0f));
    for (int index = 0; index < 3; ++index) {
        material->customShader.constValues.clear();
        runtime->Tick(0.0);
        ASSERT_EQ(material->customShader.constValues.at("u_Value").size(), 3u);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[2], 3.0f);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Null")[0], 0.0f);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Duplicate")[0], 2.0f);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Alpha")[0], 0.75f);
    }
    source->update(std::string("4 5"));
    runtime->Tick(0.0);
    ASSERT_EQ(material->customShader.constValues.at("u_Value").size(), 2u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[1], 5.0f);
    material->customShader.constValues["u_Value"] = ShaderValue(9.0f);
    runtime->Tick(0.0);
    EXPECT_EQ(material->customShader.constValues.at("u_Value").size(), 2u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[0], 4.0f);
}

TEST(ScriptRuntimeCompat, FailedRegistrationReleasesListenersAndMaterialTargetsOnlyInItsTail) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"amount", RuntimeScalarValue::Float(1.0f)}},
    });
    auto survivor = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(survivor, "u_Value",
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}));
    int survivor_calls = 0;
    runtime->RegisterDynamicValueListener(
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}),
        [&](const DynamicValue&) { ++survivor_calls; });
    auto old_node = std::make_shared<SceneNode>();
    runtime->RegisterNode("transaction", old_node.get());
    const auto snapshot = runtime->CaptureNodeRegistration("transaction");
    auto failed_node = std::make_shared<SceneNode>();
    runtime->RegisterNode("transaction", failed_node.get());
    auto failed_material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(failed_material, "u_Value",
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}));
    int failed_calls = 0;
    auto held = std::make_shared<int>(42);
    std::weak_ptr<int> resource = held;
    runtime->RegisterDynamicValueListener(
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}),
        [held, &failed_calls](const DynamicValue&) { ++failed_calls; });
    held.reset();
    ASSERT_FALSE(resource.expired());
    runtime->RollbackNodeRegistration("transaction", failed_node.get(), snapshot);
    EXPECT_TRUE(resource.expired());
    failed_material->customShader.constValues["u_Value"] = ShaderValue(91.0f);
    runtime->ApplyProjectPropertyOverride({{"amount", RuntimeScalarValue::Float(7.0f)}});
    runtime->Tick(0.0);
    EXPECT_EQ(failed_calls, 1);
    EXPECT_EQ(survivor_calls, 2);
    EXPECT_FLOAT_EQ(failed_material->customShader.constValues.at("u_Value")[0], 91.0f);
    EXPECT_FLOAT_EQ(survivor->customShader.constValues.at("u_Value")[0], 7.0f);
    EXPECT_TRUE(runtime->HasNodeNamed("transaction"));
    runtime->SetNodeTranslate("transaction", Eigen::Vector3f(4, 5, 0));
    EXPECT_TRUE(old_node->Translate().isApprox(Eigen::Vector3f(4, 5, 0)));
}

TEST(ShaderValueUpdaterCompat, AudioDiscoveryDoesNotAffectUnrelatedMaterialSlots) {
    struct ResetAudioOnExit {
        ~ResetAudioOnExit() { audio::ResetAudioResponseServiceForTesting(); }
    } reset_audio;
    audio::AudioSpectrumSnapshot snapshot;
    snapshot.left64.fill(0.5f);
    audio::SetAudioSpectrumSnapshotForTesting(snapshot);
    Scene scene;
    SceneCamera camera(1920, 1080, 0.01f, 1000.0f);
    scene.activeCamera = &camera;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    scene.runtime->AttachScene(&scene);
    scene.runtime->SetAudioResponseEnabled(true);
    scene.elapsingTime = 2.0;
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    WPShaderValueUpdater updater(&scene);
    const ExistsUniformOp time_only = [](std::string_view name) { return name == "g_Time"; };
    updater.InitUniforms(node.get(), 0, time_only);
    updater.InitUniforms(node.get(), 0, time_only);
    EXPECT_FALSE(scene.runtime->AudioResponseActive());
    sprite_map_t sprites;
    std::vector<std::string> names;
    const UpdateUniformOp capture = [&](std::string_view name, const ShaderValue& value) {
        names.emplace_back(name);
        if (name == "g_Time") {
            ASSERT_EQ(value.size(), 1u);
            EXPECT_FLOAT_EQ(value[0], 2.0f);
        }
    };
    updater.UpdateUniforms(node.get(), 0, sprites, capture);
    EXPECT_EQ(names, std::vector<std::string> { "g_Time" });
    updater.InitUniforms(node.get(), 1, [](std::string_view name) {
        return name == "g_AudioSpectrum64Left";
    });
    EXPECT_TRUE(scene.runtime->AudioResponseActive());
    names.clear();
    updater.UpdateUniforms(node.get(), 0, sprites, capture);
    EXPECT_EQ(names, std::vector<std::string> { "g_Time" });
    updater.UpdateUniforms(node.get(), 1, sprites, [&](std::string_view name, const ShaderValue& value) {
        EXPECT_EQ(name, "g_AudioSpectrum64Left");
        ASSERT_EQ(value.size(), 256u);
        for (std::size_t i = 0; i < value.size(); ++i) {
            EXPECT_FLOAT_EQ(value[i], i % 4 == 0 ? 0.5f : 0.0f);
        }
    });
    scene.activeCamera = nullptr;
}

TEST(ShaderValueUpdaterCompat, EmptyPuppetPosesDoNotEmitBoneUniforms) {
    Scene scene;
    SceneCamera camera(1920, 1080, 0.01f, 1000.0f);
    scene.activeCamera = &camera;
    scene.elapsingTime = 2.0;
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_Bones" || name == "g_Time";
    });
    auto empty_asset = std::make_shared<WPPuppet>();
    empty_asset->prepared();
    const std::array<WPPuppetLayer, 3> empty_layers {
        WPPuppetLayer {}, WPPuppetLayer { std::shared_ptr<WPPuppet> {} }, WPPuppetLayer { empty_asset }
    };
    sprite_map_t sprites;
    for (const auto& layer : empty_layers) {
        WPShaderValueData data;
        data.puppet_layer = layer;
        updater.SetNodeData(node.get(), data);
        std::vector<std::string> names;
        updater.UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
            names.emplace_back(name);
            if (name == "g_Time") {
                ASSERT_EQ(value.size(), 1u);
                EXPECT_FLOAT_EQ(value[0], 2.0f);
            }
        });
        EXPECT_EQ(names, std::vector<std::string> { "g_Time" });
    }
    auto asset = std::make_shared<WPPuppet>();
    asset->bones.emplace_back();
    asset->prepared();
    WPShaderValueData data;
    data.puppet_layer = WPPuppetLayer { asset };
    updater.SetNodeData(node.get(), data);
    std::vector<std::string> names;
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
        names.emplace_back(name);
        if (name == "g_Bones") {
            ASSERT_EQ(value.size(), 16u);
            for (std::size_t i = 0; i < value.size(); ++i) {
                EXPECT_FLOAT_EQ(value[i], i % 5 == 0 ? 1.0f : 0.0f);
            }
        }
    });
    EXPECT_EQ(names, (std::vector<std::string> { "g_Bones", "g_Time" }));
    scene.activeCamera = nullptr;
}

TEST(ScriptRuntimeCompat, CursorCoveragePreservesAllPhasesThresholdsAndLiveTransforms) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto target = std::make_shared<SceneNode>();
    auto marker = std::make_shared<SceneNode>();
    target->SetTranslate(Eigen::Vector3f(100, 100, 0));
    target->SetRotation(Eigen::Vector3f(0, 0, 0.5f));
    target->SetScale(Eigen::Vector3f(-2, 1, 1));
    runtime->RegisterNode("target", target.get());
    runtime->RegisterNodeSize("target", Eigen::Vector2f(40, 20));
    runtime->RegisterNodeHitMask("target", NodeHitMask { .width = 2, .height = 1, .alpha = {15, 16} });
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterNodeVisibility("target", target.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
function emit(n) {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x = origin.x * 10 + n;
    marker.origin = origin;
}
function cursorEnter() { emit(1); }
function cursorMove() { emit(2); }
function cursorDown() { emit(3); }
function cursorClick() { emit(4); }
function cursorUp() { emit(5); }
function cursorLeave() { emit(6); }
)JS"},
    }, "target"));
    runtime->RegisterSceneScript(
        R"JS(scene.on('cursorClick', function() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.y += 1;
    marker.origin = origin;
});)JS",
        "target");
    runtime->Tick(0.0);
    runtime->SetCursorEnter(true);
    const auto point = [&](float local_x) {
        target->UpdateTrans();
        const Eigen::Vector4d world = target->ModelTrans() * Eigen::Vector4d(local_x, 0, 0, 1);
        runtime->SetCursorWorldPosition(world.head<3>().cast<float>());
    };
    point(-10);
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 0);
    EXPECT_FLOAT_EQ(marker->Translate().y(), 0);
    point(10);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 12345);
    EXPECT_FLOAT_EQ(marker->Translate().y(), 1);
    runtime->BeginFrame();
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 123452);
    point(-10);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 1234526);
    runtime->SetNodeTranslate("marker", Eigen::Vector3f::Zero());
    target->SetRotation(Eigen::Vector3f::Zero());
    target->SetScale(Eigen::Vector3f(-1, 1, 1));
    point(20);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 12);
    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0, 0, 1);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 126);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, CursorCallbacksRecheckLaterTargetsWithoutAddingVisibilityFiltering) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto first = std::make_shared<SceneNode>();
    auto second = std::make_shared<SceneNode>();
    auto marker = std::make_shared<SceneNode>();
    runtime->RegisterNode("first", first.get());
    runtime->RegisterNodeSize("first", Eigen::Vector2f(40, 40));
    runtime->RegisterNode("second", second.get());
    runtime->RegisterNodeSize("second", Eigen::Vector2f(40, 40));
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterNodeVisibility("first", first.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
let calls = 0;
function cursorClick() {
    const next = thisScene.getLayer('second');
    const origin = next.origin;
    origin.x = ++calls === 1 ? 100 : 0;
    next.origin = origin;
    next.visible = false;
}
)JS"},
    }, "first"));
    runtime->RegisterNodeVisibility("second", second.get(), ResolveBoolSetting(*runtime, {
        {"value", true},
        {"script", R"JS(function cursorClick() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x += 1;
    marker.origin = origin;
})JS"},
    }, "second"));
    runtime->Tick(0.0);
    runtime->SetCursorWorldPosition(Eigen::Vector3f::Zero());
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 0);
    EXPECT_FLOAT_EQ(second->Translate().x(), 100);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(second->Translate().x(), 0);
    EXPECT_FALSE(second->Visible());
    EXPECT_FLOAT_EQ(marker->Translate().x(), 1);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, RollbackRestoresCoverageAndSharedPuppetAndHonorsIdentity) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    runtime->RegisterNodeSize("subject", Eigen::Vector2f(40, 40));
    runtime->RegisterNodeHitMask("subject", NodeHitMask { .width = 1, .height = 1, .alpha = {0} });
    WPPuppetLayer layer(MakeSingleShotPuppet());
    WPPuppetLayer::AnimationLayer authored;
    authored.id = 7;
    layer.prepared(std::span(&authored, 1));
    ASSERT_TRUE(layer.setFrame(0, 2.5));
    runtime->RegisterPuppetLayer("subject", layer);
    const auto snapshot = runtime->CaptureNodeRegistration("subject");
    auto failed = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", failed.get());
    runtime->RegisterNodeHitMask("subject", NodeHitMask { .width = 1, .height = 1, .alpha = {255} });
    runtime->RegisterPuppetLayer("subject", WPPuppetLayer(MakeSingleShotPuppet()));
    runtime->RollbackNodeRegistration("subject", failed.get(), snapshot);
    ASSERT_NE(runtime->FindPuppetLayer("subject"), nullptr);
    EXPECT_FLOAT_EQ(runtime->FindPuppetLayer("subject")->genFrame(0)[0].translation().x(), 2.5f);
    ASSERT_TRUE(runtime->FindPuppetLayer("subject")->setFrame(0, 3.5));
    EXPECT_FLOAT_EQ(layer.genFrame(0)[0].translation().x(), 3.5f);
    runtime->RegisterSceneScript("function cursorClick() { thisLayer.visible = false; }", "subject");
    runtime->SetCursorEnter(true);
    runtime->SetCursorWorldPosition(Eigen::Vector3f::Zero());
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_TRUE(node->Visible());

    auto replacement = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", replacement.get());
    runtime->RollbackNodeRegistration("subject", failed.get(), snapshot);
    runtime->SetNodeTranslate("subject", Eigen::Vector3f(1, 2, 0));
    EXPECT_TRUE(replacement->Translate().isApprox(Eigen::Vector3f(1, 2, 0)));
    runtime->RollbackNodeRegistration("subject", replacement.get(), nullptr);
    EXPECT_EQ(runtime->FindPuppetLayer("subject"), nullptr);
    auto fresh = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", fresh.get());
    runtime->RegisterNodeSize("subject", Eigen::Vector2f(40, 40));
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FALSE(fresh->Visible());
}

TEST(ScriptRuntimeCompat, MaterialSecondPhaseRepairsSceneCallbackWrites) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "u_Value", std::make_unique<DynamicValue>(3.0f));
    auto visible = std::make_unique<DynamicValue>(true);
    int writes = 0;
    visible->listen([&](const DynamicValue&) {
        material->customShader.constValues["u_Value"] = ShaderValue(91.0f);
        ++writes;
    });
    runtime->RegisterNodeVisibility("subject", node.get(), std::move(visible));
    runtime->RegisterSceneScript("function update() { thisLayer.visible = !thisLayer.visible; }", "subject");
    for (int frame = 0; frame < 3; ++frame) {
        runtime->Tick(0.0);
        EXPECT_EQ(writes, frame + 1);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[0], 3.0f);
    }
}

TEST(ScriptRuntimeCompat, CloneGrowthSharesSourcesButRepairsIndependentDestinations) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto source_node = std::make_shared<SceneNode>(
        Eigen::Vector3f::Zero(), Eigen::Vector3f::Ones(), Eigen::Vector3f::Zero(), "source");
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(source_node);
    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/template.json", source_node, Eigen::Vector2f(20, 20));
    auto value = std::make_unique<DynamicValue>(2.0f);
    auto* source = value.get();
    runtime->RegisterMaterialConstant(mesh->MaterialSlotPtr(), "u_Value", std::move(value));
    for (int index = 0; index < 40; ++index) {
        ASSERT_FALSE(runtime->CreateLayerFromTemplate("models/template.json", "source").empty());
    }
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 41u);
    source->update(7.0f);
    runtime->Tick(0.0);
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        EXPECT_FLOAT_EQ(child->Mesh()->Material()->customShader.constValues.at("u_Value")[0], 7.0f);
        if (child.get() != source_node.get()) child->Mesh()->Material()->customShader.constValues.clear();
    }
    EXPECT_FLOAT_EQ(mesh->Material()->customShader.constValues.at("u_Value")[0], 7.0f);
    runtime->Tick(0.0);
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        EXPECT_FLOAT_EQ(child->Mesh()->Material()->customShader.constValues.at("u_Value")[0], 7.0f);
    }
}

TEST(ScriptRuntimeCompat, RollbackDropsNewAnimationsAndAlphaButPreservesReusedPlayback) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    ScalarAnimation animation {
        .initial_value = 1.0f, .fps = 10.0, .length_frames = 100.0,
        .name = "survivor",
        .keyframes = {{.frame = 0.0, .value = 1.0f}, {.frame = 100.0, .value = 11.0f}},
    };
    auto survivor = runtime->RegisterScalarAnimation("subject", animation);
    runtime->Tick(0.2);
    const auto snapshot = runtime->CaptureNodeRegistration("subject");
    auto failed_node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", failed_node.get());
    auto reused = runtime->RegisterScalarAnimation("subject", animation);
    reused->SetFrame(5.0);
    animation.name = "failed";
    auto failed_playback = runtime->RegisterScalarAnimation("subject", animation);
    std::weak_ptr<ScalarAnimationPlayback> failed_owner = failed_playback;
    auto failed_material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialAlphaAnimation(failed_material, failed_playback);
    failed_playback.reset();
    runtime->RollbackNodeRegistration("subject", failed_node.get(), snapshot);
    EXPECT_TRUE(failed_owner.expired());
    EXPECT_EQ(runtime->FindScalarAnimation("subject", "failed"), nullptr);
    EXPECT_DOUBLE_EQ(survivor->frame, 5.0);
    failed_material->customShader.constValues["g_UserAlpha"] = ShaderValue(91.0f);
    runtime->Tick(0.2);
    EXPECT_DOUBLE_EQ(survivor->frame, 7.0);
    EXPECT_FLOAT_EQ(failed_material->customShader.constValues.at("g_UserAlpha")[0], 91.0f);
}

} // namespace
} // namespace wallpaper
