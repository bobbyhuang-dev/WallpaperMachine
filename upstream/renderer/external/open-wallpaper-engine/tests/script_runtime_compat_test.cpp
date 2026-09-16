#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "WPShaderValueUpdater.hpp"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scripting/ScriptEngine.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <iterator>
#include <memory>
#include <thread>
#include <unordered_map>

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
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view n, ShaderValue v) {
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
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view n, ShaderValue v) {
        if (n == "g_ModelViewProjectionMatrix") actual = v;
    });
    const auto second_expected =
        ShaderValue::fromMatrix(screen->GetViewProjectionMatrix() * node->ModelTrans());
    ASSERT_EQ(actual.size(), second_expected.size());
    for (std::size_t i = 0; i < actual.size(); ++i) {
        EXPECT_NEAR(actual[i], second_expected[i], 1e-5);
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
    runtime->RegisterMaterialConstant(material, "u_Opacity", std::make_unique<DynamicValue>(1.5f),
        runtime->RegisterScalarAnimation("subject", *animation));
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
    audio::ResetAudioResponseServiceForTesting();

    std::array<float, 200> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = std::sin(static_cast<float>(index) * 0.05f);
    }

    std::string error;
    for (uint32_t submit = 0; submit < 6u; ++submit) {
        ASSERT_TRUE(audio::SubmitMonoAudioFrames(
            12000u,
            static_cast<uint32_t>(samples.size()),
            samples.data(),
            &error))
            << error;
    }

    audio::AudioSpectrumSnapshot snapshot {};
    for (int attempt = 0; attempt < 100; ++attempt) {
        snapshot = audio::CurrentAudioSpectrumSnapshot();
        if (snapshot.generation > 0u) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_GT(snapshot.generation, 0u);

    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    scene.runtime->AttachScene(&scene);
    scene.runtime->MarkSceneRequiresAudioResponse();
    scene.runtime->SetAudioResponseEnabled(true);
    scene.activeCamera = new SceneCamera(1920, 1080, 0.01f, 1000.0f);

    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);

    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_AudioSpectrum16Left" || name == "g_AudioSpectrum16Right" ||
               name == "g_AudioSpectrum32Left" || name == "g_AudioSpectrum32Right" ||
               name == "g_AudioSpectrum64Left" || name == "g_AudioSpectrum64Right";
    });

    sprite_map_t values;
    std::unordered_map<std::string, ShaderValue> updates;
    updater.UpdateUniforms(node.get(), values, [&](std::string_view name, ShaderValue value) {
        updates.emplace(std::string(name), std::move(value));
    });

    auto expect_packed = [&](const char* name, const auto& source, std::size_t count) {
        const auto it = updates.find(name);
        ASSERT_NE(it, updates.end()) << name;
        ASSERT_EQ(it->second.size(), count * 4u) << name;
        for (std::size_t index = 0; index < count; ++index) {
            EXPECT_FLOAT_EQ(it->second[index * 4u], source[index]) << name << "[" << index << "]";
            EXPECT_FLOAT_EQ(it->second[index * 4u + 1u], 0.0f) << name << "[" << index << "].y";
            EXPECT_FLOAT_EQ(it->second[index * 4u + 2u], 0.0f) << name << "[" << index << "].z";
            EXPECT_FLOAT_EQ(it->second[index * 4u + 3u], 0.0f) << name << "[" << index << "].w";
        }
    };

    expect_packed("g_AudioSpectrum16Left", snapshot.left16, snapshot.left16.size());
    expect_packed("g_AudioSpectrum16Right", snapshot.right16, snapshot.right16.size());
    expect_packed("g_AudioSpectrum32Left", snapshot.left32, snapshot.left32.size());
    expect_packed("g_AudioSpectrum32Right", snapshot.right32, snapshot.right32.size());
    expect_packed("g_AudioSpectrum64Left", snapshot.left64, snapshot.left64.size());
    expect_packed("g_AudioSpectrum64Right", snapshot.right64, snapshot.right64.size());

    delete scene.activeCamera;
    scene.activeCamera = nullptr;
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
        [&](std::string_view name, ShaderValue value) {
            slot_zero_updates.emplace(std::string(name), std::move(value));
        });

    sprite_map_t slot_one_sprites;
    std::unordered_map<std::string, ShaderValue> slot_one_updates;
    updater.UpdateUniforms(
        node.get(),
        1,
        slot_one_sprites,
        [&](std::string_view name, ShaderValue value) {
            slot_one_updates.emplace(std::string(name), std::move(value));
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
    updater.UpdateUniforms(node.get(), 1, sprites, [&](std::string_view name, ShaderValue value) {
        updates.emplace(std::string(name), std::move(value));
    });

    EXPECT_TRUE(updates.contains("g_Time"));

    delete scene.activeCamera;
    scene.activeCamera = nullptr;
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
        [&](std::string_view name, ShaderValue value) {
            slot_zero_updates.emplace(std::string(name), std::move(value));
        });

    sprite_map_t slot_one_sprites;
    std::unordered_map<std::string, ShaderValue> slot_one_updates;
    updater.UpdateUniforms(
        node.get(),
        1,
        slot_one_sprites,
        [&](std::string_view name, ShaderValue value) {
            slot_one_updates.emplace(std::string(name), std::move(value));
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

} // namespace
} // namespace wallpaper
