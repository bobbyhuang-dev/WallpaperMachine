#include "Presentation/WallpaperScaling.hpp"
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

// The presented image is the camera rectangle stretched into the scaling
// viewport, which FILL pushes outside the window. Cursor coordinates have to
// follow that rectangle: mapping them onto the raw canvas compresses every hit
// box toward the screen centre on scenes whose aspect differs from the display.
TEST(MouseInput, CursorViewportMapsWindowOntoTheCroppedSceneRectangle) {
    const auto filled =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 3456, 2234, 1.0, 1.0);
    const auto crop = ComputeWallpaperCursorMapping(filled, 3840.0, 1080.0, 7680.0, 2160.0);
    ASSERT_TRUE(crop.valid);
    // A FILL crop keeps the full scene height and shows
    // window_width * scene_height / window_height scene units horizontally.
    EXPECT_NEAR(crop.size_x, 3456.0 * 2160.0 / 2234.0, 1.0);
    EXPECT_NEAR(crop.origin_x, 3840.0 - 0.5 * 3456.0 * 2160.0 / 2234.0, 1.0);
    EXPECT_NEAR(crop.origin_y, 0.0, 1.0);
    EXPECT_NEAR(crop.size_y, 2160.0, 1.0);

    const auto letterboxed =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000, 1000, 1.0, 1.0);
    const auto fit = ComputeWallpaperCursorMapping(letterboxed, 960.0, 540.0, 1920.0, 1080.0);
    ASSERT_TRUE(fit.valid);
    EXPECT_NEAR(fit.origin_x, 0.0, 1.0);
    EXPECT_NEAR(fit.size_x, 1920.0, 1.0);
    // Cursor positions over the letterbox bars stay outside the scene, and the
    // drawn content stays the camera rectangle.
    EXPECT_LT(fit.origin_y, 0.0);
    EXPECT_GT(fit.origin_y + fit.size_y, 1080.0);
    EXPECT_NEAR(fit.origin_y + 0.5 * fit.size_y, 540.0, 1.0);
    EXPECT_NEAR(fit.content_origin_x, 0.0, 1.0e-6);
    EXPECT_NEAR(fit.content_origin_y, 0.0, 1.0e-6);
    EXPECT_NEAR(fit.content_size_x, 1920.0, 1.0e-6);
    EXPECT_NEAR(fit.content_size_y, 1080.0, 1.0e-6);

    EXPECT_FALSE(ComputeWallpaperCursorMapping(filled, 3840.0, 1080.0, 0.0, 2160.0).valid);
    EXPECT_FALSE(ComputeWallpaperCursorMapping({}, 3840.0, 1080.0, 7680.0, 2160.0).valid);
}

TEST(MouseInput, LayerHitTestingFollowsWhereTheWallpaperIsPresented) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 7680,
        .canvas_height = 2160,
    });
    ASSERT_NE(runtime, nullptr);

    auto layer = std::make_shared<SceneNode>();
    layer->SetTranslate(Eigen::Vector3f(3850.0f, 865.0f, 0.0f));
    runtime->RegisterNode("layer", layer.get());
    runtime->RegisterNodeSize("layer", Eigen::Vector2f(275.0f, 134.0f));
    auto marker = std::make_shared<SceneNode>();
    marker->SetVisible(false);
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(
        R"JS(
function cursorEnter() { scene.getObject('marker').visible = true; }
function cursorLeave() { scene.getObject('marker').visible = false; }
)JS",
        "layer");

    const auto layout =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 3456, 2234, 1.0, 1.0);
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

    // Where the presented wallpaper draws a scene point, in window fractions.
    const auto screen_x = [&](double world) {
        const double fraction = (world - 3840.0) / 7680.0 + 0.5;
        return (fraction * layout.viewport_px.width + layout.viewport_px.x) / 3456.0;
    };
    const auto screen_y = [&](double world) {
        const double fraction = 0.5 - (world - 1080.0) / 2160.0;
        return (fraction * layout.viewport_px.height + layout.viewport_px.y) / 2234.0;
    };

    runtime->SetCursorEnter(true);
    bool       cursor_was_in_window = false;
    const auto hover                = [&](double world_x, double world_y) {
        runtime->SetCursorInput(static_cast<float>(screen_x(world_x)),
                                static_cast<float>(screen_y(world_y)));
        cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
        runtime->Tick(1.0 / 60.0);
        return runtime->NodeVisible("marker");
    };

    EXPECT_TRUE(hover(3850.0, 865.0));
    // Near the drawn left and right edges, far outside the canvas-relative
    // fraction the window would map to without the presentation rectangle.
    EXPECT_TRUE(hover(3850.0 - 130.0, 865.0));
    EXPECT_TRUE(hover(3850.0 + 130.0, 865.0));
    EXPECT_FALSE(hover(3850.0 + 200.0, 865.0));
    EXPECT_FALSE(hover(3850.0, 865.0 + 100.0));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A letterboxed presentation leaves window area the wallpaper never draws.
