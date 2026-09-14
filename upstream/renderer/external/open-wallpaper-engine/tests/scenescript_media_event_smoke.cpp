#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <memory>

namespace wallpaper
{
namespace
{

struct RuntimeWithProbeNodes {
    std::shared_ptr<SceneNode>           exported_probe;
    std::shared_ptr<SceneNode>           callback_probe;
    std::unique_ptr<SceneRuntimeContext> runtime;
};

RuntimeWithProbeNodes CreateRuntimeWithProbeNodes() {
    RuntimeWithProbeNodes fixture;
    fixture.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 3840,
        .canvas_height = 2160,
    });
    if (fixture.runtime == nullptr) return fixture;

    fixture.exported_probe = std::make_shared<SceneNode>();
    fixture.callback_probe = std::make_shared<SceneNode>();
    fixture.exported_probe->SetVisible(false);
    fixture.callback_probe->SetVisible(false);

    fixture.runtime->RegisterNode("exportedProbe", fixture.exported_probe.get());
    fixture.runtime->RegisterNode("callbackProbe", fixture.callback_probe.get());
    return fixture;
}

TEST(SceneScriptMediaEventSmoke, ExportedHandlerAndSceneCallbackReceivePlaybackEvent) {
    auto fixture = CreateRuntimeWithProbeNodes();
    ASSERT_NE(fixture.runtime, nullptr);
    ASSERT_FALSE(fixture.runtime->NodeVisible("exportedProbe"));
    ASSERT_FALSE(fixture.runtime->NodeVisible("callbackProbe"));

    fixture.runtime->RegisterSceneScript(
        R"JS(
function mediaPlaybackChanged(event) {
  if (event.state === 0) {
    scene.getObject('exportedProbe').visible = true;
  }
}

scene.on('mediaPlaybackChanged', function(event) {
  if (event.state === 0) {
    scene.getObject('callbackProbe').visible = true;
  }
});
)JS",
        "");
    ASSERT_EQ(fixture.runtime->sceneScriptCount(), 1u);

    fixture.runtime->SetMediaIntegrationEnabled(true);
    fixture.runtime->DispatchMediaEventJson(R"({"type":"mediaPlaybackChanged","state":0})");

    EXPECT_TRUE(fixture.runtime->NodeVisible("exportedProbe"));
    EXPECT_TRUE(fixture.runtime->NodeVisible("callbackProbe"));
    EXPECT_EQ(fixture.runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, DisabledMediaIntegrationSuppressesPlaybackEvents) {
    auto fixture = CreateRuntimeWithProbeNodes();
    ASSERT_NE(fixture.runtime, nullptr);

    fixture.runtime->RegisterSceneScript(
        R"JS(
function mediaPlaybackChanged(event) {
  scene.getObject('exportedProbe').visible = true;
}

scene.on('mediaPlaybackChanged', function(event) {
  scene.getObject('callbackProbe').visible = true;
});
)JS",
        "");
    ASSERT_EQ(fixture.runtime->sceneScriptCount(), 1u);

    fixture.runtime->SetMediaIntegrationEnabled(false);
    fixture.runtime->DispatchMediaEventJson(R"({"type":"mediaPlaybackChanged","state":0})");

    EXPECT_FALSE(fixture.runtime->NodeVisible("exportedProbe"));
    EXPECT_FALSE(fixture.runtime->NodeVisible("callbackProbe"));
    EXPECT_EQ(fixture.runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, VideoPlaybackControlsResolveWrappedState) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    runtime->RegisterNodeVideoTexture("videoLayer", "textures/clip.mp4");
    runtime->SetVideoTextureDuration("textures/clip.mp4", 3.0);

    EXPECT_TRUE(runtime->PauseNodeVideoTexture("videoLayer"));
    EXPECT_TRUE(runtime->SetNodeVideoTextureCurrentTime("videoLayer", 7.5));
    EXPECT_TRUE(runtime->SetNodeVideoTextureRate("videoLayer", -2.0f));

    const auto state = runtime->ResolveVideoPlaybackState("textures/clip.mp4", 99.0);
    EXPECT_TRUE(state.paused);
    EXPECT_FLOAT_EQ(state.rate, 0.0f);
    EXPECT_DOUBLE_EQ(state.scene_elapsed_seconds, 1.5);
}

