#include "Runtime/SceneRuntimeContext.hpp"
#include "Scripting/ScriptEngine.hpp"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>

namespace wallpaper
{
namespace
{

TEST(MouseInput, FrameInputsExposeCursorPositionEnterAndButtons) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButton(0, true);

    const auto& first = runtime->hostContext();
    EXPECT_FLOAT_EQ(first.cursor_normalized_position.x(), 0.25f);
    EXPECT_FLOAT_EQ(first.cursor_normalized_position.y(), 0.75f);
    EXPECT_TRUE(first.cursor_in_window);
    EXPECT_EQ(first.mouse_buttons_down, 1u);
    EXPECT_EQ(first.mouse_buttons_pressed, 1u);
    EXPECT_EQ(first.mouse_buttons_released, 0u);

    runtime->BeginFrame();
    const auto& held = runtime->hostContext();
    EXPECT_EQ(held.mouse_buttons_down, 1u);
    EXPECT_EQ(held.mouse_buttons_pressed, 0u);
    EXPECT_EQ(held.mouse_buttons_released, 0u);

    runtime->SetCursorButton(0, false);
    const auto& released = runtime->hostContext();
    EXPECT_EQ(released.mouse_buttons_down, 0u);
    EXPECT_EQ(released.mouse_buttons_pressed, 0u);
    EXPECT_EQ(released.mouse_buttons_released, 1u);

    runtime->SetCursorEnter(false);
    EXPECT_FALSE(runtime->hostContext().cursor_in_window);
}

TEST(MouseInput, ButtonEdgesOnlyTrackRealStateTransitions) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    runtime->SetCursorButton(0, true);
    runtime->BeginFrame();
    runtime->SetCursorButton(0, true);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_down, 1u);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_pressed, 0u);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_released, 0u);

    runtime->SetCursorButton(0, false);
    runtime->BeginFrame();
    runtime->SetCursorButton(0, false);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_down, 0u);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_pressed, 0u);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_released, 0u);

    runtime->SetCursorButton(1, false);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_down, 0u);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_pressed, 0u);
    EXPECT_EQ(runtime->hostContext().mouse_buttons_released, 0u);
}

TEST(MouseInput, NormalizedCursorInputIsClamped) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    runtime->SetCursorInput(-0.25f, 1.25f);

    EXPECT_FLOAT_EQ(runtime->hostContext().cursor_normalized_position.x(), 0.0f);
    EXPECT_FLOAT_EQ(runtime->hostContext().cursor_normalized_position.y(), 1.0f);
    EXPECT_FLOAT_EQ(runtime->hostContext().cursor_world_position.x(), 0.0f);
    EXPECT_FLOAT_EQ(runtime->hostContext().cursor_world_position.y(), 0.0f);
}

TEST(MouseInput, CursorWorldPositionUsesSceneYAxis) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    runtime->SetCursorInput(0.25f, 0.25f);
    const auto higher = runtime->hostContext().cursor_world_position;

    runtime->SetCursorInput(0.25f, 0.75f);
    const auto lower = runtime->hostContext().cursor_world_position;

    EXPECT_FLOAT_EQ(higher.x(), 480.0f);
    EXPECT_FLOAT_EQ(higher.y(), 810.0f);
    EXPECT_FLOAT_EQ(lower.x(), 480.0f);
    EXPECT_FLOAT_EQ(lower.y(), 270.0f);
    EXPECT_GT(higher.y(), lower.y());
}

TEST(MouseInput, SceneScriptReceivesCursorCallbacks) {
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
var down = 0;
var up = 0;
var enter = 0;
var leave = 0;
var move = 0;
var click = 0;
function cursorDown(event) {
  if (event.button === 0 && input.cursorPosition.x === 0.25 && input.cursorPosition.y === 0.75) {
    down++;
  }
}
function cursorUp(event) {
  if (event.button === 0) up++;
}
function cursorEnter() { enter++; }
function cursorLeave() { leave++; }
function cursorMove() { move++; }
function cursorClick(event) {
  if (event.button === 0) click++;
}
function update() {
  if (down === 1 && up === 1 && enter === 1 && leave === 1 && move === 1 && click === 1) {
    scene.getObject('probe').visible = true;
  }
}
)JS",
        "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButton(0, true);
    runtime->DispatchCursorEnter();
    runtime->DispatchCursorMove();
    runtime->DispatchCursorDown(0);
    runtime->DispatchCursorClick(0);
    runtime->SetCursorButton(0, false);
    runtime->DispatchCursorUp(0);
    runtime->SetCursorEnter(false);
    runtime->DispatchCursorLeave();
    runtime->Tick(1.0 / 60.0);

    EXPECT_TRUE(runtime->NodeVisible("probe"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, SceneScriptReceivesCursorUpAfterPointerLeavesWindow) {
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
var down = 0;
var up = 0;
var leave = 0;
function cursorDown(event) {
  if (event.button === 0) down++;
}
function cursorUp(event) {
  if (event.button === 0) up++;
}
function cursorLeave() { leave++; }
function update() {
  if (down === 1 && up === 1 && leave === 1) {
    scene.getObject('probe').visible = true;
  }
}
)JS",
        "");
    ASSERT_EQ(runtime->sceneScriptCount(), 1u);

    runtime->SetCursorInput(0.25f, 0.75f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(1u, 1u, 0u);
    bool cursor_was_in_window = runtime->DispatchCursorFrameEvents(false);

    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0u, 0u, 1u);
    cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
    runtime->Tick(1.0 / 60.0);

    EXPECT_FALSE(cursor_was_in_window);
    EXPECT_TRUE(runtime->NodeVisible("probe"));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

} // namespace
} // namespace wallpaper