// Extrapolated coordinates there must not reach layers that extend past the
// canvas edge, or the bars behave like an invisible extension of the scene.
TEST(MouseInput, LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    // Half of this layer hangs below the canvas, so it is drawn only down to
    // the bottom edge of the wallpaper.
    auto layer = std::make_shared<SceneNode>();
    layer->SetTranslate(Eigen::Vector3f(960.0f, 40.0f, 0.0f));
    runtime->RegisterNode("layer", layer.get());
    runtime->RegisterNodeSize("layer", Eigen::Vector2f(400.0f, 200.0f));
    auto marker = std::make_shared<SceneNode>();
    marker->SetVisible(false);
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(
        R"JS(
function cursorEnter() { scene.getObject('marker').visible = true; }
function cursorLeave() { scene.getObject('marker').visible = false; }
)JS",
        "layer");

    const auto layout =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000, 1000, 1.0, 1.0);
    const auto mapping = ComputeWallpaperCursorMapping(layout, 960.0, 540.0, 1920.0, 1080.0);
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

    runtime->SetCursorEnter(true);
    bool       cursor_was_in_window = false;
    const auto hover                = [&](float x, float y) {
        runtime->SetCursorInput(x, y);
        cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
        runtime->Tick(1.0 / 60.0);
        return runtime->NodeVisible("marker");
    };

    // Bottom edge of the drawn wallpaper, over the layer.
    const double drawn_bottom_px = layout.viewport_px.y + layout.viewport_px.height;
    EXPECT_TRUE(hover(0.5f, static_cast<float>((drawn_bottom_px - 1.0) / 1000.0)));
    // Just below it, on the bar. The extrapolated scene position is still
    // inside the layer's box, but the wallpaper draws nothing there.
    runtime->SetCursorInput(0.5f, static_cast<float>((drawn_bottom_px + 8.0) / 1000.0));
    const float bar_world_y = runtime->hostContext().cursor_world_position.y();
    EXPECT_LT(bar_world_y, 0.0f);
    EXPECT_GT(bar_world_y, -60.0f);
    EXPECT_FALSE(hover(0.5f, static_cast<float>((drawn_bottom_px + 8.0) / 1000.0)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, StationarySampleRemapsEveryFrameAndRechecksLiveLayerGeometry) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width = 200,
        .canvas_height = 100,
    });
    auto layer = std::make_shared<SceneNode>();
    auto marker = std::make_shared<SceneNode>();
    layer->SetTranslate(Eigen::Vector3f(100, 50, 0));
    runtime->RegisterNode("layer", layer.get());
    runtime->RegisterNodeSize("layer", Eigen::Vector2f(20, 20));
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(R"JS(
function emit(component) {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin[component] += 1;
    marker.origin = origin;
}
function cursorEnter() { emit('x'); }
function cursorLeave() { emit('y'); }
function cursorMove() { emit('z'); }
)JS", "layer");
    // One window-normalized sample, retained by the native renderer even when
    // the Rust delivery cache suppresses all subsequent identical writes.
    const Eigen::Vector2f sample(0.5f, 0.5f);
    bool was_inside = false;
    const auto frame = [&](const CursorViewport& viewport) {
        runtime->BeginFrame();
        runtime->SetCursorViewport(viewport);
        runtime->SetCursorInput(sample.x(), sample.y());
        runtime->SetCursorEnter(true);
        was_inside = runtime->DispatchCursorFrameEvents(was_inside);
    };
    frame(CursorViewport { .origin = Eigen::Vector2f::Zero(), .size = Eigen::Vector2f(200, 100) });
    EXPECT_TRUE(runtime->hostContext().cursor_world_position.isApprox(Eigen::Vector3f(100, 50, 0)));
    EXPECT_TRUE(marker->Translate().isApprox(Eigen::Vector3f(1, 0, 1)));
    frame(CursorViewport { .origin = Eigen::Vector2f(100, 0), .size = Eigen::Vector2f(200, 100) });
    EXPECT_TRUE(runtime->hostContext().cursor_world_position.isApprox(Eigen::Vector3f(200, 50, 0)));
    EXPECT_TRUE(marker->Translate().isApprox(Eigen::Vector3f(1, 1, 1)));
    layer->SetTranslate(Eigen::Vector3f(200, 50, 0));
    frame(CursorViewport { .origin = Eigen::Vector2f(100, 0), .size = Eigen::Vector2f(200, 100) });
    EXPECT_TRUE(marker->Translate().isApprox(Eigen::Vector3f(2, 1, 2)));
    frame(CursorViewport {
        .origin = Eigen::Vector2f(100, 0), .size = Eigen::Vector2f(200, 100),
        .content_origin = Eigen::Vector2f(0, 0), .content_size = Eigen::Vector2f(100, 100),
    });
    EXPECT_TRUE(marker->Translate().isApprox(Eigen::Vector3f(2, 2, 2)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, GlobalReleaseRemainsObservableOutsidePresentedContentAndWindow) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto marker = std::make_shared<SceneNode>();
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(
        R"JS(function cursorUp() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x += 1;
    marker.origin = origin;
})JS", "");
    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0, 0, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 1.0f);
    runtime->SetCursorViewport(CursorViewport {
        .origin = Eigen::Vector2f::Zero(), .size = Eigen::Vector2f(200, 100),
        .content_origin = Eigen::Vector2f::Zero(), .content_size = Eigen::Vector2f(20, 20),
    });
    runtime->SetCursorInput(0.5f, 0.5f);
    runtime->SetCursorEnter(true);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 2.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

} // namespace
} // namespace wallpaper