TEST(SceneScriptMediaEventSmoke, VideoPlaybackControlsApplyToAllTexturesOnSameNode) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    runtime->RegisterNodeVideoTexture("videoLayer", "textures/diffuse.mp4");
    runtime->RegisterNodeVideoTexture("videoLayer", "textures/mask.mp4");
    runtime->SetVideoTextureDuration("textures/diffuse.mp4", 3.0);
    runtime->SetVideoTextureDuration("textures/mask.mp4", 5.0);

    EXPECT_TRUE(runtime->PauseNodeVideoTexture("videoLayer"));
    EXPECT_TRUE(runtime->SetNodeVideoTextureCurrentTime("videoLayer", 7.5));
    EXPECT_TRUE(runtime->SetNodeVideoTextureRate("videoLayer", 0.25f));

    const auto diffuse_state = runtime->ResolveVideoPlaybackState("textures/diffuse.mp4", 99.0);
    EXPECT_TRUE(diffuse_state.paused);
    EXPECT_FLOAT_EQ(diffuse_state.rate, 0.25f);
    EXPECT_DOUBLE_EQ(diffuse_state.scene_elapsed_seconds, 1.5);

    const auto mask_state = runtime->ResolveVideoPlaybackState("textures/mask.mp4", 99.0);
    EXPECT_TRUE(mask_state.paused);
    EXPECT_FLOAT_EQ(mask_state.rate, 0.25f);
    EXPECT_DOUBLE_EQ(mask_state.scene_elapsed_seconds, 2.5);
}

TEST(SceneScriptMediaEventSmoke, MissingVideoPlaybackUsesFallbackElapsedTime) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    const auto state = runtime->ResolveVideoPlaybackState("textures/missing.mp4", 12.25);
    EXPECT_FALSE(state.paused);
    EXPECT_FLOAT_EQ(state.rate, 1.0f);
    EXPECT_DOUBLE_EQ(state.scene_elapsed_seconds, 12.25);
}

TEST(SceneScriptMediaEventSmoke, StringBackedVec3ProjectPropertyKeepsVectorValue) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "scale", RuntimeScalarValue::String("2 3 4") },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("probe", node.get());
    runtime->RegisterNodeScale(
        "probe",
        node.get(),
        ResolveVec3Setting(
            *runtime,
            nlohmann::json {
                { "user", "scale" },
                { "value", "1 1 1" },
            },
            "probe"));

    EXPECT_FLOAT_EQ(runtime->NodeScale("probe").x(), 2.0f);
    EXPECT_FLOAT_EQ(runtime->NodeScale("probe").y(), 3.0f);
    EXPECT_FLOAT_EQ(runtime->NodeScale("probe").z(), 4.0f);

    runtime->ApplyProjectPropertyOverride({
        { "scale", RuntimeScalarValue::String("5 6 7") },
    });
    runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(runtime->NodeScale("probe").x(), 5.0f);
    EXPECT_FLOAT_EQ(runtime->NodeScale("probe").y(), 6.0f);
    EXPECT_FLOAT_EQ(runtime->NodeScale("probe").z(), 7.0f);
}

TEST(SceneScriptMediaEventSmoke, UserBoundScriptedVisibleCanHideLayer) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "newproperty24", RuntimeScalarValue::Bool(false) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNodeVisibility(
        "part",
        node.get(),
        ResolveBoolSetting(
            *runtime,
            nlohmann::json {
                { "script", "export function update(value) { return value; }" },
                { "user", "newproperty24" },
                { "value", true },
            },
            "part"));

    runtime->Tick(1.0 / 60.0);

    EXPECT_FALSE(runtime->NodeVisible("part"));
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, UserBoundScriptedVisibleIgnoresObjectReturn) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "newproperty24", RuntimeScalarValue::Bool(false) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNodeVisibility(
        "part",
        node.get(),
        ResolveBoolSetting(
            *runtime,
            nlohmann::json {
                {
                    "script",
                    R"JS(
var weizhi = { x: 1, y: 2, z: 3 };

export function init(value) {
  return value;
}

export function update(value) {
  return weizhi;
}
)JS",
                },
                { "user", "newproperty24" },
                { "value", true },
            },
            "part"));

    EXPECT_FALSE(runtime->NodeVisible("part"));
    EXPECT_FALSE(node->Visible());

    runtime->Tick(1.0 / 60.0);
    runtime->Tick(3.0);

    EXPECT_FALSE(runtime->NodeVisible("part"));
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, UserBoundScriptedVisibleKeepsLaterOverride) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "newproperty24", RuntimeScalarValue::Bool(true) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNodeVisibility(
        "part",
        node.get(),
        ResolveBoolSetting(
            *runtime,
            nlohmann::json {
                {
                    "script",
                    R"JS(
var weizhi = { x: 1, y: 2, z: 3 };

export function init(value) {
  weizhi = value;
  return value;
}

export function update(value) {
  return weizhi;
}
)JS",
                },
                { "user", "newproperty24" },
                { "value", true },
            },
            "part"));

    runtime->ApplyProjectPropertyOverride({
        { "newproperty24", RuntimeScalarValue::Bool(false) },
    });
    runtime->Tick(1.0 / 60.0);
    runtime->Tick(3.0);

    EXPECT_FALSE(runtime->NodeVisible("part"));
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, ScriptPropertyOverrideDrivesLayerOrigin) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 3840,
        .canvas_height = 2160,
        .project_properties = {
            { "x", RuntimeScalarValue::Float(0.8f) },
            { "y", RuntimeScalarValue::Float(0.25f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("Clock", node.get());
    runtime->RegisterNodeTranslate(
        "Clock",
        node.get(),
        ResolveVec3Setting(
            *runtime,
            nlohmann::json {
                {
                    "script",
                    R"JS(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'x', value: 0.5 })
  .addSlider({ name: 'y', value: 0.5 })
  .finish();

export function update(value) {
  value.x = scriptProperties.x * engine.canvasSize.x;
  value.y = scriptProperties.y * engine.canvasSize.y;
  return value;
}
)JS",
                },
                {
                    "scriptproperties",
                    {
                        { "x", { { "user", "x" }, { "value", 1.0f } } },
                        { "y", { { "user", "y" }, { "value", 1.0f } } },
                    },
                },
                { "value", "0.00000 0.00000 0.00000" },
            },
            "Clock"));

    runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(runtime->NodeTranslate("Clock").x(), 3072.0f);
    EXPECT_FLOAT_EQ(runtime->NodeTranslate("Clock").y(), 540.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, BottomAlignedLayerScalesUpFromBottomEdge) {
    auto fixture = CreateRuntimeWithProbeNodes();
    ASSERT_NE(fixture.runtime, nullptr);

    fixture.exported_probe->SetTranslate(Eigen::Vector3f(100.0f, 50.0f, 0.0f));
    fixture.exported_probe->SetScale(Eigen::Vector3f(1.0f, 1.0f, 1.0f));
    fixture.runtime->RegisterNode("exportedProbe", fixture.exported_probe.get());
    fixture.runtime->RegisterNodeSize("exportedProbe", Eigen::Vector2f(20.0f, 10.0f));

    fixture.runtime->RegisterSceneScript(
        R"JS(
function update() {
  var bar = scene.getObject('exportedProbe');
  bar.alignment = 'bottom';
  bar.scale = new Vec3(1, 4, 1);
  bar.origin = new Vec3(100, 50, 0);
}
)JS",
        "");
    ASSERT_EQ(fixture.runtime->sceneScriptCount(), 1u);

    fixture.runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(fixture.runtime->NodeScale("exportedProbe").y(), 4.0f);
    EXPECT_FLOAT_EQ(fixture.runtime->NodeTranslate("exportedProbe").x(), 100.0f);
    EXPECT_FLOAT_EQ(fixture.runtime->NodeTranslate("exportedProbe").y(), 50.0f);
    EXPECT_FLOAT_EQ(fixture.exported_probe->Translate().y(), 65.0f);
    EXPECT_EQ(fixture.runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, BottomAlignedLayerAppliesRenderedTransform) {
    auto fixture = CreateRuntimeWithProbeNodes();
    ASSERT_NE(fixture.runtime, nullptr);

    fixture.exported_probe->SetTranslate(Eigen::Vector3f(100.0f, 50.0f, 0.0f));
    fixture.exported_probe->SetScale(Eigen::Vector3f(1.0f, 1.0f, 1.0f));
    fixture.runtime->RegisterNode("exportedProbe", fixture.exported_probe.get());
    fixture.runtime->RegisterNodeSize("exportedProbe", Eigen::Vector2f(20.0f, 10.0f));

    fixture.runtime->RegisterSceneScript(
        R"JS(
function update() {
  var bar = scene.getObject('exportedProbe');
  bar.alignment = 'bottom';
  bar.scale = new Vec3(3, 4, 1);
  bar.origin = new Vec3(100, 50, 0);
}
)JS",
        "");

    fixture.runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(fixture.runtime->NodeScale("exportedProbe").x(), 3.0f);
    EXPECT_FLOAT_EQ(fixture.runtime->NodeScale("exportedProbe").y(), 4.0f);
    EXPECT_FLOAT_EQ(fixture.runtime->NodeTranslate("exportedProbe").x(), 100.0f);
    EXPECT_FLOAT_EQ(fixture.runtime->NodeTranslate("exportedProbe").y(), 50.0f);
    EXPECT_FLOAT_EQ(fixture.exported_probe->Translate().x(), 100.0f);
    EXPECT_FLOAT_EQ(fixture.exported_probe->Translate().y(), 65.0f);
    EXPECT_EQ(fixture.runtime->scriptErrorCount(), 0u);
}

TEST(SceneScriptMediaEventSmoke, VisualizerScriptPropertiesDriveLayerScale) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "newproperty10", RuntimeScalarValue::Float(3.0f) },
            { "newproperty11", RuntimeScalarValue::Float(30.0f) },
            { "yp", RuntimeScalarValue::Bool(true) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("Simple Visualizer", node.get());
    runtime->RegisterNodeVisibility(
        "Simple Visualizer",
        node.get(),
        ResolveBoolSetting(
            *runtime,
            nlohmann::json {
                {
                    "script",
                    R"JS(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'barWidth', value: 5 })
  .addSlider({ name: 'scaleY', value: 60 })
  .finish();

export function update(value) {
  thisLayer.scale = new Vec3(scriptProperties.barWidth, scriptProperties.scaleY, 1);
  return value;
}
)JS",
                },
                {
                    "scriptproperties",
                    {
                        { "barWidth", { { "user", "newproperty10" }, { "value", 5.0f } } },
                        { "scaleY", { { "user", "newproperty11" }, { "value", 60.0f } } },
                    },
                },
                { "user", "yp" },
                { "value", true },
            },
            "Simple Visualizer"));

    runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(runtime->NodeScale("Simple Visualizer").x(), 3.0f);
    EXPECT_FLOAT_EQ(runtime->NodeScale("Simple Visualizer").y(), 30.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

} // namespace
} // namespace wallpaper
